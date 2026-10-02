import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';

void main(List<String> args) {
  // Только для отладки: --route=/settings открывает страницу сразу, --theme=light|dark.
  String? arg(String name) {
    if (!kDebugMode) return null;
    final prefix = '--$name=';
    for (final a in args) {
      if (a.startsWith(prefix)) return a.substring(prefix.length);
    }
    return null;
  }

  runApp(ZapretLauncherApp(
    initialRoute: arg('route'),
    themeOverride: switch (arg('theme')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    },
  ));
}
