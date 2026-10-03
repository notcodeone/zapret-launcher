import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Знак приложения: молния на скруглённом квадрате. Один рисунок — для шапки,
/// значка в трее и файла app_icon.ico.
abstract final class BrandMark {
  /// Молния в сетке 24 × 24 — как «zap» из Lucide.
  static const _bolt = [
    Offset(13, 2),
    Offset(3, 14),
    Offset(12, 14),
    Offset(11, 22),
    Offset(21, 10),
    Offset(12, 10),
  ];

  /// Рисует знак в квадрате [rect]. [dot] — точка состояния в правом нижнем углу.
  static void paint(
    Canvas canvas,
    Rect rect, {
    required Color background,
    required Color foreground,
    Color? dot,
    Color? dotRing,
    bool filledBolt = false,
  }) {
    final s = rect.width;
    final square = RRect.fromRectAndRadius(rect, Radius.circular(s * .29));
    canvas.drawRRect(square, Paint()..color = background);

    // Молния занимает около 64 % квадрата.
    final scale = s * .64 / 24;
    final origin =
        rect.topLeft + Offset((s - 24 * scale) / 2, (s - 24 * scale) / 2);
    final path = Path()
      ..addPolygon([for (final p in _bolt) origin + p * scale], true);
    final paint = Paint()
      ..color = foreground
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (filledBolt ? 1.4 : 2) * scale;
    if (filledBolt) {
      canvas.drawPath(path, paint..style = PaintingStyle.fill);
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    } else {
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    }

    if (dot != null) {
      final r = s * .2;
      final c = rect.bottomRight - Offset(r, r);
      if (dotRing != null) {
        canvas.drawCircle(c, r + s * .07, Paint()..color = dotRing);
      }
      canvas.drawCircle(c, r, Paint()..color = dot);
    }
  }

  /// Знак в пикселях RGBA (прямая альфа) — для значка в трее.
  static Future<Uint8List> renderRgba(
    int size, {
    required Color background,
    required Color foreground,
    Color? dot,
    Color? dotRing,
  }) async {
    final image = await _render(
      size,
      background: background,
      foreground: foreground,
      dot: dot,
      dotRing: dotRing,
      filledBolt: size <= 24,
    );
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// Знак в PNG — для файла значка приложения.
  static Future<Uint8List> renderPng(
    int size, {
    required Color background,
    required Color foreground,
  }) async {
    final image = await _render(
      size,
      background: background,
      foreground: foreground,
      filledBolt: size <= 24,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  static Future<ui.Image> _render(
    int size, {
    required Color background,
    required Color foreground,
    Color? dot,
    Color? dotRing,
    required bool filledBolt,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Маленький отступ, чтобы сглаживание не обрезалось по краю.
    final inset = size >= 32 ? size / 32 : 0.0;
    paint(
      canvas,
      Rect.fromLTWH(inset, inset, size - inset * 2, size - inset * 2),
      background: background,
      foreground: foreground,
      dot: dot,
      dotRing: dotRing,
      filledBolt: filledBolt,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    picture.dispose();
    return image;
  }
}

/// Кадр BMP для .ico: заголовок BITMAPINFOHEADER, пиксели BGRA снизу вверх и пустая маска.
Uint8List icoBitmapFrame(Uint8List rgba, int size) {
  final maskRow = ((size + 31) ~/ 32) * 4;
  final out = ByteData(40 + size * size * 4 + maskRow * size)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, size, Endian.little)
    ..setInt32(8, size * 2, Endian.little) // Высота вместе с маской.
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 32, Endian.little);
  var o = 40;
  for (var y = size - 1; y >= 0; y--) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      out
        ..setUint8(o++, rgba[i + 2])
        ..setUint8(o++, rgba[i + 1])
        ..setUint8(o++, rgba[i])
        ..setUint8(o++, rgba[i + 3]);
    }
  }
  return out.buffer.asUint8List();
}

/// Собирает файл .ico из кадров разных размеров: PNG (для 128 и 256) или BMP ([icoBitmapFrame]).
Uint8List buildIco(Map<int, Uint8List> framesBySize) {
  final sizes = framesBySize.keys.toList()..sort();
  final header = BytesBuilder();
  final body = BytesBuilder();
  final dir = ByteData(6)
    ..setUint16(0, 0, Endian.little)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, sizes.length, Endian.little);
  header.add(dir.buffer.asUint8List());
  var offset = 6 + 16 * sizes.length;
  for (final s in sizes) {
    final frame = framesBySize[s]!;
    final e = ByteData(16)
      ..setUint8(0, s >= 256 ? 0 : s)
      ..setUint8(1, s >= 256 ? 0 : s)
      ..setUint8(2, 0)
      ..setUint8(3, 0)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 32, Endian.little)
      ..setUint32(8, frame.length, Endian.little)
      ..setUint32(12, offset, Endian.little);
    header.add(e.buffer.asUint8List());
    body.add(frame);
    offset += frame.length;
  }
  return (BytesBuilder()
        ..add(header.toBytes())
        ..add(body.toBytes()))
      .toBytes();
}
