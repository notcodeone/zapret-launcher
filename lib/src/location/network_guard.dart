import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/network_watch.dart';
import 'country.dart';
import 'provider.dart';

/// Почему лаунчер сам выключил zapret.
enum AutoOffReason {
  /// Сменилась страна — например, включили VPN.
  countryChanged,

  /// В новой сети Discord и YouTube открываются и без обхода.
  servicesOpen,

  /// В профиле этой сети отмечено, что zapret не нужен.
  profile,
}

class AutoOff {
  const AutoOff(
    this.reason, {
    required this.at,
    this.from,
    this.to,
    this.network,
  });

  final AutoOffReason reason;
  final DateTime at;

  /// Страна, в которой zapret был включён.
  final String? from;

  /// Страна сейчас.
  final String? to;

  /// Имя сети из профиля.
  final String? network;
}

/// Что сделал профиль сети, когда сеть определилась.
enum ProfileDecision {
  /// Профиля нет или всё и так как надо.
  none,

  /// Профиль сменил стратегию или настройки — zapret нужно перезапустить.
  changed,

  /// В этой сети zapret не нужен.
  zapretOff,
}

typedef ProfileOutcome = ({ProfileDecision decision, String? network});

/// Профиль сети применяет свои настройки; [startup] — при запуске лаунчера.
typedef ProfileHook = Future<ProfileOutcome> Function({required bool startup});

/// Что сторож сети может делать с zapret. В приложении — контроллер, в тестах — подделка.
abstract interface class GuardedZapret {
  bool get running;

  /// Лаунчер занят другим действием — сторож подождёт.
  bool get busy;

  /// Выключить zapret. false — не получилось. [status] — что показать в шапке.
  Future<bool> stop({String? status});

  /// Включить zapret. false — не получилось.
  Future<bool> start({String? status});

  /// Открываются ли Discord и YouTube без обхода — zapret в это время выключен.
  /// null — сети нет, понять нельзя.
  Future<bool?> servicesOpen();
}

/// Сторож сети: при смене сети или страны решает, нужен ли сейчас обход.
///
/// Смену сети узнаём сразу — от Windows ([networkEvent]) и по отпечатку адресов
/// раз в [pollEvery]; потом ждём [settle], пока сеть устоится (VPN поднимает
/// адаптер, DHCP выдаёт адрес). Раз в [countryEvery] сверяем страну и без смены
/// адресов: VPN может сменить сервер.
class NetworkGuard extends ChangeNotifier {
  NetworkGuard({
    required this.zapret,
    required this.enabled,
    required this.countryEnabled,
    CountryLookup? lookup,
    Future<String> Function()? fingerprint,
    ProviderLookup? providerLookup,
    bool Function()? providerEnabled,
    this.onNetwork,
    bool Function()? canControl,
    this.onEvent,
    this.settle = const Duration(seconds: 3),
    this.pollEvery = const Duration(seconds: 5),
    this.countryEvery = const Duration(minutes: 5),
    this.countryMaxAge = const Duration(minutes: 1),
  }) : _lookup = lookup ?? lookupCountry,
       _fingerprint = fingerprint ?? networkFingerprint,
       _providerLookup = providerLookup ?? lookupProvider,
       _providerEnabled = providerEnabled ?? (() => false),
       _canControl = canControl ?? (() => true);

  final ProviderLookup _providerLookup;
  final bool Function() _providerEnabled;

  /// Можно ли сейчас включать и выключать zapret (есть права администратора).
  final bool Function() _canControl;

  /// Сеть определилась — профиль сети применяет свои настройки.
  /// [startup] — при запуске лаунчера: работающий zapret не перезапускать.
  final ProfileHook? onNetwork;

  // ── Провайдер ──

  /// Номер AS провайдера: «AS12389»; null — неизвестен.
  String? asn;

  /// Название провайдера от сервиса.
  String? isp;
  DateTime? providerCheckedAt;
  Future<ProviderResult?>? _pendingProvider;

  /// Узнаёт провайдера — для профилей сетей.
  Future<ProviderResult?> checkProvider({bool force = false}) {
    if (!_providerEnabled()) {
      asn = null;
      isp = null;
      return Future.value(null);
    }
    if (_pendingProvider case final pending?) return pending;
    final checkedAt = providerCheckedAt;
    if (!force &&
        asn != null &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < countryMaxAge) {
      return Future.value((asn: asn!, isp: isp, country: country, source: ''));
    }
    return _pendingProvider = () async {
      try {
        final r = await _providerLookup();
        asn = r.asn;
        isp = r.isp;
        return r;
      } on Object {
        asn = null;
        isp = null;
        return null;
      } finally {
        providerCheckedAt = DateTime.now();
        _pendingProvider = null;
        _notify();
      }
    }();
  }

