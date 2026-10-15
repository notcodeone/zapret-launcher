import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/telegram/cloudflare.dart';
import 'package:zapret_launcher/src/telegram/config.dart';
import 'package:zapret_launcher/src/telegram/log_file.dart';
import 'package:zapret_launcher/src/telegram/mtproto.dart';
import 'package:zapret_launcher/src/telegram/upstream.dart';

/// WebSocket к локальному серверу вместо настоящего; запоминает, куда и как.
class _Opener {
  _Opener(this.port, {this.works = _any});

  static bool _any(String host) => true;

  final int port;
  final bool Function(String host) works;
  final calls = <({String host, String path, bool secure})>[];

  Future<(WebSocket, Socket?)> call(
    String host,
    String domain, {
    required String path,
    String? sni,
    bool secure = true,
  }) async {
    calls.add((host: host, path: path, secure: secure));
    if (!works(host)) throw const SocketException('сброс');
    return (await WebSocket.connect('ws://127.0.0.1:$port/apiws'), null);
  }
}

TelegramConfigForm _form({
  String host = '127.0.0.1',
  String port = '1080',
  String secret = '00112233445566778899aabbccddeeff',
  String dcIp = '2:149.154.167.220\n4:149.154.167.220',
  bool cfCustom = false,
  String cfDomains = '',
  bool worker = false,
  String workerDomains = '',
  String bufKb = '256',
  String poolSize = '4',
  String logMaxMb = '5',
}) => TelegramConfigForm(
  host: host,
  port: port,
  secret: secret,
  dcIp: dcIp,
  cfproxy: true,
  cfproxyUserDomainEnabled: cfCustom,
  cfproxyUserDomains: cfDomains,
  cfproxyWorkerEnabled: worker,
  cfproxyWorkerDomains: workerDomains,
  noSecure: false,
  verbose: false,
  bufKb: bufKb,
  poolSize: poolSize,
  logMaxMb: logMaxMb,
);

