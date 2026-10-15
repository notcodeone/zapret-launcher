import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/app.dart';
import 'package:zapret_launcher/src/controller.dart';
import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/telegram/desktop.dart';
import 'package:zapret_launcher/src/telegram/telegram_proxy.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/bundle.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';

import 'helpers.dart';

/// Прокси понарошку: без изолята и сокетов, порт можно «занять».
class _FakeProxy extends TelegramProxy {
  final starts = <(String, int)>[];
  int stops = 0;
  bool portBusy = false;
  bool _running = false;

  @override
  bool get running => _running;

  @override
  Future<void> start({required String secret, required int port}) async {
    starts.add((secret, port));
    if (portBusy) {
      throw TelegramProxyException('Порт $port занят другой программой');
    }
    _running = true;
  }

  @override
  Future<void> stop() async {
    if (_running) stops++;
    _running = false;
  }

  void crash() {
    _running = false;
    onCrash?.call();
  }
}

/// zapret не установлен и не запущен — Windows не опрашиваем.
class _IdleRunner extends ZapretRunner {
  @override
  RuntimeStatus status() =>
      const RuntimeStatus(processes: [], service: null, serviceStrategy: null);
}

/// Telegram Desktop понарошку: установлен ли, запущен ли и что открывали.
class _FakeDesktop extends TelegramDesktop {
  bool isInstalled = true;
  bool isRunning = false;
  final opened = <String>[];

  @override
  bool get installed => isInstalled;

  @override
  bool get running => isRunning;

  @override
  bool open(String link, {required bool elevated}) {
    opened.add(link);
    return true;
  }
}

