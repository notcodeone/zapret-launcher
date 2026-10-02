import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/pages/network_menu.dart';
import 'package:zapret_launcher/src/platform/win32.dart' as win;
import 'package:zapret_launcher/src/zapret/diagnostics.dart';
import 'package:zapret_launcher/src/zapret/install.dart';
import 'package:zapret_launcher/src/zapret/network.dart';
import 'package:zapret_launcher/src/zapret/probe.dart';

class _FakeSystem implements DiagnosticsSystem {
  _FakeSystem({
    this.running = const {'BFE'},
    this.serviceList = const [],
    this.processes = const {},
    this.proxy,
    this.doh = true,
    this.oneDrivePath,
    this.hosts = '127.0.0.1 localhost\r\n',
  });

  final Set<String> running;
  final List<win.ServiceEntry> serviceList;
  final Set<String> processes;
  final String? proxy;
  final bool doh;
  final String? oneDrivePath;
  final String? hosts;

  @override
  bool serviceRunning(String name) => running.contains(name);
  @override
  List<win.ServiceEntry> services() => serviceList;
  @override
  bool processRunning(String exe) => processes.contains(exe);
  @override
  String? proxyServer() => proxy;
  @override
  bool secureDns() => doh;
  @override
  String? oneDrive() => oneDrivePath;
  @override
  String? readHosts() => hosts;
}

win.ServiceEntry _svc(String name, [String display = '', bool on = true]) =>
    win.ServiceEntry(name, display, on ? win.ServiceState.running : win.ServiceState.stopped);

DiagnosticResult? _find(List<DiagnosticResult> r, String id) {
  for (final x in r) {
    if (x.id == id) return x;
  }
  return null;
}

const _repo = '1.1.1.1 a.example\r\n# comment\r\n2.2.2.2 b.example\r\n';

