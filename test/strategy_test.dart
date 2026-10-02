import 'package:flutter_test/flutter_test.dart';
import 'package:zapret_launcher/src/zapret/strategy.dart';

/// Укороченная копия формата general.bat из zapret-discord-youtube.
const _bat = r'''
@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"
call service.bat status_zapret
call service.bat load_game_filter
echo:

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
cd /d %BIN%

start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=80,443,%GameFilterTCP% --wf-udp=443,%GameFilterUDP% ^
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake --dpi-desync-repeats=6 --new ^
--filter-tcp=443 --hostlist-domains=discord.media --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-tls=0x00000000
''';

void main() {
  group('parseWinwsArgs', () {
    test('склеивает строки с ^ и снимает кавычки', () {
      final args = parseWinwsArgs(_bat);
      expect(args.first, '--wf-tcp=80,443,%GameFilterTCP%');
      expect(args, contains('--hostlist=%LISTS%list-general.txt'));
      expect(args, contains('--new'));
      expect(args, isNot(contains('^')));
      expect(args.last, '--dpi-desync-fake-tls=0x00000000');
      expect(args.where((a) => a == '--new').length, 1);
    });

    test('без строки winws.exe — ошибка', () {
      expect(() => parseWinwsArgs('@echo off\r\necho hi\r\n'), throwsFormatException);
    });

    test('понимает CRLF', () {
      final args = parseWinwsArgs(_bat.replaceAll('\n', '\r\n'));
      expect(args.first, '--wf-tcp=80,443,%GameFilterTCP%');
    });
  });

  group('resolveArgs', () {
    test('подставляет переменные без учёта регистра', () {
      final out = resolveArgs(
        ['--hostlist=%LISTS%list.txt', '--wf-tcp=80,%gamefiltertcp%'],
        {'LISTS': r'C:\z\lists\', 'GameFilterTCP': '12'},
      );
      expect(out, [r'--hostlist=C:\z\lists\list.txt', '--wf-tcp=80,12']);
    });

    test('неизвестная переменная — ошибка', () {
      expect(() => resolveArgs(['%NOPE%'], {}), throwsFormatException);
    });
  });

  group('buildCommandLine', () {
    test('пути в кавычках, простые значения — как есть', () {
      final cmd = buildCommandLine(r'C:\z\bin\winws.exe', [
        '--wf-tcp=80,443',
        r'--hostlist=C:\z\lists\list general.txt',
        '--new',
      ]);
      expect(cmd, r'"C:\z\bin\winws.exe" --wf-tcp=80,443 --hostlist="C:\z\lists\list general.txt" --new');
    });

    test('удваивает обратный слэш перед закрывающей кавычкой', () {
      expect(buildCommandLine('a.exe', [r'--dir=C:\z\']), r'"a.exe" --dir="C:\z\\"');
    });
  });

  test('естественная сортировка: ALT2 раньше ALT10', () {
    final names = ['general (ALT10).bat', 'general (ALT2).bat', 'general.bat', 'general (ALT).bat'];
    names.sort((a, b) => naturalKey(a).compareTo(naturalKey(b)));
    expect(names, ['general (ALT).bat', 'general (ALT2).bat', 'general (ALT10).bat', 'general.bat']);
  });
}
