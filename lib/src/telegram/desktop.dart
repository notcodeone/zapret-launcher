import 'dart:io';

import '../platform/win32.dart' as win;

/// Telegram Desktop на этом компьютере. Ссылка tg:// запускает закрытый Telegram,
/// поэтому перед ней лаунчер спрашивает, а не запускает его сам.
class TelegramDesktop {
  const TelegramDesktop();

  /// Установлен: при установке Telegram Desktop регистрирует протокол tg://.
  bool get installed {
    try {
      return Process.runSync('reg', [
            'query',
            r'HKEY_CLASSES_ROOT\tg\shell\open\command',
          ]).exitCode ==
          0;
    } on Object {
      return false;
    }
  }

  /// Запущен: ссылка попадёт в открытое окно, ничего не запуская.
  bool get running => win.findProcesses('Telegram.exe').isNotEmpty;

  /// Открывает ссылку от имени обычного пользователя. false — Windows не открыла.
  bool open(String link, {required bool elevated}) =>
      win.openLink(link, elevated: elevated);
}
