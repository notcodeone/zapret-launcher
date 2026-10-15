import 'dart:io';

import '../platform/win32.dart' as win;

/// Что нашлось на компьютере: чем открыть ссылку tg://.
class TelegramInstall {
  const TelegramInstall({this.exe, this.handlesLinks = false});

  /// Telegram.exe обычной версии (не из Microsoft Store): его можно запустить
  /// со ссылкой, даже если ссылки tg:// он ещё не принимает.
  final String? exe;

  /// Windows знает, чем открывать ссылки tg://: Telegram прописывает это при
  /// первом запуске, версия из Microsoft Store — при установке.
  final bool handlesLinks;
}

/// Что лаунчер спрашивает у Windows, чтобы найти Telegram. Подменяется в тестах.
class TelegramSystem {
  const TelegramSystem();

  win.DesktopUser? desktopUser() => win.desktopUser();

  String? readString(win.RegistryHive hive, String key, [String value = '']) =>
      win.readRegistryString(key, value, hive: hive);

  List<String> subkeys(win.RegistryHive hive, String key) =>
      win.registrySubkeys(key, hive: hive);

  /// Пути к запущенным Telegram.exe в сеансе [session] (null — в любом);
  /// null в списке — путь не узнать.
  List<String?> running(int? session) => [
    for (final p in win.findProcesses(TelegramDesktop.exeName))
      if (session == null || win.processSessionId(p.pid) == session)
        win.processImagePath(p.pid),
  ];

  bool exists(String path) => File(path).existsSync();

  String? env(String name) => Platform.environment[name];
}

/// Telegram Desktop на этом компьютере. Ссылка tg:// запускает закрытый Telegram,
/// поэтому перед ней лаунчер спрашивает, а не запускает его сам.
///
/// Ищем у того, кто сидит за компьютером, а не у того, от чьего имени работает
/// лаунчер: при запросе прав администратора могли ввести пароль другой учётной
/// записи, и тогда HKEY_CURRENT_USER и %APPDATA% лаунчера — чужие.
class TelegramDesktop {
  const TelegramDesktop([this._system = const TelegramSystem()]);

  final TelegramSystem _system;

  static const exeName = 'Telegram.exe';

  /// Начала имён пакетов Microsoft Store, которые открывают ссылки tg://:
  /// Telegram Desktop и Unigram.
  static const _storePackages = [
    'TelegramMessengerLLP.',
    '38833FF26BA1D.Unigram',
  ];

  static const _uninstall = r'Software\Microsoft\Windows\CurrentVersion\Uninstall';
  static const _uninstall32 =
      r'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall';

  /// Установлен: есть чем открыть ссылку tg://.
  bool get installed => find() != null;

  /// Запущен у того, кто сидит за компьютером: ссылка попадёт в открытое окно.
  bool get running => _system.running(_system.desktopUser()?.session).isNotEmpty;

