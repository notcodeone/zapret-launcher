import 'package:zapret_launcher/src/location/network_guard.dart';
import 'package:zapret_launcher/src/platform/autostart.dart';

/// Сторож сети без запросов страны и чтения адаптеров — для тестов приложения.
NetworkGuard quietGuard(GuardedZapret zapret, ProfileHook _) => NetworkGuard(
  zapret: zapret,
  enabled: () => false,
  countryEnabled: () => false,
  fingerprint: () async => 'test',
);

/// Автозапуск без Планировщика заданий: помнит состояние в памяти.
class FakeAutostart implements LauncherAutostart {
  AutostartState state = AutostartState.off;
  final calls = <String>[];

  @override
  Future<AutostartState> query() async => state;

  @override
  Future<void> enable(String exe) async {
    calls.add('enable');
    state = AutostartState(registered: true, command: exe);
  }

  @override
  Future<void> disable() async {
    calls.add('disable');
    state = AutostartState.off;
  }
}