void main() {
  late Directory tmp;
  late _FakeProxy proxy;
  late _FakeDesktop desktop;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zl-tg-');
    proxy = _FakeProxy();
    desktop = _FakeDesktop();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  SettingsStore store() => SettingsStore(path: p.join(tmp.path, 's.json'));

  AppController make([AppSettings settings = const AppSettings()]) {
    final s = store()..save(settings.copyWith(autoCheckUpdates: false));
    return AppController(
      toasts: ToastController(),
      store: s,
      runner: _IdleRunner(),
      isElevated: () => true,
      guardFactory: quietGuard,
      watchNetworkEvents: false,
      launcherAutostart: FakeAutostart(),
      bundle: ZapretBundle(Directory(p.join(tmp.path, 'no-bundle'))),
      builtinZapretDir: p.join(tmp.path, 'builtin'),
      telegramProxy: proxy,
      telegramDesktop: desktop,
    );
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  testWidgets('включение: секрет создаётся и сохраняется, ссылка с ним', (
    tester,
  ) async {
    final c = make();
    await tester.runAsync(() async {
      c.init();
      await c.setTelegramProxy(true);
    });
    expect(c.telegramState, TelegramProxyState.on);
    final secret = store().load().telegramSecret!;
    expect(isTelegramSecret(secret), isTrue);
    expect(proxy.starts, [(secret, 1443)]);
    expect(c.telegramLink, endsWith('port=1443&secret=dd$secret'));
    expect(store().load().telegramProxy, isTrue);

    await tester.runAsync(() => c.setTelegramProxy(false));
    expect(c.telegramState, TelegramProxyState.off);
    expect(proxy.stops, 1);
    expect(store().load().telegramProxy, isFalse);
    // Секрет остаётся: ссылка в Telegram не устареет.
    expect(store().load().telegramSecret, secret);
    await tester.runAsync(settle);
    c.dispose();
  });

  testWidgets('включённый прокси запускается сам — с тем же секретом', (
    tester,
  ) async {
    const secret = '00112233445566778899aabbccddeeff';
    final c = make(
      const AppSettings(telegramProxy: true, telegramSecret: secret),
    );
    await tester.runAsync(() async {
      c.init();
      await settle();
    });
    expect(proxy.starts, [(secret, 1443)]);
    expect(c.telegramState, TelegramProxyState.on);
    c.dispose();
  });

  testWidgets('порт занят — ошибка; освободили — «Ещё раз» запускает', (
    tester,
  ) async {
    proxy.portBusy = true;
    final c = make();
    await tester.runAsync(() async {
      c.init();
      await c.setTelegramProxy(true);
    });
    expect(c.telegramState, TelegramProxyState.failed);
    expect(c.telegramError?.title, contains('занят'));

    proxy.portBusy = false;
    await tester.runAsync(c.retryTelegramProxy);
    expect(c.telegramState, TelegramProxyState.on);
    expect(c.telegramError, isNull);
    await tester.runAsync(settle);
    c.dispose();
  });

  testWidgets('упал — запускается снова, но не бесконечно', (tester) async {
    final c = make();
    await tester.runAsync(() async {
      c.init();
      await c.setTelegramProxy(true);
      for (var i = 0; i < 3; i++) {
        proxy.crash();
        expect(c.telegramState, TelegramProxyState.starting);
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        expect(c.telegramState, TelegramProxyState.on);
      }
      proxy.crash();
    });
    expect(proxy.starts, hasLength(4));
    expect(c.telegramState, TelegramProxyState.failed);
    expect(c.telegramError?.title, contains('снова и снова'));
    await tester.runAsync(settle);
    c.dispose();
  });

  testWidgets(
    'упал и выключили-включили до перезапуска — без лишнего запуска',
    (tester) async {
      final c = make();
      await tester.runAsync(() async {
        c.init();
        await c.setTelegramProxy(true);
        proxy.crash();
        await c.setTelegramProxy(false);
        await c.setTelegramProxy(true);
        await Future<void>.delayed(const Duration(milliseconds: 2200));
      });
      expect(proxy.starts, hasLength(2));
      expect(c.telegramState, TelegramProxyState.on);
      await tester.runAsync(settle);
      c.dispose();
    },
  );

  testWidgets('упал и лаунчер закрывается — прокси не запускается снова', (
    tester,
  ) async {
    final c = make();
    await tester.runAsync(() async {
      c.init();
      await c.setTelegramProxy(true);
      proxy.crash();
      await c.prepareToQuit();
      await Future<void>.delayed(const Duration(milliseconds: 2200));
    });
    expect(proxy.starts, hasLength(1));
    expect(proxy.running, isFalse);
    await tester.runAsync(settle);
    c.dispose();
  });

  testWidgets('«Экспериментальные функции»: прокси включается оттуда', (
    tester,
  ) async {
    final c = make();
    c.init();
    tester.view.physicalSize = const Size(560, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(ZapretLauncherApp(controller: c));
    await tester.pumpAndSettle();
    // Выключенный прокси на главной не показывается.
    expect(find.text('Telegram'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ZapretLauncherApp(controller: c, initialRoute: '/settings/experimental'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Экспериментальные функции'), findsWidgets);
    await tester.tap(find.byType(NcSwitch));
    await tester.runAsync(settle);
    await tester.pumpAndSettle();
    expect(c.settings.telegramProxy, isTrue);
    expect(proxy.starts, hasLength(1));
    expect(c.telegramState, TelegramProxyState.on);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(ZapretLauncherApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('Работает'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    tester.view.reset();
    c.dispose();
  });

  testWidgets('страница Telegram: включённый прокси — кнопка «Подключить»', (
    tester,
  ) async {
    final c = make();
    await tester.runAsync(() async {
      c.init();
      await c.setTelegramProxy(true);
    });
    await tester.pumpWidget(
      ZapretLauncherApp(controller: c, initialRoute: '/telegram'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Прокси для Telegram'), findsOneWidget);
    expect(find.text('Подключить'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:1443'), findsWidgets);

    await tester.tap(find.byType(NcSwitch));
    await tester.runAsync(settle);
    await tester.pumpAndSettle();
    expect(c.telegramState, TelegramProxyState.off);
    expect(find.text('Подключить'), findsNothing);
    c.dispose();
  });

  group('«Подключить»', () {
    Future<AppController> openPage(WidgetTester tester) async {
      final c = make();
      await tester.runAsync(() async {
        c.init();
        await c.setTelegramProxy(true);
      });
      await tester.pumpWidget(
        ZapretLauncherApp(controller: c, initialRoute: '/telegram'),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('Telegram закрыт — сначала спрашиваем, запускать ли', (
      tester,
    ) async {
      final c = await openPage(tester);
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();
      expect(find.text('Запустить Telegram?'), findsOneWidget);

      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(desktop.opened, isEmpty);

      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запустить'));
      await tester.pumpAndSettle();
      expect(desktop.opened, [c.telegramLink]);
      c.dispose();
    });

    testWidgets('Telegram открыт — ссылка сразу, без вопроса', (tester) async {
      desktop.isRunning = true;
      final c = await openPage(tester);
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();
      expect(find.text('Запустить Telegram?'), findsNothing);
      expect(desktop.opened, [c.telegramLink]);
      c.dispose();
    });

    testWidgets('Telegram Desktop не установлен — ссылка копируется', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      desktop.isInstalled = false;
      final c = await openPage(tester);
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();
      expect(find.text('Запустить Telegram?'), findsNothing);
      expect(desktop.opened, isEmpty);
      expect(copied, c.telegramLink);
      expect(find.textContaining('не найден'), findsOneWidget);
      // Подсказка висит 6 секунд — дожидаемся, чтобы не осталось таймера.
      await tester.pumpAndSettle(const Duration(seconds: 7));
      c.dispose();
    });
  });
}
