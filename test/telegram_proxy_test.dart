import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapret_launcher/src/telegram/aes_ctr.dart';
import 'package:zapret_launcher/src/telegram/mtproto.dart';
import 'package:zapret_launcher/src/telegram/proxy_server.dart';
import 'package:zapret_launcher/src/telegram/telegram_proxy.dart';
import 'package:zapret_launcher/src/telegram/upstream.dart';

import 'telegram_helpers.dart';

void main() {
  group('AES-CTR', () {
    test('эталон NIST SP 800-38A F.5.5 (CTR-AES256)', () {
      final aes = dartAes(
        hexBytes(
          '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4',
        ),
        hexBytes('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'),
      );
      final out = aes.process(
        hexBytes(
          '6bc1bee22e409f96e93d7e117393172a'
          'ae2d8a571e03ac9c9eb76fac45af8e51'
          '30c81c46a35ce411e5fbc1191a0a52ef'
          'f69f2445df4f9b17ad2b417be66c3710',
        ),
      );
      expect(
        toHex(out),
        '601ec313775789a5b7a7f504bbf3d228'
        'f443e3ca4d62b59aca84e990cacaf5c5'
        '2b0930daa23de94ce87017ba2d84988d'
        'dfc9c58db67aada613c2dd08457941a6',
      );
    });

    test('эталоны FIPS-197: блок AES-128 и AES-256', () {
      // Гамма CTR для первого блока — зашифрованный IV.
      final pt = hexBytes('00112233445566778899aabbccddeeff');
      final k128 = Uint8List.fromList(List.generate(16, (i) => i));
      final k256 = Uint8List.fromList(List.generate(32, (i) => i));
      expect(
        toHex(dartAes(k128, pt).process(Uint8List(16))),
        '69c4e0d86a7b0430d8cdb78070b4c55a',
      );
      expect(
        toHex(dartAes(k256, pt).process(Uint8List(16))),
        '8ea2b7ca516745bfeafc49904b496089',
      );
    });

    test('куски любой длины дают тот же поток, счётчик переносится', () {
      final r = Random(7);
      final key = randomBytes(32, r);
      // Младшие байты счётчика у края — проверяем перенос в старшие.
      final iv = hexBytes('00000000000000000000fffffffffffe');
      final data = randomBytes(5000, r);
      final whole = dartAes(key, iv).process(data);
      final aes = dartAes(key, iv);
      final parts = <int>[];
      var i = 0;
      while (i < data.length) {
        final n = min(r.nextInt(70), data.length - i);
        parts.addAll(aes.process(Uint8List.sublistView(data, i, i + n)));
        i += n;
      }
      expect(parts, whole);
    });

    test('CNG и Dart совпадают', () {
      final r = Random(3);
      final key = randomBytes(32, r);
      final iv = randomBytes(16, r);
      final data = randomBytes(100000, r);
      final dart = dartAes(key, iv);
      final cng = AesCtr(key, iv, native: true);
      expect(cng, isNot(isA<DartAesCtr>()), reason: 'CNG недоступен');
      var i = 0;
      while (i < data.length) {
        final n = min(1 + r.nextInt(20000), data.length - i);
        final chunk = Uint8List.sublistView(data, i, i + n);
        expect(cng.process(chunk), dart.process(chunk));
        i += n;
      }
      cng.dispose();
    }, skip: Platform.isWindows ? false : 'CNG есть только в Windows');
  });

  group('рукопожатие', () {
    final secret = hexBytes('0123456789abcdef0123456789abcdef');

    test('прокси понимает первый пакет клиента', () {
      for (final (index, dc, media, test) in [
        (2, 2, false, false),
        (-4, 4, true, false),
        (10002, 2, false, true),
        (-10001, 1, true, true),
      ]) {
        final client = FakeTelegramClient(
          secret: secret,
          transport: MtprotoTransport.paddedIntermediate,
          dcIndex: index,
        );
        final hello = ClientHandshake.parse(client.handshake, secret)!;
        expect(hello.transport, MtprotoTransport.paddedIntermediate);
        expect(hello.target.dc, dc);
        expect(hello.target.media, media);
        expect(hello.target.test, test);
      }
    });

    test('чужой секрет — не наш клиент', () {
      final client = FakeTelegramClient(
        secret: secret,
        transport: MtprotoTransport.abridged,
        dcIndex: 2,
      );
      final other = hexBytes('ffeeddccbbaa99887766554433221100');
      expect(ClientHandshake.parse(client.handshake, other), isNull);
    });

    test('первый пакет для Telegram: метка, DC и без запретных начал', () {
      final r = Random(11);
      for (var i = 0; i < 200; i++) {
        final init = relayHandshake(
          MtprotoTransport.intermediate,
          const TelegramTarget(4, media: true),
          random: r,
        );
        expect(init[0], isNot(0xef));
        expect(init.sublist(4, 8), isNot([0, 0, 0, 0]));
        final server = FakeTelegramServer(init);
        expect(server.transport, MtprotoTransport.intermediate);
        expect(server.dcIndex, -4);
      }
    });

    test('шифры сессии: данные проходят в обе стороны', () {
      final r = Random(5);
      final client = FakeTelegramClient(
        secret: secret,
        transport: MtprotoTransport.intermediate,
        dcIndex: 2,
      );
      final hello = ClientHandshake.parse(client.handshake, secret)!;
      final relay = relayHandshake(hello.transport, hello.target, random: r);
      final ciphers = SessionCiphers(hello, secret, relay);
      final server = FakeTelegramServer(relay);

      for (var i = 0; i < 5; i++) {
        final up = randomBytes(1 + r.nextInt(3000), r);
        expect(server.decrypt(ciphers.upstream(client.encrypt(up))), up);
        final down = randomBytes(1 + r.nextInt(3000), r);
        expect(client.decrypt(ciphers.downstream(server.encrypt(down))), down);
      }
    });
  });

  group('нарезка на пакеты', () {
    /// Режет поток на случайные куски и собирает то, что выдал PacketSplitter.
    List<Uint8List> run(MtprotoTransport t, List<Uint8List> packets, Random r) {
      final stream = Uint8List.fromList([for (final p in packets) ...p]);
      final splitter = PacketSplitter(t);
      final out = <Uint8List>[];
      var i = 0;
      while (i < stream.length) {
        final n = min(1 + r.nextInt(900), stream.length - i);
        final chunk = Uint8List.sublistView(stream, i, i + n);
        // Нарезке нужен и открытый текст — здесь он совпадает с «шифром».
        out.addAll(splitter.split(chunk, chunk));
        i += n;
      }
      out.addAll(splitter.flush());
      return out;
    }

    test('intermediate: каждый пакет — отдельно, как бы ни резали поток', () {
      final r = Random(1);
      final packets = [
        for (var i = 0; i < 40; i++)
          intermediatePacket(randomBytes(r.nextInt(2000) + 4, r)),
      ];
      expect(run(MtprotoTransport.intermediate, packets, r), packets);
      expect(run(MtprotoTransport.paddedIntermediate, packets, r), packets);
    });

    test('abridged: короткие и длинные заголовки', () {
      final r = Random(2);
      final packets = [
        for (var i = 0; i < 30; i++)
          abridgedPacket(
            randomBytes(4 * (1 + r.nextInt(i.isEven ? 100 : 1000)), r),
          ),
      ];
      expect(run(MtprotoTransport.abridged, packets, r), packets);
    });

    test('флаг быстрого подтверждения не мешает длине', () {
      final body = Uint8List(16);
      final p = intermediatePacket(body);
      p[3] |= 0x80;
      final splitter = PacketSplitter(MtprotoTransport.intermediate);
      expect(splitter.split(p, p), [p]);
    });

    test('непонятная длина — дальше без нарезки', () {
      final splitter = PacketSplitter(MtprotoTransport.intermediate);
      final zero = Uint8List(10);
      expect(splitter.split(zero, zero), [zero]);
      final next = Uint8List.fromList([1, 2, 3]);
      expect(splitter.split(next, next), [next]);
    });

    test('недособранный хвост отдаётся при закрытии', () {
      final splitter = PacketSplitter(MtprotoTransport.intermediate);
      final p = intermediatePacket(Uint8List(100));
      final head = Uint8List.sublistView(p, 0, 50);
      expect(splitter.split(head, head), isEmpty);
      expect(splitter.flush(), [head]);
    });
  });

  group('прокси', () {
    final secret = hexBytes('00112233445566778899aabbccddeeff');
    late FakeTelegramWebSocket telegram;

    setUp(() async {
      telegram = FakeTelegramWebSocket();
      await telegram.start();
    });
    tearDown(() => telegram.close());

    Future<TelegramProxyServer> startProxy(TelegramConnector connector) async {
      final server = TelegramProxyServer(
        secret: secret,
        port: 0,
        connector: connector,
      );
      await server.start();
      addTearDown(server.stop);
      return server;
    }

    test('Telegram ↔ прокси ↔ WebSocket: пакеты и ответы целиком', () async {
      final connector = LocalConnector(telegram.port);
      final proxy = await startProxy(connector);
      final r = Random(9);
      final client = FakeTelegramClient(
        secret: secret,
        transport: MtprotoTransport.intermediate,
        dcIndex: -2,
      );
      final socket = await Socket.connect('127.0.0.1', proxy.boundPort);
      final reader = SocketReader(socket);
      final packets = [
        for (var i = 0; i < 20; i++)
          intermediatePacket(randomBytes(4 + r.nextInt(5000), r)),
      ];
      // Рукопожатие и первые данные — одним куском, как часто делает клиент.
      final first = Uint8List.fromList([
        ...client.handshake,
        ...client.encrypt(packets.first),
      ]);
      socket.add(first);
      for (final p in packets.skip(1)) {
        final enc = client.encrypt(p);
        // Режем пакет пополам: прокси должен собрать его сам.
        socket.add(enc.sublist(0, enc.length ~/ 2));
        await socket.flush();
        socket.add(enc.sublist(enc.length ~/ 2));
      }
      await socket.flush();

      for (final p in packets) {
        final reply = client.decrypt(await reader.read(p.length));
        expect(reply, p.reversed.toList());
      }
      expect(telegram.messages, packets);
      expect(telegram.dcIndexes, [-2]);
      expect(connector.targets.single.media, isTrue);
      expect(proxy.stats.webSocket, 1);

      socket.destroy();
      reader.cancel();
    });

    test(
      'Telegram закрыл первым — сессия кончается, прокси работает дальше',
      () async {
        final closing = FakeTelegramWebSocket(closeAfterReply: true);
        await closing.start();
        addTearDown(closing.close);
        final proxy = await startProxy(LocalConnector(closing.port));
        final r = Random(4);
        for (var round = 0; round < 2; round++) {
          final client = FakeTelegramClient(
            secret: secret,
            transport: MtprotoTransport.intermediate,
            dcIndex: 2,
            random: r,
          );
          final socket = await Socket.connect('127.0.0.1', proxy.boundPort);
          final reader = SocketReader(socket);
          final packet = intermediatePacket(randomBytes(64, r));
          socket.add([...client.handshake, ...client.encrypt(packet)]);
          final reply = client.decrypt(await reader.read(packet.length));
          expect(reply, packet.reversed.toList());
          await reader.waitClosed();
          socket.destroy();
        }
        expect(proxy.stats.webSocket, 2);
        expect(proxy.stats.active, 0);
      },
    );

    test(
      'чужой секрет — соединение закрывается, Telegram не трогаем',
      () async {
        final connector = LocalConnector(telegram.port);
        final proxy = await startProxy(connector);
        final client = FakeTelegramClient(
          secret: hexBytes('ffffffffffffffffffffffffffffffff'),
          transport: MtprotoTransport.intermediate,
          dcIndex: 2,
        );
        final socket = await Socket.connect('127.0.0.1', proxy.boundPort);
        final reader = SocketReader(socket);
        socket.add(client.handshake);
        await reader.waitClosed();
        expect(connector.targets, isEmpty);
        expect(proxy.stats.badHandshakes, 1);
        socket.destroy();
      },
    );

    test('Telegram недоступен — клиент отключается, счётчик неудач', () async {
      final proxy = await startProxy(
        LocalConnector(telegram.port, available: false),
      );
      final client = FakeTelegramClient(
        secret: secret,
        transport: MtprotoTransport.abridged,
        dcIndex: 5,
      );
      final socket = await Socket.connect('127.0.0.1', proxy.boundPort);
      final reader = SocketReader(socket);
      socket.add(client.handshake);
      await reader.waitClosed();
      expect(proxy.stats.failed, 1);
      expect(proxy.stats.active, 0);
      socket.destroy();
    });
  });

  group('прокси в изоляте', () {
    Future<int> freePort() async {
      final s = await ServerSocket.bind('127.0.0.1', 0);
      final port = s.port;
      await s.close();
      return port;
    }

    test('запускается, слушает порт и останавливается', () async {
      final port = await freePort();
      final proxy = TelegramProxy();
      await proxy.start(secret: generateTelegramSecret(), port: port);
      expect(proxy.running, isTrue);
      final socket = await Socket.connect('127.0.0.1', port);
      socket.destroy();
      await proxy.stop();
      expect(proxy.running, isFalse);
      // Порт освободился.
      final again = await ServerSocket.bind('127.0.0.1', port);
      await again.close();
    });

    test('порт занят — понятная ошибка', () async {
      final busy = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(busy.close);
      final proxy = TelegramProxy();
      await expectLater(
        proxy.start(secret: generateTelegramSecret(), port: busy.port),
        throwsA(
          isA<TelegramProxyException>().having(
            (e) => e.message,
            'message',
            contains('занят'),
          ),
        ),
      );
      expect(proxy.running, isFalse);
    });
  });

  test('ссылка и секрет', () {
    final s = generateTelegramSecret();
    expect(isTelegramSecret(s), isTrue);
    expect(isTelegramSecret('xyz'), isFalse);
    expect(
      telegramProxyLink(port: 1443, secret: s),
      'tg://proxy?server=127.0.0.1&port=1443&secret=dd$s',
    );
    expect(webSocketDomains(const TelegramTarget(4, media: true)), [
      'kws4-1.web.telegram.org',
      'kws4.web.telegram.org',
    ]);
    expect(webSocketDomains(const TelegramTarget(203)), [
      'kws2.web.telegram.org',
    ]);
  });
}
