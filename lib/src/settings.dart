import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'location/profiles.dart';

/// Откуда zapret: встроенный в лаунчер или своя папка пользователя.
enum ZapretSource {
  /// Идёт вместе с лаунчером; лежит в [SettingsStore.defaultZapretDir], обновляется сам.
  builtin,

  /// zapret-discord-youtube из папки пользователя — лаунчер запускает его как есть.
  custom,
}

/// Настройки лаунчера: %APPDATA%\ZapretLauncher\settings.json.
class AppSettings {
  const AppSettings({
    this.zapretSource,
    this.zapretDir,
    this.strategy,
    this.themeMode = ThemeMode.system,
    this.closeToTray = true,
    this.watchdog = true,
    this.trayHintShown = false,
    this.runModeAsked = false,
    this.networkGuard = true,
    this.countryCheck = true,
    this.profilesEnabled = true,
    this.profiles = const [],
    this.autoCheckUpdates = true,
    this.autoUpdateZapret = true,
    this.skippedZapretVersion,
  });

  /// Откуда zapret; null — настройки от версии без встроенного zapret (решит контроллер).
  final ZapretSource? zapretSource;

  /// Своя папка zapret ([ZapretSource.custom]); помнится и при встроенном.
  final String? zapretDir;

  /// Выбранная стратегия (имя файла без .bat).
  final String? strategy;
  final ThemeMode themeMode;

  /// Крестик прячет окно в трей, а не закрывает лаунчер.
  final bool closeToTray;

  /// Перезапускать winws.exe, если он закрылся сам.
  final bool watchdog;

  /// Подсказку «лаунчер в трее» уже показывали.
  final bool trayHintShown;

  /// Уже спросили, как запускать zapret — как general.bat или службой Windows.
  /// Сам способ — в системе: стоит служба zapret или нет.
  final bool runModeAsked;

  /// При смене сети выключать zapret, если обход не нужен, и включать снова.
  final bool networkGuard;

  /// Определять страну по IP через открытые сервисы.
  final bool countryCheck;

  /// Помнить стратегию для каждой сети (провайдера) и переключать её сам.
  final bool profilesEnabled;
  final List<NetworkProfile> profiles;

  /// Раз в 6 часов спрашивать, вышли ли новые версии лаунчера и zapret.
  final bool autoCheckUpdates;

  /// Ставить новые версии zapret самому.
  final bool autoUpdateZapret;

  /// Версия zapret, от которой лаунчер откатился: сам её больше не ставит.
  final String? skippedZapretVersion;

  AppSettings copyWith({
    ZapretSource? zapretSource,
    String? zapretDir,
    String? strategy,
    ThemeMode? themeMode,
    bool? closeToTray,
    bool? watchdog,
    bool? trayHintShown,
    bool? runModeAsked,
    bool? networkGuard,
    bool? countryCheck,
    bool? profilesEnabled,
    List<NetworkProfile>? profiles,
    bool? autoCheckUpdates,
    bool? autoUpdateZapret,
    String? skippedZapretVersion,
  }) => AppSettings(
    zapretSource: zapretSource ?? this.zapretSource,
    zapretDir: zapretDir ?? this.zapretDir,
    strategy: strategy ?? this.strategy,
    themeMode: themeMode ?? this.themeMode,
    closeToTray: closeToTray ?? this.closeToTray,
    watchdog: watchdog ?? this.watchdog,
    trayHintShown: trayHintShown ?? this.trayHintShown,
    runModeAsked: runModeAsked ?? this.runModeAsked,
    networkGuard: networkGuard ?? this.networkGuard,
    countryCheck: countryCheck ?? this.countryCheck,
    profilesEnabled: profilesEnabled ?? this.profilesEnabled,
    profiles: profiles ?? this.profiles,
    autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
    autoUpdateZapret: autoUpdateZapret ?? this.autoUpdateZapret,
    skippedZapretVersion: skippedZapretVersion ?? this.skippedZapretVersion,
  );

  Map<String, Object?> toJson() => {
    'zapretSource': zapretSource?.name,
    'zapretDir': zapretDir,
    'strategy': strategy,
    'themeMode': themeMode.name,
    'closeToTray': closeToTray,
    'watchdog': watchdog,
    'trayHintShown': trayHintShown,
    'runModeAsked': runModeAsked,
    'networkGuard': networkGuard,
    'countryCheck': countryCheck,
    'profilesEnabled': profilesEnabled,
    'profiles': [for (final p in profiles) p.toJson()],
    'autoCheckUpdates': autoCheckUpdates,
    'autoUpdateZapret': autoUpdateZapret,
    'skippedZapretVersion': skippedZapretVersion,
  };

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    zapretSource: ZapretSource.values
        .where((s) => s.name == json['zapretSource'])
        .firstOrNull,
    zapretDir: json['zapretDir'] as String?,
    strategy: json['strategy'] as String?,
    themeMode: ThemeMode.values.firstWhere(
      (m) => m.name == json['themeMode'],
      orElse: () => ThemeMode.system,
    ),
    closeToTray: json['closeToTray'] as bool? ?? true,
    watchdog: json['watchdog'] as bool? ?? true,
    trayHintShown: json['trayHintShown'] as bool? ?? false,
    // Нет в файле — настройки от прежней версии: zapret уже запускали, не спрашиваем.
    runModeAsked: json['runModeAsked'] as bool? ?? true,
    networkGuard: json['networkGuard'] as bool? ?? true,
    countryCheck: json['countryCheck'] as bool? ?? true,
    profilesEnabled: json['profilesEnabled'] as bool? ?? true,
    profiles: [
      for (final p in (json['profiles'] as List? ?? const []))
        ?NetworkProfile.fromJson(p),
    ],
    autoCheckUpdates: json['autoCheckUpdates'] as bool? ?? true,
    autoUpdateZapret: json['autoUpdateZapret'] as bool? ?? true,
    skippedZapretVersion: json['skippedZapretVersion'] as String?,
  );
}

class SettingsStore {
  SettingsStore({String? path}) : _file = File(path ?? _defaultPath());

  final File _file;

  static String _defaultPath() {
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return p.join(appData, 'ZapretLauncher', 'settings.json');
  }

  /// Папка встроенного zapret. ProgramData — путь без кириллицы и пробелов
  /// (с ними winws.exe работает ненадёжно) и доступен службе Windows.
  static String defaultZapretDir() {
    final programData =
        Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    return p.join(programData, 'ZapretLauncher', 'zapret');
  }

  AppSettings load() {
    try {
      if (!_file.existsSync()) return const AppSettings();
      return AppSettings.fromJson(
        jsonDecode(_file.readAsStringSync()) as Map<String, Object?>,
      );
    } on Object {
      // Повреждённый файл — начинаем с настроек по умолчанию.
      return const AppSettings();
    }
  }

  void save(AppSettings settings) {
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
    tmp.renameSync(_file.path);
  }
}
