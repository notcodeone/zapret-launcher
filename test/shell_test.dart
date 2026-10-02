import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/controller.dart';

import 'helpers.dart';
import 'package:zapret_launcher/src/platform/window.dart';
import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/shell.dart';
import 'package:zapret_launcher/src/ui/brand.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/install.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';
import 'package:zapret_launcher/src/zapret/strategy.dart';

/// winws.exe, который можно «уронить»; система не трогается.
class _FlakyRunner extends ZapretRunner {
  _FlakyRunner(this.root);

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
  Future<void> killProcesses() async {}

  @override
  Future<void> stopAll() async => alive = false;
}

/// Окно без раннера: запоминает, что с ним делали.
class _FakeWindow extends WindowChannel {
  final calls = <String>[];
  bool visible = true;
  List<TrayMenuEntry> menu = const [];
  String tooltip = '';
  int iconBytes = 0;

  @override
  Future<void> show() async {
    calls.add('show');
    visible = true;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    visible = false;
  }

  @override
  Future<void> quit() async => calls.add('quit');

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<void> setInterceptClose(bool value) async => calls.add('intercept:$value');

  @override
  Future<int> trayIconSize() async => 16;

  @override
  Future<void> setTray({required Uint8List rgba, required int size, required String tooltip}) async {
    iconBytes = rgba.length;
    this.tooltip = tooltip;
  }

  @override
  Future<void> setTrayMenu(List<TrayMenuEntry> items) async => menu = items;

  @override
  Future<void> removeTray() async => calls.add('removeTray');

  @override
  Future<void> balloon(String title, String text) async => calls.add('balloon:$title');
}

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zl-shell-');
    root = p.join(tmp.path, 'zapret');
    File(p.join(root, 'bin', 'winws.exe')).createSync(recursive: true);
    File(p.join(root, 'general.bat')).writeAsStringSync('"%BIN%winws.exe" --wf-tcp=80');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  AppController make(_FlakyRunner runner, {bool closeToTray = true}) {
    final store = SettingsStore(path: p.join(tmp.path, 'settings.json'))
      ..save(AppSettings(zapretDir: root, closeToTray: closeToTray));
    return AppController(
      toasts: ToastController(),
      store: store,
      runner: runner,
      isElevated: () => true,
      guardFactory: quietGuard,
      watchNetworkEvents: false,
      launcherAutostart: FakeAutostart(),
    )..init();
  }

  void dispose(AppController c) {
    c.dispose();
    c.toasts.dispose();
  }

  testWidgets('сторож перезапускает winws.exe, но не больше 3 раз за 5 минут', (tester) async {
    final runner = _FlakyRunner(root);
    final c = make(runner);
    expect(c.running, isTrue);

    for (var i = 1; i <= 3; i++) {
      runner.alive = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(runner.starts, i, reason: 'перезапуск $i');
      expect(c.running, isTrue);
    }

    runner.alive = false;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(runner.starts, 3);
    expect(c.error?.title, contains('снова и снова'));
    dispose(c);
  });

  testWidgets('выключили сами — сторож не вмешивается', (tester) async {
    final runner = _FlakyRunner(root);
    final c = make(runner);
    await c.stop();
    await tester.pump(const Duration(seconds: 5));
    expect(runner.starts, 0);
    expect(c.running, isFalse);
    dispose(c);
  });

  testWidgets('сторож выключен в настройках', (tester) async {
    final runner = _FlakyRunner(root);
    final c = make(runner)..setWatchdog(false);
    runner.alive = false;
    await tester.pump(const Duration(seconds: 5));
    expect(runner.starts, 0);
    dispose(c);
  });

  testWidgets('трей: значок, меню и закрытие в трей', (tester) async {
    final c = make(_FlakyRunner(root));
    final w = _FakeWindow();
    final shell = DesktopShell(c, window: w);
    await tester.runAsync(() async {
      await shell.init();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    expect(w.calls, contains('intercept:true'));
    expect(w.iconBytes, 16 * 16 * 4);
    expect(w.tooltip, contains('Zapret работает — «Стандартная»'));
    expect(w.menu.map((e) => e.label), contains('Выключить zapret'));
    expect(w.menu.last.label, 'Выход');

    // Крестик прячет окно; подсказка — только в первый раз.
    w.onCloseRequested!();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(w.visible, isFalse);
    expect(w.calls.where((e) => e.startsWith('balloon')).length, 1);
    w.onCloseRequested!();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(w.calls.where((e) => e.startsWith('balloon')).length, 1);

    // «Открыть» из меню значка.
    w.onTrayMenu!(1);
    expect(w.visible, isTrue);

    shell.dispose();
    dispose(c);
  });

  testWidgets('без сворачивания в трей крестик закрывает лаунчер', (tester) async {
    final c = make(_FlakyRunner(root), closeToTray: false);
    final w = _FakeWindow();
    final shell = DesktopShell(c, window: w);
    await tester.runAsync(shell.init);
    w.onCloseRequested!();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(w.calls, containsAllInOrder(['removeTray', 'quit']));
    shell.dispose();
    dispose(c);
  });

  test('ico: заголовок, каталог и кадры', () {
    final bmp = icoBitmapFrame(Uint8List(16 * 16 * 4), 16);
    expect(bmp.length, 40 + 16 * 16 * 4 + 4 * 16);
    final png = Uint8List.fromList(List.filled(100, 1));
    final ico = buildIco({256: png, 16: bmp});
    final d = ByteData.sublistView(ico);
    expect(d.getUint16(2, Endian.little), 1); // тип — значок
    expect(d.getUint16(4, Endian.little), 2); // два кадра
    expect(ico[6], 16); // сначала меньший
    expect(ico[6 + 16], 0); // 256 записывается как 0
    final firstOffset = d.getUint32(6 + 12, Endian.little);
    expect(firstOffset, 6 + 16 * 2);
    expect(ico.length, 6 + 32 + bmp.length + png.length);
  });
}
