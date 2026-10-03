import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// Свои списки zapret — их service.bat создаёт и не трогает при обновлении.
enum UserListKind {
  /// Сайты, которые обходить вдобавок к стандартному списку.
  bypass('list-general-user.txt', 'domain.example.abc', ip: false),

  /// Сайты, которые не трогать.
  exclude('list-exclude-user.txt', 'domain.example.abc', ip: false),

  /// Адреса и подсети, которые не трогать в режиме IPSet.
  ipExclude('ipset-exclude-user.txt', '203.0.113.113/32', ip: true);

  const UserListKind(this.fileName, this.placeholder, {required this.ip});

  final String fileName;

  /// Заглушка, без которой файл нельзя оставлять пустым.
  final String placeholder;
  final bool ip;
}

class UserList {
  const UserList(this.kind, this.entries, {this.header = const []});

  final UserListKind kind;

  /// Записи в порядке файла: домены в punycode или IP-адреса с маской.
  final List<String> entries;

  /// Строки-комментарии в начале файла — сохраняются как есть.
  final List<String> header;

  UserList withEntries(List<String> entries) =>
      UserList(kind, entries, header: header);
}

UserList readUserList(String listsDir, UserListKind kind) {
  final f = File(p.join(listsDir, kind.fileName));
  if (!f.existsSync()) return UserList(kind, const []);
  final header = <String>[];
  final entries = <String>[];
  final seen = <String>{};
  for (final raw in decodeText(f.readAsBytesSync()).split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      if (entries.isEmpty) header.add(line);
      continue;
    }
    if (line.toLowerCase() == kind.placeholder) continue;
    if (seen.add(line.toLowerCase())) entries.add(line);
  }
  return UserList(kind, entries, header: header);
}

void writeUserList(String listsDir, UserList list) {
  Directory(listsDir).createSync(recursive: true);
  // Пустым файл оставлять нельзя — тогда winws.exe ведёт себя иначе. Пишем заглушку, как service.bat.
  final body = list.entries.isEmpty ? [list.kind.placeholder] : list.entries;
  final f = File(p.join(listsDir, list.kind.fileName));
  final tmp = File('${f.path}.tmp');
  tmp.writeAsStringSync('${[...list.header, ...body].join('\r\n')}\r\n');
  tmp.renameSync(f.path);
}

/// Сколько записей в стандартном списке zapret (list-general.txt).
int countStandardList(String listsDir) {
  final f = File(p.join(listsDir, 'list-general.txt'));
  if (!f.existsSync()) return 0;
  var n = 0;
  for (final line in decodeText(f.readAsBytesSync()).split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isNotEmpty && !t.startsWith('#')) n++;
  }
  return n;
}

/// Текст файла: UTF-8 (с BOM или без) или UTF-16 LE с BOM — так сохраняет Блокнот.
String decodeText(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final units = <int>[
      for (var i = 2; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ];
    return String.fromCharCodes(units);
  }
  final start =
      bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF
      ? 3
      : 0;
  return utf8.decode(bytes.sublist(start), allowMalformed: true);
}

/// Файл для экспорта: комментарий-заголовок и записи по одной на строку.
String exportText(UserList list, {DateTime? now}) {
  final d = now ?? DateTime.now();
  final date =
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final title = switch (list.kind) {
    UserListKind.bypass => 'Сайты для обхода',
    UserListKind.exclude => 'Сайты-исключения',
    UserListKind.ipExclude => 'IP-исключения',
  };
  return '# $title — ZapretLauncher, $date\r\n${list.entries.join('\r\n')}\r\n';
}

// ── Разбор ввода ────────────────────────────────────────────────────────────

class ParsedEntries {
  const ParsedEntries(this.entries, this.invalid);

  /// Нормализованные записи без повторов, в порядке ввода.
  final List<String> entries;

  /// Что не удалось понять — показываем человеку.
  final List<String> invalid;
}

/// Разбирает ввод или файл: по строкам, через пробелы, запятые и точки с запятой.
/// Понимает ссылки, `*.example.com`, строки hosts (`0.0.0.0 example.com`) и комментарии.
ParsedEntries parseEntries(String text, {required bool ip}) {
  final entries = <String>[];
  final seen = <String>{};
  final invalid = <String>[];
  for (var line in text.split(RegExp(r'\r?\n'))) {
    final hash = line.indexOf('#');
    if (hash >= 0) line = line.substring(0, hash);
    for (final token in line.split(RegExp(r'[\s,;]+'))) {
      if (token.isEmpty) continue;
      final value = ip ? normalizeIp(token) : normalizeDomain(token);
      if (value == null) {
        // В списке доменов адреса — это строки hosts, а не ошибка.
        if (!ip && normalizeIp(token) != null) continue;
        invalid.add(token);
        continue;
      }
      if (value == UserListKind.bypass.placeholder ||
          value == UserListKind.ipExclude.placeholder) {
        continue;
      }
      if (seen.add(value)) entries.add(value);
    }
  }
  return ParsedEntries(entries, invalid);
}

final _label = RegExp(r'^(?!-)[a-z0-9_-]{1,63}(?<!-)$');

