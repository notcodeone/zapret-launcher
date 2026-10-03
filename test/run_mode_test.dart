import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/app.dart';
import 'package:zapret_launcher/src/controller.dart';
import 'package:zapret_launcher/src/platform/win32.dart' as win;
import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/bundle.dart';
import 'package:zapret_launcher/src/zapret/install.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';
import 'package:zapret_launcher/src/zapret/strategy.dart';

import 'helpers.dart';

/// zapret понарошку: процесс и служба — флажки. Систему не трогает: настоящие
/// installService/removeService/unloadDriver поставили бы службу на машине тестов.
class _FakeRunner extends ZapretRunner {
  _FakeRunner(this.root);

  final String root;
  bool process = false;
  bool serviceInstalled = false;
  bool serviceRunning = false;
  final log = <String>[];

  @override
  RuntimeStatus status() => RuntimeStatus(
    processes: process || serviceRunning
        ? [WinwsProcess(1, p.join(root, 'bin', 'winws.exe'))]
        : const [],
    service: serviceInstalled
        ? win.ServiceInfo(
            state: serviceRunning
                ? win.ServiceState.running
                : win.ServiceState.stopped,
            binaryPath: '"${p.join(root, 'bin', 'winws.exe')}" --wf-tcp=80',
          )
        : null,
    serviceStrategy: serviceInstalled ? 'general' : null,
  );

  @override
  void prepare(ZapretInstall install) {}

  @override
  Future<void> startProcess(
    ZapretInstall install,
    Strategy strategy,
    GameFilter filter,
  ) async {
    log.add('process');
    process = true;
  }

  @override
  Future<void> installService(
    ZapretInstall install,
    Strategy strategy,
    GameFilter filter, {
    bool start = true,
  }) async {
    log.add(start ? 'service+start' : 'service');
    serviceInstalled = true;
    serviceRunning = start;
  }

  @override
  Future<void> startService() async => serviceRunning = true;

  @override
  Future<void> stopAll() async {
    process = false;
    serviceRunning = false;
  }

  @override
  Future<void> removeService({bool cleanupDriver = true}) async {
    log.add('remove');
    serviceInstalled = false;
    serviceRunning = false;
  }

  @override
  Future<void> killProcesses() async {}
  @override
  Future<void> unloadDriver() async {}
}

void main() {
  late Directory tmp;
  late String root;
  late _FakeRunner runner;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zl-mode-');
    root = p.join(tmp.path, 'zapret');
    File(p.join(root, 'bin', 'winws.exe')).createSync(recursive: true);
    File(p.join(root, 'general.bat'))
        .writeAsStringSync('"%BIN%winws.exe" --wf-tcp=80');
    runner = _FakeRunner(root);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // Пусть доделает своё после init (проверка автозапуска лаунчера), прежде чем закрыть.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  AppController make({AppSettings? settings, String? rawJson}) {
    final store = SettingsStore(path: p.join(tmp.path, 's.json'));
    if (settings != null) store.save(settings);
    if (rawJson != null) {
      File(p.join(tmp.path, 's.json')).writeAsStringSync(rawJson);
    }
    return AppController(
      toasts: ToastController(),
      store: store,
      runner: runner,
      isElevated: () => true,
      guardFactory: quietGuard,
      watchNetworkEvents: false,
      launcherAutostart: FakeAutostart(),
      bundle: ZapretBundle(Directory(p.join(tmp.path, 'no-bundle'))),
      builtinZapretDir: p.join(tmp.path, 'builtin'),
    );
  }

  testWidgets(
    'новая установка — спросим; прежняя версия или служба уже стоит — нет',
    (tester) async {
      await tester.runAsync(() async {
        final fresh = make(
          settings: AppSettings(zapretDir: root, autoCheckUpdates: false),
        )..init();
        expect(fresh.needsRunModeChoice, isTrue);
        await settle();
        fresh.dispose();

        // Настройки от версии без этого вопроса: zapret уже запускали.
        final old = make(
          rawJson:
              '{"zapretDir": ${'"${root.replaceAll(r'\', r'\\')}"'}, "autoCheckUpdates": false}',
        )..init();
        expect(old.needsRunModeChoice, isFalse);
        await settle();
        old.dispose();

        runner.serviceInstalled = true;
        final withService = make(
          settings: AppSettings(zapretDir: root, autoCheckUpdates: false),
        )..init();
        expect(withService.needsRunModeChoice, isFalse);
        await settle();
        withService.dispose();
      });
    },
  );

  testWidgets(
    'первое включение службой — служба ставится и запускается, больше не спросим',
    (tester) async {
      final c = make(
        settings: AppSettings(zapretDir: root, autoCheckUpdates: false),
      );
      await tester.runAsync(() async {
        c.init();
        await c.startFirstTime(service: true);
      });
      expect(runner.log, ['service+start']);
      expect(c.running, isTrue);
      expect(c.autostart, isTrue);
      expect(c.needsRunModeChoice, isFalse);
      expect(c.settings.runModeAsked, isTrue);
      c.dispose();
    },
  );

  testWidgets('смена способа не включает выключенный zapret', (tester) async {
    final c = make(
      settings: AppSettings(zapretDir: root, autoCheckUpdates: false),
    );
    await tester.runAsync(() async {
      c.init();
      await c.setAutostart(true);
    });
    expect(runner.log, ['service']);
    expect(c.autostart, isTrue);
    expect(c.running, isFalse);

    // Обратно — как general.bat: служба убирается, zapret так и не включён.
    await tester.runAsync(() => c.setAutostart(false));
    expect(runner.log, ['service', 'remove']);
    expect(c.autostart, isFalse);
    expect(c.running, isFalse);
    c.dispose();
  });

  testWidgets('на главной первое «Включить» спрашивает, как запускать', (
    tester,
  ) async {
    final c = make(
      settings: AppSettings(zapretDir: root, autoCheckUpdates: false),
    )..init();
    tester.view.physicalSize = const Size(560, 640);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(ZapretLauncherApp(controller: c));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NcButton, 'Включить'));
    await tester.pumpAndSettle();
    expect(find.text('Как запускать zapret?'), findsOneWidget);
    expect(find.text('Как general.bat'), findsOneWidget);

    await tester.tap(find.text('Как general.bat'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(NcDialogButton, 'Включить'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(runner.log, ['process']);
    expect(c.running, isTrue);
    expect(c.settings.runModeAsked, isTrue);

    await tester.pumpWidget(const SizedBox());
    c.dispose();
    c.toasts.dispose();
    tester.view.reset();
  });
}
