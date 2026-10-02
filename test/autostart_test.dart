import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/controller.dart';
import 'package:zapret_launcher/src/platform/autostart.dart';
import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';

import 'helpers.dart';

class _IdleRunner extends ZapretRunner {
  @override
  RuntimeStatus status() => const RuntimeStatus(processes: [], service: null, serviceStrategy: null);
}

void main() {
  group('задача Планировщика', () {
    final xml = LauncherAutostart.taskXml(
      exe: r'C:\Program Files\Zapret & Co\ZapretLauncher.exe',
      user: r'PC\Иван',
    );

    test('с XML-объявлением в самом начале', () {
      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-16"?>'));
    });

    test('при входе пользователя, с наивысшими правами и сразу в трей', () {
      expect(xml, contains('<LogonTrigger>'));
      expect(xml, contains(r'<UserId>PC\Иван</UserId>'));
      expect(xml, contains('<RunLevel>HighestAvailable</RunLevel>'));
      expect(xml, contains('<Arguments>--minimized</Arguments>'));
      expect(xml, contains('<LogonType>InteractiveToken</LogonType>'));
    });

    test('без остановки через 72 часа и при работе от батареи', () {
      expect(xml, contains('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'));
      expect(xml, contains('<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'));
      expect(xml, contains('<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'));
      expect(xml, contains('<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'));
    });

    test('путь экранирован', () {
      expect(xml, contains(r'<Command>"C:\Program Files\Zapret &amp; Co\ZapretLauncher.exe"</Command>'));
      expect(xml, contains(r'<WorkingDirectory>C:\Program Files\Zapret &amp; Co</WorkingDirectory>'));
    });

    test('сравнение пути без учёта регистра', () {
      const s = AutostartState(registered: true, command: r'C:\Apps\ZapretLauncher.exe');
      expect(s.matches(r'c:\apps\zapretlauncher.exe'), isTrue);
      expect(s.matches(r'C:\Other\ZapretLauncher.exe'), isFalse);
      expect(AutostartState.off.matches(r'C:\Apps\ZapretLauncher.exe'), isFalse);
    });
  });

  testWidgets('переключатель добавляет и убирает задачу', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('zl-auto-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final autostart = FakeAutostart();
    final c = AppController(
      toasts: ToastController(),
      store: SettingsStore(path: p.join(tmp.path, 's.json')),
      runner: _IdleRunner(),
      isElevated: () => true,
      guardFactory: quietGuard,
      watchNetworkEvents: false,
      launcherAutostart: autostart,
    );
    await tester.runAsync(() async {
      c.init();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(c.launcherAutostart?.registered, isFalse);

    await tester.runAsync(() => c.setLauncherAutostart(true));
    expect(autostart.calls, ['enable']);
    expect(c.launcherAutostart!.matches(c.launcherPath), isTrue);

    await tester.runAsync(() => c.setLauncherAutostart(false));
    expect(c.launcherAutostart!.registered, isFalse);
    c.dispose();
    c.toasts.dispose();
  });
}
