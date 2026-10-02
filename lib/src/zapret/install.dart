import 'dart:io';

import 'package:path/path.dart' as p;

import 'strategy.dart';

/// Режим игрового фильтра — как в service.bat (utils/game_filter.enabled).
enum GameFilterMode { disabled, all, tcp, udp }

class GameFilter {
  const GameFilter({
    this.mode = GameFilterMode.disabled,
    this.tcpRange = defaultRange,
    this.udpRange = defaultRange,
  });

  static const defaultRange = '1024-65535';

  /// Заглушка вместо диапазона, когда фильтр выключен: порт 12 никто не использует.
  static const _off = '12';

  final GameFilterMode mode;
  final String tcpRange;
  final String udpRange;

  bool get enabled => mode != GameFilterMode.disabled;

  String get tcpValue =>
      mode == GameFilterMode.all || mode == GameFilterMode.tcp ? tcpRange : _off;
  String get udpValue =>
      mode == GameFilterMode.all || mode == GameFilterMode.udp ? udpRange : _off;

  GameFilter copyWith({GameFilterMode? mode}) =>
      GameFilter(mode: mode ?? this.mode, tcpRange: tcpRange, udpRange: udpRange);

  /// Разбор файла в формате service.bat: строки `mode=…`, `tcp=…`, `udp=…`.
  /// Старый формат — просто `all`, `tcp` или `udp` без значения.
  static GameFilter parse(String text) {
    var mode = GameFilterMode.disabled;
    String? tcp;
    String? udp;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final eq = line.indexOf('=');
      final key = (eq < 0 ? line : line.substring(0, eq)).trim().toLowerCase();
      final value = eq < 0 ? '' : line.substring(eq + 1).trim();
      switch (key) {
        case 'mode':
          mode = GameFilterMode.values.firstWhere(
            (m) => m.name == value.toLowerCase(),
            orElse: () => GameFilterMode.disabled,
          );
        case 'all':
          mode = GameFilterMode.all;
        case 'tcp':
          if (value.isEmpty) {
            mode = GameFilterMode.tcp;
          } else {
            tcp = value;
          }
        case 'udp':
          if (value.isEmpty) {
            mode = GameFilterMode.udp;
          } else {
            udp = value;
          }
      }
    }
    return GameFilter(
      mode: mode,
      tcpRange: validateRange(tcp) ?? defaultRange,
      udpRange: validateRange(udp) ?? defaultRange,
    );
  }

  String serialize() => 'mode=${mode.name}\r\ntcp=$tcpRange\r\nudp=$udpRange\r\n';

  /// Порты и диапазоны через запятую: «1024-1934,1936-65535». null — ошибка.
  static String? validateRange(String? input) {
    if (input == null) return null;
    final s = input.replaceAll(' ', '');
    if (s.isEmpty) return null;
    for (final item in s.split(',')) {
      final m = RegExp(r'^([1-9]\d{0,4})(?:-([1-9]\d{0,4}))?$').firstMatch(item);
      if (m == null) return null;
      final a = int.parse(m[1]!);
      final b = int.parse(m[2] ?? m[1]!);
      if (a > 65535 || b > 65535 || a > b) return null;
    }
    return s;
  }
}

/// Режим IPSet — как в service.bat:
/// none — список-заглушка, loaded — список адресов, any — пустой файл (весь трафик).
enum IpsetMode { none, loaded, any }

/// Установленная копия zapret-discord-youtube.
class ZapretInstall {
  ZapretInstall._(this.root, this.version, this.strategies);

  final Directory root;

  /// Версия из service.bat (LOCAL_VERSION), если удалось прочитать.
  final String? version;
  final List<Strategy> strategies;

  static const _ipsetStub = '203.0.113.113/32';

  String get binDir => p.join(root.path, 'bin');
  String get listsDir => p.join(root.path, 'lists');
  String get utilsDir => p.join(root.path, 'utils');
  File get winws => File(p.join(binDir, 'winws.exe'));

  File get _gameFilterFile => File(p.join(utilsDir, 'game_filter.enabled'));
  File get _ipsetFile => File(p.join(listsDir, 'ipset-all.txt'));
  File get _ipsetBackup => File(p.join(listsDir, 'ipset-all.txt.backup'));

  /// Похожа ли папка на zapret: есть bin/winws.exe и хотя бы одна стратегия.
  static bool looksLikeZapret(Directory dir) =>
      File(p.join(dir.path, 'bin', 'winws.exe')).existsSync() &&
      findStrategies(dir).isNotEmpty;

