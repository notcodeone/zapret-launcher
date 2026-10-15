import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart' show defaultTelegramProxyPort;
import 'mtproto.dart';
import 'upstream.dart';

/// Счётчики прокси — для страницы Telegram и журнала.
class TelegramProxyStats {
  const TelegramProxyStats({
    this.active = 0,
    this.total = 0,
    this.webSocket = 0,
    this.cloudflare = 0,
    this.tcp = 0,
    this.failed = 0,
    this.badHandshakes = 0,
    this.bytesUp = 0,
    this.bytesDown = 0,
  });

  /// Открытые сейчас соединения Telegram с прокси.
  final int active;
  final int total;

  /// Сессии через WebSocket к веб-версии, через Cloudflare-прокси и напрямую по TCP.
  final int webSocket;
  final int cloudflare;
  final int tcp;

  /// Не удалось подключиться к Telegram ни одним способом.
  final int failed;

  /// Неверный секрет или не MTProto: в Telegram сохранена старая ссылка.
  final int badHandshakes;
  final int bytesUp;
  final int bytesDown;

  Map<String, int> toMap() => {
    'active': active,
    'total': total,
    'webSocket': webSocket,
    'cloudflare': cloudflare,
    'tcp': tcp,
    'failed': failed,
    'badHandshakes': badHandshakes,
    'bytesUp': bytesUp,
    'bytesDown': bytesDown,
  };

  factory TelegramProxyStats.fromMap(Map<Object?, Object?> m) {
    int v(String k) => m[k] as int? ?? 0;
    return TelegramProxyStats(
      active: v('active'),
      total: v('total'),
      webSocket: v('webSocket'),
      cloudflare: v('cloudflare'),
      tcp: v('tcp'),
      failed: v('failed'),
      badHandshakes: v('badHandshakes'),
      bytesUp: v('bytesUp'),
      bytesDown: v('bytesDown'),
    );
  }
}

/// Локальный MTProto-прокси: Telegram Desktop подключается к нему, а он — к Telegram
/// через WebSocket веб-версии. Работает в том изоляте, где запущен.
class TelegramProxyServer {
  TelegramProxyServer({
    required this.secret,
    this.host = '127.0.0.1',
    this.port = defaultTelegramProxyPort,
    this.bufferBytes = 256 * 1024,
    TelegramConnector? connector,
    this.onLog,
    this.onDetail,
    this.handshakeTimeout = const Duration(seconds: 10),
  }) : _connector = connector ?? DirectTelegramConnector() {
    if (secret.length != 16) {
      throw ArgumentError.value(secret.length, 'secret', '16 байт');
    }
  }

  final Uint8List secret;
  final String host;
  final int port;

  /// Буфер сокетов Telegram Desktop ↔ прокси (buf_kb у tg-ws-proxy).
  final int bufferBytes;
  final TelegramConnector _connector;
  final Duration handshakeTimeout;

  /// Строки для журнала: подключения, ошибки.
  final void Function(String line)? onLog;

  /// Только в файл лога: итог каждой сессии.
  final void Function(String line)? onDetail;

  ServerSocket? _server;
  final _clients = <Socket>{};

  int _active = 0;
  int _total = 0;
  int _ws = 0;
  int _cf = 0;
  int _tcp = 0;
  int _failed = 0;
  int _bad = 0;
  int _up = 0;
  int _down = 0;

  /// Порт, который реально слушаем (при [port] 0 — выбранный системой).
  int get boundPort => _server?.port ?? port;

  TelegramProxyStats get stats => TelegramProxyStats(
    active: _active,
    total: _total,
    webSocket: _ws,
    cloudflare: _cf,
    tcp: _tcp,
    failed: _failed,
    badHandshakes: _bad,
    bytesUp: _up,
    bytesDown: _down,
  );

  /// Бросает SocketException, если порт занят.
  Future<void> start() async {
    _server = await ServerSocket.bind(host, port);
    _server!.listen(
      _accept,
      onError: (Object e) => _log('Ошибка приёма подключения: $e'),
    );
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    for (final c in _clients.toList()) {
      c.destroy();
    }
    _clients.clear();
    _connector.close();
  }

  void _accept(Socket client) {
    _clients.add(client);
    _active++;
    _total++;
    unawaited(
      _serve(client)
          .catchError((Object e) => _log('Сессия оборвалась: $e'))
          .whenComplete(() {
            _active--;
            _clients.remove(client);
            client.destroy();
          }),
    );
  }

