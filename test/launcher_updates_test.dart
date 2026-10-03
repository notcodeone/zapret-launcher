import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zapret_launcher/src/updates/launcher_updates.dart';

Map<String, dynamic> _release({
  String tag = 'v0.2.0',
  String asset = 'ZapretLauncher-Setup-0.2.0.exe',
  String? digest,
  bool prerelease = false,
  String url = 'https://example.com/setup.exe',
  int size = 10,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/notcodeone/zapret-launcher/releases/tag/$tag',
  'prerelease': prerelease,
  'draft': false,
  'body': '- Что нового',
  'assets': [
    {
      'name': 'notes.txt',
      'browser_download_url': 'https://example.com/n.txt',
      'size': 1,
    },
    {
      'name': asset,
      'browser_download_url': url,
      'size': size,
      'digest': ?digest,
    },
  ],
};

void main() {
  group('parseRelease', () {
    test('версия из тега и установщик среди файлов', () {
      final r = LauncherUpdates.parseRelease(_release(digest: 'sha256:ABC'))!;
      expect(r.version, '0.2.0');
      expect(r.installerUrl.toString(), 'https://example.com/setup.exe');
      expect(r.sha256, 'abc');
      expect(r.notes, '- Что нового');
    });

    test('без установщика, предрелиз и странный тег — не обновление', () {
      expect(
        LauncherUpdates.parseRelease(_release(asset: 'source.zip')),
        isNull,
      );
      expect(LauncherUpdates.parseRelease(_release(prerelease: true)), isNull);
      expect(LauncherUpdates.parseRelease(_release(tag: 'nightly')), isNull);
    });
  });

  test('копия в Program Files — установленная', () {
    final pf = Platform.environment['ProgramFiles']!;
    expect(isInstalledCopy('$pf\\ZapretLauncher\\ZapretLauncher.exe'), isTrue);
    expect(
      isInstalledCopy(
        r'C:\Git\zapret-launcher\build\windows\x64\runner\Release\ZapretLauncher.exe',
      ),
      isFalse,
    );
  });

  group('download', () {
    late HttpServer server;
    final payload = List<int>.generate(50000, (i) => i % 251);

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    LauncherRelease release(String? sha) => LauncherUpdates.parseRelease(
      _release(
        url: 'http://127.0.0.1:${server.port}/setup.exe',
        size: payload.length,
        digest: sha == null ? null : 'sha256:$sha',
      ),
    )!;

    test('скачивает и сверяет хэш', () async {
      final u = LauncherUpdates();
      final progress = <double?>[];
      final f = await u.download(
        release(sha256.convert(payload).toString()),
        onProgress: progress.add,
      );
      expect(f.lengthSync(), payload.length);
      expect(progress.last, 1.0);
      await f.parent.delete(recursive: true);
      u.close();
    });

    test('чужой файл — отказ и удаление', () async {
      final u = LauncherUpdates();
      await expectLater(
        u.download(release('0' * 64)),
        throwsA(isA<LauncherUpdateException>()),
      );
      u.close();
    });
  });
}
