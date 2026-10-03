import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/controller.dart';
import 'package:zapret_launcher/src/location/network_guard.dart';
import 'package:zapret_launcher/src/location/profiles.dart';
import 'package:zapret_launcher/src/location/provider.dart';
import 'package:zapret_launcher/src/settings.dart';
import 'package:zapret_launcher/src/ui/ui.dart';
import 'package:zapret_launcher/src/zapret/install.dart';
import 'package:zapret_launcher/src/zapret/runner.dart';
import 'package:zapret_launcher/src/zapret/strategy.dart';

import 'helpers.dart';

/// winws.exe понарошку: помнит, с какой стратегией его запустили.
class _FakeRunner extends ZapretRunner {
  _FakeRunner(this.root);

  final String root;
  bool alive = true;
  String? started;

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
    started = strategy.id;
    alive = true;
  }

  @override
  Future<void> killProcesses() async {}

  @override
  Future<void> stopAll() async => alive = false;
}

/// Мост к контроллеру, но «открываются ли сайты без обхода» решает тест.
class _Bridge implements GuardedZapret {
  _Bridge(this.inner);

  final GuardedZapret inner;
  bool? open = false;

  @override
  bool get running => inner.running;
  @override
  bool get busy => inner.busy;
  @override
  Future<bool> stop({String? status}) => inner.stop(status: status);
  @override
  Future<bool> start({String? status}) => inner.start(status: status);
  @override
  Future<bool?> servicesOpen() async => open;
}

void main() {
  test('номер AS и короткое имя провайдера', () {
    expect(normalizeAsn('12389'), 'AS12389');
    expect(normalizeAsn('as8359'), 'AS8359');
    expect(normalizeAsn('Rostelecom'), isNull);
    expect(providerShortName('PJSC Rostelecom', 'AS12389'), 'Rostelecom');
    expect(providerShortName('Rostelecom networks', 'AS12389'), 'Rostelecom');
    expect(providerShortName('MTS PJSC', 'AS8359'), 'MTS');
    expect(providerShortName(null, 'AS1'), 'AS1');
  });

  test('профили переживают сохранение настроек', () {
    final tmp = Directory.systemTemp.createTempSync('zl-prof-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = SettingsStore(path: p.join(tmp.path, 's.json'));
    store.save(AppSettings(profiles: [
      NetworkProfile(
        asn: 'AS12389',
        name: 'Дом',
        isp: 'Rostelecom',
        strategy: 'general (ALT5)',
        gameFilter: GameFilterMode.tcp,
        ipset: IpsetMode.loaded,
        zapretOff: true,
        lastSeen: DateTime(2026, 10, 2),
      ),
    ]));
    final loaded = store.load().profiles.single;
    expect(loaded.name, 'Дом');
    expect(loaded.strategy, 'general (ALT5)');
    expect(loaded.gameFilter, GameFilterMode.tcp);
    expect(loaded.ipset, IpsetMode.loaded);
    expect(loaded.zapretOff, isTrue);
  });

  testWidgets('стратегия запоминается для сети и возвращается при возвращении', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('zl-prof-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final root = p.join(tmp.path, 'zapret');
    File(p.join(root, 'bin', 'winws.exe')).createSync(recursive: true);
    for (final id in ['general', 'general (ALT2)', 'general (ALT3)']) {
      File(p.join(root, '$id.bat')).writeAsStringSync('"%BIN%winws.exe" --wf-tcp=80');
    }
    final store = SettingsStore(path: p.join(tmp.path, 's.json'))
      ..save(AppSettings(zapretDir: root, strategy: 'general', networkGuard: true));

    var asn = 'AS12389';
    final runner = _FakeRunner(root);
    late _Bridge bridge;
    final c = AppController(
      toasts: ToastController(),
      store: store,
      runner: runner,
      isElevated: () => true,
      watchNetworkEvents: false,
      launcherAutostart: FakeAutostart(),
      guardFactory: (zapret, onNetwork) {
        bridge = _Bridge(zapret);
        return NetworkGuard(
          zapret: bridge,
          enabled: () => true,
          countryEnabled: () => true,
          lookup: () async => (country: 'RU', source: 'test'),
          providerEnabled: () => true,
          providerLookup: () async =>
              (asn: asn, isp: asn == 'AS12389' ? 'PJSC Rostelecom' : 'MTS PJSC', country: 'RU', source: 'test'),
          fingerprint: () async => 'net',
          onNetwork: onNetwork,
          settle: Duration.zero,
        );
      },
    );
    await tester.runAsync(() async {
      c.init();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    // Первая сеть, где zapret уже работает, — запомнилась сама.
    expect(c.profiles.single.asn, 'AS12389');
    expect(c.profiles.single.name, 'Rostelecom');
    expect(c.isNewNetwork, isFalse);

    // Выбрали стратегию — профиль её помнит.
    await tester.runAsync(() => c.selectStrategy(c.install!.strategyById('general (ALT2)')!));
    expect(c.profileFor('AS12389')!.strategy, 'general (ALT2)');

    // Новая сеть: блокировки есть — zapret снова включён, но своей стратегии нет.
    asn = 'AS8359';
    await tester.runAsync(c.guard.networkChanged);
    expect(c.running, isTrue);
    expect(c.isNewNetwork, isTrue);
    expect(c.currentNetworkName, 'MTS');
    await tester.runAsync(() => c.selectStrategy(c.install!.strategyById('general (ALT3)')!));
    expect(c.profileFor('AS8359')!.strategy, 'general (ALT3)');
    expect(c.isNewNetwork, isFalse);

    // Вернулись домой — стратегия переключилась сама.
    asn = 'AS12389';
    await tester.runAsync(c.guard.networkChanged);
    expect(c.strategy!.id, 'general (ALT2)');
    expect(runner.started, 'general (ALT2)');
    expect(c.running, isTrue);

    // В сети МТС zapret не нужен.
    c.setProfileZapretOff('AS8359', true);
    asn = 'AS8359';
    await tester.runAsync(c.guard.networkChanged);
    expect(c.running, isFalse);
    expect(c.guard.autoOff?.reason, AutoOffReason.profile);
    expect(c.guard.autoOff?.network, 'MTS');

    // Домой — блокировки есть, включаем с домашней стратегией.
    asn = 'AS12389';
    bridge.open = false;
    await tester.runAsync(c.guard.networkChanged);
    expect(c.running, isTrue);
    expect(runner.started, 'general (ALT2)');

    // Отметили сеть, в которой компьютер сейчас, — zapret выключается сразу.
    c.setProfileZapretOff('AS12389', true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(c.running, isFalse);
    expect(c.guard.autoOff?.reason, AutoOffReason.profile);
    expect(c.guard.autoOff?.network, 'Rostelecom');

    // Сняли отметку — zapret снова работает.
    c.setProfileZapretOff('AS12389', false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(c.running, isTrue);
    expect(c.guard.autoOff, isNull);

    c.dispose();
    c.toasts.dispose();
  });
}
