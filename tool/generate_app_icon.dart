// Собирает windows/runner/resources/app_icon.ico из знака приложения (BrandMark).
// Запуск: flutter test tool/generate_app_icon.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapret_launcher/src/ui/brand.dart';
import 'package:zapret_launcher/src/ui/theme.dart';

void main() {
  test('app_icon.ico', () async {
    final frames = <int, Uint8List>{};
    for (final size in const [16, 20, 24, 32, 40, 48, 64, 128, 256]) {
      const p = Palette.light;
      // Маленькие размеры — BMP (их понимает всё), большие — PNG, как принято в .ico.
      frames[size] = size <= 64
          ? icoBitmapFrame(
              await BrandMark.renderRgba(size, background: p.primary, foreground: p.onPrimary),
              size)
          : await BrandMark.renderPng(size, background: p.primary, foreground: p.onPrimary);
    }
    final out = File('windows/runner/resources/app_icon.ico');
    await out.writeAsBytes(buildIco(frames));
    expect(out.lengthSync(), greaterThan(1000));
  });
}