/// Домен в том виде, в каком его видит zapret: строчными буквами, русские — в punycode.
/// null — не похоже на домен.
String? normalizeDomain(String raw) {
  var s = raw.trim().toLowerCase();
  s = s.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
  s = s.split(RegExp(r'[/?#]')).first;
  final at = s.lastIndexOf('@');
  if (at >= 0) s = s.substring(at + 1);
  s = s.replaceFirst(RegExp(r':\d+$'), '');
  s = s.replaceFirst(RegExp(r'^\*?\.'), '');
  s = s.replaceFirst(RegExp(r'\.+$'), '');
  if (s.isEmpty || InternetAddress.tryParse(s) != null) return null;
  // Без точки — только зона целиком, латиницей: «ru», «com». Одно русское слово — не домен.
  if (!s.contains('.') &&
      !RegExp(r'^([a-z]{2,63}|xn--[a-z0-9-]+)$').hasMatch(s)) {
    return null;
  }
  final ascii = domainToAscii(s);
  if (ascii == null || ascii.length > 253) return null;
  if (!ascii.split('.').every(_label.hasMatch)) return null;
  return ascii;
}

/// IPv4 или IPv6, можно с маской подсети: `1.2.3.0/24`. null — не похоже на адрес.
String? normalizeIp(String raw) {
  final s = raw.trim();
  final parts = s.split('/');
  if (s.isEmpty || parts.length > 2) return null;
  final addr = InternetAddress.tryParse(parts[0]);
  if (addr == null) return null;
  if (parts.length == 1) return addr.address;
  final prefix = int.tryParse(parts[1]);
  final max = addr.type == InternetAddressType.IPv4 ? 32 : 128;
  if (prefix == null || prefix < 0 || prefix > max) return null;
  return '${addr.address}/$prefix';
}

// ── Punycode (RFC 3492) ─────────────────────────────────────────────────────

const _base = 36, _tMin = 1, _tMax = 26, _skew = 38, _damp = 700;
const _initialBias = 72, _initialN = 128;

int _adapt(int delta, int numPoints, bool first) {
  var d = first ? delta ~/ _damp : delta ~/ 2;
  d += d ~/ numPoints;
  var k = 0;
  while (d > ((_base - _tMin) * _tMax) ~/ 2) {
    d ~/= _base - _tMin;
    k += _base;
  }
  return k + (_base - _tMin + 1) * d ~/ (d + _skew);
}

int _threshold(int k, int bias) =>
    k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);

String punycodeEncode(String input) {
  final cps = input.runes.toList();
  final out = StringBuffer();
  for (final c in cps) {
    if (c < 0x80) out.writeCharCode(c);
  }
  final b = out.length;
  var h = b;
  if (b > 0) out.write('-');
  var n = _initialN, delta = 0, bias = _initialBias;
  while (h < cps.length) {
    final m = cps.where((c) => c >= n).reduce(math.min);
    delta += (m - n) * (h + 1);
    n = m;
    for (final c in cps) {
      if (c < n) delta++;
      if (c != n) continue;
      var q = delta;
      for (var k = _base; ; k += _base) {
        final t = _threshold(k, bias);
        if (q < t) break;
        out.writeCharCode(_digit(t + (q - t) % (_base - t)));
        q = (q - t) ~/ (_base - t);
      }
      out.writeCharCode(_digit(q));
      bias = _adapt(delta, h + 1, h == b);
      delta = 0;
      h++;
    }
    delta++;
    n++;
  }
  return out.toString();
}

String punycodeDecode(String input) {
  final d = input.lastIndexOf('-');
  final out = <int>[if (d > 0) ...input.substring(0, d).codeUnits];
  var n = _initialN, i = 0, bias = _initialBias;
  var pos = d > 0 ? d + 1 : 0;
  while (pos < input.length) {
    final oldI = i;
    var w = 1;
    for (var k = _base; ; k += _base) {
      if (pos >= input.length) throw const FormatException('Обрыв punycode');
      final digit = _value(input.codeUnitAt(pos++));
      i += digit * w;
      final t = _threshold(k, bias);
      if (digit < t) break;
      w *= _base - t;
    }
    bias = _adapt(i - oldI, out.length + 1, oldI == 0);
    n += i ~/ (out.length + 1);
    i %= out.length + 1;
    out.insert(i, n);
    i++;
  }
  return String.fromCharCodes(out);
}

int _digit(int d) => d < 26 ? 97 + d : 22 + d; // a–z, затем 0–9

int _value(int c) {
  if (c >= 48 && c <= 57) return c - 22;
  if (c >= 65 && c <= 90) return c - 65;
  if (c >= 97 && c <= 122) return c - 97;
  throw const FormatException('Недопустимый символ punycode');
}

/// Домен в ASCII: русские части — в xn--…; null — не получилось.
String? domainToAscii(String domain) {
  try {
    return domain
        .split('.')
        .map((label) {
          if (label.runes.every((c) => c < 0x80)) return label;
          return 'xn--${punycodeEncode(label)}';
        })
        .join('.');
  } on Object {
    return null;
  }
}

/// Домен для человека: xn--… обратно в буквы.
String domainToUnicode(String domain) {
  return domain
      .split('.')
      .map((label) {
        if (!label.startsWith('xn--')) return label;
        try {
          return punycodeDecode(label.substring(4));
        } on FormatException {
          return label;
        }
      })
      .join('.');
}