void main() {
  test('чистая система — всё в порядке', () {
    final r = diagnose(_FakeSystem(), repoHosts: _repo.replaceAll('\r\n', '\n'));
    expect(r.where((x) => x.level == CheckLevel.problem), isEmpty);
    expect(_find(r, 'bfe')!.level, CheckLevel.ok);
    expect(_find(r, 'software')!.level, CheckLevel.ok);
    expect(_find(r, 'hosts-repo')!.level, CheckLevel.info);
    expect(_find(r, 'hosts-repo')!.fix, isA<HostsBlockFix>());
  });

  test('проблемы находятся и предлагают исправления', () {
    final r = diagnose(_FakeSystem(
      running: {'WinDivert'},
      serviceList: [
        _svc('GoodbyeDPI', 'GoodbyeDPI', false),
        _svc('KNDBWM', 'Killer Network Service'),
        _svc('NordVPN Service', 'NordVPN'),
        _svc('Intel(R) CNS', 'Intel Connectivity Network Service'),
      ],
      processes: {'AdguardSvc.exe'},
      proxy: '127.0.0.1:8080',
      doh: false,
      hosts: '1.2.3.4 www.youtube.com\r\n',
    ));
    expect(_find(r, 'bfe')!.fix, isA<StartServiceFix>());
    expect((_find(r, 'conflicts')!.fix as RemoveServicesFix).services, ['GoodbyeDPI']);
    expect(_find(r, 'windivert')!.fix, isA<UnloadDriverFix>());
    expect(_find(r, 'adguard')!.level, CheckLevel.problem);
    expect(_find(r, 'killer')!.level, CheckLevel.problem);
    expect(_find(r, 'intel')!.level, CheckLevel.problem);
    expect(_find(r, 'software'), isNull);
    expect(_find(r, 'vpn')!.detail, contains('NordVPN'));
    expect(_find(r, 'proxy')!.detail, contains('127.0.0.1:8080'));
    expect(_find(r, 'dns')!.level, CheckLevel.info);
    expect(_find(r, 'hosts-youtube')!.fix, isA<OpenFix>());
  });

  test('закомментированная запись YouTube в hosts не считается', () {
    final r = diagnose(_FakeSystem(hosts: '# 1.2.3.4 youtube.com\r\n'));
    expect(_find(r, 'hosts-youtube'), isNull);
  });

  test('драйвер при запущенном winws.exe — не проблема', () {
    final r = diagnose(_FakeSystem(running: {'BFE', 'WinDivert'}, processes: {'winws.exe'}));
    expect(_find(r, 'windivert'), isNull);
  });

  group('файлы и путь zapret', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zl-diag-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    ZapretInstall make(String dir, {bool sys = true}) {
      final root = Directory(p.join(tmp.path, dir))..createSync(recursive: true);
      File(p.join(root.path, 'bin', 'winws.exe')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'WinDivert.dll')).createSync();
      if (sys) File(p.join(root.path, 'bin', 'WinDivert64.sys')).createSync();
      File(p.join(root.path, 'general.bat')).writeAsStringSync('"%BIN%winws.exe" --new');
      return ZapretInstall.open(root.path)!;
    }

    test('нет WinDivert64.sys — переустановить', () {
      final r = diagnose(_FakeSystem(), install: make('z', sys: false));
      expect(_find(r, 'files')!.level, CheckLevel.problem);
      expect(_find(r, 'files')!.detail, contains('WinDivert64.sys'));
      expect(_find(r, 'files')!.fix, isA<ReinstallFix>());
    });

    test('русские буквы и OneDrive в пути', () {
      expect(_find(diagnose(_FakeSystem(), install: make('запрет')), 'path')!.level,
          CheckLevel.warning);
      final inst = make('od/zapret');
      final r = diagnose(_FakeSystem(oneDrivePath: p.join(tmp.path, 'od')), install: inst);
      expect(_find(r, 'path')!.level, CheckLevel.problem);
    });
  });

  group('hosts', () {
    test('статус по первой и последней строке', () {
      expect(hostsBlockStatus('x', _repo), HostsStatus.missing);
      expect(hostsBlockStatus('1.1.1.1 a.example\n2.2.2.2 b.example', _repo), HostsStatus.upToDate);
      expect(hostsBlockStatus('$hostsBegin\n9.9.9.9 old\n$hostsEnd', _repo), HostsStatus.outdated);
    });

    test('блок дописывается, а при повторе — заменяется', () {
      const hosts = '127.0.0.1 localhost';
      final once = mergeHostsBlock(hosts, _repo);
      expect(once, startsWith('127.0.0.1 localhost\r\n'));
      expect(once, contains('1.1.1.1 a.example\r\n2.2.2.2 b.example'));
      expect(once, isNot(contains('# comment')));
      expect(hostsBlockStatus(once, _repo), HostsStatus.upToDate);
      final twice = mergeHostsBlock(once, '3.3.3.3 c.example');
      expect(twice, isNot(contains('a.example')));
      expect(RegExp(hostsBegin).allMatches(twice).length, 1);
      expect(twice, contains('3.3.3.3 c.example'));
    });
  });

  group('сводка сети', () {
    TargetResult t(String name, bool ok, {ProbeOutcome? outcome}) => TargetResult(
        ProbeTarget(name, Uri.parse('https://x.y')), outcome ?? (ok ? ProbeOutcome.ok : ProbeOutcome.blocked));

    NetworkReport report(List<TargetResult> r) =>
        NetworkReport(checkedAt: DateTime(2026), targets: r, withZapret: true);

    test('всё открывается', () {
      final r = report([t('DiscordMain', true), t('YouTubeWeb', true)]);
      expect(r.allOk, isTrue);
      expect(networkSummary(r, checking: false), 'Всё открывается');
    });

    test('один сервис не открывается, другой — частично', () {
      final r = report([
        t('DiscordMain', false),
        t('DiscordCDN', false),
        t('YouTubeWeb', true),
        t('YouTubeImage', false),
      ]);
      expect(r.health('Discord'), ServiceHealth.down);
      expect(r.health('YouTube'), ServiceHealth.partial);
      expect(networkSummary(r, checking: false), 'Discord не открывается');
    });

    test('два сервиса не открываются', () {
      final r = report([t('DiscordMain', false), t('YouTubeWeb', false), t('GoogleMain', true)]);
      expect(networkSummary(r, checking: false), 'Discord и YouTube не открываются');
    });

    test('нет интернета', () {
      final r = report([
        t('DiscordMain', false, outcome: ProbeOutcome.noHost),
        t('YouTubeWeb', false, outcome: ProbeOutcome.noHost),
      ]);
      expect(r.offline, isTrue);
      expect(networkSummary(r, checking: false), 'Нет интернета');
    });
  });
}
