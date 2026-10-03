import 'dart:io';

import 'package:path/path.dart' as p;

/// Zapret, встроенный в лаунчер: архив релиза среди файлов приложения
/// (assets/zapret, его кладёт tool/fetch_zapret.ps1). С ним лаунчер работает
/// сразу после установки — ничего не скачивая.
class ZapretBundle {
  ZapretBundle(this.dir);

  /// Файлы приложения рядом с exe: data\flutter_assets\assets\zapret.
  factory ZapretBundle.app() => ZapretBundle(
    Directory(
      p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'zapret',
      ),
    ),
  );

  final Directory dir;

  String? _version;
  bool _read = false;

  /// Версия встроенного zapret; null — в этой сборке его нет (например, собрана без
  /// tool/fetch_zapret.ps1) — тогда zapret скачивается с GitHub, как раньше.
  String? get version {
    if (_read) return _version;
    _read = true;
    try {
      final v = File(p.join(dir.path, 'version.txt')).readAsStringSync().trim();
      if (v.isNotEmpty && _zip(v).existsSync()) _version = v;
    } on FileSystemException {
      // Нет встроенного zapret.
    }
    return _version;
  }

  File _zip(String version) => File(p.join(dir.path, 'zapret-$version.zip'));

  /// Копия архива во временной папке — installFromZip удаляет папку архива после распаковки.
  Future<File> copyZip() async {
    final v = version;
    if (v == null) {
      throw const FileSystemException('В лаунчере нет встроенного zapret');
    }
    final tmp = await Directory.systemTemp.createTemp('zapret-launcher-');
    return _zip(v).copy(p.join(tmp.path, 'zapret-$v.zip'));
  }
}
