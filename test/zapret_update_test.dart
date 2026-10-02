import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/controller.dart';
import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/bundle.dart';
import 'package:zapret_launcher/src/zapret/install.dart';
import 'package:zapret_launcher/src/zapret/probe.dart';
import 'package:zapret_launcher/src/zapret/releases.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';
import 'package:zapret_launcher/src/zapret/strategy.dart';

import 'helpers.dart';

/// winws.exe понарошку. Драйвер и службы не трогает — важно: настоящие
/// unloadDriver/removeService остановили бы WinDivert на машине, где идут тесты.
class _FakeRunner extends ZapretRunner {
  _FakeRunner(this.root);

  final String root;
  bool alive = true;
  int starts = 0;

  @override
  RuntimeStatus status() => RuntimeStatus(
        processes: alive ? [WinwsProcess(1, p.join(root, 'bin', 'winws.exe'))] : const [],
        service: null,
        serviceStrategy: null,
      );

  @override
  void prepare(ZapretInstall install) {}
  @override
  Future<void> startProcess(ZapretInstall install, Strategy strategy, GameFilter filter) async {
    starts++;
    alive = true;
  }

  @override
  Future<void> stopAll() async => alive = false;
  @override
  Future<void> killProcesses() async {}
  @override
  Future<void> unloadDriver() async {}
  @override
  Future<void> removeService({bool cleanupDriver = true}) async {}
}

/// Релиз zapret из готового архива.
class _FakeReleases extends ReleaseClient {
  _FakeReleases(this.version, this.zip);

  final String version;
  final File zip;

  @override
  Future<ReleaseInfo> latest() async => ReleaseInfo(
        version: version,
        zipUrl: Uri.parse('https://example.com/z.zip'),
        pageUrl: Uri.parse('https://example.com'),
      );

  @override
  Future<File> download(ReleaseInfo release, {void Function(double? progress)? onProgress}) async {
    // installFromZip удаляет папку архива — отдаём копию.
    final dir = Directory.systemTemp.createTempSync('zl-zip-');
    return zip.copySync(p.join(dir.path, 'z.zip'));
  }
}

/// Сайты открываются, пока не поставят «сломанную» версию zapret.
class _FakeProber extends HttpProber {
  _FakeProber(this.brokenWhen);

  final bool Function() brokenWhen;

  @override
  Future<TargetResult> check(ProbeTarget target) async => TargetResult(
        target,
        brokenWhen() && target.group == 'Discord' ? ProbeOutcome.blocked : ProbeOutcome.ok,
        latency: const Duration(milliseconds: 50),
      );
}

void main() {
  late Directory tmp;
  late String root;
  late File zip;

  void fakeZapret(String dir, String version) {
    File(p.join(dir, 'bin', 'winws.exe')).createSync(recursive: true);
    File(p.join(dir, 'general.bat')).writeAsStringSync('"%BIN%winws.exe" --wf-tcp=80');
    File(p.join(dir, 'service.bat')).writeAsStringSync('set "LOCAL_VERSION=$version"\r\n');
    File(p.join(dir, 'lists', 'list-general-user.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('my.site\r\n');
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('zl-upd-');
    root = p.join(tmp.path, 'zapret');
    fakeZapret(root, '1.0.0');
    final src = p.join(tmp.path, 'release', 'zapret-2.0.0');
    fakeZapret(src, '2.0.0');
    zip = File(p.join(tmp.path, 'z.zip'));
    final enc = ZipFileEncoder()..create(zip.path);
    await enc.addDirectory(Directory(src));
    await enc.close();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppController> make(WidgetTester tester, {required bool brokenAfter}) async {
    late AppController c;
    final store = SettingsStore(path: p.join(tmp.path, 's.json'))
      ..save(AppSettings(zapretDir: root, strategy: 'general', autoCheckUpdates: false));
    c = AppController(
      toasts: ToastController(),
      store: store,
      runner: _FakeRunner(root),
      releases: _FakeReleases('2.0.0', zip),
      isElevated: () => true,
      guardFactory: quietGuard,
      watchNetworkEvents: false,
      launcherAutostart: FakeAutostart(),
      prober: _FakeProber(() => brokenAfter && c.install?.version == '2.0.0'),
      // Встроенный zapret — в той же папке; архива в лаунчере нет: обновления только с GitHub.
      builtinZapretDir: root,
      bundle: ZapretBundle(Directory(p.join(tmp.path, 'no-bundle'))),
    );
    await tester.runAsync(() async {
      c.init();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    return c;
  }

  testWidgets('новая версия работает — остаётся, прежняя сохранена', (tester) async {
    final c = await make(tester, brokenAfter: false);
    await tester.runAsync(() => c.checkUpdates(silent: true));
    expect(c.install!.version, '2.0.0');
    expect(c.running, isTrue);
    expect(c.previousZapretVersion, '1.0.0');
    expect(File(p.join(root, 'lists', 'list-general-user.txt')).readAsStringSync(), 'my.site\r\n');
    c.dispose();
    c.toasts.dispose();
  });

  testWidgets('новая версия сломала Discord — откат и больше не ставится', (tester) async {
    final c = await make(tester, brokenAfter: true);
    await tester.runAsync(() => c.checkUpdates(silent: true));
    expect(c.install!.version, '1.0.0');
    expect(c.running, isTrue);
    expect(c.settings.skippedZapretVersion, '2.0.0');
    expect(c.previousZapretVersion, '2.0.0');

    // Следующая проверка эту версию сама не ставит.
    await tester.runAsync(() => c.checkUpdates(silent: true));
    expect(c.install!.version, '1.0.0');

    // А вручную — можно.
    await tester.runAsync(() => c.installLatest());
    expect(c.install!.version, '2.0.0');
    c.dispose();
    c.toasts.dispose();
  });

  testWidgets('автообновление выключено — только оповещение', (tester) async {
    final c = await make(tester, brokenAfter: false);
    c.setAutoUpdateZapret(false);
    await tester.runAsync(() => c.checkUpdates(silent: true));
    expect(c.install!.version, '1.0.0');
    expect(c.updateAvailable, isTrue);
    c.dispose();
    c.toasts.dispose();
  });
}
