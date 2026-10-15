import '../app_info.dart';
import '../platform/win32.dart' as win;
import '../telegram/desktop.dart';
import 'feedback.dart';

/// Обращение через сообщения канала в Telegram — пока сервер поддержки недоступен.
/// Лаунчер ничего не отправляет сам: копирует текст в буфер обмена и открывает
/// сообщения канала, человек вставляет и отправляет его от своего аккаунта.
/// Подставить текст в поле ввода ссылкой на сообщения канала Telegram не даёт.
class FeedbackTelegram {
  FeedbackTelegram({
    String? channel,
    bool Function(String link, {required bool elevated})? open,
    bool Function()? hasApp,
  }) : channel = _normalize(channel ?? AppInfo.feedbackTelegram),
       _open = open ?? _shellOpen,
       _hasApp = hasApp ?? (() => const TelegramDesktop().installed);

  /// Публичное имя канала без «@»; пустое — не настроено.
  final String channel;
  final bool Function(String link, {required bool elevated}) _open;
  final bool Function() _hasApp;

  bool get configured => channel.isNotEmpty;

  /// Сообщения канала в Telegram Desktop.
  String get appLink => 'tg://resolve?domain=$channel&direct';

  /// То же в браузере — если Telegram Desktop не установлен.
  String get webLink => 'https://t.me/$channel?direct';

  /// Текст для сообщений канала: метка, обращение и версии. Сведения о системе и
  /// журнал — только если человек сам их приложил ([log] не null).
  static String message({
    required FeedbackKind kind,
    required String text,
    required Map<String, Object> details,
    String? log,
  }) {
    final tag = switch (kind) {
      FeedbackKind.bug => '#ошибка',
      FeedbackKind.idea => '#предложение',
    };
    final about = [
      '${AppInfo.name} ${details['launcher'] ?? AppInfo.version}',
      if (details['zapret'] case final v?) 'zapret $v',
      if (details['windows'] case final v?) 'Windows $v',
      if (details['strategy'] case final v?) '«$v»',
    ].join(' · ');
    return [
      '$tag\n${text.trim()}\n\n$about',
      if (log != null) ...[
        [
          'Сведения о системе:',
          for (final e in details.entries) '${e.key}: ${e.value}',
        ].join('\n'),
        if (log.trim().isNotEmpty) log,
      ],
    ].join('\n\n');
  }

  /// Открывает сообщения канала; текст обращения уже должен быть в буфере обмена.
  /// false — Windows не смогла открыть ни приложение, ни браузер.
  bool open({required bool elevated}) {
    if (!configured) {
      throw const FeedbackException(
        'Отправка обращений в этой сборке не настроена.',
      );
    }
    if (_hasApp() && _open(appLink, elevated: elevated)) return true;
    return _open(webLink, elevated: elevated);
  }

  /// Принимает «name», «@name», «t.me/name».
  static String _normalize(String raw) {
    final s = raw
        .trim()
        .replaceFirst(RegExp(r'^(https?://)?(t\.me|telegram\.me)/'), '')
        .replaceFirst(RegExp('^@'), '');
    return RegExp(r'^[A-Za-z0-9_]{4,32}$').hasMatch(s) ? s : '';
  }

  /// От имени обычного пользователя: иначе Telegram получил бы права лаунчера.
  static bool _shellOpen(String link, {required bool elevated}) =>
      win.openLink(link, elevated: elevated);
}
