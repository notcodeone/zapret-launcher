import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import 'location/network_guard.dart';
import 'location/profiles.dart';
import 'app_info.dart';
import 'platform/autostart.dart';
import 'platform/network_watch.dart';
import 'platform/win32.dart' as win;
import 'settings.dart';
import 'updates/launcher_updates.dart';
import 'ui/ui.dart';
import 'zapret/bundle.dart';
import 'zapret/diagnostics.dart';
import 'zapret/install.dart';
import 'zapret/network.dart';
import 'zapret/probe.dart';
import 'zapret/releases.dart';
import 'zapret/runner.dart';
import 'zapret/strategy.dart';
import 'zapret/user_lists.dart';

/// Ошибка, которую показываем красной строкой над содержимым.
class AppError {
  const AppError(this.title, [this.detail]);

  final String title;
  final String? detail;
}

/// Состояние приложения и все действия с zapret.
class AppController extends ChangeNotifier {
  AppController({
    required this.toasts,
    SettingsStore? store,
    ZapretRunner? runner,
    ReleaseClient? releases,
    LauncherUpdates? launcherUpdates,
    DiagnosticsSystem? diagnosticsSystem,
    this._probeEnvironment,
    bool Function()? isElevated,
    this._guardFactory,
    this._watchNetworkEvents = true,
    LauncherAutostart? launcherAutostart,
    HttpProber? prober,
    ZapretBundle? bundle,
    String? builtinZapretDir,
  })  : _bundle = bundle ?? ZapretBundle.app(),
        _builtinDir = builtinZapretDir ?? SettingsStore.defaultZapretDir(),
        _autostart = launcherAutostart ?? const LauncherAutostart(),
        _prober = prober ?? HttpProber(),
        _isElevated = isElevated ?? win.isElevated,
        _store = store ?? SettingsStore(),
        _runner = runner ?? ZapretRunner(),
        _releases = releases ?? ReleaseClient(),
        _launcherUpdates = launcherUpdates ?? LauncherUpdates(),
        _diagSystem = diagnosticsSystem ?? WindowsDiagnosticsSystem();

  final ToastController toasts;
  final SettingsStore _store;
  final ZapretRunner _runner;
  final ReleaseClient _releases;
  final LauncherUpdates _launcherUpdates;
  Timer? _updateTimer;
  final DiagnosticsSystem _diagSystem;
  final HttpProber _prober;
  final bool Function() _isElevated;

  /// Zapret, встроенный в лаунчер, и папка, куда он распаковывается.
  final ZapretBundle _bundle;
  final String _builtinDir;

  /// Сторож сети; подменяется в тестах (без запросов страны и чтения адаптеров).
  final NetworkGuard Function(GuardedZapret zapret, ProfileHook onNetwork)? _guardFactory;
  final bool _watchNetworkEvents;
  final _netWatch = WindowsNetworkWatch();
  final LauncherAutostart _autostart;
  AutostartState? _autostartState;

  /// Задача автозапуска лаунчера; null — ещё не проверяли.
  AutostartState? get launcherAutostart => _autostartState;

  /// Путь к этому лаунчеру — его запускает задача автозапуска.
  String get launcherPath => Platform.resolvedExecutable;

  Future<void> refreshLauncherAutostart() async {
    try {
      _autostartState = await _autostart.query();
    } on Object {
      _autostartState = AutostartState.off;
    }
    notifyListeners();
  }

  /// Открывать лаунчер при входе в Windows — свёрнутым в трей, без запроса прав.
  Future<void> setLauncherAutostart(bool value) async {
    await _task(
      HeaderStatus('autostart', value ? 'Добавляю в автозапуск…' : 'Убираю из автозапуска…'),
      () async {
        try {
          if (value) {
            await _autostart.enable(launcherPath);
          } else {
            await _autostart.disable();
          }
        } on AutostartException catch (e) {
          throw ZapretException(e.message, detail: e.detail);
        }
      },
    );
    await refreshLauncherAutostart();
  }

  /// Сторож сети: страна, смена сети, автоматическое выключение zapret.
  late final NetworkGuard guard;

  /// Окружение подбора стратегии; null — настоящий winws.exe. Подменяется в тестах.
  final ProbeEnvironment Function(ZapretInstall install, GameFilter filter)? _probeEnvironment;

  AppSettings _settings = const AppSettings();
  bool _elevated = false;
  ZapretInstall? _install;
  RuntimeStatus _runtime =
      const RuntimeStatus(processes: [], service: null, serviceStrategy: null);
  HeaderStatus? _busy;
  AppError? _error;
  ReleaseInfo? _latest;
  bool _checkingUpdates = false;
  GameFilter _gameFilter = const GameFilter();
  IpsetMode _ipsetMode = IpsetMode.none;
  Timer? _poll;
  AutoPick? _autoPick;
  AutoPickProgress? _probeProgress;
  AutoPickReport? _probeReport;
  NetworkReport? _network;
  bool _checkingNetwork = false;
  Timer? _networkTimer;
  Timer? _networkSoon;
  List<DiagnosticResult>? _diagnostics;
  bool _diagnosing = false;

  /// Каким zapret должен быть после последнего действия — по нему работает сторож.
  bool _wantRunning = false;
  final _watchdogRestarts = <DateTime>[];

  /// Как закрыть приложение (убрать значок из трея и выйти). Задаёт оболочка окна.
  Future<void> Function()? quitHandler;

  /// Уведомление, когда окно может быть спрятано в трей. Задаёт оболочка окна.
  void Function(String title, String text)? onBackgroundNotice;

  AppSettings get settings => _settings;
  ThemeMode get themeMode => _settings.themeMode;
  bool get elevated => _elevated;
  ZapretInstall? get install => _install;
  RuntimeStatus get runtime => _runtime;

  /// Что сейчас делает приложение — показывается в шапке.
  HeaderStatus? get busy => _busy;
  AppError? get error => _error;
  ReleaseInfo? get latest => _latest;
  bool get checkingUpdates => _checkingUpdates;
  GameFilter get gameFilter => _gameFilter;
  IpsetMode get ipsetMode => _ipsetMode;

  bool get running => _runtime.running;
  bool get autostart => _runtime.serviceInstalled;

  /// Идёт подбор стратегии.
  bool get probing => _autoPick != null;
  AutoPickProgress? get probeProgress => _probeProgress;

  /// Итог последнего подбора — живёт, пока открыт лаунчер.
  AutoPickReport? get probeReport => _probeReport;

  /// Последняя проверка сети.
  NetworkReport? get network => _network;
  bool get checkingNetwork => _checkingNetwork;

  /// Результаты диагностики; null — ещё не запускалась.
  List<DiagnosticResult>? get diagnostics => _diagnostics;
  bool get diagnosing => _diagnosing;

  /// Сайты для проверки: utils/targets.txt из zapret, иначе — список по умолчанию.
  List<ProbeTarget> get probeTargets {
    final inst = _install;
    if (inst != null) {
      final f = File('${inst.utilsDir}\\targets.txt');
      try {
        if (f.existsSync()) {
          final parsed = parseTargets(f.readAsStringSync());
          if (parsed.isNotEmpty) return parsed;
        }
      } on FileSystemException {
        // Возьмём список по умолчанию.
      }
    }
    return defaultProbeTargets;
  }

  /// Откуда zapret: встроенный в лаунчер (по умолчанию) или своя папка.
  ZapretSource get zapretSource => _settings.zapretSource ?? ZapretSource.builtin;
  bool get builtin => zapretSource == ZapretSource.builtin;

