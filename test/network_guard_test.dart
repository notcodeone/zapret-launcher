import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapret_launcher/src/location/country.dart';
import 'package:zapret_launcher/src/location/network_guard.dart';
import 'package:zapret_launcher/src/location/provider.dart';

/// zapret без winws.exe: помнит, что с ним делали.
class _FakeZapret implements GuardedZapret {
  @override
  bool running = true;
  @override
  bool busy = false;

  /// Что вернёт проверка «без обхода».
  bool? open = false;
  final log = <String>[];

  @override
  Future<bool> stop({String? status}) async {
    log.add('stop');
    running = false;
    return true;
  }

  @override
  Future<bool> start({String? status}) async {
    log.add('start');
    running = true;
    return true;
  }

  @override
  Future<bool?> servicesOpen() async {
    log.add('check');
    return open;
  }
}

void main() {
  late _FakeZapret zapret;
  late String country;
  late List<String> events;
  late bool enabled;

  NetworkGuard make({String print = 'wifi=192.168.1.5'}) => NetworkGuard(
    zapret: zapret,
    enabled: () => enabled,
    countryEnabled: () => true,
    lookup: () async => (country: country, source: 'test'),
    fingerprint: () async => print,
    onEvent: (title, _) => events.add(title),
    settle: Duration.zero,
  );

  setUp(() {
    zapret = _FakeZapret();
    country = 'RU';
    events = [];
    enabled = true;
  });

  test(
    'включили VPN в другой стране — zapret выключается, вернулись — включается',
    () async {
      final g = make();
      await g.start();
      expect(g.baseline, 'RU');

      // Через VPN всё открывается и без обхода.
      country = 'FI';
      zapret.open = true;
      await g.networkChanged();
      expect(zapret.running, isFalse);
      expect(g.autoOff?.reason, AutoOffReason.countryChanged);
      expect(g.autoOff?.to, 'FI');
      expect(events.single, contains('сменилась страна'));

      // Сеть снова сменилась, но блокировок по-прежнему нет — не включаем.
      await g.networkChanged();
      expect(zapret.running, isFalse);

      // VPN выключили: снова Россия и блокировки.
      country = 'RU';
      zapret.open = false;
      await g.networkChanged();
      expect(zapret.running, isTrue);
      expect(g.autoOff, isNull);
      expect(events.last, 'Zapret снова включён');
      g.dispose();
    },
  );

  test(
    'та же страна, в новой сети блокировок нет — zapret выключается',
    () async {
      final g = make();
      await g.start();
      zapret.open = true;
      await g.networkChanged();
      expect(zapret.log, ['stop', 'check']);
      expect(zapret.running, isFalse);
      expect(g.autoOff?.reason, AutoOffReason.servicesOpen);
      g.dispose();
    },
  );

  test('та же страна, блокировки на месте — zapret снова включён', () async {
    final g = make();
    await g.start();
    zapret.open = false;
    await g.networkChanged();
    expect(zapret.log, ['stop', 'check', 'start']);
    expect(zapret.running, isTrue);
    expect(g.autoOff, isNull);
    expect(events, isEmpty);
    g.dispose();
  });

  test('сети нет — zapret возвращается как был', () async {
    final g = make();
    await g.start();
    zapret.open = null;
    await g.networkChanged();
    expect(zapret.running, isTrue);
    expect(g.autoOff, isNull);
    g.dispose();
  });

  test('выключили сами — сторож не включает', () async {
    zapret.running = false;
    final g = make();
    await g.start();
    g.userStopped();
    await g.networkChanged();
    expect(zapret.log, isEmpty);
    g.dispose();
  });

  test(
    'zapret включили при VPN, VPN выключили — блокировки есть, zapret остаётся',
    () async {
      country = 'FI';
      final g = make();
      await g.start();
      expect(g.baseline, 'FI');

      country = 'RU';
      zapret.open = false;
      await g.networkChanged();
      expect(zapret.log, ['stop', 'check', 'start']);
      expect(zapret.running, isTrue);
      expect(g.autoOff, isNull);
      expect(g.baseline, 'RU');
      g.dispose();
    },
  );

  test('включили сами в другой стране — это новая точка отсчёта', () async {
    final g = make();
    await g.start();
    country = 'FI';
    zapret.open = true;
    await g.networkChanged();
    expect(g.autoOff, isNotNull);
    // Пользователь включил zapret в Финляндии вручную.
    zapret.running = true;
    g.userStarted();
    expect(g.autoOff, isNull);
    expect(g.baseline, 'FI');
    g.dispose();
  });

  test('слежение выключено — только обновляем страну', () async {
    enabled = false;
    final g = make();
    await g.start();
    country = 'FI';
    await g.networkChanged();
    expect(zapret.log, isEmpty);
    expect(g.country, 'FI');
    g.dispose();
  });

  test('смена адресов запускает проверку после паузы', () async {
    var print = 'wifi=192.168.1.5';
    final g = NetworkGuard(
      zapret: zapret,
      enabled: () => true,
      countryEnabled: () => true,
      lookup: () async => (country: country, source: 'test'),
      fingerprint: () async => print,
      settle: const Duration(milliseconds: 20),
      pollEvery: const Duration(milliseconds: 10),
    );
    await g.start();
    country = 'FI';
    zapret.open = true;
    print = 'wifi=192.168.1.5,wg0=10.8.0.2';
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(zapret.running, isFalse);
    expect(g.autoOff?.reason, AutoOffReason.countryChanged);
    g.dispose();
  });

  test('отметили текущую сеть — zapret выключается сразу, без запросов и без слежения', () async {
    var lookups = 0;
    enabled = false;
    final g = NetworkGuard(
      zapret: zapret,
      enabled: () => enabled,
      countryEnabled: () => true,
      lookup: () async {
        lookups++;
        return (country: country, source: 'test');
      },
      providerEnabled: () => true,
      // Сервис провайдера не ответил бы — а он и не нужен: сеть та же.
      providerLookup: () async {
        lookups++;
        throw const SocketException('нет ответа');
      },
      fingerprint: () async => 'wifi',
      onEvent: (title, _) => events.add(title),
    );
    await g.start();
    final before = lookups;

    await g.currentProfileOff('Офис');
    expect(zapret.log, ['stop']);
    expect(g.autoOff?.reason, AutoOffReason.profile);
    expect(g.autoOff?.network, 'Офис');
    expect(events, ['Zapret выключен: сеть «Офис»']);
    expect(lookups, before);

    // Отметку сняли — zapret возвращается.
    await g.currentProfileOn();
    expect(zapret.log, ['stop', 'start']);
    expect(g.autoOff, isNull);
    g.dispose();
  });

  test(
    'лаунчер открыли в сети, где zapret не нужен, — работающий выключается',
    () async {
      Future<ProfileOutcome> office({required bool startup}) async =>
          (decision: ProfileDecision.zapretOff, network: 'Офис');
      NetworkGuard guard() => NetworkGuard(
        zapret: zapret,
        enabled: () => enabled,
        countryEnabled: () => true,
        lookup: () async => (country: country, source: 'test'),
        fingerprint: () async => 'wifi',
        onNetwork: office,
      );

      // Без слежения за сетью сам не трогает.
      enabled = false;
      final off = guard();
      await off.start();
      expect(zapret.log, isEmpty);
      off.dispose();

      enabled = true;
      final g = guard();
      await g.start();
      expect(zapret.log, ['stop']);
      expect(g.autoOff?.reason, AutoOffReason.profile);
      g.dispose();
    },
  );

  group('lookupCountry', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        switch (req.uri.path) {
          case '/bad':
            req.response.write('{"country": "XX"}');
          case '/trace':
            req.response.write('fl=1\nloc=FI\nwarp=off\n');
          case '/fail':
            req.response.statusCode = 500;
        }
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('неизвестный код пропускается, отвечает следующий', () async {
      final r = await lookupCountry(
        sources: [
          CountrySource(
            'bad',
            url('/bad'),
            (b) => RegExp('"country": "(..)"').firstMatch(b)?.group(1),
          ),
          CountrySource(
            'trace',
            url('/trace'),
            (b) =>
                RegExp(r'^loc=(\S+)$', multiLine: true).firstMatch(b)?.group(1),
          ),
        ],
        stagger: const Duration(milliseconds: 10),
      );
      expect(r.country, 'FI');
      expect(r.source, 'trace');
      expect(countryName(r.country), 'Финляндия');
    });

    test('никто не ответил — ошибка со списком причин', () async {
      expect(
        lookupCountry(
          sources: [CountrySource('fail', url('/fail'), (b) => b)],
          stagger: const Duration(milliseconds: 10),
        ),
        throwsA(isA<CountryLookupException>()),
      );
    });
  });

  group('lookupProvider', () {
    late HttpServer server;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.write(switch (req.uri.path) {
          '/ipwho' => '{"success":true,"country_code":"RU","connection":{"asn":12389,"isp":"Rostelecom"}}',
          '/ipapi' => '{"asn":"AS8359","org":"MTS PJSC","country_code":"RU"}',
          _ => '{"success":false}',
        });
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));
    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('ответ ipwho.is', () async {
      final r = await lookupProvider(
        sources: [
          ProviderSource('ipwho', url('/ipwho'), ProviderSource.all[0].parse),
        ],
      );
      expect(r.asn, 'AS12389');
      expect(r.isp, 'Rostelecom');
      expect(r.country, 'RU');
    });

    test('первый без провайдера — отвечает следующий', () async {
      final r = await lookupProvider(
        sources: [
          ProviderSource('bad', url('/bad'), ProviderSource.all[0].parse),
          ProviderSource('ipapi', url('/ipapi'), ProviderSource.all[1].parse),
        ],
        stagger: const Duration(milliseconds: 10),
      );
      expect(r.asn, 'AS8359');
      expect(r.source, 'ipapi');
    });
  });
}
