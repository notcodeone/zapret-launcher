import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../app_info.dart';

/// Репозиторий лаунчера: отсюда приходят его обновления.
const launcherRepo = 'notcodeone/zapret-launcher';

/// Установщик в релизе: ZapretLauncher-Setup-0.2.0.exe.
final _installerName = RegExp(
  r'^ZapretLauncher-Setup-.*\.exe$',
  caseSensitive: false,
);

class LauncherRelease {
  const LauncherRelease({
    required this.version,
    required this.installerUrl,
    required this.pageUrl,
    this.size,
    this.sha256,
    this.notes,
  });

  final String version;
  final Uri installerUrl;
  final Uri pageUrl;
  final int? size;

  /// Хэш установщика от GitHub; null — GitHub его не дал.
  final String? sha256;

  /// Что нового — текст релиза.
  final String? notes;
}

class LauncherUpdateException implements Exception {
  const LauncherUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LauncherUpdates {
  LauncherUpdates({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const _headers = {
    'User-Agent': '${AppInfo.name}/${AppInfo.version}',
    'Accept': 'application/vnd.github+json',
  };

  /// Последний релиз лаунчера; null — релизов ещё нет или в нём нет установщика.
  Future<LauncherRelease?> latest() async {
    final r = await _http
        .get(
          Uri.parse(
            'https://api.github.com/repos/$launcherRepo/releases/latest',
          ),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) {
      throw LauncherUpdateException(
        'GitHub ответил ${r.statusCode}. Попробуйте позже',
      );
    }
    return parseRelease(jsonDecode(r.body) as Map<String, dynamic>);
  }

  static LauncherRelease? parseRelease(Map<String, dynamic> json) {
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = (json['tag_name'] as String? ?? '').trim();
    final version = tag.startsWith('v') || tag.startsWith('V')
        ? tag.substring(1)
        : tag;
    if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) return null;
    final assets = (json['assets'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final installer = assets
        .where((a) => _installerName.hasMatch(a['name'] as String? ?? ''))
        .firstOrNull;
    if (installer == null) return null;
    final digest = installer['digest'] as String?;
    return LauncherRelease(
      version: version,
      installerUrl: Uri.parse(installer['browser_download_url'] as String),
      pageUrl: Uri.parse(
        json['html_url'] as String? ??
            'https://github.com/$launcherRepo/releases',
      ),
      size: installer['size'] as int?,
      sha256: digest != null && digest.startsWith('sha256:')
          ? digest.substring(7).toLowerCase()
          : null,
      notes: json['body'] as String?,
    );
  }

  /// Скачивает установщик и сверяет размер и хэш. [onProgress] — доля от 0 до 1.
  Future<File> download(
    LauncherRelease release, {
    void Function(double? progress)? onProgress,
  }) async {
    final req = http.Request('GET', release.installerUrl)
      ..headers['User-Agent'] = _headers['User-Agent']!;
    final resp = await _http.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw LauncherUpdateException(
        'Не удалось скачать ZapretLauncher ${release.version}: ответ ${resp.statusCode}',
      );
    }
    final total = resp.contentLength ?? release.size;
    final dir = await Directory.systemTemp.createTemp(
      'zapret-launcher-update-',
    );
    final file = File(
      p.join(dir.path, 'ZapretLauncher-Setup-${release.version}.exe'),
    );
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp.stream.timeout(
        const Duration(seconds: 30),
      )) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total != null && total > 0 ? received / total : null);
      }
    } finally {
      await sink.close();
    }
    if (total != null && received != total) {
      throw const LauncherUpdateException(
        'Загрузка оборвалась. Попробуйте ещё раз',
      );
    }
    final expected = release.sha256;
    if (expected != null &&
        (await sha256.bind(file.openRead()).first).toString() != expected) {
      await dir.delete(recursive: true);
      throw const LauncherUpdateException(
        'Установщик не совпал с опубликованным — скачивание отменено. Попробуйте ещё раз',
      );
    }
    return file;
  }

  void close() => _http.close();
}

/// Лаунчер установлен установщиком — тогда обновление ставится тихо поверх.
/// Иначе (сборка из исходников) установщик откроется с мастером: человек увидит, куда он ставит.
bool isInstalledCopy(String exe) {
  final pf = [
    Platform.environment['ProgramFiles'],
    Platform.environment['ProgramW6432'],
  ].nonNulls;
  final lower = exe.toLowerCase();
  return pf.any((dir) => lower.startsWith('${dir.toLowerCase()}\\'));
}
