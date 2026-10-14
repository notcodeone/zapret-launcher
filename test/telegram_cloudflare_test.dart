import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/telegram/cloudflare.dart';
import 'package:zapret_launcher/src/telegram/mtproto.dart';
import 'package:zapret_launcher/src/telegram/upstream.dart';

// Домены здесь выдуманные: настоящий список в репозиторий не попадает.

/// Запись tg-ws-proxy наоборот: буквы сдвигаются вперёд на их число, зона — «.com».
String encode(String name) {
  bool letter(int c) => (c >= 97 && c <= 122);
  final shift = name.codeUnits.where(letter).length;
  return '${String.fromCharCodes([for (final c in name.codeUnits) letter(c) ? (c - 97 + shift) % 26 + 97 : c])}.com';
}

final zone = String.fromCharCodes(const [46, 99, 111, 46, 117, 107]);

/// Открывает WebSocket к локальному серверу вместо настоящего; запоминает адреса.
class FakeOpener {
  FakeOpener(this.port, {this.works = _any});

  static bool _any(String host) => true;

  final int port;
  final bool Function(String host) works;
  final hosts = <String>[];

  Future<(WebSocket, SecureSocket?)> call(
    String host,
    String domain, {
    required String path,
    String? sni,
  }) async {
    hosts.add(host);
    if (!works(host)) throw const SocketException('сброс');
    return (await WebSocket.connect('ws://127.0.0.1:$port$path'), null);
  }
}