  /// Открывает установку или возвращает null, если папка не похожа на zapret.
  static ZapretInstall? open(String path) {
    final dir = Directory(path);
    if (!looksLikeZapret(dir)) return null;
    return ZapretInstall._(dir, readVersion(dir), findStrategies(dir));
  }

  static String? readVersion(Directory dir) {
    final f = File(p.join(dir.path, 'service.bat'));
    if (!f.existsSync()) return null;
    final m = RegExp(r'set\s+"LOCAL_VERSION=([^"]+)"', caseSensitive: false)
        .firstMatch(f.readAsStringSync());
    return m?.group(1)?.trim();
  }

  Strategy? strategyById(String? id) {
    if (id == null) return null;
    for (final s in strategies) {
      if (s.id.toLowerCase() == id.toLowerCase()) return s;
    }
    return null;
  }

  /// Переменные, которые .bat получают от service.bat.
  Map<String, String> variables(GameFilter filter) => {
        'BIN': '$binDir\\',
        'LISTS': '$listsDir\\',
        'GameFilter': filter.mode == GameFilterMode.udp ? filter.udpValue : filter.tcpValue,
        'GameFilterTCP': filter.tcpValue,
        'GameFilterUDP': filter.udpValue,
      };

  /// Готовые аргументы winws.exe для стратегии.
  Future<List<String>> argsFor(Strategy strategy, GameFilter filter) async =>
      resolveArgs(await strategy.readTemplate(), variables(filter));

  // ── Игровой фильтр ──

  GameFilter readGameFilter() {
    final f = _gameFilterFile;
    if (!f.existsSync()) return const GameFilter();
    return GameFilter.parse(f.readAsStringSync());
  }

  void writeGameFilter(GameFilter filter) {
    Directory(utilsDir).createSync(recursive: true);
    _gameFilterFile.writeAsStringSync(filter.serialize());
  }

  // ── IPSet ──

  IpsetMode readIpsetMode() {
    final f = _ipsetFile;
    if (!f.existsSync()) return IpsetMode.any;
    final text = f.readAsStringSync();
    if (text.trim().isEmpty) return IpsetMode.any;
    if (text.contains(_ipsetStub)) return IpsetMode.none;
    return IpsetMode.loaded;
  }

  bool get hasIpsetBackup => _ipsetBackup.existsSync();

  /// Переключает режим так же, как service.bat. Для loaded нужна резервная копия
  /// списка; если её нет — вернёт false, список надо скачать ([writeIpsetList]).
  bool setIpsetMode(IpsetMode target) {
    final current = readIpsetMode();
    if (current == target) return true;
    if (current == IpsetMode.loaded) {
      // Сохраняем загруженный список, чтобы потом вернуть его.
      _ipsetFile.copySync(_ipsetBackup.path);
    }
    switch (target) {
      case IpsetMode.none:
        _ipsetFile.writeAsStringSync('$_ipsetStub\r\n');
      case IpsetMode.any:
        _ipsetFile.writeAsStringSync('');
      case IpsetMode.loaded:
        if (!_ipsetBackup.existsSync()) return false;
        _ipsetBackup.copySync(_ipsetFile.path);
        _ipsetBackup.deleteSync();
    }
    return true;
  }

  void writeIpsetList(String content) {
    _ipsetFile.writeAsStringSync(content);
  }

  /// Свежий список адресов: в режиме «по списку» — сразу в работу,
  /// в остальных — в резервную копию, чтобы он включился при переходе на список.
  void storeIpsetList(String content) {
    if (readIpsetMode() == IpsetMode.loaded) {
      _ipsetFile.writeAsStringSync(content);
    } else {
      _ipsetBackup.writeAsStringSync(content);
    }
  }

  // ── Пользовательские списки ──

  /// Создаёт пользовательские списки, если их нет: стратегии ссылаются на них,
  /// и без файлов winws.exe не запустится. Содержимое — как у service.bat.
  void ensureUserLists() {
    Directory(listsDir).createSync(recursive: true);
    void create(String name, String content) {
      final f = File(p.join(listsDir, name));
      if (!f.existsSync()) f.writeAsStringSync(content);
    }

    create('ipset-exclude-user.txt', '$_ipsetStub\r\n');
    create('list-general-user.txt', '# Never leave this file empty\r\ndomain.example.abc\r\n');
    create('list-exclude-user.txt', 'domain.example.abc\r\n');
  }

  /// Файлы пользователя, которые переживают обновление zapret.
  static const preservedFiles = [
    'lists/list-general-user.txt',
    'lists/list-exclude-user.txt',
    'lists/ipset-exclude-user.txt',
    'utils/game_filter.enabled',
    'utils/check_updates.enabled',
  ];
}