  Future<void> _serve(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);
    setSocketBuffers(client, bufferBytes);
    final Uint8List init;
    final Stream<Uint8List> rest;
    try {
      (init, rest) = await readHead(
        client,
        handshakeLength,
      ).timeout(handshakeTimeout);
    } on Object {
      return; // Закрыли, не поздоровавшись, или молчат.
    }

    final hello = ClientHandshake.parse(init, secret);
    if (hello == null) {
      _bad++;
      _log('Чужое подключение: неверный секрет или не MTProto');
      return;
    }
    final target = hello.target;
    final relayInit = relayHandshake(hello.transport, target);
    final ciphers = SessionCiphers(hello, secret, relayInit);
    Upstream? up;
    try {
      up = await _connector.connect(target);
      if (up == null) {
        _failed++;
        _log(
          '$target: Telegram недоступен ни через WebSocket, ни через '
          'Cloudflare, ни напрямую',
        );
        return;
      }
      switch (up.route) {
        case 'TCP':
          _tcp++;
        case final r when r.startsWith('Cloudflare'):
          _cf++;
        default:
          _ws++;
      }
      _log('$target: ${up.route}');
      final started = DateTime.now();
      final (sent, received) = await _bridge(
        client,
        rest,
        up,
        ciphers,
        hello.transport,
        relayInit,
      );
      final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
      onDetail?.call(
        '$target, ${up.route}: сессия закрыта — отправлено ${_size(sent)}, '
        'получено ${_size(received)} за ${seconds.toStringAsFixed(1)} с',
      );
    } finally {
      up?.close();
      ciphers.dispose();
    }
  }

  /// Пересылка в обе стороны, пока одна из сторон не закроется.
  /// Итог — сколько байт отправлено в Telegram и получено от него.
  Future<(int, int)> _bridge(
    Socket client,
    Stream<Uint8List> fromClient,
    Upstream up,
    SessionCiphers ciphers,
    MtprotoTransport transport,
    Uint8List relayInit,
  ) async {
    final splitter = up.framed ? PacketSplitter(transport) : null;
    var sent = 0;
    var received = 0;

    Stream<Uint8List> outgoing() async* {
      yield relayInit;
      await for (final chunk in fromClient) {
        _up += chunk.length;
        sent += chunk.length;
        if (splitter == null) {
          yield ciphers.upstream(chunk);
          continue;
        }
        late Uint8List plain;
        final cipher = ciphers.upstream(chunk, (p) => plain = p);
        for (final part in splitter.split(cipher, plain)) {
          yield part;
        }
      }
      if (splitter != null) {
        for (final part in splitter.flush()) {
          yield part;
        }
      }
    }

    final toTelegram = up.send(outgoing());
    final toClient = client.addStream(
      up.incoming.map((data) {
        _down += data.length;
        received += data.length;
        return ciphers.downstream(data);
      }),
    );
    try {
      await Future.any([toTelegram, toClient]);
    } on Object {
      // Обрыв с любой стороны — просто конец сессии.
    }
    toTelegram.ignore();
    toClient.ignore();
    return (sent, received);
  }

  void _log(String line) => onLog?.call(line);

  static String _size(int bytes) => bytes < 1024
      ? '$bytes Б'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} КБ'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ';
}

/// Первые [length] байт потока и всё остальное — отдельным потоком. Пока остаток
/// не слушают, сокет на паузе: данные не теряются и не копятся.
Future<(Uint8List, Stream<Uint8List>)> readHead(
  Stream<Uint8List> source,
  int length,
) {
  final done = Completer<(Uint8List, Stream<Uint8List>)>();
  final buffer = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> sub;
  sub = source.listen(
    (chunk) {
      buffer.add(chunk);
      if (buffer.length < length) return;
      sub.pause();
      final all = buffer.takeBytes();
      late final StreamController<Uint8List> rest;
      rest = StreamController<Uint8List>(
        onListen: () {
          if (all.length > length) rest.add(Uint8List.sublistView(all, length));
          sub
            ..onData(rest.add)
            ..onError(rest.addError)
            ..onDone(rest.close)
            ..resume();
        },
        onPause: sub.pause,
        onResume: sub.resume,
        onCancel: sub.cancel,
      );
      done.complete((Uint8List.sublistView(all, 0, length), rest.stream));
    },
    onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    },
    onDone: () {
      if (!done.isCompleted) {
        done.completeError(const SocketException('Соединение закрыто'));
      }
    },
  );
  return done.future.catchError((Object e) {
    sub.cancel();
    throw e;
  });
}