  /// Куда распаковывается встроенный zapret.
  String get builtinZapretDir => _builtinDir;

  /// Версия zapret, встроенного в эту сборку лаунчера; null — его нет.
  String? get bundledVersion => _bundle.version;

  /// Самая новая версия zapret, до которой можно обновиться: с GitHub или встроенная.
  String? get newestZapretVersion {
    final l = _latest?.version;
    final b = builtin ? _bundle.version : null;
    if (l == null || b == null) return l ?? b;
    return compareVersions(b, l) > 0 ? b : l;
  }

  /// Есть ли обновление zapret новее установленного.
  bool get updateAvailable => _newerThanInstalled(newestZapretVersion);

  bool _newerThanInstalled(String? version) {
    final v = _install?.version;
    return version != null && v != null && compareVersions(version, v) > 0;
  }

  Strategy? get strategy {
    final inst = _install;
    if (inst == null || inst.strategies.isEmpty) return null;
    return inst.strategyById(_settings.strategy) ??
        inst.strategyById(_runtime.serviceStrategy) ??
        inst.strategyById('general') ??
        inst.strategies.first;
  }

  /// winws.exe запущен из другой папки, чем выбранный zapret.
  bool get runningElsewhere {
    final root = _runtime.activeRoot;
    final inst = _install;
    if (!running || root == null || inst == null) return false;
    return root.toLowerCase() != inst.root.path.toLowerCase();
  }

  // ── Запуск приложения ──

  void init() {
    _settings = _store.load();
    _elevated = _isElevated();
    _runtime = _runner.status();
    if (_settings.zapretSource == null) _chooseSource();
    _install = _locateInstall();
    if (_settings.strategy == null && _runtime.serviceStrategy != null) {
      _saveSettings(_settings.copyWith(strategy: _runtime.serviceStrategy));
    }
    _readZapretSettings();
    _wantRunning = _runtime.running;
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refreshRuntime());
    _networkTimer = Timer.periodic(const Duration(minutes: 10), (_) => checkNetwork());
    _scheduleNetworkCheck(const Duration(seconds: 1));

