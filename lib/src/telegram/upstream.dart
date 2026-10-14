import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'mtproto.dart';

/// Соединение с Telegram, через которое идёт одна сессия клиента.
abstract interface class Upstream {
  /// Как подключились — для журнала: «WebSocket», «TCP».
  String get route;

  /// Каждое сообщение — отдельный пакет MTProto (WebSocket) или сплошной поток (TCP).
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

/// Адреса дата-центров для прямого TCP — как DC_DEFAULT_IPS у Flowseal.
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

/// Подключение как у tg-ws-proxy: WebSocket к веб-версии Telegram по известному IP
/// (DNS не нужен), при сбросе — с чужим именем сервера; если WebSocket для этого DC
/// нет или он не открылся — напрямую по TCP.
class DirectTelegramConnector implements TelegramConnector {
  DirectTelegramConnector({
    Map<int, String> webSocketIps = defaultWebSocketIps,
    this.timeout = const Duration(seconds: 8),
    this._frontingFirst = false,
  }) : _wsIps = webSocketIps;

  final Map<int, String> _wsIps;
  final Duration timeout;

  /// Последний раз помогла подмена имени — с неё и начинаем.
  bool _frontingFirst;

  /// TCP-адрес → когда пробовать снова (после неудач — всё реже, до часа).
  final _tcpRetryAfter = <String, DateTime>{};
  final _tcpFailures = <String, int>{};

  @override
  Future<Upstream?> connect(TelegramTarget target) async {
    final ip = _wsIps[target.dc == 203 ? 2 : target.dc];
    if (ip != null) {
      for (final domain in webSocketDomains(target)) {
        for (final fronted in _frontingFirst ? [true, false] : [false, true]) {
          try {
            final (ws, tls) = await _openWebSocket(
              ip,
              domain,
              path: target.test ? '/apiws_test' : '/apiws',
              sni: fronted ? frontingSni : null,
            );
            _frontingFirst = fronted;
            return WebSocketUpstream(
              ws,
              fronted ? 'WebSocket, $frontingSni' : 'WebSocket',
              socket: tls,
            );
          } on Object {
            continue;
          }
        }
      }
    }
    return _tcp(target);
  }

  Future<Upstream?> _tcp(TelegramTarget target) async {
    final ip = (target.test ? _testDcIps : telegramDcIps)[target.dc];
    if (ip == null) return null;
    final retry = _tcpRetryAfter[ip];
    if (retry != null && DateTime.now().isBefore(retry)) return null;
    try {
      final socket = await Socket.connect(ip, 443, timeout: timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _tcpFailures.remove(ip);
      _tcpRetryAfter.remove(ip);
      return SocketUpstream(socket);
    } on Object {
      final n = (_tcpFailures[ip] ?? 0) + 1;
      _tcpFailures[ip] = n;
      final seconds = (30 * (1 << (n - 1).clamp(0, 7))).clamp(30, 3600);
      _tcpRetryAfter[ip] = DateTime.now().add(Duration(seconds: seconds));
      return null;
    }
  }

  /// WebSocket к [ip] с именем [domain] в Host; в TLS — [sni] или то же имя.
  /// Вместе с WebSocket — его TLS-сокет: им соединение рвётся сразу.
  Future<(WebSocket, SecureSocket?)> _openWebSocket(
    String ip,
    String domain, {
    required String path,
    String? sni,
  }) async {
    SecureSocket? tls;
    final client = HttpClient()
      ..userAgent = null
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = timeout
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        final raw = Socket.connect(ip, 443, timeout: timeout);
        return ConnectionTask.fromSocket(
          raw.then((socket) async {
            socket.setOption(SocketOption.tcpNoDelay, true);
            return tls = await SecureSocket.secure(
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
        'wss://$domain$path',
        protocols: const ['binary'],
        customClient: client,
        compression: CompressionOptions.compressionOff,
      ).timeout(timeout);
      client.close();
      return (ws, tls);
    } on Object {
      client.close(force: true);
      tls?.destroy();
      rethrow;
    }
  }

  @override
  void close() {}
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
  WebSocketUpstream(this._ws, this.route, {this._socket});

  final WebSocket _ws;
  final SecureSocket? _socket;

  @override
  final String route;

  @override
  bool get framed => true;

  @override
  Stream<Uint8List> get incoming => _ws
      .where((m) => m is List<int>)
      .map((m) => m is Uint8List ? m : Uint8List.fromList(m as List<int>));

  @override
  Future<void> send(Stream<Uint8List> outgoing) => _ws.addStream(outgoing);

  @override
  void close() {
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
