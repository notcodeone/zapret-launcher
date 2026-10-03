import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/app.dart';
import 'package:zapret_launcher/src/controller.dart';

import 'helpers.dart';

import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/bundle.dart';
import 'package:zapret_launcher/src/zapret/install.dart';
import 'package:zapret_launcher/src/zapret/probe.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';
import 'package:zapret_launcher/src/zapret/strategy.dart';

/// Ничего не запущено и службы нет — независимо от компьютера, где идут тесты.
/// Система не трогается: ни netsh, ни завершения процессов.
class _IdleRunner extends ZapretRunner {
  @override
  RuntimeStatus status() =>
      const RuntimeStatus(processes: [], service: null, serviceStrategy: null);

  @override
  void prepare(ZapretInstall install) {}

  @override
  Future<void> killProcesses() async {}

  @override
  Future<void> stopAll() async {}
}

/// Подбор без winws.exe: у каждой стратегии — свои открывающиеся сервисы.
class _FakeProbeEnv implements ProbeEnvironment {
  _FakeProbeEnv(this.gate);

  /// Задерживает запуск ALT2, чтобы увидеть экран хода проверки.
  final Completer<void> gate;
  String? _running;

  static const _open = {
    null: {'Google'},
    'general (ALT)': {'Google', 'YouTube'},
    'general (ALT2)': {'Google', 'YouTube', 'Discord', 'Cloudflare'},
  };

  @override
  Future<bool> start(Strategy s) async {
    if (s.id == 'general (ALT2)') await gate.future;
    if (s.id == 'general (ALT3)') return false;
    _running = s.id;
    return true;
  }

  @override
  Future<void> stop() async => _running = null;

  @override
  Future<TargetResult> check(ProbeTarget t) async => TargetResult(
    t,
    (_open[_running] ?? const {}).contains(t.group)
        ? ProbeOutcome.ok
        : ProbeOutcome.blocked,
    latency: const Duration(milliseconds: 90),
  );

  @override
  void abort() {}
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('zl-app-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppController> pumpApp(
    WidgetTester tester, {
    String? zapretDir,
    String? route,
    ProbeEnvironment? probe,
  }) async {
    final store = SettingsStore(path: p.join(tmp.path, 'settings.json'));
    if (zapretDir != null) store.save(AppSettings(zapretDir: zapretDir));
    final toasts = ToastController();
    final c = AppController(
      toasts: toasts,
      store: store,
      runner: _IdleRunner(),
      guardFactory: quietGuard,
      watchNetworkEvents: false,
      launcherAutostart: FakeAutostart(),
      probeEnvironment: probe == null ? null : (_, _) => probe,
      builtinZapretDir: p.join(tmp.path, 'builtin'),
      bundle: ZapretBundle(Directory(p.join(tmp.path, 'no-bundle'))),
    )..init();
    tester.view.physicalSize = const Size(560, 640);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      ZapretLauncherApp(controller: c, initialRoute: route),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> dispose(WidgetTester tester, AppController c) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    c.toasts.dispose();
    tester.view.reset();
  }

  testWidgets('без zapret — предлагает скачать или указать папку', (
    tester,
  ) async {
    final c = await pumpApp(
      tester,
      zapretDir: p.join(tmp.path, 'nothing-here'),
    );
    expect(c.install, isNull);
    expect(find.text('Zapret не установлен'), findsOneWidget);
    expect(find.text('Указать папку'), findsOneWidget);
    await dispose(tester, c);
  });

