import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cloudflare.dart';
import 'mtproto.dart';

/// Соединение с Telegram, через которое идёт одна сессия клиента.
abstract interface class Upstream {
  /// Как подключились — для журнала: «WebSocket», «Cloudflare», «TCP».
  String get route;

  /// Каждое сообщение — отдельный пакет MTProto (WebSocket) или сплошной поток.
  bool get framed;

  /// Данные от Telegram.
  Stream<Uint8List> get incoming;

  /// Отправляет поток в Telegram; завершается, когда он кончился.
  Future<void> send(Stream<Uint8List> outgoing);

  void close();
}

/// Подключается к Telegram для клиента; null — не вышло ни одним способом.
abstract interface class TelegramConnector {
  Future<Upstream?> connect(TelegramTarget target);

  void close();
}

/// Адреса дата-центров для прямого TCP и CF Worker — как DC_DEFAULT_IPS у Flowseal.
const telegramDcIps = {
  1: '149.154.175.50',
  2: '149.154.167.51',
  3: '149.154.175.100',
  4: '149.154.167.91',
  5: '149.154.171.5',
  203: '91.105.192.100',
};
const _testDcIps = {
  1: '149.154.175.10',
  2: '149.154.167.40',
  3: '149.154.175.117',
};

/// Адрес веб-версии Telegram, через который WebSocket работает для DC 2 и 4 —
/// по умолчанию у Flowseal (--dc-ip 2:… --dc-ip 4:…).
const defaultWebSocketIps = {2: '149.154.167.220', 4: '149.154.167.220'};

/// Чужое имя сервера в TLS — когда соединения с именем telegram.org сбрасывают.
/// Тот же, что у Flowseal.
const frontingSni = 'sprinthost.ru';

/// Открывает WebSocket к [host] с именем [domain] в Host; в TLS — [sni] или то же
/// имя; без [secure] — обычный HTTP на порт 80. Вместе с WebSocket — его сокет.
typedef WebSocketOpener = Future<(WebSocket, Socket?)> Function(
  String host,
  String domain, {
  required String path,
  String? sni,
  bool secure,
});

/// SO_SNDBUF и SO_RCVBUF — как --buf-kb у tg-ws-proxy. Не вышло — остаются системные.
void setSocketBuffers(Socket socket, int bytes) {
  if (bytes <= 0) return;
  final (send, receive) = Platform.isLinux || Platform.isAndroid
      ? (7, 8)
      : (0x1001, 0x1002);
  try {
    for (final option in [send, receive]) {
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelSocket, option, bytes),
      );
    }
  } on Object {
    // Не поддерживается — не страшно.
  }
}

/// Подключение как у tg-ws-proxy: WebSocket к веб-версии Telegram по известному IP
/// (DNS не нужен) — готовый из пула или новый, при сбросе — с чужим именем сервера;
/// если WebSocket для этого DC нет или он не открылся — CF Worker, Cloudflare-прокси
/// и в конце напрямую по TCP.
class DirectTelegramConnector implements TelegramConnector {
  DirectTelegramConnector({
    Map<int, String> webSocketIps = defaultWebSocketIps,
    this.timeout = const Duration(seconds: 8),
    this.cloudflare,
    this.workerDomains = const [],
    this.noSecure = false,
    this.poolSize = 4,
    this.bufferBytes = 256 * 1024,
    this.onDebug,
    WebSocketOpener? openWebSocket,
    this._connectTcp,
    this._frontingFirst = false,
  }) : _wsIps = webSocketIps,
       _opener = openWebSocket {
    _pool = WebSocketPool(size: poolSize, open: _openDirect, onDebug: onDebug);
  }

  final Map<int, String> _wsIps;
  final Duration timeout;

  /// Домены Cloudflare-прокси; null или пусто — без него.
  final CloudflareDomains? cloudflare;

  /// Домены CF Worker; пусто — без него.
  final List<String> workerDomains;

  /// CF-прокси и CF Worker — по HTTP на порт 80, без TLS.
  final bool noSecure;

  /// Готовых WebSocket на DC; 0 — прямого WebSocket нет совсем, как у tg-ws-proxy.
  final int poolSize;
  final int bufferBytes;

  /// Подробности для лога (включён подробный лог).
  final void Function(String line)? onDebug;

  late final WebSocketPool _pool;

  /// Подменяются в тестах.
  final WebSocketOpener? _opener;
  final Future<Socket> Function(String ip)? _connectTcp;

  /// Сколько доменов пробовать за одно подключение: если Cloudflare закрыт целиком,
  /// перебор всех доменов задержал бы каждое подключение на минуты.
  static const cloudflareTries = 3;

  /// После неудачи Cloudflare пробуем снова всё реже, до часа.
  DateTime? _cloudflareRetryAfter;
  int _cloudflareFailures = 0;

