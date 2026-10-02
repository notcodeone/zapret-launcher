import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zapret_launcher/src/zapret/install.dart';
import 'package:zapret_launcher/src/zapret/releases.dart';

void main() {
  group('GameFilter', () {
    test('формат service.bat', () {
      final f = GameFilter.parse('mode=tcp\r\ntcp=1024-2000,3000\r\nudp=1024-65535\r\n');
      expect(f.mode, GameFilterMode.tcp);
      expect(f.tcpValue, '1024-2000,3000');
      expect(f.udpValue, '12');
      expect(GameFilter.parse(f.serialize()).tcpRange, '1024-2000,3000');
    });

    test('старый формат и неверные диапазоны', () {
      expect(GameFilter.parse('all').mode, GameFilterMode.all);
      expect(GameFilter.parse('udp').mode, GameFilterMode.udp);
      expect(GameFilter.parse('mode=all\ntcp=70000').tcpRange, GameFilter.defaultRange);
    });

    test('выключен — заглушка 12', () {
      const f = GameFilter();
      expect(f.tcpValue, '12');
      expect(f.udpValue, '12');
    });

    test('validateRange', () {
      expect(GameFilter.validateRange('1024-65535'), '1024-65535');
      expect(GameFilter.validateRange(' 80, 443 '), '80,443');
      expect(GameFilter.validateRange('0-10'), isNull);
      expect(GameFilter.validateRange('2000-1000'), isNull);
      expect(GameFilter.validateRange('abc'), isNull);
    });
  });

  group('ZapretInstall', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('zl-test-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Directory fakeZapret(String dir, {String version = '1.0.0', String userList = ''}) {
      final root = Directory(p.join(tmp.path, dir))..createSync(recursive: true);
      File(p.join(root.path, 'bin', 'winws.exe')).createSync(recursive: true);
      File(p.join(root.path, 'general.bat'))
          .writeAsStringSync('start "z" /min "%BIN%winws.exe" --wf-tcp=80\r\n');
      File(p.join(root.path, 'general (ALT2).bat'))
          .writeAsStringSync('start "z" /min "%BIN%winws.exe" --wf-tcp=443\r\n');
      File(p.join(root.path, 'service.bat'))
          .writeAsStringSync('@echo off\r\nset "LOCAL_VERSION=$version"\r\n');
      File(p.join(root.path, 'lists', 'ipset-all.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('1.2.3.0/24\r\n');
      if (userList.isNotEmpty) {
        File(p.join(root.path, 'lists', 'list-general-user.txt')).writeAsStringSync(userList);
      }
      return root;
    }

    test('открывает папку, читает версию и стратегии', () {
      final z = ZapretInstall.open(fakeZapret('z').path)!;
      expect(z.version, '1.0.0');
      expect(z.strategies.map((s) => s.title), ['ALT2', 'Стандартная']);
      expect(z.strategyById('GENERAL (alt2)')?.title, 'ALT2');
      expect(ZapretInstall.open(tmp.path), isNull);
    });

    test('IPSet: loaded → none → any → loaded', () {
      final z = ZapretInstall.open(fakeZapret('z').path)!;
      expect(z.readIpsetMode(), IpsetMode.loaded);
      expect(z.setIpsetMode(IpsetMode.none), isTrue);
      expect(z.readIpsetMode(), IpsetMode.none);
      expect(z.setIpsetMode(IpsetMode.any), isTrue);
      expect(z.readIpsetMode(), IpsetMode.any);
      expect(z.setIpsetMode(IpsetMode.loaded), isTrue);
      expect(z.readIpsetMode(), IpsetMode.loaded);
      expect(File(p.join(z.listsDir, 'ipset-all.txt')).readAsStringSync(), contains('1.2.3.0/24'));
    });

    test('пользовательские списки создаются и не перезаписываются', () {
      final z = ZapretInstall.open(fakeZapret('z', userList: 'my.site\r\n').path)!;
      z.ensureUserLists();
      expect(File(p.join(z.listsDir, 'list-general-user.txt')).readAsStringSync(), 'my.site\r\n');
      expect(File(p.join(z.listsDir, 'list-exclude-user.txt')).existsSync(), isTrue);
    });

    test('обновление из архива сохраняет списки пользователя и режим IPSet', () async {
      final target = fakeZapret('target', version: '1.0.0', userList: 'keep.me\r\n');
      ZapretInstall.open(target.path)!.setIpsetMode(IpsetMode.any);

      // Новый релиз: папка внутри архива, как в некоторых сборках.
      final src = fakeZapret('release/zapret-2.0.0', version: '2.0.0');
      final zipDir = Directory(p.join(tmp.path, 'dl'))..createSync();
      final zipPath = p.join(zipDir.path, 'z.zip');
      final encoder = ZipFileEncoder()..create(zipPath);
      await encoder.addDirectory(src);
      await encoder.close();

      final installed = await installFromZip(File(zipPath), target);
      expect(installed.version, '2.0.0');
      expect(File(p.join(target.path, 'lists', 'list-general-user.txt')).readAsStringSync(), 'keep.me\r\n');
      expect(installed.readIpsetMode(), IpsetMode.any);
      expect(tmp.listSync().whereType<Directory>().any((d) => p.basename(d.path).startsWith('.zapret-')),
          isFalse);

      // Прежняя версия сохранена рядом.
      final previous = previousVersionDir(target);
      expect(ZapretInstall.readVersion(previous), '1.0.0');

      // Откат: версии меняются местами, списки и режим IPSet — с собой.
      File(p.join(target.path, 'lists', 'list-general-user.txt')).writeAsStringSync('new.list\r\n');
      final back = await swapWithPrevious(target);
      expect(back.version, '1.0.0');
      expect(ZapretInstall.readVersion(previous), '2.0.0');
      expect(File(p.join(target.path, 'lists', 'list-general-user.txt')).readAsStringSync(), 'new.list\r\n');
      expect(back.readIpsetMode(), IpsetMode.any);

      // И обратно.
      expect((await swapWithPrevious(target)).version, '2.0.0');
    });

    test('без прежней версии откат невозможен', () async {
      final target = fakeZapret('solo');
      expect(swapWithPrevious(target), throwsA(isA<ReleaseException>()));
    });
  });

  test('compareVersions', () {
    expect(compareVersions('1.10.3', '1.9.9'), greaterThan(0));
    expect(compareVersions('1.10.3', '1.10.3'), 0);
    expect(compareVersions('1.10', '1.10.1'), lessThan(0));
  });
}