void main() {
  group('настройки', () {
    test('по умолчанию — как у tg-ws-proxy, порт 1080', () {
      const c = TelegramProxyConfig();
      expect(c.host, '127.0.0.1');
      expect(c.port, 1080);
      expect(c.dcIp, ['2:149.154.167.220', '4:149.154.167.220']);
      expect(c.webSocketIps, {2: '149.154.167.220', 4: '149.154.167.220'});
      expect(c.cfproxy, isTrue);
      expect(c.bufKb, 256);
      expect(c.poolSize, 4);
      expect(c.logMaxMb, 5);
    });

    test('ключи — как в config.json у tg-ws-proxy, туда и обратно', () {
      const c = TelegramProxyConfig(
        host: '0.0.0.0',
        port: 1443,
        secret: 'ab',
        dcIp: ['1:1.2.3.4'],
        cfproxyUserDomainEnabled: true,
        cfproxyUserDomains: ['a.test'],
        cfproxyWorkerEnabled: true,
        cfproxyWorkerDomains: ['w.workers.dev'],
        noSecure: true,
        verbose: true,
        bufKb: 64,
        poolSize: 0,
        logMaxMb: 10,
      );
      final j = c.toJson();
      expect(j.keys, containsAll(['dc_ip', 'cfproxy_user_domain', 'buf_kb']));
      final back = TelegramProxyConfig.fromJson(j);
      expect(back.toJson(), j);
      expect(back.linkHost, '127.0.0.1');
      expect(back.userCloudflareDomains, ['a.test']);
      expect(back.workerDomains, ['w.workers.dev']);
      // Выключенные свои домены и Worker не используются, хоть и помнятся.
      final off = back.copyWith(
        cfproxyUserDomainEnabled: false,
        cfproxyWorkerEnabled: false,
      );
      expect(off.userCloudflareDomains, isEmpty);
      expect(off.workerDomains, isEmpty);
    });

    test('проверка формы — тексты ошибок как у tg-ws-proxy', () {
      expect(_form().validate(), isEmpty);
      expect(
        _form(host: 'localhost').validate()['host'],
        'Некорректный IP-адрес.',
      );
      expect(
        _form(port: '70000').validate()['port'],
        'Порт должен быть числом 1-65535',
      );
      expect(
        _form(secret: 'abc').validate()['secret'],
        'Ключ должен содержать ровно 32 hex-символа (16 байт).',
      );
      expect(
        _form(secret: 'zz112233445566778899aabbccddeeff').validate()['secret'],
        'Ключ должен состоять только из hex-символов (0-9, a-f).',
      );
      expect(
        _form(dcIp: '2-149.154.167.220').validate()['dcIp'],
        'Неверный формат DC:IP: 2-149.154.167.220',
      );
      expect(
        _form(dcIp: '2:999.1.1.1').validate()['dcIp'],
        'Неверная запись DC:IP: 2:999.1.1.1',
      );
      expect(_form(cfCustom: true).validate(), contains('cfproxyUserDomains'));
      expect(_form(worker: true).validate(), contains('cfproxyWorkerDomains'));
      expect(_form(bufKb: '2').validate(), contains('bufKb'));
      expect(_form(poolSize: '-1').validate(), contains('poolSize'));
      expect(_form(logMaxMb: '0').validate(), contains('logMaxMb'));
    });

    test(
      'форма → настройки: домены через запятую, пустые строки DC пропущены',
      () {
        final c = _form(
          dcIp: '2:149.154.167.220\n\n 4:149.154.167.91 ',
          cfCustom: true,
          cfDomains: 'A.test, b.test;a.test',
          poolSize: '0',
        ).toConfig();
        expect(c.dcIp, ['2:149.154.167.220', '4:149.154.167.91']);
        expect(c.cfproxyUserDomains, ['a.test', 'b.test']);
        expect(c.poolSize, 0);
        expect(
          _form().sameAs(TelegramConfigForm.of(_form().toConfig())),
          isTrue,
        );
      },
    );
  });

  group('подключение к Telegram', () {
    late HttpServer ws;

    setUp(() async {
      ws = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ws.listen(
        (r) async => (await WebSocketTransformer.upgrade(r)).listen((_) {}),
      );
    });
    tearDown(() => ws.close(force: true));

    Future<Socket> noTcp(String ip) =>
        Future.error(const SocketException('нет'));

    test('пул: готовые WebSocket на каждый DC, обычные и медиа', () async {
      final opener = _Opener(ws.port);
      final c = DirectTelegramConnector(
        poolSize: 2,
        openWebSocket: opener.call,
        connectTcp: noTcp,
      );
      addTearDown(c.close);
      c.warmup();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // DC 2 и 4 × обычные и медиа × 2.
      expect(opener.calls, hasLength(8));
      final up = await c.connect(const TelegramTarget(2));
      expect(up!.route, 'WebSocket');
      up.close();
      // Взятое сразу пополняется.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(opener.calls, hasLength(9));
    });

    test('пул 0 — прямого WebSocket нет, как у tg-ws-proxy', () async {
      final opener = _Opener(ws.port);
      final c = DirectTelegramConnector(
        poolSize: 0,
        cloudflare: CloudflareDomains(['a.test']),
        openWebSocket: opener.call,
        connectTcp: noTcp,
      );
      final up = await c.connect(const TelegramTarget(2));
      expect(up!.route, 'Cloudflare');
      up.close();
      expect(opener.calls.single.host, 'kws2.a.test');
    });

    test(
      'CF Worker — раньше CF-прокси, адрес DC в запросе, поток не режется',
      () async {
        final opener = _Opener(ws.port);
        final c = DirectTelegramConnector(
          cloudflare: CloudflareDomains(['a.test']),
          workerDomains: const ['w.workers.dev'],
          openWebSocket: opener.call,
          connectTcp: noTcp,
        );
        final up = await c.connect(const TelegramTarget(5));
        expect(up!.route, 'Cloudflare Worker');
        expect(up.framed, isFalse);
        up.close();
        expect(opener.calls.single.host, 'w.workers.dev');
        expect(opener.calls.single.path, '/apiws?dst=149.154.171.5&dc=5');
        expect(opener.calls.single.secure, isTrue);
      },
    );

    test('без TLS — CF-прокси и Worker по порту 80', () async {
      final opener = _Opener(ws.port, works: (h) => !h.contains('workers'));
      final c = DirectTelegramConnector(
        cloudflare: CloudflareDomains(['a.test']),
        workerDomains: const ['w.workers.dev'],
        noSecure: true,
        openWebSocket: opener.call,
        connectTcp: noTcp,
      );
      (await c.connect(const TelegramTarget(1)))!.close();
      expect(opener.calls.map((c) => c.secure), [false, false]);
      expect(opener.calls.last.host, 'kws1.a.test');
    });
  });

  test('файл лога: дорос до предела — прежний в «.1», запись заново', () {
    final tmp = Directory.systemTemp.createTempSync('zl-log-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = p.join(tmp.path, 'proxy.log');
    final log = ProxyLogFile(path, maxBytes: 200);
    for (var i = 0; i < 10; i++) {
      log.write('строка $i ${'x' * 20}');
    }
    log.close();
    final now = File(path).readAsStringSync();
    final old = File('$path.1').readAsStringSync();
    expect(File(path).lengthSync(), lessThanOrEqualTo(200));
    expect(now, contains('строка 9'));
    expect(old, isNot(contains('строка 9')));
  });
}