  /// Worker → когда пробовать снова; удачный пробуем первым.
  final _workerRetryAfter = <String, DateTime>{};
  String? _workerLast;

  /// Последний раз помогла подмена имени — с неё и начинаем.
  bool _frontingFirst;

  /// TCP-адрес → когда пробовать снова (после неудач — всё реже, до часа).
  final _tcpRetryAfter = <String, DateTime>{};
  final _tcpFailures = <String, int>{};

  /// Начать держать готовые WebSocket для всех DC из DC → IP: обычные и для медиа.
  void warmup() {
    if (poolSize <= 0) return;
    _pool.start([
      for (final dc in _wsIps.keys) ...[
        TelegramTarget(dc),
        TelegramTarget(dc, media: true),
      ],
    ]);
  }

  /// WebSocket к веб-версии — только готовый из пула, как у tg-ws-proxy. Пусто —
  /// сразу запасные пути, а пул пополняется в фоне: если веб-версия не отвечает,
  /// новое подключение ждало бы её до 32 с, и Telegram сдавался бы раньше.
  @override
  Future<Upstream?> connect(TelegramTarget target) async {
    if (poolSize > 0 && _wsIp(target) != null) {
      final pooled = _pool.take(target);
      if (pooled != null) return pooled;
    }
    return await _worker(target) ??
        await _cloudflare(target) ??
        await _tcp(target);
  }

  String? _wsIp(TelegramTarget target) =>
      _wsIps[target.dc] ?? (target.dc == 203 ? _wsIps[2] : null);

  /// WebSocket к веб-версии: для медиа сначала kwsN-1, имя — своё или чужое.
  Future<WebSocketUpstream?> _openDirect(TelegramTarget target) async {
    final ip = _wsIp(target);
    if (ip == null) return null;
    for (final domain in webSocketDomains(target)) {
      for (final fronted in _frontingFirst ? [true, false] : [false, true]) {
        try {
          final (ws, socket) = await (_opener ?? _openWebSocket)(
            ip,
            domain,
            path: target.test ? '/apiws_test' : '/apiws',
            sni: fronted ? frontingSni : null,
          );
          _frontingFirst = fronted;
          return WebSocketUpstream(
            ws,
            fronted ? 'WebSocket, $frontingSni' : 'WebSocket',
            socket: socket,
          );
        } on Object catch (e) {
          _debug(
            '$target: WebSocket $domain через $ip'
            '${fronted ? ' с именем $frontingSni' : ''} не открылся: $e',
          );
        }
      }
    }
    return null;
  }

  /// CF Worker: WebSocket к домену Worker, а он — TCP к DC по адресу из запроса.
  /// Поток не режется на пакеты — Worker пересылает его как есть (как у tg-ws-proxy).
  Future<Upstream?> _worker(TelegramTarget target) async {
    if (workerDomains.isEmpty) return null;
    final dst = (target.test ? _testDcIps : telegramDcIps)[target.dc];
    if (dst == null) return null;
    final now = DateTime.now();
    final order = [
      ?_workerLast,
      for (final d in workerDomains)
        if (d != _workerLast) d,
    ];
    for (final domain in order) {
      final retry = _workerRetryAfter[domain];
      if (retry != null && now.isBefore(retry)) continue;
      try {
        final (ws, socket) = await (_opener ?? _openWebSocket)(
          domain,
          domain,
          path: '/apiws?dst=$dst&dc=${target.dc}',
          secure: !noSecure,
        );
        _workerLast = domain;
        _workerRetryAfter.remove(domain);
        return WebSocketUpstream(
          ws,
          'Cloudflare Worker',
          socket: socket,
          framed: false,
        );
      } on Object catch (e) {
        _workerRetryAfter[domain] = now.add(const Duration(minutes: 1));
        _debug('$target: CF Worker не открылся: $e');
      }
    }
    return null;
  }

  /// WebSocket через Cloudflare: kwsN.<домен>, сертификат — самого домена.
  /// Имена доменов в лог не пишем.
  Future<Upstream?> _cloudflare(TelegramTarget target) async {
    final domains = cloudflare;
    if (domains == null || domains.isEmpty || target.test) return null;
    final retry = _cloudflareRetryAfter;
    if (retry != null && DateTime.now().isBefore(retry)) return null;
    for (final base in domains.forDc(target.dc).take(cloudflareTries)) {
      final host = 'kws${target.dc}.$base';
      try {
        final (ws, socket) = await (_opener ?? _openWebSocket)(
          host,
          host,
          path: '/apiws',
          secure: !noSecure,
        );
        domains.use(target.dc, base);
        _cloudflareFailures = 0;
        _cloudflareRetryAfter = null;
        return WebSocketUpstream(ws, 'Cloudflare', socket: socket);
      } on Object catch (e) {
        _debug('$target: Cloudflare не открылся: ${e.runtimeType}');
      }
    }
    final n = ++_cloudflareFailures;
    final seconds = (30 * (1 << (n - 1).clamp(0, 7))).clamp(30, 3600);
    _cloudflareRetryAfter = DateTime.now().add(Duration(seconds: seconds));
    _debug('Cloudflare недоступен — следующая попытка через $seconds с');
    return null;
  }

