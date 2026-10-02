import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapret_launcher/src/zapret/probe.dart';
import 'package:zapret_launcher/src/zapret/strategy.dart';

Strategy _s(String id) => Strategy(id: id, file: File('$id.bat'));

/// Подделка: у каждой стратегии свой набор открывающихся сайтов.
class _FakeEnv implements ProbeEnvironment {
  _FakeEnv(this.open, {this.noStart = const {}, this.noHost = false});

  /// id стратегии (null — без обхода) → какие сайты открываются.
  final Map<String?, Set<String>> open;
  final Set<String> noStart;
  final bool noHost;
  String? _running;
  final log = <String>[];
  void Function()? onCheck;

  @override
  Future<bool> start(Strategy s) async {
    log.add('start ${s.id}');
    if (noStart.contains(s.id)) return false;
    _running = s.id;
    return true;
  }

  @override
  Future<void> stop() async {
    log.add('stop');
    _running = null;
  }

  @override
  Future<TargetResult> check(ProbeTarget t) async {
    onCheck?.call();
    if (noHost) return TargetResult(t, ProbeOutcome.noHost);
    final ok = open[_running]?.contains(t.name) ?? false;
    return TargetResult(t, ok ? ProbeOutcome.ok : ProbeOutcome.blocked,
        latency: const Duration(milliseconds: 100));
  }

  @override
  void abort() {}
}

final _targets = [
  ProbeTarget('DiscordMain', Uri.parse('https://discord.com')),
  ProbeTarget('DiscordCDN', Uri.parse('https://cdn.discordapp.com')),
  ProbeTarget('YouTubeWeb', Uri.parse('https://www.youtube.com')),
  ProbeTarget('GoogleMain', Uri.parse('https://www.google.com')),
];

void main() {
  test('parseTargets: только http(s), комментарии и PING пропускаются', () {
    final t = parseTargets('''
# comment
DiscordMain           = "https://discord.com"
### YouTube
YouTubeWeb = "https://www.youtube.com"
CloudflareDNS1111     = "PING:1.1.1.1"
broken line
''');
    expect(t.map((e) => e.name), ['DiscordMain', 'YouTubeWeb']);
    expect(t.first.group, 'Discord');
    expect(ProbeTarget('Something', Uri.parse('https://x.y')).group, 'Другие');
  });

  test('подбор: лучшая — та, что открывает больше сайтов', () async {
    final env = _FakeEnv({
      null: {'GoogleMain'},
      'a': {'GoogleMain', 'YouTubeWeb'},
      'b': {'GoogleMain', 'YouTubeWeb', 'DiscordMain', 'DiscordCDN'},
      'c': {'GoogleMain'},
    }, noStart: {'d'});
    final report = await AutoPick(
      env: env,
      strategies: [_s('a'), _s('b'), _s('c'), _s('d')],
      targets: _targets,
    ).run();

    expect(report.baseline.okCount, 1);
    expect(report.best!.strategy!.id, 'b');
    expect(report.ranked.map((r) => r.strategy!.id), ['b', 'a', 'c', 'd']);
    expect(report.results.last.failedToStart, isTrue);
    expect(report.best!.byGroup['Discord'], (2, 2));
    // После каждой стратегии winws.exe останавливается.
    expect(env.log.where((e) => e == 'stop').length, 5);
  });

  test('если ничего не лучше, чем без обхода, — лучшей нет', () async {
    final env = _FakeEnv({null: {'GoogleMain'}, 'a': {'GoogleMain'}});
    final report = await AutoPick(env: env, strategies: [_s('a')], targets: _targets).run();
    expect(report.best, isNull);
  });

  test('отмена останавливает перебор', () async {
    final env = _FakeEnv({null: {}, 'a': {'GoogleMain'}, 'b': {'GoogleMain'}});
    late AutoPick pick;
    pick = AutoPick(env: env, strategies: [_s('a'), _s('b')], targets: _targets);
    final progress = <AutoPickProgress>[];
    final report = await pick.run(onProgress: (p) {
      progress.add(p);
      if (p.current?.id == 'a') pick.cancel();
    });
    expect(report.cancelled, isTrue);
    expect(report.results, isEmpty);
    expect(env.log, isNot(contains('start b')));
    expect(env.log.last, 'stop');
  });

  test('без обхода всё открывается — стратегии не перебираются', () async {
    final all = {for (final t in _targets) t.name};
    final env = _FakeEnv({null: all, 'a': all});
    final report = await AutoPick(env: env, strategies: [_s('a')], targets: _targets).run();
    expect(report.results, isEmpty);
    expect(report.best, isNull);
    expect(env.log, isNot(contains('start a')));
  });

  test('ни один адрес не найден — нет интернета', () async {
    final env = _FakeEnv({}, noHost: true);
    expect(
      AutoPick(env: env, strategies: [_s('a')], targets: _targets).run(),
      throwsA(isA<NoInternetException>()),
    );
  });

  group('HttpProber на локальном сервере', () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) async {
        switch (req.uri.path) {
          case '/ok':
            req.response.add(List.filled(100 * 1024, 65));
            await req.response.close();
          case '/redirect':
            req.response
              ..statusCode = 301
              ..headers.set('location', '/ok');
            await req.response.close();
          case '/freeze':
            // Отдаём 20 КБ и замолкаем — как при блокировке «16–20».
            req.response.contentLength = 100 * 1024;
            req.response.add(List.filled(20 * 1024, 65));
            await req.response.flush();
          case '/silent':
            // Ничего не отвечаем.
            break;
        }
      });
    });

    tearDown(() => server.close(force: true));

    final prober = HttpProber(timeout: const Duration(seconds: 2));

    Future<TargetResult> check(String path) =>
        prober.check(ProbeTarget('T', base.replace(path: path)));

    test('ответ с данными — открыт', () async {
      final r = await check('/ok');
      expect(r.outcome, ProbeOutcome.ok);
      expect(r.bytes, greaterThanOrEqualTo(64 * 1024));
    });

    test('редирект — тоже открыт', () async {
      expect((await check('/redirect')).outcome, ProbeOutcome.ok);
    });

    test('данные встали после 20 КБ — заморозка', () async {
      final r = await check('/freeze');
      expect(r.outcome, ProbeOutcome.stalled);
      expect(r.bytes, 20 * 1024);
    });

    test('нет ответа — блокировка', () async {
      final r = await check('/silent');
      expect(r.outcome, ProbeOutcome.blocked);
    });

    test('порт закрыт — блокировка', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final r = await prober.check(ProbeTarget('T', Uri.parse('http://127.0.0.1:$port/')));
      expect(r.outcome, ProbeOutcome.blocked);
    });
  });
}