    final bridge = _GuardBridge(this);
    guard = _guardFactory?.call(bridge, _onNetworkIdentified) ??
        NetworkGuard(
          zapret: bridge,
          // Без прав администратора zapret не выключить и не включить.
          enabled: () => _settings.networkGuard && _elevated,
          countryEnabled: () => _settings.countryCheck,
          providerEnabled: () => _settings.profilesEnabled,
          onNetwork: _onNetworkIdentified,
          canControl: () => _elevated,
          onEvent: _onGuardEvent,
        );
    guard.addListener(notifyListeners);
    unawaited(guard.start());
    if (_watchNetworkEvents) _netWatch.start(guard.networkEvent);
    notifyListeners();
    // Раз в 6 часов — новые версии лаунчера и zapret. Первая проверка — когда
    // встроенный zapret готов: иначе обновление с GitHub обгонит распаковку.
    _updateTimer = Timer.periodic(const Duration(hours: 6), (_) => _periodicUpdateCheck());
    _prepared = _prepareBuiltin();
    unawaited(_prepared.whenComplete(() {
      if (_settings.autoCheckUpdates) return _periodicUpdateCheck();
    }));
    unawaited(refreshLauncherAutostart());
  }

  /// Первый запуск или настройки от версии без встроенного zapret. Свою папку
  /// оставляем своей: ту, что была выбрана, или ту, откуда zapret уже работает.
  /// Иначе — встроенный (в его папку лаунчер раньше и скачивал zapret).
  void _chooseSource() {
    String? custom;
    for (final path in [_settings.zapretDir, _runtime.activeRoot]) {
      if (path == null) continue;
      if (p.equals(path, _builtinDir)) break;
      if (ZapretInstall.open(path) != null) {
        custom = path;
        break;
      }
    }
    _saveSettings(_settings.copyWith(
      zapretSource: custom == null ? ZapretSource.builtin : ZapretSource.custom,
      zapretDir: custom,
    ));
  }

  /// Встроенный zapret — в своей папке, своя — в выбранной.
  ZapretInstall? _locateInstall() {
    final path = builtin ? _builtinDir : _settings.zapretDir;
    return path == null ? null : ZapretInstall.open(path);
  }

  late Future<void> _prepared;

  /// Встроенный zapret готов: распакован или обновлён после запуска лаунчера.
  Future<void> get prepared => _prepared;

  /// Встроенный zapret: при первом запуске — распаковать, а если лаунчер обновился
  /// и внутри zapret новее — поставить и его (когда zapret обновляется сам).
  Future<void> _prepareBuiltin() async {
    final bundled = _bundle.version;
    if (!builtin || bundled == null) return;
    if (_install == null) {
      await installBundled();
      return;
    }
    if (!_newerThanInstalled(bundled)) return;
    if (!_settings.autoUpdateZapret || bundled == _settings.skippedZapretVersion) return;
    await _autoUpdate(bundled, () => installBundled(auto: true));
  }

  void _readZapretSettings() {
    _resetListsCache();
    final inst = _install;
    if (inst == null) return;
    _gameFilter = inst.readGameFilter();
    _ipsetMode = inst.readIpsetMode();
  }

  void _refreshRuntime() {
    if (_busy != null) return;
    final next = _runner.status();
    if (_sameRuntime(next, _runtime)) return;
    _runtime = next;
    notifyListeners();
    if (_settings.watchdog && _wantRunning && !next.running && _elevated) {
      unawaited(_recover());
    }
  }

  /// Сторож: winws.exe закрылся сам — запускаем снова, но не бесконечно.
  Future<void> _recover() async {
    final inst = _install;
    final s = strategy;
    if (inst == null || s == null || _busy != null) return;
    final now = DateTime.now();
    _watchdogRestarts.removeWhere((t) => now.difference(t) > const Duration(minutes: 5));
    if (_watchdogRestarts.length >= 3) {
      _wantRunning = false;
      _error = const AppError(
        'winws.exe закрывается снова и снова',
        'Лаунчер перезапустил его 3 раза за 5 минут и перестал. Возможно, его закрывает '
            'антивирус — загляните в диагностику.',
      );
      onBackgroundNotice?.call('Zapret не работает', 'winws.exe закрывается снова и снова — откройте лаунчер.');
      notifyListeners();
      return;
    }
    _watchdogRestarts.add(now);
    final ok = await _task(const HeaderStatus('watchdog', 'winws.exe закрылся — запускаю снова…'), () async {
      if (_runner.status().serviceInstalled) {
        await _runner.startService();
      } else {
        await _runner.startProcess(inst, s, _gameFilter);
      }
    });
    if (ok) {
      toasts.show(const ToastData('winws.exe закрылся — запустил снова', icon: LucideIcons.rotateCw));
      onBackgroundNotice?.call('Zapret перезапущен', 'winws.exe закрылся сам — лаунчер запустил его снова.');
    }
  }

  static bool _sameRuntime(RuntimeStatus a, RuntimeStatus b) =>
      a.processes.length == b.processes.length &&
      a.service?.state == b.service?.state &&
      a.serviceStrategy == b.serviceStrategy &&
      a.activeRoot == b.activeRoot;

  void _saveSettings(AppSettings s) {
    _settings = s;
    try {
      _store.save(s);
    } on FileSystemException {
      // Не сохранилось — не повод мешать работе.
    }
  }

  void _onGuardEvent(String title, String text) {
    toasts.show(ToastData(title, icon: LucideIcons.globe));
    onBackgroundNotice?.call(title, text);
  }

  @override
  void dispose() {
    _netWatch.stop();
    guard.removeListener(notifyListeners);
    guard.dispose();
    _poll?.cancel();
    _networkTimer?.cancel();
    _updateTimer?.cancel();
    _launcherUpdates.close();
    _networkSoon?.cancel();
    _prober.abortAll();
    _releases.close();
    super.dispose();
  }

  // ── Действия ──

  void dismissError() {
    _error = null;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _saveSettings(_settings.copyWith(themeMode: mode));
    notifyListeners();
  }

  void setCloseToTray(bool value) {
    _saveSettings(_settings.copyWith(closeToTray: value));
    notifyListeners();
  }

  void setWatchdog(bool value) {
    _saveSettings(_settings.copyWith(watchdog: value));
    _watchdogRestarts.clear();
    notifyListeners();
  }

  void markTrayHintShown() => _saveSettings(_settings.copyWith(trayHintShown: true));

  void setNetworkGuard(bool value) {
    _saveSettings(_settings.copyWith(networkGuard: value));
    if (!value) guard.userStopped();
    notifyListeners();
  }

  void setCountryCheck(bool value) {
    _saveSettings(_settings.copyWith(countryCheck: value));
    unawaited(guard.checkCountry(force: true));
    notifyListeners();
  }

  // ── Профили сетей ──

  List<NetworkProfile> get profiles => _settings.profiles;
  bool get profilesEnabled => _settings.profilesEnabled;

  NetworkProfile? profileFor(String? asn) {
    if (asn == null) return null;
    for (final p in profiles) {
      if (p.asn == asn) return p;
    }
    return null;
  }

  /// Профиль сети, в которой компьютер сейчас.
  NetworkProfile? get currentProfile => profilesEnabled ? profileFor(guard.asn) : null;

  /// Как назвать текущую сеть: имя профиля или провайдер.
  String? get currentNetworkName {
    final asn = guard.asn;
    if (asn == null) return null;
    return currentProfile?.name ?? providerShortName(guard.isp, asn);
  }

  /// Новая сеть: провайдер известен, своего профиля нет, а другие — есть.
  bool get isNewNetwork =>
      profilesEnabled &&
      guard.asn != null &&
      currentProfile == null &&
      profiles.isNotEmpty &&
      _install != null &&
      guard.autoOff == null;

  void setProfilesEnabled(bool value) {
    _saveSettings(_settings.copyWith(profilesEnabled: value));
    if (value) unawaited(guard.checkProvider(force: true).then((_) => notifyListeners()));
    notifyListeners();
  }

  void _upsertProfile(NetworkProfile profile) {
    final list = [
      profile,
      for (final p in profiles)
        if (p.asn != profile.asn) p,
    ];
    _saveSettings(_settings.copyWith(profiles: list));
  }

  /// Запоминает, как zapret настроен сейчас, — для сети, в которой компьютер.
  void _rememberForNetwork() {
    final asn = guard.asn;
    if (!profilesEnabled || asn == null) return;
    final now = DateTime.now();
    final base = profileFor(asn) ??
        NetworkProfile(asn: asn, name: providerShortName(guard.isp, asn), lastSeen: now);
    _upsertProfile(base.copyWith(
      isp: guard.isp,
      country: guard.country,
      strategy: _settings.strategy ?? strategy?.id,
      gameFilter: _gameFilter.mode,
      ipset: _ipsetMode,
      lastSeen: now,
    ));
    notifyListeners();
  }

  /// «Оставить как есть» для новой сети: запомнить текущие настройки.
  void rememberCurrentNetwork() => _rememberForNetwork();

  void renameProfile(String asn, String name) {
    final p = profileFor(asn);
    final trimmed = name.trim();
    if (p == null || trimmed.isEmpty || trimmed == p.name) return;
    _upsertProfile(p.copyWith(name: trimmed));
    notifyListeners();
  }

  void setProfileZapretOff(String asn, bool value) {
    final p = profileFor(asn);
    if (p == null) return;
    _upsertProfile(p.copyWith(zapretOff: value));
    notifyListeners();
    // Отметили сеть, в которой компьютер сейчас, — zapret выключается (или возвращается) сразу.
    if (asn == guard.asn) {
      unawaited(value ? guard.currentProfileOff(p.name) : guard.currentProfileOn());
    }
  }

  /// Стратегия профиля; для текущей сети — сразу и в работу.
  Future<void> setProfileStrategy(String asn, Strategy s) async {
    if (asn == guard.asn) return selectStrategy(s);
    final p = profileFor(asn);
    if (p == null) return;
    _upsertProfile(p.copyWith(strategy: s.id));
    notifyListeners();
  }

  void deleteProfile(String asn) {
    _saveSettings(_settings.copyWith(profiles: [
      for (final p in profiles)
        if (p.asn != asn) p,
    ]));
    notifyListeners();
  }

  /// Сеть определилась: применяем её профиль. Вызывает сторож сети.
  Future<ProfileOutcome> _onNetworkIdentified({required bool startup}) async {
    const none = (decision: ProfileDecision.none, network: null);
    final asn = guard.asn;
    final inst = _install;
    if (!profilesEnabled || asn == null || inst == null) return none;
    var profile = profileFor(asn);
    if (profile == null) {
      // Первая сеть, где zapret уже работает, — для неё всё и настраивали.
      if (profiles.isEmpty && running) _rememberForNetwork();
      notifyListeners();
      return none;
    }
    profile = profile.copyWith(lastSeen: DateTime.now(), isp: guard.isp, country: guard.country);
    _upsertProfile(profile);
    if (profile.zapretOff) return (decision: ProfileDecision.zapretOff, network: profile.name);
    // При запуске лаунчера работающий zapret не трогаем.
    if (startup && running) return none;

    var changed = false;
    final s = inst.strategyById(profile.strategy);
    if (s != null && s.id != strategy?.id) {
      _saveSettings(_settings.copyWith(strategy: s.id));
      changed = true;
    }
    if (profile.gameFilter != _gameFilter.mode) {
      _gameFilter = _gameFilter.copyWith(mode: profile.gameFilter);
      try {
        inst.writeGameFilter(_gameFilter);
        changed = true;
      } on FileSystemException {
        // Не записался — останется прежний.
      }
    }
    if (profile.ipset != _ipsetMode) {
      try {
        if (inst.setIpsetMode(profile.ipset)) changed = true;
      } on FileSystemException {
        // Оставим как было.
      }
      _ipsetMode = inst.readIpsetMode();
    }
    notifyListeners();
    if (changed && !startup) {
      final title = 'Сеть «${profile.name}»: стратегия «${strategy?.title}»';
      toasts.show(ToastData(title, icon: LucideIcons.router));
      onBackgroundNotice?.call(title, 'Лаунчер переключил настройки zapret под эту сеть.');
    }
    return (decision: changed ? ProfileDecision.changed : ProfileDecision.none, network: profile.name);
  }

  /// Выход: подбор стратегии останавливается, и zapret возвращается как был.
  Future<void> prepareToQuit() async {
    if (!probing) return;
    cancelAutoPick();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (probing || _busy != null) {
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Выполняет действие со статусом в шапке; ошибки — красной строкой.
  Future<bool> _task(HeaderStatus status, Future<void> Function() body) async {
    if (_busy != null) return false;
    _busy = status;
    _error = null;
    final wasRunning = running;
    final strategyBefore = _runtime.serviceStrategy ?? _settings.strategy;
    notifyListeners();
    // Состояние обхода поменялось — проверяем, открываются ли сайты теперь.
    void recheck() {
      final strategyNow = _runtime.serviceStrategy ?? _settings.strategy;
      if (running != wasRunning || (running && strategyNow != strategyBefore) ||
          status.kind == 'restart' || status.kind == 'probe') {
        _scheduleNetworkCheck(const Duration(seconds: 2));
      }
    }
    try {
      await body();
      return true;
    } on ZapretException catch (e) {
      _error = AppError(e.message, e.detail);
    } on LauncherUpdateException catch (e) {
      _error = AppError(e.message);
    } on ReleaseException catch (e) {
      _error = AppError(e.message);
    } on win.Win32Exception catch (e) {
      _error = AppError(e.operation, 'Код ошибки Windows ${e.code}');
    } on FileSystemException catch (e) {
      _error = AppError('Не удалось изменить файлы zapret', e.osError?.message ?? e.message);
    } on SocketException {
      _error = const AppError('Нет связи с GitHub', 'Проверьте интернет и попробуйте ещё раз');
    } on TimeoutException {
      _error = const AppError('GitHub не ответил вовремя', 'Попробуйте ещё раз');
    } on Object catch (e) {
      _error = AppError('Что-то пошло не так', e.toString());
    } finally {
      _busy = null;
      _runtime = _runner.status();
      // Что получилось после действия пользователя — то сторож и бережёт.
      _wantRunning = _runtime.running;
      recheck();
      notifyListeners();
    }
    return false;
  }

  // ── Проверка сети ──

  void _scheduleNetworkCheck(Duration delay) {
    _networkSoon?.cancel();
    _networkSoon = Timer(delay, checkNetwork);
  }

  /// Быстро проверяет сайты из targets.txt с текущим состоянием zapret.
  Future<void>? _networkCheck;

  /// Если проверка уже идёт — дожидаемся её, а не начинаем вторую.
  Future<void> checkNetwork() {
    // Во время подбора и перезапусков результат ничего не скажет.
    if (_busy != null) return Future.value();
    return _networkCheck ??= _doCheckNetwork().whenComplete(() => _networkCheck = null);
  }

  Future<void> _doCheckNetwork() async {
    _checkingNetwork = true;
    notifyListeners();
    try {
      final targets = probeTargets;
      final results = await Future.wait([for (final t in targets) _prober.check(t)]);
      final withZapret = running;
      _network = NetworkReport(
        checkedAt: DateTime.now(),
        targets: results,
        withZapret: withZapret,
        strategyTitle: withZapret ? strategy?.title : null,
      );
    } finally {
      _checkingNetwork = false;
      notifyListeners();
    }
  }

  // ── Диагностика ──

  /// Проверки из service.bat: что может мешать zapret.
  Future<void> runDiagnostics() async {
    if (_diagnosing) return;
    _diagnosing = true;
    notifyListeners();
    try {
      String? repoHosts;
      try {
        repoHosts = await _releases.fetchRepoHosts();
      } on Object {
        // Без репозитория просто не проверим записи hosts.
      }
      _diagnostics = diagnose(_diagSystem, install: _install, repoHosts: repoHosts);
    } finally {
      _diagnosing = false;
      notifyListeners();
    }
  }

  /// Исправление из диагностики. Опасные — после подтверждения на странице.
  Future<void> applyFix(DiagnosticFix fix) async {
    switch (fix) {
      case OpenFix(:final target, :final parameters):
        win.shellExecute(target, parameters: parameters);
        return;
      case ReinstallFix():
        await reinstallZapret();
      case StartServiceFix(:final service):
        await _task(const HeaderStatus('fix', 'Запускаю службу…'), () async {
          try {
            win.startService(service);
          } on win.Win32Exception catch (e) {
            throw ZapretException('Не удалось запустить службу $service', detail: 'код ${e.code}');
          }
        });
      case UnloadDriverFix():
        await _task(const HeaderStatus('fix', 'Выгружаю WinDivert…'), _runner.unloadDriver);
      case RemoveServicesFix(:final services):
        await _task(const HeaderStatus('fix', 'Удаляю другие обходы…'), () async {
          await _runner.removeServices(services);
          await _runner.unloadDriver();
        });
      case HostsBlockFix(:final content):
        await _task(const HeaderStatus('fix', 'Обновляю hosts…'), () async {
          final file = File(hostsPath);
          final current = await file.readAsString();
          await file.copy('$hostsPath.zapret-launcher.bak');
          await file.writeAsString(mergeHostsBlock(current, content));
          toasts.show(const ToastData('Адреса для Telegram и Discord добавлены в hosts'));
        });
    }
    await runDiagnostics();
  }

  /// Закрывает Discord и удаляет его кэш — как в service.bat.
  Future<void> clearDiscordCache() async {
    await _task(const HeaderStatus('fix', 'Очищаю кэш Discord…'), () async {
      final appData = Platform.environment['APPDATA'];
      if (appData == null) throw const ZapretException('Не найдена папка APPDATA');
      var found = false;
      final failed = <String>[];
      for (final (exe, folder) in discordInstalls) {
        final dir = Directory('$appData\\$folder');
        if (!dir.existsSync()) continue;
        found = true;
        for (final proc in win.findProcesses(exe)) {
          try {
            win.terminateProcess(proc.pid);
          } on win.Win32Exception {
            // Попробуем удалить кэш всё равно.
          }
        }
        for (final name in discordCacheDirs) {
          final cache = Directory('${dir.path}\\$name');
          if (!cache.existsSync()) continue;
          try {
            await cache.delete(recursive: true);
          } on FileSystemException {
            failed.add(cache.path);
          }
        }
      }
      if (!found) throw const ZapretException('Discord не найден', detail: 'Нет папок Discord в APPDATA');
      if (failed.isNotEmpty) {
        throw ZapretException('Часть кэша Discord не удалилась', detail: failed.join(', '));
      }
      toasts.show(const ToastData('Кэш Discord очищен'));
    });
  }

  // ── Свои списки ──

  final _lists = <UserListKind, UserList>{};
  DateTime? _listsEditedAt;
  int? _standardCount;

  /// Свой список; читается с диска один раз, дальше — из памяти.
  UserList userList(UserListKind kind) {
    final inst = _install;
    if (inst == null) return UserList(kind, const []);
    return _lists[kind] ??= () {
      try {
        return readUserList(inst.listsDir, kind);
      } on FileSystemException {
        return UserList(kind, const []);
      }
    }();
  }

  /// Сколько сайтов в стандартном списке zapret.
  int get standardListSize {
    final inst = _install;
    if (inst == null) return 0;
    return _standardCount ??= countStandardList(inst.listsDir);
  }

  /// Списки поменялись после запуска winws.exe — нужен перезапуск, чтобы они точно применились.
  bool get listsChanged {
    final edited = _listsEditedAt;
    if (!running || edited == null) return false;
    final started = _runner.lastStart;
    return started == null || edited.isAfter(started);
  }

  void _resetListsCache() {
    _lists.clear();
    _standardCount = null;
  }

  bool _saveList(UserList list) {
    final inst = _install;
    if (inst == null) return false;
    try {
      writeUserList(inst.listsDir, list);
    } on FileSystemException catch (e) {
      _error = AppError('Не удалось сохранить список', e.osError?.message ?? e.message);
      notifyListeners();
      return false;
    }
    _lists[list.kind] = list;
    _listsEditedAt = DateTime.now();
    notifyListeners();
    return true;
  }

  /// Добавляет записи из ввода. Возвращает, сколько добавилось и сколько уже было.
  (int added, int existing) addEntries(UserListKind kind, List<String> entries) {
    final list = userList(kind);
    final known = {for (final e in list.entries) e.toLowerCase()};
    final fresh = [for (final e in entries) if (!known.contains(e.toLowerCase())) e];
    if (fresh.isEmpty) return (0, entries.length);
    // Новые — сверху: их сразу видно.
    if (!_saveList(list.withEntries([...fresh, ...list.entries]))) return (0, 0);
    return (fresh.length, entries.length - fresh.length);
  }

  void removeEntry(UserListKind kind, String entry) {
    final list = userList(kind);
    _saveList(list.withEntries([for (final e in list.entries) if (e != entry) e]));
  }

  /// Вернуть удалённую запись на прежнее место — для «Вернуть» в оповещении.
  void restoreEntry(UserListKind kind, String entry, int index) {
    final list = userList(kind);
    if (list.entries.contains(entry)) return;
    final entries = [...list.entries]..insert(index.clamp(0, list.entries.length), entry);
    _saveList(list.withEntries(entries));
  }

  void clearList(UserListKind kind) => _saveList(userList(kind).withEntries(const []));

  /// Импорт из текстового файла: домены по строкам, ссылки, строки hosts.
  void importList(UserListKind kind) {
    final path = win.pickOpenFile(title: 'Импорт списка');
    if (path == null) return;
    final String text;
    try {
      text = decodeText(File(path).readAsBytesSync());
    } on FileSystemException catch (e) {
      _error = AppError('Не удалось прочитать файл', e.osError?.message ?? e.message);
      notifyListeners();
      return;
    }
    final parsed = parseEntries(text, ip: kind.ip);
    final name = path.split(RegExp(r'[\\/]')).last;
    if (parsed.entries.isEmpty) {
      _error = AppError(
        'В файле $name нет ${kind.ip ? 'IP-адресов' : 'доменов'}',
        parsed.invalid.isEmpty ? null : 'Не удалось разобрать: ${parsed.invalid.take(5).join(', ')}',
      );
      notifyListeners();
      return;
    }
    final (added, existing) = addEntries(kind, parsed.entries);
    final skipped = parsed.invalid.length;
    toasts.show(ToastData(
      added == 0
          ? 'Всё из $name уже есть в списке'
          : 'Добавлено $added из $name${existing > 0 ? ', уже были $existing' : ''}'
              '${skipped > 0 ? ', пропущено $skipped' : ''}',
      icon: LucideIcons.fileDown,
    ));
  }

  /// Экспорт в текстовый файл — его можно импортировать на другом компьютере.
  void exportList(UserListKind kind) {
    final list = userList(kind);
    final name = switch (kind) {
      UserListKind.bypass => 'zapret-обходить.txt',
      UserListKind.exclude => 'zapret-не-трогать.txt',
      UserListKind.ipExclude => 'zapret-ip-исключения.txt',
    };
    final path = win.pickSaveFile(title: 'Экспорт списка', fileName: name);
    if (path == null) return;
    try {
      File(path).writeAsStringSync(exportText(list));
    } on FileSystemException catch (e) {
      _error = AppError('Не удалось сохранить файл', e.osError?.message ?? e.message);
      notifyListeners();
      return;
    }
    toasts.show(ToastData('Список сохранён: ${list.entries.length} записей',
        icon: LucideIcons.fileUp));
  }

  /// Перезапуск, чтобы winws.exe перечитал списки.
  Future<void> applyLists() => _restartIfRunning('Применяю списки…');

  /// Свежий список адресов IPSet из репозитория.
  Future<void> updateIpsetList() async {
    final inst = _install;
    if (inst == null) return;
    final ok = await _task(const HeaderStatus('ipset', 'Скачиваю список адресов…'), () async {
      inst.storeIpsetList(await _releases.fetchIpsetList());
    });
    _ipsetMode = inst.readIpsetMode();
    if (ok) {
      toasts.show(const ToastData('Список адресов IPSet обновлён'));
      if (_ipsetMode == IpsetMode.loaded) await _restartIfRunning('Применяю новый список…');
    }
  }

  void _setBusyText(HeaderStatus status) {
    _busy = status;
    notifyListeners();
  }

  Future<void> toggle() => running ? stop() : start();

  Future<void> start() async {
    final inst = _install;
    final s = strategy;
    if (inst == null || s == null) return;
    final ok = await _task(HeaderStatus('start', 'Запускаю «${s.title}»…'), () => _startWith(inst, s));
    // Включили сами — сторож сети запоминает страну и больше не спорит,
    // а профиль сети — с какими настройками здесь работает zapret.
    if (ok) {
      guard.userStarted();
      _rememberForNetwork();
    }
  }

  Future<void> _startWith(ZapretInstall inst, Strategy s) async {
    if (_runner.status().serviceInstalled) {
      // Служба есть — переставляем её с текущей стратегией и настройками.
      await _runner.stopAll();
      await _runner.installService(inst, s, _gameFilter);
    } else {
      await _runner.startProcess(inst, s, _gameFilter);
    }
  }

  Future<void> stop() async {
    final ok = await _task(const HeaderStatus('stop', 'Останавливаю…'), _runner.stopAll);
    // Выключили сами — сторож сети не включит zapret обратно.
    if (ok) guard.userStopped();
  }

  /// Открываются ли Discord и YouTube прямо сейчас — для сторожа сети, при выключенном zapret.
  Future<bool?> _servicesOpenWithoutZapret() async {
    final targets = [
      for (final t in probeTargets)
        if (t.group == 'Discord' || t.group == 'YouTube') t,
    ];
    if (targets.isEmpty || _busy != null) return null;
    _busy = const HeaderStatus('guard', 'Сеть сменилась — проверяю, нужен ли обход…');
    notifyListeners();
    try {
      final results = await Future.wait([for (final t in targets) _prober.check(t)]);
      if (results.every((r) => r.outcome == ProbeOutcome.noHost)) return null;
      return results.every((r) => r.ok);
    } finally {
      _busy = null;
      notifyListeners();
    }
  }

  /// Перезапуск с текущими настройками — если zapret работает.
  Future<void> _restartIfRunning(String reason) async {
    final inst = _install;
    final s = strategy;
    if (!running || inst == null || s == null) return;
    await _task(HeaderStatus('restart', reason), () async {
      await _runner.stopAll();
      await _startWith(inst, s);
    });
  }

  Future<void> selectStrategy(Strategy s) async {
    if (strategy?.id == s.id && running) return;
    _saveSettings(_settings.copyWith(strategy: s.id));
    _rememberForNetwork();
    notifyListeners();
    await _restartIfRunning('Перезапускаю с «${s.title}»…');
  }

  /// Автозапуск вместе с Windows — это служба zapret.
  Future<void> setAutostart(bool value) async {
    final inst = _install;
    final s = strategy;
    if (inst == null || s == null) return;
    final wasRunning = running;
    if (value) {
      await _task(const HeaderStatus('service', 'Ставлю службу…'), () async {
        await _runner.stopAll();
        await _runner.installService(inst, s, _gameFilter);
      });
    } else {
      await _task(const HeaderStatus('service', 'Убираю службу…'), () async {
        await _runner.removeService(cleanupDriver: false);
        // Обход не должен пропасть оттого, что убрали автозапуск.
        if (wasRunning) await _runner.startProcess(inst, s, _gameFilter);
      });
    }
  }

  Future<void> setGameFilterMode(GameFilterMode mode) async {
    final inst = _install;
    if (inst == null || mode == _gameFilter.mode) return;
    _gameFilter = _gameFilter.copyWith(mode: mode);
    try {
      inst.writeGameFilter(_gameFilter);
    } on FileSystemException catch (e) {
      _error = AppError('Не удалось сохранить игровой фильтр', e.osError?.message);
    }
    _rememberForNetwork();
    notifyListeners();
    await _restartIfRunning('Применяю игровой фильтр…');
  }

  Future<void> setIpsetMode(IpsetMode mode) async {
    final inst = _install;
    if (inst == null || mode == _ipsetMode) return;
    final ok = await _task(const HeaderStatus('ipset', 'Меняю режим IPSet…'), () async {
      if (!inst.setIpsetMode(mode)) {
        // Резервной копии списка нет — скачиваем свежий.
        _setBusyText(const HeaderStatus('ipset', 'Скачиваю список адресов…'));
        inst.writeIpsetList(await _releases.fetchIpsetList());
      }
    });
    _ipsetMode = inst.readIpsetMode();
    if (ok) _rememberForNetwork();
    notifyListeners();
    if (ok) await _restartIfRunning('Применяю IPSet…');
  }

  // ── Обновления лаунчера ──

  LauncherRelease? _launcherLatest;
  bool _launcherChecked = false;
  bool _checkingLauncher = false;

  LauncherRelease? get launcherLatest => _launcherLatest;
  bool get checkingLauncher => _checkingLauncher;

  /// Проверяли и релизов лаунчера пока нет.
  bool get launcherNoReleases => _launcherChecked && _launcherLatest == null;

  bool get launcherUpdateAvailable {
    final l = _launcherLatest;
    return l != null && compareVersions(l.version, AppInfo.version) > 0;
  }

  void setAutoCheckUpdates(bool value) {
    _saveSettings(_settings.copyWith(autoCheckUpdates: value));
    notifyListeners();
  }

  /// Раз в 6 часов: новые версии лаунчера и zapret.
  Future<void> _periodicUpdateCheck() async {
    if (!_settings.autoCheckUpdates) return;
    await checkLauncherUpdate(silent: true);
    await checkUpdates(silent: true);
  }

  Future<void> checkLauncherUpdate({bool silent = false}) async {
    if (_checkingLauncher) return;
    _checkingLauncher = true;
    notifyListeners();
    try {
      final had = launcherUpdateAvailable;
      _launcherLatest = await _launcherUpdates.latest();
      _launcherChecked = true;
      if (launcherUpdateAvailable && !had) {
        // Что нового — в настройках («Что нового»); в оповещении одно действие.
        toasts.show(ToastData.update(
          'Вышел ${AppInfo.name} ${_launcherLatest!.version}',
          actionLabel: 'Обновить',
          onAction: updateLauncher,
        ));
      } else if (!silent && !launcherUpdateAvailable) {
        toasts.show(ToastData('Установлена последняя версия лаунчера — ${AppInfo.version}'));
      }
    } on Object catch (e) {
      if (!silent) {
        _error = AppError('Не удалось проверить обновления лаунчера',
            e is LauncherUpdateException ? e.message : 'Проверьте интернет и попробуйте ещё раз');
      }
    } finally {
      _checkingLauncher = false;
      notifyListeners();
    }
  }

  /// Описание выпуска лаунчера на GitHub — раздел версии из CHANGELOG.md.
  void openLauncherReleasePage() {
    final url = _launcherLatest?.pageUrl.toString() ?? 'https://github.com/$launcherRepo/releases/latest';
    win.shellExecute(url);
  }

  /// Проверить и лаунчер, и zapret — кнопка «Проверить» в настройках.
  Future<void> checkAllUpdates() async {
    await checkLauncherUpdate(silent: true);
    await checkUpdates();
  }

  /// Скачивает установщик новой версии, запускает его и закрывает лаунчер:
  /// установщик дождётся закрытия, поставит версию поверх и запустит её.
  /// Zapret при этом не останавливается — он работает отдельно от лаунчера.
  Future<void> updateLauncher() async {
    final ok = await _task(const HeaderStatus('launcher', 'Проверяю версию лаунчера…'), () async {
      final release = await _launcherUpdates.latest();
      _launcherLatest = release;
      _launcherChecked = true;
      if (release == null || compareVersions(release.version, AppInfo.version) <= 0) {
        throw const LauncherUpdateException('Установлена последняя версия лаунчера');
      }
      final label = 'Скачиваю ${AppInfo.name} ${release.version}';
      _setBusyText(HeaderStatus('launcher', '$label…'));
      final installer = await _launcherUpdates.download(release, onProgress: (v) {
        if (v != null) _setBusyText(HeaderStatus('launcher', '$label — ${(v * 100).round()}%'));
      });
      _setBusyText(HeaderStatus('launcher', 'Запускаю установку ${release.version}…'));
      // Установленную копию обновляем тихо; сборку из исходников — мастером, чтобы было видно куда.
      final silent = isInstalledCopy(launcherPath);
      final started = win.shellExecute(
        installer.path,
        parameters: silent ? '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /UPDATE=1' : null,
      );
      if (!started) {
        throw const LauncherUpdateException('Установщик не запустился: Windows отклонила запуск');
      }
    });
    if (!ok) return;
    final quit = quitHandler;
    if (quit != null) await quit();
  }

  Future<void> checkUpdates({bool silent = false}) async {
    if (_checkingUpdates) return;
    _checkingUpdates = true;
    notifyListeners();
    var autoUpdate = false;
    try {
      final hadUpdate = _newerThanInstalled(_latest?.version);
      _latest = await _releases.latest();
      final fresh = _newerThanInstalled(_latest!.version);
      final skipped = _latest!.version == _settings.skippedZapretVersion;
      // Сам лаунчер обновляет только встроенный zapret: своя папка — забота её хозяина.
      if (fresh && silent && builtin && _settings.autoUpdateZapret && !skipped && _elevated) {
        // Ставим сами — после того как проверка закончится.
        autoUpdate = true;
      } else if (fresh && !hadUpdate) {
        toasts.show(ToastData.update(
          'Вышел zapret ${_latest!.version}',
          actionLabel: 'Обновить',
          onAction: updateZapret,
        ));
      } else if (!silent && !updateAvailable && _install != null) {
        toasts.show(ToastData('Установлена последняя версия zapret — ${_install!.version}'));
      }
    } on Object catch (e) {
      if (!silent) {
        _error = AppError('Не удалось проверить обновления',
            e is ReleaseException ? e.message : 'Проверьте интернет и попробуйте ещё раз');
      }
    } finally {
      _checkingUpdates = false;
      notifyListeners();
    }
    if (autoUpdate) await _autoUpdateZapret();
  }

  /// Обновить zapret до самой новой версии: встроенную в лаунчер — без загрузки, иначе с GitHub.
  Future<bool> updateZapret() {
    final b = builtin ? _bundle.version : null;
    final newest = newestZapretVersion;
    if (b != null && newest != null && compareVersions(b, newest) >= 0) return installBundled();
    return installLatest();
  }

  /// Поставить zapret заново (диагностика нашла, что файлов не хватает): встроенный,
  /// если он не старее установленного, иначе — последний с GitHub.
  Future<bool> reinstallZapret() {
    final b = builtin ? _bundle.version : null;
    final v = _install?.version;
    if (b != null && (v == null || compareVersions(b, v) >= 0)) return installBundled();
    return installLatest();
  }

  /// Распаковывает zapret, встроенный в лаунчер, — без интернета. Первая установка
  /// или обновление; прежняя версия остаётся рядом, как и при обновлении с GitHub.
  Future<bool> installBundled({bool auto = false}) async {
    final version = _bundle.version;
    if (version == null) return false;
    final firstInstall = ZapretInstall.open(_builtinDir) == null;
    final ok = await _task(
      HeaderStatus('install', firstInstall ? 'Распаковываю zapret $version…' : 'Ставлю zapret $version…'),
      () async {
        final zip = await _bundle.copyZip();
        await _replaceZapret(_builtinDir, () => installFromZip(zip, Directory(_builtinDir)));
      },
    );
    if (ok) {
      toasts.show(ToastData(
        firstInstall
            ? 'Zapret $version готов к работе'
            : auto
                ? 'Zapret обновился вместе с лаунчером до $version'
                : 'Zapret обновлён до $version',
        icon: firstInstall ? LucideIcons.packageCheck : LucideIcons.download,
      ));
      if (auto) {
        onBackgroundNotice?.call('Zapret обновлён до $version', 'Новая версия пришла вместе с лаунчером.');
      }
    }
    return ok;
  }

  /// Скачивает и ставит последнюю версию zapret с GitHub: первая установка или обновление.
  /// Прежняя версия остаётся рядом — к ней можно вернуться ([rollbackZapret]).
  Future<bool> installLatest({bool auto = false}) async {
    final firstInstall = _install == null;
    // Своя папка обновляется на месте; если её нет — zapret встанет как встроенный.
    final targetPath = builtin ? _builtinDir : _install?.root.path ?? _builtinDir;
    String? installed;
    final ok = await _task(const HeaderStatus('update', 'Проверяю версию zapret…'), () async {
      final release = await _releases.latest();
      _latest = release;
      final label = 'Скачиваю zapret ${release.version}';
      _setBusyText(HeaderStatus('download', '$label…'));
      final zip = await _releases.download(release, onProgress: (v) {
        if (v != null) _setBusyText(HeaderStatus('download', '$label — ${(v * 100).round()}%'));
      });
      _setBusyText(HeaderStatus('install', 'Устанавливаю zapret ${release.version}…'));
      await _replaceZapret(targetPath, () => installFromZip(zip, Directory(targetPath)));
      installed = release.version;
    });
    if (ok) {
      toasts.show(ToastData(
        firstInstall
            ? 'Zapret $installed установлен'
            : auto
                ? 'Zapret обновился сам до $installed'
                : 'Zapret обновлён до $installed',
        icon: LucideIcons.download,
        actionLabel: firstInstall ? null : 'Что нового',
        onAction: firstInstall ? null : openReleasePage,
      ));
      if (auto) onBackgroundNotice?.call('Zapret обновлён до $installed', 'Лаунчер поставил новую версию сам.');
    }
    return ok;
  }

  /// Прежняя версия zapret, к которой можно вернуться; null — её нет.
  String? get previousZapretVersion {
    final inst = _install;
    if (inst == null) return null;
    final dir = previousVersionDir(inst.root);
    if (!dir.existsSync()) return null;
    return ZapretInstall.readVersion(dir) ?? 'прежняя';
  }

  /// Вернуть прежнюю версию zapret (и обратно — версии меняются местами).
  Future<bool> rollbackZapret({String? because}) async {
    final inst = _install;
    final previous = previousZapretVersion;
    if (inst == null || previous == null) return false;
    final from = inst.version;
    final ok = await _task(HeaderStatus('rollback', 'Возвращаю zapret $previous…'), () async {
      await _replaceZapret(inst.root.path, () => swapWithPrevious(inst.root));
    });
    if (ok) {
      final title = because == null ? 'Вернул zapret $previous' : 'Zapret $from $because — вернул $previous';
      toasts.show(ToastData(title, icon: LucideIcons.undo2));
      if (because != null) onBackgroundNotice?.call(title, 'Эту версию лаунчер сам больше не поставит.');
    }
    return ok;
  }

  /// Замена файлов zapret или переход в другую папку: остановить (файлы заняты, пока
  /// работает winws.exe и загружен драйвер), заменить и запустить снова так же —
  /// службой или процессом. Zapret, работавший из прежней папки, переезжает в новую.
  Future<void> _replaceZapret(String targetPath, Future<ZapretInstall> Function() replace) async {
    final before = _runner.status();
    final active = before.activeRoot;
    final current = _install?.root.path;
    final affected = active != null &&
        (p.equals(active, targetPath) || (current != null && p.equals(active, current)));
    final wasRunning = before.running && affected;
    final hadService = before.serviceInstalled && affected;
    final chosen = _settings.strategy;
    if (affected) {
      await _runner.stopAll();
      await _runner.unloadDriver();
    }
    final inst = await replace();
    _install = inst;
    final isBuiltin = p.equals(inst.root.path, _builtinDir);
    // Своя папка помнится и при встроенном — чтобы вернуться к ней одним нажатием.
    _saveSettings(_settings.copyWith(
      zapretSource: isBuiltin ? ZapretSource.builtin : ZapretSource.custom,
      zapretDir: isBuiltin ? null : inst.root.path,
    ));
    _readZapretSettings();

    final s = strategy;
    if (chosen != null && s != null && inst.strategyById(chosen) == null) {
      // В новой версии такой стратегии нет — берём стандартную и говорим об этом.
      _error = AppError('Стратегии «${Strategy(id: chosen, file: File(chosen)).title}» нет в zapret ${inst.version}',
          'Включена «${s.title}». Если сайты не открываются — подберите стратегию заново.');
    }
    if (s != null && (wasRunning || hadService)) {
      _setBusyText(HeaderStatus('start', 'Запускаю «${s.title}»…'));
      if (hadService) {
        await _runner.installService(inst, s, _gameFilter);
      } else {
        await _runner.startProcess(inst, s, _gameFilter);
      }
    }
  }

  void setAutoUpdateZapret(bool value) {
    _saveSettings(_settings.copyWith(autoUpdateZapret: value));
    notifyListeners();
  }

  Future<void> _autoUpdateZapret() async {
    final target = _latest?.version;
    if (target != null) await _autoUpdate(target, () => installLatest(auto: true));
  }

  /// Новая версия zapret ставится сама. Если с ней Discord или YouTube перестали
  /// открываться, а до обновления открывались, — возвращаем прежнюю и её больше не ставим.
  Future<void> _autoUpdate(String target, Future<bool> Function() install) async {
    if (!_elevated || _busy != null || probing || _install == null) return;
    final wasRunning = running;
    // Как было до обновления — чтобы было с чем сравнить.
    if (wasRunning) await checkNetwork();
    final before = wasRunning ? _network : null;
    if (!await install()) return;
    if (before == null || !running) return;
    await Future<void>.delayed(const Duration(seconds: 3));
    await checkNetwork();
    final after = _network;
    if (after == null || !_brokeServices(before, after)) return;
    _saveSettings(_settings.copyWith(skippedZapretVersion: target));
    await rollbackZapret(because: 'сломал обход');
  }

  /// Discord или YouTube открывались до, а после — нет.
  static bool _brokeServices(NetworkReport before, NetworkReport after) {
    if (after.offline) return false;
    for (final g in const ['Discord', 'YouTube']) {
      if (before.health(g) == ServiceHealth.ok && after.health(g) != ServiceHealth.ok) return true;
    }
    return false;
  }

  /// Подбор стратегии: проверка без обхода, затем каждая стратегия по очереди.
  /// После проверки zapret возвращается в то состояние, в каком был.
  Future<void> autoPick() async {
    final inst = _install;
    if (inst == null || inst.strategies.isEmpty || _busy != null || runningElsewhere) return;
    final before = _runner.status();
    final previous = strategy;
    final pick = AutoPick(
      env: _probeEnvironment?.call(inst, _gameFilter) ??
          _WinwsProbeEnvironment(_runner, inst, _gameFilter),
      strategies: inst.strategies,
      targets: probeTargets,
    );
    _autoPick = pick;
    _probeReport = null;
    _probeProgress = null;

    await _task(const HeaderStatus('probe', 'Проверяю сайты без обхода…'), () async {
      try {
        _runner.prepare(inst);
        // Две копии winws.exe одновременно не работают — останавливаем текущую.
        if (before.running) await _runner.stopAll();
        final report = await pick.run(onProgress: (p) {
          _probeProgress = p;
          if (pick.cancelled) return notifyListeners();
          _setBusyText(HeaderStatus(
            'probe',
            p.current != null
                ? 'Проверяю «${p.current!.title}» — ${p.index + 1} из ${p.total}'
                : p.baseline == null
                    ? 'Проверяю сайты без обхода…'
                    : 'Подвожу итоги…',
          ));
        });
        _probeReport = report;
        final best = report.best;
        if (!report.cancelled && best != null) {
          toasts.show(ToastData(
            'Лучшая — «${best.strategy!.title}»: ${best.okCount} из ${best.total} сайтов',
            icon: LucideIcons.trophy,
            actionLabel: 'Включить',
            onAction: () => applyStrategy(best.strategy!),
          ));
        }
      } on NoInternetException {
        throw const ZapretException('Сайты не открываются даже без обхода',
            detail: 'Адреса не находятся — проверьте подключение к интернету');
      } finally {
        _autoPick = null;
        await _runner.killProcesses();
        // Возвращаем как было до проверки.
        if (before.serviceRunning) {
          _setBusyText(const HeaderStatus('restore', 'Возвращаю службу zapret…'));
          await _runner.startService();
        } else if (before.running && previous != null) {
          _setBusyText(HeaderStatus('restore', 'Возвращаю «${previous.title}»…'));
          await _runner.startProcess(inst, previous, _gameFilter);
        }
      }
    });
  }

  /// Остановить подбор: текущая стратегия доплетётся, дальше — не пойдём.
  void cancelAutoPick() {
    _autoPick?.cancel();
    _setBusyText(const HeaderStatus('probe', 'Останавливаю проверку…'));
  }

  /// Выбрать стратегию и включить zapret с ней.
  Future<void> applyStrategy(Strategy s) async {
    _saveSettings(_settings.copyWith(strategy: s.id));
    _rememberForNetwork();
    notifyListeners();
    if (running) {
      await _restartIfRunning('Перезапускаю с «${s.title}»…');
    } else {
      await start();
    }
  }

  /// Своя папка с уже скачанным zapret. Если zapret работает — перезапустится из неё.
  Future<void> chooseFolder() async {
    final path = win.pickFolder(title: 'Папка zapret-discord-youtube — та, где лежит service.bat');
    if (path == null) return;
    final inst = ZapretInstall.open(path);
    if (inst == null) {
      _error = AppError('В этой папке нет zapret', '$path — нет bin\\winws.exe или файлов general*.bat');
      notifyListeners();
      return;
    }
    if (await _useInstall(inst)) {
      toasts.show(ToastData('Папка zapret выбрана', icon: LucideIcons.folderOpen));
    }
  }

  /// Встроенный zapret или своя папка. Своей папки ещё нет — спросим, где она.
  Future<void> setZapretSource(ZapretSource source) async {
    if (source == zapretSource && _install != null) return;
    if (source == ZapretSource.custom) {
      final dir = _settings.zapretDir;
      final inst = dir == null ? null : ZapretInstall.open(dir);
      if (inst == null) return chooseFolder();
      if (await _useInstall(inst)) {
        toasts.show(ToastData('Zapret из своей папки', icon: LucideIcons.folderOpen));
      }
      return;
    }
    final existing = ZapretInstall.open(_builtinDir);
    final bundled = _bundle.version;
    // Встроенный новее распакованного — ставим его, если zapret обновляется сам.
    final fresher = bundled != null &&
        (existing == null ||
            (_settings.autoUpdateZapret &&
                bundled != _settings.skippedZapretVersion &&
                compareVersions(bundled, existing.version ?? '0') > 0));
    if (fresher) {
      await installBundled();
    } else if (existing != null) {
      if (await _useInstall(existing)) {
        toasts.show(const ToastData('Встроенный zapret', icon: LucideIcons.package));
      }
    } else {
      // Сборка без встроенного zapret: на главной предложим скачать его с GitHub.
      _install = null;
      _saveSettings(_settings.copyWith(zapretSource: ZapretSource.builtin));
      _readZapretSettings();
      notifyListeners();
    }
  }

  /// Перейти на zapret из другой папки; работающий zapret переезжает вместе с выбором.
  Future<bool> _useInstall(ZapretInstall inst) => _task(
        HeaderStatus('source', running ? 'Перезапускаю zapret из новой папки…' : 'Меняю папку zapret…'),
        () => _replaceZapret(inst.root.path, () async => inst),
      );

  void openZapretFolder() {
    final inst = _install;
    if (inst != null) win.shellExecute(inst.root.path);
  }

  void openReleasePage() {
    final url = _latest?.pageUrl.toString() ?? 'https://github.com/$zapretRepo/releases/latest';
    win.shellExecute(url);
  }

  /// Перезапуск от имени администратора; текущее окно закрывается.
  Future<void> restartElevated() async {
    if (win.relaunchElevated()) {
      // Новый экземпляр ждёт, пока этот закроется (см. windows/runner/main.cpp).
      final quit = quitHandler;
      if (quit != null) {
        await quit();
      } else {
        exit(0);
      }
    } else {
      _error = const AppError('Права администратора не получены',
          'Windows отклонила запрос. Запустите лаунчер правой кнопкой → «Запуск от имени администратора»');
      notifyListeners();
    }
  }
}

/// Что сторож сети может делать с zapret — через контроллер, со статусом в шапке.
class _GuardBridge implements GuardedZapret {
  _GuardBridge(this._c);

  final AppController _c;

  @override
  bool get running => _c.running;

  @override
  bool get busy => _c._busy != null || _c.probing;

  @override
  Future<bool> stop({String? status}) => _c._task(
      HeaderStatus('guard', status ?? 'Сеть сменилась — выключаю zapret…'), _c._runner.stopAll);

  @override
  Future<bool> start({String? status}) async {
    final inst = _c._install;
    final s = _c.strategy;
    if (inst == null || s == null) return false;
    return _c._task(HeaderStatus('guard', status ?? 'Включаю «${s.title}»…'), () => _c._startWith(inst, s));
  }

  @override
  Future<bool?> servicesOpen() => _c._servicesOpenWithoutZapret();
}

/// Подбор на настоящем winws.exe: запросы из лаунчера тоже идут через WinDivert.
class _WinwsProbeEnvironment implements ProbeEnvironment {
  _WinwsProbeEnvironment(this._runner, this._install, this._filter);

  final ZapretRunner _runner;
  final ZapretInstall _install;
  final GameFilter _filter;
  final _http = HttpProber();

  @override
  Future<bool> start(Strategy strategy) => _runner.startForProbe(_install, strategy, _filter);

  @override
  Future<void> stop() => _runner.killProcesses();

  @override
  Future<TargetResult> check(ProbeTarget target) => _http.check(target);

  @override
  void abort() => _http.abortAll();
}

/// Даёт страницам доступ к [AppController].
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child})
      : super(notifier: controller);

  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Без подписки на изменения — для initState и обработчиков.
  static AppController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
