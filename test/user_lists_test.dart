import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/zapret/user_lists.dart';

void main() {
  group('punycode', () {
    test('эталоны', () {
      expect(punycodeEncode('bücher'), 'bcher-kva');
      expect(punycodeEncode('münchen'), 'mnchen-3ya');
      expect(punycodeEncode('президент'), 'd1abbgf6aiiy');
      expect(punycodeEncode('рф'), 'p1ai');
      expect(punycodeDecode('d1abbgf6aiiy'), 'президент');
      expect(punycodeDecode('mnchen-3ya'), 'münchen');
    });

    test('домены целиком туда и обратно', () {
      expect(domainToAscii('президент.рф'), 'xn--d1abbgf6aiiy.xn--p1ai');
      expect(domainToUnicode('xn--d1abbgf6aiiy.xn--p1ai'), 'президент.рф');
      expect(domainToUnicode('discord.com'), 'discord.com');
    });
  });

  group('normalizeDomain', () {
    test('ссылки, маски и регистр', () {
      expect(
        normalizeDomain('https://Discord.com/channels/123?x=1'),
        'discord.com',
      );
      expect(normalizeDomain('*.example.com'), 'example.com');
      expect(normalizeDomain('.example.com.'), 'example.com');
      expect(normalizeDomain('user@host.example.org:8443'), 'host.example.org');
      expect(normalizeDomain('Президент.РФ'), 'xn--d1abbgf6aiiy.xn--p1ai');
      expect(normalizeDomain('ru'), 'ru');
    });

    test('не домены', () {
      expect(normalizeDomain(''), isNull);
      expect(normalizeDomain('1.2.3.4'), isNull);
      expect(normalizeDomain('-bad.com'), isNull);
      expect(normalizeDomain('a..b'), isNull);
      expect(normalizeDomain('хм хм'), isNull);
      expect(normalizeDomain('не'), isNull);
      expect(normalizeDomain('localhost1'), isNull);
    });
  });

  test('normalizeIp', () {
    expect(normalizeIp('1.2.3.4'), '1.2.3.4');
    expect(normalizeIp('10.0.0.0/8'), '10.0.0.0/8');
    expect(normalizeIp('2001:db8::/32'), '2001:db8::/32');
    expect(normalizeIp('1.2.3.4/33'), isNull);
    expect(normalizeIp('1.2.3'), isNull);
    expect(normalizeIp('example.com'), isNull);
  });

  test('parseEntries: строки hosts, комментарии, повторы, ошибки', () {
    final r = parseEntries('''
# мой список
0.0.0.0 example.com
https://example.com/page, foo.org; bar.net
domain.example.abc
не_домен!
''', ip: false);
    expect(r.entries, ['example.com', 'foo.org', 'bar.net']);
    expect(r.invalid, ['не_домен!']);

    final ips = parseEntries('1.2.3.4 10.0.0.0/8\nexample.com', ip: true);
    expect(ips.entries, ['1.2.3.4', '10.0.0.0/8']);
    expect(ips.invalid, ['example.com']);
  });

  group('файлы', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zl-lists-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('заглушка скрыта при чтении и пишется в пустой список', () {
      File(p.join(tmp.path, 'list-general-user.txt')).writeAsStringSync(
        '# Never leave this file empty\r\ndomain.example.abc\r\n',
      );
      final l = readUserList(tmp.path, UserListKind.bypass);
      expect(l.entries, isEmpty);
      expect(l.header, ['# Never leave this file empty']);

      writeUserList(tmp.path, l.withEntries(['discord.com', 'youtube.com']));
      expect(
        File(p.join(tmp.path, 'list-general-user.txt')).readAsStringSync(),
        '# Never leave this file empty\r\ndiscord.com\r\nyoutube.com\r\n',
      );

      writeUserList(tmp.path, l.withEntries(const []));
      expect(readUserList(tmp.path, UserListKind.bypass).entries, isEmpty);
      expect(
        File(p.join(tmp.path, 'list-general-user.txt')).readAsStringSync(),
        contains('domain.example.abc'),
      );
    });

    test('файл в UTF-16 с BOM, как из Блокнота', () {
      final text = '﻿example.com\r\nпрезидент.рф\r\n';
      final bytes = [0xFF, 0xFE];
      for (final unit in text.substring(1).codeUnits) {
        bytes
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      expect(parseEntries(decodeText(bytes), ip: false).entries, [
        'example.com',
        'xn--d1abbgf6aiiy.xn--p1ai',
      ]);
      expect(decodeText([0xEF, 0xBB, 0xBF, ...utf8.encode('a.b')]), 'a.b');
    });

    test('экспорт', () {
      final text = exportText(
        const UserList(UserListKind.exclude, ['a.com', 'b.com']),
        now: DateTime(2026, 10, 2),
      );
      expect(
        text,
        '# Сайты-исключения — ZapretLauncher, 2026-10-02\r\na.com\r\nb.com\r\n',
      );
      expect(parseEntries(text, ip: false).entries, ['a.com', 'b.com']);
    });

    test('стандартный список считается без комментариев', () {
      File(p.join(tmp.path, 'list-general.txt'))
          .writeAsStringSync('# x\na.com\n\nb.com\n');
      expect(countStandardList(tmp.path), 2);
    });
  });
}
