import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:zapret_launcher/src/telegram/aes_ctr.dart';
import 'package:zapret_launcher/src/telegram/mtproto.dart';
import 'package:zapret_launcher/src/telegram/upstream.dart';

Uint8List hexBytes(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List randomBytes(int n, Random r) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);

Uint8List _sha(List<int> a, List<int> b) =>
    Uint8List.fromList(sha256.convert([...a, ...b]).bytes);

Uint8List _reversed(Uint8List b) => Uint8List.fromList(b.reversed.toList());

/// Telegram Desktop со стороны прокси: первый пакет с секретом и шифры потока.
class FakeTelegramClient {
  FakeTelegramClient({
    required Uint8List secret,
    required MtprotoTransport transport,
    required int dcIndex,
    Random? random,
  }) {
    final r = random ?? Random(1);
    final init = randomBytes(64, r);
    init[0] = 0x01; // не 0xef и не начало HTTP/TLS
    init.fillRange(56, 60, transport.tagByte);
    ByteData.sublistView(init).setInt16(60, dcIndex, Endian.little);
    final prekeyIv = init.sublist(8, 56);
    _enc = DartAesCtr(
      _sha(prekeyIv.sublist(0, 32), secret),
      prekeyIv.sublist(32),
    );
    final encrypted = _enc.process(init);
    handshake = Uint8List.fromList([
      ...init.sublist(0, 56),
      ...encrypted.sublist(56),
    ]);
    final back = _reversed(prekeyIv);
    _dec = DartAesCtr(_sha(back.sublist(0, 32), secret), back.sublist(32));
  }

  late final Uint8List handshake;
  late final DartAesCtr _enc;
  late final DartAesCtr _dec;

  Uint8List encrypt(Uint8List plain) => _enc.process(plain);
  Uint8List decrypt(Uint8List data) => _dec.process(data);
}

/// Сервер Telegram со стороны прокси: разбирает первый пакет прокси (без секрета).
class FakeTelegramServer {
  FakeTelegramServer(Uint8List relayInit) {
    final keyIv = relayInit.sublist(8, 56);
    _dec = DartAesCtr(keyIv.sublist(0, 32), keyIv.sublist(32));
    final plain = _dec.process(relayInit);
    transport = MtprotoTransport.fromTag(plain, 56);
    dcIndex = ByteData.sublistView(plain).getInt16(60, Endian.little);
    final back = _reversed(keyIv);
    _enc = DartAesCtr(back.sublist(0, 32), back.sublist(32));
  }

  late final DartAesCtr _dec;
  late final DartAesCtr _enc;
  late final MtprotoTransport? transport;
  late final int dcIndex;

  Uint8List decrypt(Uint8List data) => _dec.process(data);
  Uint8List encrypt(Uint8List plain) => _enc.process(plain);
}

/// Пакет intermediate: длина (4 байта LE) и тело.
Uint8List intermediatePacket(Uint8List body) {
  final b = Uint8List(4 + body.length);
  ByteData.sublistView(b).setUint32(0, body.length, Endian.little);
  b.setAll(4, body);
  return b;
}

/// Пакет abridged: длина в словах одним байтом или 0x7f и три байта.
Uint8List abridgedPacket(Uint8List body) {
  assert(body.length % 4 == 0);
  final words = body.length ~/ 4;
  final header = words < 0x7f
      ? [words]
      : [0x7f, words & 0xff, (words >> 8) & 0xff, (words >> 16) & 0xff];
  return Uint8List.fromList([...header, ...body]);
}

/// Локальный WebSocket-сервер вместо веб-версии Telegram: проверяет первый пакет,
/// собирает присланные сообщения и отвечает на каждое — его же телом, развёрнутым.
class FakeTelegramWebSocket {
  FakeTelegramWebSocket({this.closeAfterReply = false});

  /// Ответить на первое сообщение и закрыть соединение — Telegram закрывает первым.
  final bool closeAfterReply;

  late final HttpServer _http;

  /// Первые пакеты сессий: какие DC запрашивал прокси.
  final dcIndexes = <int>[];

  /// Расшифрованные сообщения от прокси — по одному на пакет.
  final messages = <Uint8List>[];

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      FakeTelegramServer? server;
      ws.listen((m) {
        final data = Uint8List.fromList(m as List<int>);
        if (server == null) {
          server = FakeTelegramServer(data);
          dcIndexes.add(server!.dcIndex);
          return;
        }
        final plain = server!.decrypt(data);
        messages.add(plain);
        ws.add(server!.encrypt(Uint8List.fromList(plain.reversed.toList())));
        if (closeAfterReply) ws.close();
      });
    });
  }

  int get port => _http.port;

  Future<void> close() => _http.close(force: true);
}

/// Подключение прокси к [FakeTelegramWebSocket] вместо настоящего Telegram.
class LocalConnector implements TelegramConnector {
  LocalConnector(this.port, {this.available = true});

  final int port;
  final bool available;
  final targets = <TelegramTarget>[];

  @override
  Future<Upstream?> connect(TelegramTarget target) async {
    targets.add(target);
    if (!available) return null;
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/apiws');
    return WebSocketUpstream(ws, 'WebSocket');
  }

  @override
  void close() {}
}

/// Читает из сокета ровно [n] байт.
class SocketReader {
  SocketReader(Stream<Uint8List> s) {
    _sub = s.listen(
      (d) {
        _buf.add(d);
        _notify();
      },
      onDone: () {
        _done = true;
        _notify();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder();
  Completer<void>? _wake;
  bool _done = false;

  bool get closed => _done;

  void _notify() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List> read(int n) async {
    while (_buf.length < n) {
      if (_done) throw StateError('Сокет закрыт: есть ${_buf.length} из $n');
      _wake = Completer<void>();
      await _wake!.future.timeout(const Duration(seconds: 5));
    }
    final all = _buf.takeBytes();
    _buf.add(all.sublist(n));
    return all.sublist(0, n);
  }

  /// Ждёт, пока сокет закроют с той стороны.
  Future<void> waitClosed() async {
    while (!_done) {
      _wake = Completer<void>();
      await _wake!.future.timeout(const Duration(seconds: 5));
    }
  }

  void cancel() => _sub.cancel();
}

/// AesCtr, чтобы в тестах сравнивать реализации.
AesCtr dartAes(Uint8List key, Uint8List iv) => AesCtr(key, iv, native: false);
