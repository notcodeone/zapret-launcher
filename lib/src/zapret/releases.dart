import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../app_info.dart';
import 'install.dart';

/// Официальный репозиторий. Качаем только отсюда.
const zapretRepo = 'Flowseal/zapret-discord-youtube';

class ReleaseInfo {
  const ReleaseInfo({required this.version, required this.zipUrl, this.size, required this.pageUrl});

  final String version;
  final Uri zipUrl;
  final int? size;
  final Uri pageUrl;
}

class ReleaseException implements Exception {
  const ReleaseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Сравнение версий вида 1.10.3. Положительное — a новее b.
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      v.split(RegExp(r'[^0-9]+')).where((s) => s.isNotEmpty).map(int.parse).toList();
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

class ReleaseClient {
  ReleaseClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const _headers = {
    'User-Agent': '${AppInfo.name}/${AppInfo.version}',
    'Accept': 'application/vnd.github+json',
    'Cache-Control': 'no-cache',
  };

  /// Последний релиз. Сначала GitHub API; если он не ответил (например,
  /// исчерпан лимит запросов), — version.txt из репозитория и прямая ссылка.
  Future<ReleaseInfo> latest() async {
    try {
      final r = await _http
          .get(Uri.parse('https://api.github.com/repos/$zapretRepo/releases/latest'),
              headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final json = jsonDecode(r.body) as Map<String, dynamic>;
        final tag = (json['tag_name'] as String).trim();
        final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
        final zip = assets.where((a) => (a['name'] as String).toLowerCase().endsWith('.zip'));
        if (zip.isNotEmpty) {
          return ReleaseInfo(
            version: tag,
            zipUrl: Uri.parse(zip.first['browser_download_url'] as String),
            size: zip.first['size'] as int?,
            pageUrl: Uri.parse(json['html_url'] as String),
          );
        }
      }
    } on Object {
      // Переходим к запасному способу.
    }
    final r = await _http
        .get(
          Uri.parse('https://raw.githubusercontent.com/$zapretRepo/main/.service/version.txt'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw const ReleaseException('GitHub не ответил. Проверьте интернет и попробуйте ещё раз');
    }
    final v = r.body.trim();
    return ReleaseInfo(
      version: v,
      zipUrl: Uri.parse(
          'https://github.com/$zapretRepo/releases/download/$v/zapret-discord-youtube-$v.zip'),
      pageUrl: Uri.parse('https://github.com/$zapretRepo/releases/tag/$v'),
    );
  }

  /// Скачивает архив релиза во временную папку. [onProgress] — доля от 0 до 1
  /// (null, если размер неизвестен).
  Future<File> download(ReleaseInfo release, {void Function(double? progress)? onProgress}) async {
    final req = http.Request('GET', release.zipUrl)..headers.addAll({'User-Agent': _headers['User-Agent']!});
    final resp = await _http.send(req).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw ReleaseException('Не удалось скачать zapret ${release.version}: ответ ${resp.statusCode}');
    }
    final total = resp.contentLength ?? release.size;
    final dir = await Directory.systemTemp.createTemp('zapret-launcher-');
    final file = File(p.join(dir.path, 'zapret-${release.version}.zip'));
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total != null && total > 0 ? received / total : null);
      }
    } finally {
      await sink.close();
    }
    if (total != null && received != total) {
      throw const ReleaseException('Загрузка оборвалась. Попробуйте ещё раз');
    }
    return file;
  }

  /// Список адресов IPSet из репозитория (то же, что «Update IPSet List» в service.bat).
  Future<String> fetchIpsetList() async {
    final r = await _http
        .get(
          Uri.parse(
              'https://raw.githubusercontent.com/$zapretRepo/refs/heads/main/.service/ipset-service.txt'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200 || r.body.trim().isEmpty) {
      throw const ReleaseException('Не удалось скачать список адресов');
    }
    return r.body;
  }

  /// Файл hosts из репозитория (то же, что «Update Hosts File» в service.bat).
  Future<String> fetchRepoHosts() async {
    final r = await _http
        .get(
          Uri.parse('https://raw.githubusercontent.com/$zapretRepo/refs/heads/main/.service/hosts'
              '?t=${DateTime.now().millisecondsSinceEpoch}'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200 || r.body.trim().isEmpty) {
      throw const ReleaseException('Не удалось скачать hosts из репозитория');
    }
    return r.body;
  }

  void close() => _http.close();
}

/// Где лежит прежняя версия zapret после обновления: рядом, `<папка>.previous`.
/// Рядом — значит на том же диске: переименование работает всегда.
Directory previousVersionDir(Directory target) => Directory('${target.path}.previous');

/// Распаковывает архив релиза в [target], сохраняя пользовательские файлы
/// прежней версии и режим IPSet. Прежняя версия остаётся в [previousVersionDir] —
/// к ней можно вернуться. winws.exe к этому моменту должен быть остановлен.
Future<ZapretInstall> installFromZip(File zip, Directory target, {bool keepPrevious = true}) async {
  final parent = target.parent;
  await parent.create(recursive: true);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final staging = Directory(p.join(parent.path, '.zapret-new-$stamp'));
  final old = Directory(p.join(parent.path, '.zapret-old-$stamp'));
  await _sweepLeftovers(parent);

  try {
    await _extractZip(zip, staging);
    final newRoot = _findRoot(staging);
    if (newRoot == null) {
      throw const ReleaseException('В архиве нет zapret: не найден bin\\winws.exe');
    }

    final previous = target.existsSync() ? ZapretInstall.open(target.path) : null;
    final ipsetMode = previous?.readIpsetMode();

    if (target.existsSync()) await target.rename(old.path);
    try {
      await newRoot.rename(target.path);
    } on FileSystemException {
      // Не получилось поставить новую версию — возвращаем прежнюю.
      if (old.existsSync()) await old.rename(target.path);
      rethrow;
    }

    if (old.existsSync()) {
      for (final rel in ZapretInstall.preservedFiles) {
        final src = File(p.join(old.path, rel));
        if (src.existsSync()) {
          final dst = File(p.join(target.path, rel));
          await dst.parent.create(recursive: true);
          await src.copy(dst.path);
        }
      }
    }

    final installed = ZapretInstall.open(target.path);
    if (installed == null) {
      throw const ReleaseException('После распаковки zapret не найден');
    }
    if (ipsetMode != null) installed.setIpsetMode(ipsetMode);
    installed.ensureUserLists();

    // Прежняя версия — на случай, если с новой обход перестанет работать.
    if (keepPrevious && previous != null && old.existsSync()) {
      final backup = previousVersionDir(target);
      try {
        if (backup.existsSync()) await backup.delete(recursive: true);
        await old.rename(backup.path);
      } on FileSystemException {
        // Не вышло сохранить — просто удалим ниже.
      }
    }
    return installed;
  } finally {
    for (final d in [staging, old]) {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on FileSystemException {
        // Файл мог остаться занят — уберём при следующем обновлении.
      }
    }
    try {
      await zip.parent.delete(recursive: true);
    } on FileSystemException {
      // Временная папка — не страшно.
    }
  }
}

/// Меняет местами текущую и прежнюю версии zapret: откат (и возврат обратно).
/// Пользовательские файлы и режим IPSet переносятся. winws.exe должен быть остановлен.
Future<ZapretInstall> swapWithPrevious(Directory target) async {
  final backup = previousVersionDir(target);
  if (ZapretInstall.open(backup.path) == null) {
    throw const ReleaseException('Прежней версии zapret нет');
  }
  final current = ZapretInstall.open(target.path);
  final ipsetMode = current?.readIpsetMode();
  final tmp = Directory('${target.path}.swap-${DateTime.now().millisecondsSinceEpoch}');
  await target.rename(tmp.path);
  try {
    await backup.rename(target.path);
  } on FileSystemException {
    await tmp.rename(target.path);
    rethrow;
  }
  await tmp.rename(backup.path);
  // Списки пользователя — из той версии, где с ними работали последней.
  for (final rel in ZapretInstall.preservedFiles) {
    final src = File(p.join(backup.path, rel));
    if (src.existsSync()) {
      final dst = File(p.join(target.path, rel));
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
    }
  }
  final installed = ZapretInstall.open(target.path)!;
  if (ipsetMode != null) installed.setIpsetMode(ipsetMode);
  installed.ensureUserLists();
  return installed;
}

/// Остатки прерванных обновлений (.zapret-new-…, .zapret-old-…) — их файлы могли быть заняты.
Future<void> _sweepLeftovers(Directory parent) async {
  if (!parent.existsSync()) return;
  for (final e in parent.listSync()) {
    final name = p.basename(e.path);
    if (e is Directory && (name.startsWith('.zapret-new-') || name.startsWith('.zapret-old-'))) {
      try {
        await e.delete(recursive: true);
      } on FileSystemException {
        // Всё ещё занято — в следующий раз.
      }
    }
  }
}

Future<void> _extractZip(File zip, Directory out) async {
  final input = InputFileStream(zip.path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final outPath = p.canonicalize(out.path);
    for (final entry in archive) {
      final dest = p.normalize(p.join(outPath, entry.name));
      if (!p.isWithin(outPath, dest)) {
        throw ReleaseException('Подозрительный путь в архиве: ${entry.name}');
      }
      if (entry.isDirectory) {
        await Directory(dest).create(recursive: true);
        continue;
      }
      if (!entry.isFile) continue;
      await File(dest).parent.create(recursive: true);
      await File(dest).writeAsBytes(entry.readBytes() ?? const []);
    }
  } finally {
    await input.close();
  }
}

/// Папка с bin\winws.exe — в корне архива или на уровень глубже.
Directory? _findRoot(Directory dir) {
  if (File(p.join(dir.path, 'bin', 'winws.exe')).existsSync()) return dir;
  for (final e in dir.listSync()) {
    if (e is Directory && File(p.join(e.path, 'bin', 'winws.exe')).existsSync()) return e;
  }
  return null;
}