  Future<Upstream?> _tcp(TelegramTarget target) async {
    final ip = (target.test ? _testDcIps : telegramDcIps)[target.dc];
    if (ip == null) return null;
    final retry = _tcpRetryAfter[ip];
    if (retry != null && DateTime.now().isBefore(retry)) return null;
    try {
      final socket =
          await (_connectTcp?.call(ip) ??
              Socket.connect(ip, 443, timeout: timeout));
      socket.setOption(SocketOption.tcpNoDelay, true);
      setSocketBuffers(socket, bufferBytes);
      _tcpFailures.remove(ip);
      _tcpRetryAfter.remove(ip);
      return SocketUpstream(socket);
    } on Object catch (e) {
      final n = (_tcpFailures[ip] ?? 0) + 1;
      _tcpFailures[ip] = n;
      final seconds = (30 * (1 << (n - 1).clamp(0, 7))).clamp(30, 3600);
      _tcpRetryAfter[ip] = DateTime.now().add(Duration(seconds: seconds));
      _debug('$target: TCP к $ip не открылся ($e), пауза $seconds с');
      return null;
    }
  }

  /// WebSocket к [host] (IP или имя — тогда через DNS) с именем [domain] в Host.
  Future<(WebSocket, Socket?)> _openWebSocket(
    String host,
    String domain, {
    required String path,
    String? sni,
    bool secure = true,
  }) async {
    Socket? opened;
    final client = HttpClient()
      ..userAgent = null
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = timeout
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        final raw = Socket.connect(host, secure ? 443 : 80, timeout: timeout);
        return ConnectionTask.fromSocket(
          raw.then((socket) async {
            socket.setOption(SocketOption.tcpNoDelay, true);
            setSocketBuffers(socket, bufferBytes);
            if (!secure) return opened = socket;
            return opened = await SecureSocket.secure(
              socket,
              host: sni ?? domain,
              // С чужим именем сертификат не совпадёт: принимаем сертификат
              // веб-версии Telegram. Подменить содержимое и так нельзя — MTProto
              // зашифрован ключами Telegram, TLS здесь только обёртка.
              onBadCertificate: sni == null
                  ? null
                  : (cert) => cert.subject.contains('telegram.org'),
            );
          }),
          () => raw.then((s) => s.destroy()).ignore(),
        );
      };
    try {
      final ws = await WebSocket.connect(
        '${secure ? 'wss' : 'ws'}://$domain$path',
        protocols: const ['binary'],
        customClient: client,
        compression: CompressionOptions.compressionOff,
      ).timeout(timeout);
      client.close();
      return (ws, opened);
    } on Object {
      client.close(force: true);
      opened?.destroy();
      rethrow;
    }
  }

  void _debug(String line) => onDebug?.call(line);

  @override
  void close() => _pool.close();
}

/// Готовые WebSocket к веб-версии — как ws_pool у tg-ws-proxy: по [size] на каждый
/// DC (обычные и медиа отдельно), старше [maxAge] или закрытые заменяются новыми.
/// Не открылись — следующая попытка через 1 с, 2 с, 4 с… до часа.
class WebSocketPool {
  WebSocketPool({
    required this.size,
    required this.open,
    this.maxAge = const Duration(seconds: 120),
    this.checkEvery = const Duration(seconds: 5),
    this.onDebug,
  });

  final int size;
  final Future<WebSocketUpstream?> Function(TelegramTarget target) open;
  final Duration maxAge;
  final Duration checkEvery;
  final void Function(String line)? onDebug;

  final _idle = <String, List<(WebSocketUpstream, DateTime)>>{};
  final _targets = <String, TelegramTarget>{};
  final _refilling = <String>{};
  final _retryAfter = <String, DateTime>{};
  final _failures = <String, int>{};
  Timer? _timer;
  bool _closed = false;

  bool get started => _timer != null;

  /// Готовых сейчас для [target] — для тестов и лога.
  int ready(TelegramTarget target) => _idle[_key(target)]?.length ?? 0;

  static String _key(TelegramTarget t) => '${t.dc}|${t.media}|${t.test}';

  void start(Iterable<TelegramTarget> targets) {
    if (size <= 0 || _closed) return;
    for (final t in targets) {
      _targets[_key(t)] = t;
    }
    _timer ??= Timer.periodic(checkEvery, (_) => _check());
    _check();
  }