  final GuardedZapret zapret;

  /// Включено ли автоматическое выключение и включение zapret.
  final bool Function() enabled;

  /// Можно ли спрашивать страну у внешних сервисов.
  final bool Function() countryEnabled;

  /// Что сделал сторож — для оповещения: заголовок и подробность.
  final void Function(String title, String text)? onEvent;

  final Duration settle;
  final Duration pollEvery;
  final Duration countryEvery;
  final Duration countryMaxAge;

  final CountryLookup _lookup;
  final Future<String> Function() _fingerprint;

  // ── Страна ──

  /// Код страны ISO 3166-1; null — неизвестна.
  String? country;

  /// Какой сервис назвал страну.
  String? countrySource;
  DateTime? countryCheckedAt;

  /// Почему не удалось узнать страну.
  String? countryError;
  bool checkingCountry = false;
  Future<CountryResult?>? _pendingCountry;

  // ── Решения ──

  /// Страна, в которой zapret включили. Сменилась — обход, скорее всего, не нужен.
  String? baseline;

  /// zapret выключен сторожем; null — нет.
  AutoOff? autoOff;

  /// Сторож разбирается со сменой сети.
  bool handling = false;

  String? _lastPrint;
  Timer? _poll;
  Timer? _settleTimer;
  Timer? _countryTimer;
  bool _again = false;
  bool _disposed = false;

  String? get countryLabel => country == null ? null : countryName(country!);

