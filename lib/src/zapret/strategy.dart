import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Стратегия обхода — один из файлов `general*.bat`.
class Strategy {
  const Strategy({required this.id, required this.file});

  /// Имя файла без расширения, например «general (ALT7)».
  /// Совпадает с тем, что service.bat пишет в реестр.
  final String id;
  final File file;

  /// Как человек узнаёт стратегию: «ALT7», «FAKE TLS AUTO»; general.bat — «Стандартная».
  String get title {
    final m = RegExp(r'\((.+)\)').firstMatch(id);
    return m != null ? m.group(1)!.trim() : 'Стандартная';
  }

  String get fileName => p.basename(file.path);

  /// Аргументы winws.exe, как они записаны в файле (с переменными %BIN% и т.п.).
  Future<List<String>> readTemplate() async {
    final bytes = await file.readAsBytes();
    return parseWinwsArgs(utf8.decode(bytes, allowMalformed: true));
  }
}

/// Находит стратегии в папке zapret. Порядок — как в service.bat:
/// числа сравниваются по значению (ALT2 раньше ALT10).
List<Strategy> findStrategies(Directory root) {
  if (!root.existsSync()) return const [];
  final list = <Strategy>[];
  for (final e in root.listSync(followLinks: false)) {
    if (e is! File) continue;
    final name = p.basename(e.path);
    final lower = name.toLowerCase();
    if (!lower.endsWith('.bat') || lower.startsWith('service')) continue;
    list.add(Strategy(id: p.basenameWithoutExtension(name), file: e));
  }
  list.sort((a, b) => naturalKey(a.fileName).compareTo(naturalKey(b.fileName)));
  return list;
}

/// Ключ сортировки: числа дополняются нулями до 8 знаков, как в service.bat.
String naturalKey(String s) =>
    s.toLowerCase().replaceAllMapped(RegExp(r'\d+'), (m) => m[0]!.padLeft(8, '0'));

/// Вытаскивает аргументы winws.exe из текста .bat.
///
/// Склеивает строки, продолженные «^», находит строку с `winws.exe"`
/// и разбивает остаток на аргументы с учётом кавычек.
/// Переменные (%BIN%, %LISTS%, …) остаются как есть — их подставляет [resolveArgs].
List<String> parseWinwsArgs(String batText) {
  final lines = const LineSplitter().convert(batText);
  final logical = <String>[];
  final buf = StringBuffer();
  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.endsWith('^')) {
      buf
        ..write(line.substring(0, line.length - 1))
        ..write(' ');
    } else {
      buf.write(line);
      logical.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) logical.add(buf.toString());

  final marker = RegExp(r'winws\.exe"', caseSensitive: false);
  for (final line in logical) {
    final m = marker.firstMatch(line);
    if (m == null) continue;
    final tokens = _tokenize(line.substring(m.end));
    if (tokens.isEmpty) break;
    return tokens;
  }
  throw const FormatException('В файле нет строки запуска winws.exe');
}

List<String> _tokenize(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  var inQuotes = false;
  var hasToken = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '"') {
      inQuotes = !inQuotes;
      hasToken = true;
    } else if (!inQuotes && (c == ' ' || c == '\t')) {
      if (hasToken) {
        out.add(cur.toString());
        cur.clear();
        hasToken = false;
      }
    } else {
      cur.write(c);
      hasToken = true;
    }
  }
  if (hasToken) out.add(cur.toString());
  return out.where((t) => t != '^').toList();
}

/// Подставляет переменные .bat в аргументы.
/// Неизвестная переменная — ошибка: лучше не запускать, чем запустить не то.
List<String> resolveArgs(List<String> template, Map<String, String> vars) {
  final upper = {for (final e in vars.entries) e.key.toUpperCase(): e.value};
  final re = RegExp(r'%([A-Za-z_][A-Za-z0-9_]*)%');
  return [
    for (final t in template)
      t.replaceAllMapped(re, (m) {
        final v = upper[m[1]!.toUpperCase()];
        if (v == null) throw FormatException('Неизвестная переменная %${m[1]}% в стратегии');
        return v;
      }),
  ];
}

/// Собирает командную строку для службы Windows: путь к exe в кавычках,
/// аргументы с пробелами — тоже в кавычках.
String buildCommandLine(String exe, List<String> args) {
  // Правила разбора командной строки Windows: обратные слэши перед кавычкой удваиваются.
  String escape(String v) {
    var s = v.replaceAll('"', r'\"');
    final trailing = RegExp(r'\\+$').firstMatch(s);
    if (trailing != null) s += trailing[0]!;
    return '"$s"';
  }

  String quote(String a) {
    // Пути и значения с пробелами — в кавычках, как в исходных .bat.
    if (a.isNotEmpty && !a.contains(RegExp(r'[\s"\\]'))) return a;
    final eq = a.indexOf('=');
    if (a.startsWith('--') && eq > 0) {
      return '${a.substring(0, eq + 1)}${escape(a.substring(eq + 1))}';
    }
    return escape(a);
  }

  return ['"$exe"', ...args.map(quote)].join(' ');
}