  /// Готовый WebSocket или null; взятый пул сразу пополняет.
  WebSocketUpstream? take(TelegramTarget target) {
    if (!started) return null;
    final key = _key(target);
    _targets[key] = target;
    final bucket = _idle[key];
    WebSocketUpstream? found;
    while (bucket != null && bucket.isNotEmpty) {
      final (ws, created) = bucket.removeAt(0);
      if (_stale(ws, created)) {
        ws.close();
        continue;
      }
      found = ws;
      break;
    }
    unawaited(_refill(target));
    return found;
  }

  bool _stale(WebSocketUpstream ws, DateTime created) =>
      !ws.isOpen || DateTime.now().difference(created) >= maxAge;

  void _check() {
    for (final MapEntry(key: key, value: target) in _targets.entries) {
      _idle[key]?.removeWhere((e) {
        final stale = _stale(e.$1, e.$2);
        if (stale) e.$1.close();
        return stale;
      });
      unawaited(_refill(target));
    }
  }

  Future<void> _refill(TelegramTarget target) async {
    final key = _key(target);
    if (_closed || size <= 0 || _refilling.contains(key)) return;
    final retry = _retryAfter[key];
    if (retry != null && DateTime.now().isBefore(retry)) return;
    final bucket = _idle.putIfAbsent(key, () => []);
    final needed = size - bucket.length;
    if (needed <= 0) return;
    _refilling.add(key);
    try {
      final opened = await Future.wait([
        for (var i = 0; i < needed; i++)
          open(
            target,
          ).then<WebSocketUpstream?>((ws) => ws, onError: (Object _) => null),
      ]);
      var connected = 0;
      for (final ws in opened) {
        if (ws == null) continue;
        if (_closed) {
          ws.close();
          continue;
        }
        bucket.add((ws, DateTime.now()));
        connected++;
      }
      if (connected > 0) {
        _failures.remove(key);
        _retryAfter.remove(key);
      } else {
        final n = (_failures[key] ?? 0) + 1;
        _failures[key] = n;
        final seconds = min(1 << min(n - 1, 12), 3600);
        _retryAfter[key] = DateTime.now().add(Duration(seconds: seconds));
        onDebug?.call(
          'Пул WebSocket для $target не пополнился, пауза $seconds с',
        );
      }
    } finally {
      _refilling.remove(key);
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    for (final bucket in _idle.values) {
      for (final (ws, _) in bucket) {
        ws.close();
      }
    }
    _idle.clear();
  }
}

/// Имена WebSocket веб-версии для DC: у медиа сначала отдельный сервер (kwsN-1).
List<String> webSocketDomains(TelegramTarget target) {
  final dc = target.dc == 203 ? 2 : target.dc;
  return [
    if (target.media) 'kws$dc-1.web.telegram.org',
    'kws$dc.web.telegram.org',
  ];
}

class WebSocketUpstream implements Upstream {
  /// Поток WebSocket слушается сразу: иначе Dart держит сокет на паузе и не
  /// замечает, что сервер закрыл соединение, — пул отдал бы мёртвое.
  WebSocketUpstream(this._ws, this.route, {this._socket, this.framed = true}) {
    final sub = _ws.listen(
      (m) {
        if (m is List<int>) {
          _incoming.add(m is Uint8List ? m : Uint8List.fromList(m));
        }
      },
      onError: (Object e, StackTrace st) {
        _open = false;
        _incoming
          ..addError(e, st)
          ..close();
      },
      onDone: () {
        _open = false;
        _incoming.close();
      },
      cancelOnError: true,
    );
    _incoming
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.cancel;
  }

  final WebSocket _ws;
  final Socket? _socket;
  final _incoming = StreamController<Uint8List>();
  bool _open = true;

  @override
  final String route;

  @override
  final bool framed;

  /// Соединение живо — пул может его отдать.
  bool get isOpen => _open && _ws.readyState == WebSocket.open;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Stream<Uint8List> outgoing) => _ws.addStream(outgoing);

  @override
  void close() {
    _open = false;
    try {
      _ws.close().ignore();
    } on StateError {
      // К WebSocket ещё привязан поток клиента (Telegram закрыл первым) —
      // close() так нельзя; рвём соединение ниже.
    }
    _socket?.destroy();
  }
}

class SocketUpstream implements Upstream {
  SocketUpstream(this._socket);

  final Socket _socket;

  @override
  String get route => 'TCP';

  @override
  bool get framed => false;

  @override
  Stream<Uint8List> get incoming => _socket;

  @override
  Future<void> send(Stream<Uint8List> outgoing) =>
      _socket.addStream(outgoing).then((_) => _socket.flush());

  @override
  void close() => _socket.destroy();
}
