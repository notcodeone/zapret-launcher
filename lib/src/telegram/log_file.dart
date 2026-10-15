import 'dart:convert';
import 'dart:io';

/// Файл лога прокси — как у tg-ws-proxy: строки дописываются, а когда файл
/// дорастает до [maxBytes], прежний уходит в «.1» и запись начинается заново.
class ProxyLogFile {
  ProxyLogFile(this.path, {required this.maxBytes});

  final String path;
  final int maxBytes;

  RandomAccessFile? _file;
  int _size = 0;

  /// Писать не получается (нет доступа к папке) — дальше не пытаемся.
  bool _broken = false;

  void write(String line) {
    if (_broken) return;
    try {
      _file ??= _open();
      final bytes = utf8.encode('${_time(DateTime.now())}  $line\n');
      if (_size > 0 && _size + bytes.length > maxBytes) _rotate();
      _file!.writeFromSync(bytes);
      _size += bytes.length;
    } on FileSystemException {
      _broken = true;
    }
  }

  RandomAccessFile _open() {
    final file = File(path)..parent.createSync(recursive: true);
    final raf = file.openSync(mode: FileMode.append);
    _size = raf.lengthSync();
    return raf;
  }

  void _rotate() {
    _file?.closeSync();
    final old = File('$path.1');
    if (old.existsSync()) old.deleteSync();
    File(path).renameSync(old.path);
    _file = File(path).openSync(mode: FileMode.write);
    _size = 0;
  }

  void close() {
    try {
      _file?.closeSync();
    } on FileSystemException {
      // Закрываем при остановке — не страшно.
    }
    _file = null;
  }

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