  Future<void> start() async {
    _lastPrint = await _safeFingerprint();
    if (_disposed) return;
    _poll = Timer.periodic(pollEvery, (_) => _checkFingerprint());
    _countryTimer = Timer.periodic(countryEvery, (_) => _periodicCountry());
    final r = await checkCountry();
    // Лаунчер открыли, а zapret уже работает — считаем, что включили его здесь.
    if (zapret.running && baseline == null) baseline = r?.country;
    await checkProvider();
    if (_disposed) return;
    final profile = await onNetwork?.call(startup: true);
    // Лаунчер открыли в сети, где zapret не нужен, а он работает — например, служба
    // включилась вместе с Windows.
    if (profile?.decision == ProfileDecision.zapretOff &&
        enabled() &&
        zapret.running &&
        !_disposed) {
      await currentProfileOff(profile!.network ?? 'эта');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _settleTimer?.cancel();
    _countryTimer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Windows сообщила о смене адресов.
  void networkEvent() => unawaited(_checkFingerprint());

  /// Пользователь включил zapret сам: запоминаем страну, автоматика сбрасывается.
  void userStarted() {
    autoOff = null;
    final fresh =
        countryCheckedAt != null &&
        DateTime.now().difference(countryCheckedAt!) < countryMaxAge;
    if (fresh && country != null) {
      baseline = country;
    } else {
      unawaited(
        checkCountry(force: true)
            .then((r) => baseline = r?.country ?? baseline),
      );
    }
    _notify();
  }

  /// Пользователь выключил zapret сам — сторож его не включит.
  void userStopped() {
    autoOff = null;
    baseline = null;
    _notify();
  }

  /// Узнаёт страну; свежий ответ переиспользует, одновременные проверки сливает в одну.
  Future<CountryResult?> checkCountry({bool force = false}) {
    if (!countryEnabled()) {
      country = null;
      countrySource = null;
      return Future.value(null);
    }
    if (_pendingCountry case final pending?) return pending;
    final checkedAt = countryCheckedAt;
    if (!force &&
        country != null &&
        checkedAt != null &&
        DateTime.now().difference(checkedAt) < countryMaxAge) {
      return Future.value((country: country!, source: countrySource ?? ''));
    }
    return _pendingCountry = _doCheckCountry();
  }

  Future<CountryResult?> _doCheckCountry() async {
    checkingCountry = true;
    _notify();
    try {
      final r = await _lookup();
      country = r.country;
      countrySource = r.source;
      countryError = null;
      return r;
    } on Object catch (e) {
      country = null;
      countrySource = null;
      countryError = '$e';
      return null;
    } finally {
      countryCheckedAt = DateTime.now();
      checkingCountry = false;
      _pendingCountry = null;
      _notify();
    }
  }

  Future<String?> _safeFingerprint() async {
    try {
      return await _fingerprint();
    } on Object {
      return null;
    }
  }

  Future<void> _checkFingerprint() async {
    final current = await _safeFingerprint();
    if (current == null || current == _lastPrint) return;
    final first = _lastPrint == null;
    _lastPrint = current;
    if (first) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, () => unawaited(networkChanged()));
  }

  Future<void> _periodicCountry() async {
    if (handling || !countryEnabled()) return;
    final before = country;
    final r = await checkCountry(force: true);
    // VPN сменил сервер, а адреса компьютера остались прежними.
    if (r != null && before != null && r.country != before) {
      await networkChanged();
    }
  }

  /// Подождать, пока лаунчер закончит своё (подбор стратегии, перезапуск). false — не дождались.
  Future<bool> _waitIdle() async {
    for (var i = 0; zapret.busy && i < 150; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return !zapret.busy;
  }

  /// Пользователь отметил сеть, в которой компьютер сейчас: zapret здесь не нужен.
  /// Выключаем сразу и без новых запросов страны и провайдера — сеть та же, а ответа
  /// сервиса можно и не дождаться. Это прямое указание, поэтому — и без слежения за сетью.
  Future<void> currentProfileOff(String network) async {
    if (handling) {
      // Сторож и так разбирается с сетью — профиль он прочитает уже с отметкой.
      _again = true;
      return;
    }
    if (!_canControl() || !await _waitIdle()) return;
    final off = AutoOff(
      AutoOffReason.profile,
      at: DateTime.now(),
      from: baseline,
      to: country,
      network: network,
    );
    if (zapret.running) {
      if (!await zapret.stop(
        status: 'Выключаю zapret — в сети «$network» он не нужен…',
      )) {
        return;
      }
      autoOff = off;
      onEvent?.call(
        'Zapret выключен: сеть «$network»',
        'В этой сети zapret не нужен — так отмечено в её профиле.',
      );
    } else if (autoOff != null) {
      autoOff = off;
    }
    _notify();
  }

  /// С текущей сети сняли отметку «zapret не нужен»: если выключали из-за неё — включаем.
  Future<void> currentProfileOn() async {
    if (autoOff?.reason != AutoOffReason.profile ||
        !_canControl() ||
        !await _waitIdle()) {
      return;
    }
    if (zapret.running || await zapret.start()) {
      autoOff = null;
      baseline = country ?? baseline;
      _notify();
    }
  }

  /// Сеть сменилась и устоялась: решаем, нужен ли обход.
  Future<void> networkChanged() async {
    if (handling) {
      _again = true;
      return;
    }
    handling = true;
    _notify();
    try {
      final (country, _) = await (
        checkCountry(force: true),
        checkProvider(force: true),
      ).wait;
      final now = country?.country;
      if (!await _waitIdle()) return;
      final profile =
          await onNetwork?.call(startup: false) ??
          (decision: ProfileDecision.none, network: null);

      if (!enabled()) {
        // Без слежения за сетью профиль только меняет стратегию работающего zapret.
        if (profile.decision == ProfileDecision.changed &&
            zapret.running &&
            _canControl()) {
          if (await zapret.stop()) await zapret.start();
        }
        return;
      }

      if (profile.decision == ProfileDecision.zapretOff) {
        final off = AutoOff(
          AutoOffReason.profile,
          at: DateTime.now(),
          from: baseline,
          to: now,
          network: profile.network,
        );
        if (zapret.running) {
          if (await zapret.stop()) {
            autoOff = off;
            onEvent?.call(
              'Zapret выключен: сеть «${profile.network}»',
              'В этой сети zapret не нужен — так отмечено в её профиле.',
            );
          }
        } else if (autoOff != null) {
          autoOff = off;
        }
        return;
      }

      // Решаем не по стране, а по тому, открываются ли сайты без обхода: страна
      // меняется в обе стороны (включили VPN или выключили), а блокировки — нет.
      // Смена страны — лишь повод проверить и объяснение в сообщении.
      if (zapret.running) {
        final base = baseline;
        if (!await zapret.stop()) return;
        final open = await zapret.servicesOpen();
        if (open == true) {
          final moved = base != null && now != null && now != base;
          autoOff = AutoOff(
            moved ? AutoOffReason.countryChanged : AutoOffReason.servicesOpen,
            at: DateTime.now(),
            from: base,
            to: now,
          );
          onEvent?.call(
            moved
                ? 'Zapret выключен: сменилась страна'
                : 'Zapret выключен: обход не нужен',
            '${moved ? '${countryName(base)} → ${countryName(now)}. ' : ''}'
            'Discord и YouTube открываются и так — включу снова, если блокировки вернутся.',
          );
          return;
        }
        // Блокировки на месте или сети нет — возвращаем обход.
        await zapret.start();
        baseline = now ?? base;
        return;
      }

      if (autoOff == null) return;
      // Выключали сами — включаем, когда обход снова нужен.
      final open = await zapret.servicesOpen();
      if (open == false && await zapret.start()) {
        autoOff = null;
        baseline = now ?? baseline;
        onEvent?.call(
          'Zapret снова включён',
          'Сеть сменилась: без обхода Discord и YouTube не открываются.',
        );
      }
    } finally {
      handling = false;
      _notify();
      if (_again && !_disposed) {
        _again = false;
        unawaited(networkChanged());
      }
    }
  }
}