  testWidgets('с zapret — статус, стратегия и переход в настройки', (
    tester,
  ) async {
    final root = Directory(p.join(tmp.path, 'zapret'))..createSync();
    File(p.join(root.path, 'bin', 'winws.exe')).createSync(recursive: true);
    File(p.join(root.path, 'general (ALT3).bat'))
        .writeAsStringSync('start "z" /min "%BIN%winws.exe" --wf-tcp=80\r\n');
    File(p.join(root.path, 'lists', 'ipset-all.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('203.0.113.113/32\r\n');

    final c = await pumpApp(tester, zapretDir: root.path);
    // Главное — крупно: состояние и одна кнопка; стратегия — строкой под ними.
    expect(find.text('Zapret выключен'), findsOneWidget);
    expect(find.textContaining('«ALT3»'), findsOneWidget);
    expect(find.text('Включить'), findsOneWidget);
    expect(find.text('Игровой фильтр и IPSet'), findsOneWidget);

    // Настройки — список разделов; сами настройки — на странице раздела.
    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Основные'), findsOneWidget);
    expect(find.text('Тема'), findsNothing);
    expect(find.text('Своя папка · как general.bat'), findsOneWidget);

    await tester.tap(find.text('Основные'));
    await tester.pumpAndSettle();
    expect(find.text('Тема'), findsOneWidget);

    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zapret'));
    await tester.pumpAndSettle();
    expect(find.text('Как запускать'), findsOneWidget);
    expect(find.text(root.path), findsOneWidget);
    await dispose(tester, c);
  });

  testWidgets('свои списки: добавить, убрать и вернуть', (tester) async {
    final root = Directory(p.join(tmp.path, 'zapret'))..createSync();
    File(p.join(root.path, 'bin', 'winws.exe')).createSync(recursive: true);
    File(p.join(root.path, 'general.bat'))
        .writeAsStringSync('start "z" /min "%BIN%winws.exe" --wf-tcp=80\r\n');
    final listFile = File(p.join(root.path, 'lists', 'list-general-user.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# Never leave this file empty\r\ndomain.example.abc\r\n',
      );

    final c = await pumpApp(tester, zapretDir: root.path, route: '/lists');
    expect(find.text('Здесь пока пусто'), findsOneWidget);

    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://Example.com/page\nпрезидент.рф, не домен!',
    );
    await tester.pump();
    expect(find.textContaining('Не похоже на домен: не'), findsOneWidget);
    expect(find.text('Будет добавлено: 2 сайта'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(NcDialogFrame),
        matching: find.text('Добавить'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('президент.рф'), findsOneWidget);
    expect(find.text('xn--d1abbgf6aiiy.xn--p1ai'), findsOneWidget);
    expect(
      listFile.readAsStringSync(),
      '# Never leave this file empty\r\nexample.com\r\nxn--d1abbgf6aiiy.xn--p1ai\r\n',
    );

    // Убрать и вернуть из оповещения.
    await tester.tap(find.byTooltip('Убрать').first);
    await tester.pumpAndSettle();
    expect(listFile.readAsStringSync(), isNot(contains('example.com\r\n')));
    await tester.tap(find.text('Вернуть'));
    await tester.pumpAndSettle();
    expect(
      listFile.readAsStringSync(),
      '# Never leave this file empty\r\nexample.com\r\nxn--d1abbgf6aiiy.xn--p1ai\r\n',
    );

    // Вкладка исключений — свой файл.
    await tester.tap(find.text('Не трогать'));
    await tester.pumpAndSettle();
    expect(find.text('Здесь пока пусто'), findsOneWidget);
    await dispose(tester, c);
  });

  testWidgets('подбор стратегии: ход проверки и итог', (tester) async {
    final root = Directory(p.join(tmp.path, 'zapret'))..createSync();
    File(p.join(root.path, 'bin', 'winws.exe')).createSync(recursive: true);
    for (final id in ['general (ALT)', 'general (ALT2)', 'general (ALT3)']) {
      File(p.join(root.path, '$id.bat'))
          .writeAsStringSync('start "z" /min "%BIN%winws.exe" --wf-tcp=80\r\n');
    }
    final gate = Completer<void>();
    final c = await pumpApp(
      tester,
      zapretDir: root.path,
      route: '/autopick',
      probe: _FakeProbeEnv(gate),
    );
    expect(find.text('Что проверяем'), findsOneWidget);
    expect(find.text('Начать'), findsOneWidget);

    unawaited(c.autoPick());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // Ждём на ALT2: видны ход проверки, итог без обхода и уже проверенная ALT.
    expect(find.textContaining('Проверяю «ALT2»'), findsWidgets);
    expect(find.text('Без обхода'), findsOneWidget);
    expect(find.text('Остановить'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(c.probing, isFalse);
    expect(find.textContaining('Лучшая — «ALT2»'), findsWidgets);
    expect(find.text('Включить «ALT2»'), findsOneWidget);
    expect(find.text('Не запустилась'), findsOneWidget);
    expect(c.probeReport!.best!.okCount, 12);
    await dispose(tester, c);
  });
}