  /// Ищет Telegram всеми способами, от точных к косвенным. null — не нашёлся.
  TelegramInstall? find() {
    final user = _system.desktopUser();
    final (win.RegistryHive hive, String profile, String classes) = user == null
        ? (win.RegistryHive.currentUser, '', r'Software\Classes')
        : (win.RegistryHive.users, '${user.sid}\\', '${user.sid}_Classes');
    final classRoots = [
      (hive, classes),
      (win.RegistryHive.localMachine, r'Software\Classes'),
    ];
    String? exe;
    var links = false;

    void handler(String? command) {
      final path = exeOf(command);
      if (path == null || !_system.exists(path)) return;
      links = true;
      if (!isStoreApp(path)) exe ??= path;
    }

    // Запущенный Telegram уже прописал ссылки tg:// — при старте он делает это сам.
    for (final path in _system.running(user?.session)) {
      links = true;
      if (path != null && !isStoreApp(path)) exe ??= path;
    }

    // Ссылки tg://, прописанные для пользователя или для всех.
    for (final (h, root) in classRoots) {
      handler(_system.readString(h, '$root\\tg\\shell\\open\\command'));
    }

    // Приложение для tg://, выбранное в «Приложениях по умолчанию».
    final progId = _system.readString(
      hive,
      '${profile}Software\\Microsoft\\Windows\\Shell\\Associations\\'
      'UrlAssociations\\tg\\UserChoice',
      'ProgId',
    );
    if (progId != null && progId.isNotEmpty) {
      for (final (h, root) in classRoots) {
        handler(_system.readString(h, '$root\\$progId\\shell\\open\\command'));
        final app = _system.readString(
          h,
          '$root\\$progId\\Application',
          'AppUserModelID',
        );
        if (app != null && _isStorePackage(app)) links = true;
      }
    }

    // Версия из Microsoft Store: ссылки tg:// прописаны в самом пакете, в
    // HKEY_CLASSES_ROOT\tg их нет.
    final packages = _system.subkeys(
      hive,
      '$classes\\Local Settings\\Software\\Microsoft\\Windows\\'
      'CurrentVersion\\AppModel\\Repository\\Packages',
    );
    if (packages.any(_isStorePackage)) links = true;

    // Установлен, но ещё ни разу не запускался — ссылки tg:// не прописаны.
    // Ищем в «Программах и компонентах» и в папке установки по умолчанию.
    if (exe == null) {
      for (final (h, key) in [
        (hive, '$profile$_uninstall'),
        (win.RegistryHive.localMachine, _uninstall),
        (win.RegistryHive.localMachine, _uninstall32),
      ]) {
        for (final app in _system.subkeys(h, key)) {
          final name = _system.readString(h, '$key\\$app', 'DisplayName');
          if (name == null || !name.startsWith('Telegram Desktop')) continue;
          final dir = _system.readString(h, '$key\\$app', 'InstallLocation');
          for (final path in [
            if (dir != null && dir.trim().isNotEmpty) _join(dir, exeName),
            exeOf(_system.readString(h, '$key\\$app', 'DisplayIcon')),
          ]) {
            if (path != null && !isStoreApp(path) && _system.exists(path)) {
              exe ??= path;
            }
          }
        }
      }
    }
    if (exe == null) {
      final appData = user == null
          ? _system.env('APPDATA')
          : _system.readString(
              hive,
              '${profile}Software\\Microsoft\\Windows\\CurrentVersion\\'
              'Explorer\\Shell Folders',
              'AppData',
            );
      if (appData != null && appData.isNotEmpty) {
        final path = _join(_join(appData, 'Telegram Desktop'), exeName);
        if (_system.exists(path)) exe = path;
      }
    }

    if (!links && exe == null) return null;
    return TelegramInstall(exe: exe, handlesLinks: links);
  }

  /// Открывает ссылку от имени обычного пользователя. false — открыть нечем
  /// или Windows не открыла.
  bool open(String link, {required bool elevated}) {
    final app = find();
    if (app == null) return false;
    if (app.handlesLinks && win.openLink(link, elevated: elevated)) return true;
    // Ссылки tg:// не прописаны — Telegram принимает ссылку после «--».
    final exe = app.exe;
    return exe != null && win.startAsUser(exe, '-- "$link"', elevated: elevated);
  }

  /// Программа из команды реестра: `"C:\…\Telegram.exe" -- "%1"`, `C:\…\x.exe,0`.
  static String? exeOf(String? command) {
    var s = command?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s.startsWith('"')) {
      final end = s.indexOf('"', 1);
      s = end > 1 ? s.substring(1, end) : '';
    } else {
      s = RegExp(r'^.*?\.exe', caseSensitive: false).firstMatch(s)?.group(0) ??
          s;
    }
    s = s.replaceAllMapped(
      RegExp('%([^%]+)%'),
      (m) => Platform.environment[m[1]!] ?? m[0]!,
    );
    return s.toLowerCase().endsWith('.exe') ? s : null;
  }

  /// Программа из пакета Microsoft Store — её не запустить напрямую.
  static bool isStoreApp(String path) =>
      path.toLowerCase().contains(r'\windowsapps\');

  static bool _isStorePackage(String name) => _storePackages.any(
    (p) => name.toLowerCase().startsWith(p.toLowerCase()),
  );

  static String _join(String dir, String name) =>
      dir.endsWith(r'\') ? '$dir$name' : '$dir\\$name';
}
