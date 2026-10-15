import 'package:flutter_test/flutter_test.dart';
import 'package:zapret_launcher/src/platform/win32.dart' as win;
import 'package:zapret_launcher/src/telegram/desktop.dart';

const _sid = 'S-1-5-21-1-2-3-1001';
const _appData = r'C:\Users\me\AppData\Roaming';
const _exe = '$_appData\\Telegram Desktop\\Telegram.exe';
const _store =
    r'C:\Program Files\WindowsApps\TelegramMessengerLLP.TelegramDesktop_5.6.3.0_x64__t4vj0pshhgkwm\Telegram.exe';

/// Windows понарошку: реестр — словарь «раздел\ключ|значение», файлы — множество.
class _FakeSystem extends TelegramSystem {
  win.DesktopUser? user = const win.DesktopUser(_sid, 1);
  final values = <String, String>{};
  final keys = <String, List<String>>{};
  final files = <String>{};
  final processes = <(int, String?)>[];

  @override
  win.DesktopUser? desktopUser() => user;

  @override
  String? readString(win.RegistryHive hive, String key, [String value = '']) =>
      values['${hive.name}\\$key|$value'];

  @override
  List<String> subkeys(win.RegistryHive hive, String key) =>
      keys['${hive.name}\\$key'] ?? const [];

  @override
  List<String?> running(int? session) => [
    for (final (s, path) in processes)
      if (session == null || s == session) path,
  ];

  @override
  bool exists(String path) => files.contains(path);

  @override
  String? env(String name) => name == 'APPDATA' ? _appData : null;
}

void main() {
  late _FakeSystem system;
  late TelegramDesktop desktop;

  setUp(() {
    system = _FakeSystem();
    desktop = TelegramDesktop(system);
  });

  test('ничего нет — не найден', () {
    expect(desktop.find(), isNull);
    expect(desktop.installed, isFalse);
  });

  test('обычная установка: tg:// у пользователя за компьютером', () {
    system.values['users\\${_sid}_Classes\\tg\\shell\\open\\command|'] =
        '"$_exe" -workdir "$_appData\\Telegram Desktop" -- "%1"';
    system.files.add(_exe);
    final app = desktop.find()!;
    expect(app.handlesLinks, isTrue);
    expect(app.exe, _exe);
  });

  test('tg:// ведёт на удалённую программу — не считается', () {
    system.values['users\\${_sid}_Classes\\tg\\shell\\open\\command|'] =
        '"$_exe" -- "%1"';
    expect(desktop.find(), isNull);
  });

  test('без рабочего стола — ищем у текущего пользователя', () {
    system.user = null;
    system.values['currentUser\\Software\\Classes\\tg\\shell\\open\\command|'] =
        '"$_exe" -- "%1"';
    system.files.add(_exe);
    expect(desktop.find()!.handlesLinks, isTrue);
  });

  test('версия из Microsoft Store: по пакету пользователя', () {
    system.keys['users\\${_sid}_Classes\\Local Settings\\Software\\Microsoft\\'
            'Windows\\CurrentVersion\\AppModel\\Repository\\Packages'] =
        [
          'Microsoft.WindowsStore_22409.1401.5.0_x64__8wekyb3d8bbwe',
          'TelegramMessengerLLP.TelegramDesktop_5.6.3.0_x64__t4vj0pshhgkwm',
        ];
    final app = desktop.find()!;
    expect(app.handlesLinks, isTrue);
    expect(app.exe, isNull);
  });

  test('выбран в «Приложениях по умолчанию» (пакет Store)', () {
    system.values['users\\$_sid\\Software\\Microsoft\\Windows\\Shell\\'
            'Associations\\UrlAssociations\\tg\\UserChoice|ProgId'] =
        'AppXabc';
    system.values['users\\${_sid}_Classes\\AppXabc\\Application|AppUserModelID'] =
        'TelegramMessengerLLP.TelegramDesktop_t4vj0pshhgkwm!Telegram';
    expect(desktop.find()!.handlesLinks, isTrue);
  });

  test('запущен: ссылки принимает, путь из процесса; Store — без пути', () {
    system.processes.add((1, _exe));
    expect(desktop.running, isTrue);
    expect(desktop.find()!.exe, _exe);

    system.processes
      ..clear()
      ..add((1, _store));
    final app = desktop.find()!;
    expect(app.handlesLinks, isTrue);
    expect(app.exe, isNull);
  });

  test('запущен у другого пользователя — не считается', () {
    system.processes.add((2, _exe));
    expect(desktop.running, isFalse);
    expect(desktop.find(), isNull);
  });

  test('не запускался: найден в «Программах и компонентах»', () {
    const key =
        r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{53F49750}_is1';
    system.keys['users\\$_sid\\Software\\Microsoft\\Windows\\CurrentVersion\\'
        'Uninstall'] = [
      '{53F49750}_is1',
    ];
    system.values['users\\$_sid\\$key|DisplayName'] =
        'Telegram Desktop version 5.6.3';
    system.values['users\\$_sid\\$key|InstallLocation'] =
        '$_appData\\Telegram Desktop\\';
    system.files.add(_exe);
    final app = desktop.find()!;
    expect(app.handlesLinks, isFalse);
    expect(app.exe, _exe);
  });

  test('не запускался: в папке по умолчанию пользователя за компьютером', () {
    system.values['users\\$_sid\\Software\\Microsoft\\Windows\\'
            'CurrentVersion\\Explorer\\Shell Folders|AppData'] =
        _appData;
    system.files.add(_exe);
    expect(desktop.find()!.exe, _exe);
  });

  test('программа из команды реестра', () {
    expect(TelegramDesktop.exeOf('"$_exe" -- "%1"'), _exe);
    expect(TelegramDesktop.exeOf(r'C:\Tg\Telegram.exe -- "%1"'), r'C:\Tg\Telegram.exe');
    expect(TelegramDesktop.exeOf(r'C:\Tg\Telegram.exe,0'), r'C:\Tg\Telegram.exe');
    expect(TelegramDesktop.exeOf('"$_exe",0'), _exe);
    expect(TelegramDesktop.exeOf(''), isNull);
    expect(TelegramDesktop.exeOf(null), isNull);
    expect(TelegramDesktop.isStoreApp(_store), isTrue);
    expect(TelegramDesktop.isStoreApp(_exe), isFalse);
  });
}