void main() {
  test('запись tg-ws-proxy: сдвиг букв на их число и настоящая зона', () {
    expect(encode('abc-def'), 'ghi-jkl.com');
    expect(decodeCloudflareDomain('ghi-jkl.com'), 'abc-def$zone');
    expect(decodeCloudflareDomain(encode('example1')), 'example1$zone');
    // Не в записи tg-ws-proxy — как есть.
    expect(decodeCloudflareDomain('my.example.org'), 'my.example.org');
  });

  test('список: комментарии, пустые строки, повторы и мусор отбрасываются', () {
    final text = [
      '# домены',
      '',
      encode('alpha'),
      '  ${encode('bravo')}  ',
      encode('alpha'),
      '-bad-.com',
      'my.example.org',
    ].join('\r\n');
    expect(parseCloudflareList(text), [
      'alpha$zone',
      'bravo$zone',
      'my.example.org',
    ]);
  });

  test('у каждого DC свой домен; удачный остаётся первым', () {
    final d = CloudflareDomains(['a.test', 'b.test', 'c.test'], Random(1));
    final first = d.forDc(2).first;
    expect(d.forDc(2).toSet(), {'a.test', 'b.test', 'c.test'});
    final other = d.forDc(2).firstWhere((x) => x != first);
    d.use(2, other);
    expect(d.forDc(2).first, other);
    // Тот же список — выбор не сбрасывается.
    d.update(['c.test', 'b.test', 'a.test']);
    expect(d.forDc(2).first, other);
    d.update(const []);
    expect(d.isEmpty, isTrue);
    expect(d.forDc(2), isEmpty);
  });

  group('подключение', () {
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

    test('веб-версия не открылась — Cloudflare, домен запоминается', () async {
      final opener = FakeOpener(ws.port, works: (h) => h.startsWith('kws'));
      final domains = CloudflareDomains(['a.test', 'b.test'], Random(2));
      final c = DirectTelegramConnector(
        cloudflare: domains,
        openWebSocket: opener.call,
        connectTcp: noTcp,
      );
      final up = await c.connect(const TelegramTarget(2));
      expect(up!.route, 'Cloudflare');
      up.close();
      // Сначала прямой WebSocket (с подменой имени и без), потом kws2.<домен>.
      expect(opener.hosts.take(2), everyElement('149.154.167.220'));
      expect(opener.hosts.last, startsWith('kws2.'));
      expect(domains.forDc(2).first, opener.hosts.last.substring(5));
    });

    test(
      'DC без WebSocket веб-версии — сразу Cloudflare, kws203 для 203',
      () async {
        final opener = FakeOpener(ws.port);
        final c = DirectTelegramConnector(
          cloudflare: CloudflareDomains(['a.test']),
          openWebSocket: opener.call,
          connectTcp: noTcp,
        );
        (await c.connect(const TelegramTarget(5, media: true)))!.close();
        (await c.connect(const TelegramTarget(1)))!.close();
        expect(opener.hosts, ['kws5.a.test', 'kws1.a.test']);
      },
    );

    test('Cloudflare закрыт — не больше трёх доменов, потом пауза', () async {
      final opener = FakeOpener(ws.port, works: (_) => false);
      final tcp = <String>[];
      final c = DirectTelegramConnector(
        cloudflare: CloudflareDomains([
          for (var i = 0; i < 10; i++) 'd$i.test',
        ]),
        openWebSocket: opener.call,
        connectTcp: (ip) {
          tcp.add(ip);
          return noTcp(ip);
        },
      );
      expect(await c.connect(const TelegramTarget(1)), isNull);
      expect(opener.hosts, hasLength(DirectTelegramConnector.cloudflareTries));
      expect(tcp, ['149.154.175.50']);
      // Пауза: ни Cloudflare, ни TCP (у него своя пауза) сейчас не пробуются.
      expect(await c.connect(const TelegramTarget(1)), isNull);
      expect(opener.hosts, hasLength(DirectTelegramConnector.cloudflareTries));
    });

    test('без списка доменов и для тестовых DC — без Cloudflare', () async {
      final opener = FakeOpener(ws.port);
      final c = DirectTelegramConnector(
        cloudflare: CloudflareDomains(),
        openWebSocket: opener.call,
        connectTcp: noTcp,
      );
      expect(await c.connect(const TelegramTarget(1)), isNull);
      final t = DirectTelegramConnector(
        cloudflare: CloudflareDomains(['a.test']),
        openWebSocket: opener.call,
        connectTcp: noTcp,
      );
      expect(await t.connect(const TelegramTarget(1, test: true)), isNull);
      expect(opener.hosts, isEmpty);
    });
  });

  group('список с GitHub и кэш', () {
    late Directory tmp;
    late HttpServer github;
    late String body;
    var status = 200;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('zl-cf-');
      body = [encode('alpha'), encode('bravo'), encode('charlie')].join('\n');
      status = 200;
      github = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      github.listen((r) {
        r.response.statusCode = status;
        r.response.write(body);
        r.response.close();
      });
    });
    tearDown(() async {
      await github.close(force: true);
      tmp.deleteSync(recursive: true);
    });

    String url() => 'http://127.0.0.1:${github.port}/list.txt';

    test('скачивается при запуске и ложится в кэш в той же записи', () async {
      final cache = p.join(tmp.path, 'sub', 'cf.txt');
      final domains = CloudflareDomains();
      final logs = <String>[];
      final r = CloudflareRefresher(
        domains,
        CloudflareSource(url: url(), cachePath: cache),
        onLog: logs.add,
      );
      await r.refresh();
      r.stop();
      expect(domains.length, 3);
      expect(File(cache).readAsStringSync(), body);
      expect(File(cache).readAsStringSync(), isNot(contains(zone)));
      expect(logs.single, 'Cloudflare: доменов 3');
    });

    test('GitHub недоступен или список битый — остаётся кэш', () async {
      final cache = p.join(tmp.path, 'cf.txt');
      File(cache).writeAsStringSync(body);

      status = 404;
      final domains = CloudflareDomains();
      final logs = <String>[];
      final r = CloudflareRefresher(
        domains,
        CloudflareSource(url: url(), cachePath: cache),
        onLog: logs.add,
        every: const Duration(hours: 1),
      )..start();
      // Кэш — сразу, до ответа GitHub.
      expect(domains.length, 3);
      await r.refresh();
      expect(domains.length, 3);
      expect(logs.last, contains('беру из кэша'));

      status = 200;
      body = [encode('delta'), encode('echo')].join('\n');
      await r.refresh();
      r.stop();
      expect(domains.forDc(1).toSet(), {
        'alpha$zone',
        'bravo$zone',
        'charlie$zone',
      });
      expect(logs.last, contains('не подошёл'));
      expect(File(cache).readAsStringSync(), contains(encode('charlie')));
    });
  });
}
