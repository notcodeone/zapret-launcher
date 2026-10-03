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

/// winws.exe понарошку: запускается из той папки, которую дали. Драйвер и службы
/// не трогает — настоящие unloadDriver/removeService остановили бы WinDivert на машине тестов.
class _FakeRunner extends ZapretRunner {
  _FakeRunner({this.root, this.alive = false});

  String? root;
  bool alive;
  int starts = 0;

  @override
  RuntimeStatus status() => RuntimeStatus(
    processes: alive && root != null
        ? [WinwsProcess(1, p.join(root!, 'bin', 'winws.exe'))]
        : const [],
    service: null,
    serviceStrategy: null,
  );

  @override
  void prepare(ZapretInstall install) {}
  @override
  Future<void> startProcess(
    ZapretInstall install,
    Strategy strategy,
    GameFilter filter,
  ) async {
    starts++;
    root = install.root.path;
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

/// GitHub недоступен: всё должно работать на встроенном zapret.
class _OfflineReleases extends ReleaseClient {
  @override
  Future<ReleaseInfo> latest() async => throw const SocketException('offline');

  @override
  Future<File> download(
    ReleaseInfo release, {
    void Function(double? progress)? onProgress,
  }) => throw const SocketException('offline');
}

/// Сайты открываются, пока не поставят «сломанную» версию zapret.
class _FakeProber extends HttpProber {
  _FakeProber(this.brokenWhen);

  final bool Function() brokenWhen;

  @override
  Future<TargetResult> check(ProbeTarget target) async => TargetResult(
    target,
    brokenWhen() && target.group == 'Discord'
        ? ProbeOutcome.blocked
        : ProbeOutcome.ok,
    latency: const Duration(milliseconds: 50),
  );
}

void main() {
  late Directory tmp;
  late String builtinDir;
  late String customDir;
  late ZapretBundle bundle;

  void fakeZapret(String dir, String version) {
    File(p.join(dir, 'bin', 'winws.exe')).createSync(recursive: true);
    File(p.join(dir, 'general.bat'))
        .writeAsStringSync('"%BIN%winws.exe" --wf-tcp=80');
    File(p.join(dir, 'service.bat'))
        .writeAsStringSync('set "LOCAL_VERSION=$version"\r\n');
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('zl-bundle-');
    builtinDir = p.join(tmp.path, 'ProgramData', 'zapret');
    customDir = p.join(tmp.path, 'my-zapret');
    fakeZapret(customDir, '1.5.0');

    // Как в сборке: assets/zapret с version.txt и архивом релиза.
    final assets = Directory(p.join(tmp.path, 'assets'))..createSync();
    final src = p.join(tmp.path, 'release', 'zapret-discord-youtube-2.0.0');
    fakeZapret(src, '2.0.0');
    final enc = ZipFileEncoder()
      ..create(p.join(assets.path, 'zapret-2.0.0.zip'));
    await enc.addDirectory(Directory(src));
    await enc.close();
    File(p.join(assets.path, 'version.txt')).writeAsStringSync('2.0.0\n');
    bundle = ZapretBundle(assets);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  SettingsStore store([AppSettings? settings]) {
    final s = SettingsStore(path: p.join(tmp.path, 's.json'));
    if (settings != null) s.save(settings);
    return s;
  }

  Future<AppController> make(
    WidgetTester tester, {
    required SettingsStore settings,
    _FakeRunner? runner,
    bool Function()? brokenWhen,
  }) async {
    final c = AppController(
      toasts: ToastController(),
      store: settings,
      runner: runner ?? _FakeRunner(),
      releases: _OfflineReleases(),
      isElevated: () => true,
      guardFactory: quietGuard,
      watchNetworkEvents: false,
      launcherAutostart: FakeAutostart(),
      prober: _FakeProber(brokenWhen ?? () => false),
      bundle: bundle,
      builtinZapretDir: builtinDir,
    );
    await tester.runAsync(() async {
      c.init();
      // Распаковка, а при обновлении — проверка сайтов до и после (с паузой 3 с).
      await c.prepared;
    });
    return c;
  }

  void done(AppController c) {
    c.dispose();
    c.toasts.dispose();
  }

  test('встроенный zapret: версия есть, только если рядом лежит архив', () {
    expect(bundle.version, '2.0.0');
    final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
    File(p.join(empty.path, 'version.txt')).writeAsStringSync('2.0.0');
    expect(ZapretBundle(empty).version, isNull);
    expect(
      ZapretBundle(Directory(p.join(tmp.path, 'nothing'))).version,
      isNull,
    );
  });

  testWidgets(
    'первый запуск — встроенный zapret распаковывается сам, без интернета',
    (tester) async {
      final c = await make(
        tester,
        settings: store(const AppSettings(autoCheckUpdates: false)),
      );
      expect(c.builtin, isTrue);
      expect(c.settings.zapretSource, ZapretSource.builtin);
      expect(c.install?.root.path, builtinDir);
      expect(c.install?.version, '2.0.0');
      expect(c.strategy?.id, 'general');
      expect(c.previousZapretVersion, isNull);
      expect(c.error, isNull);
      done(c);
    },
  );

  testWidgets('лаунчер обновился — встроенный zapret новее и ставится сам', (
    tester,
  ) async {
    fakeZapret(builtinDir, '1.0.0');
    File(p.join(builtinDir, 'lists', 'list-general-user.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('my.site\r\n');
    final runner = _FakeRunner(root: builtinDir, alive: true);
    final c = await make(
      tester,
      settings: store(
        const AppSettings(
          zapretSource: ZapretSource.builtin,
          autoCheckUpdates: false,
        ),
      ),
      runner: runner,
    );
    expect(c.install!.version, '2.0.0');
    expect(
      c.running,
      isTrue,
      reason: 'zapret запущен снова — уже новой версии',
    );
    expect(runner.starts, 1);
    expect(c.previousZapretVersion, '1.0.0');
    expect(
      File(p.join(builtinDir, 'lists', 'list-general-user.txt'))
          .readAsStringSync(),
      'my.site\r\n',
    );
    done(c);
  });

  testWidgets('встроенный сломал обход — откат, и сам его больше не ставит', (
    tester,
  ) async {
    fakeZapret(builtinDir, '1.0.0');
    final settings = store(
      const AppSettings(
        zapretSource: ZapretSource.builtin,
        autoCheckUpdates: false,
      ),
    );
    final c = await make(
      tester,
      settings: settings,
      runner: _FakeRunner(root: builtinDir, alive: true),
      brokenWhen: () =>
          ZapretInstall.readVersion(Directory(builtinDir)) == '2.0.0',
    );
    expect(c.install!.version, '1.0.0');
    expect(c.settings.skippedZapretVersion, '2.0.0');
    expect(c.running, isTrue);
    done(c);

    // Следующий запуск лаунчера — встроенный 2.0.0 сам не ставится.
    final again = await make(
      tester,
      settings: settings,
      runner: _FakeRunner(root: builtinDir, alive: true),
    );
    expect(again.install!.version, '1.0.0');
    expect(again.updateAvailable, isTrue);
    done(again);
  });

  testWidgets(
    'автообновление выключено — встроенный предлагается, ставится по кнопке',
    (tester) async {
      fakeZapret(builtinDir, '1.0.0');
      final c = await make(
        tester,
        settings: store(
          const AppSettings(
            zapretSource: ZapretSource.builtin,
            autoCheckUpdates: false,
            autoUpdateZapret: false,
          ),
        ),
      );
      expect(c.install!.version, '1.0.0');
      expect(c.updateAvailable, isTrue);
      expect(c.newestZapretVersion, '2.0.0');
      // GitHub недоступен — обновление берётся из лаунчера.
      expect(await tester.runAsync(c.updateZapret), isTrue);
      expect(c.install!.version, '2.0.0');
      done(c);
    },
  );

  testWidgets(
    'своя папка из прежних настроек остаётся своей и не обновляется сама',
    (tester) async {
      final c = await make(
        tester,
        settings: store(
          AppSettings(zapretDir: customDir, autoCheckUpdates: false),
        ),
      );
      expect(c.zapretSource, ZapretSource.custom);
      expect(c.install?.root.path, customDir);
      expect(c.install?.version, '1.5.0');
      expect(
        Directory(builtinDir).existsSync(),
        isFalse,
        reason: 'встроенный не распаковывается зря',
      );
      // Встроенный новее, но своя папка — забота её хозяина.
      expect(c.newestZapretVersion, isNull);
      expect(c.updateAvailable, isFalse);
      done(c);
    },
  );

  testWidgets('настройки 0.1.0 с папкой по умолчанию — это встроенный', (
    tester,
  ) async {
    fakeZapret(builtinDir, '2.0.0');
    final c = await make(
      tester,
      settings: store(
        AppSettings(zapretDir: builtinDir, autoCheckUpdates: false),
      ),
    );
    expect(c.builtin, isTrue);
    expect(c.install?.root.path, builtinDir);
    done(c);
  });

  testWidgets(
    'первый запуск, zapret уже работает из своей папки — его и берём',
    (tester) async {
      final c = await make(
        tester,
        settings: store(const AppSettings(autoCheckUpdates: false)),
        runner: _FakeRunner(root: customDir, alive: true),
      );
      expect(c.zapretSource, ZapretSource.custom);
      expect(c.install?.root.path, customDir);
      expect(c.runningElsewhere, isFalse);
      done(c);
    },
  );

  testWidgets(
    'переключение на свою папку и обратно — zapret переезжает работающим',
    (tester) async {
      final runner = _FakeRunner();
      // Своя папка выбиралась раньше — к ней переходим сразу, без выбора папки.
      final c = await make(
        tester,
        settings: store(
          AppSettings(
            zapretSource: ZapretSource.builtin,
            zapretDir: customDir,
            autoCheckUpdates: false,
          ),
        ),
        runner: runner,
      );
      expect(c.install?.root.path, builtinDir);
      await tester.runAsync(c.start);
      expect(runner.root, builtinDir);

      await tester.runAsync(() => c.setZapretSource(ZapretSource.custom));
      expect(c.zapretSource, ZapretSource.custom);
      expect(c.install?.root.path, customDir);
      expect(runner.root, customDir);
      expect(c.running, isTrue);

      await tester.runAsync(() => c.setZapretSource(ZapretSource.builtin));
      expect(c.builtin, isTrue);
      expect(c.install?.root.path, builtinDir);
      expect(runner.root, builtinDir);
      expect(c.running, isTrue);
      // Своя папка помнится — чтобы вернуться к ней одним нажатием.
      expect(c.settings.zapretDir, customDir);
      expect(runner.starts, 3);
      done(c);
    },
  );

  testWidgets('прежней своей папки нет — встроенный', (tester) async {
    final c = await make(
      tester,
      settings: store(
        AppSettings(
          zapretDir: p.join(tmp.path, 'gone'),
          autoCheckUpdates: false,
        ),
      ),
    );
    expect(c.builtin, isTrue);
    expect(c.install?.version, '2.0.0');
    done(c);
  });
}
