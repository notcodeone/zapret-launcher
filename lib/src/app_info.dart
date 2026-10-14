abstract final class AppInfo {
  static const name = 'ZapretLauncher';
  static const version = '1.0.1';

  /// Сервер обращений из «Настройки» → «Обратная связь» (проект support-bot).
  /// Адрес — при сборке: `--dart-define=FEEDBACK_SERVER=https://admin.notcode.one`.
  /// Пока домен недоступен, по умолчанию пусто — обращения идут через Telegram.
  static const feedbackServer = String.fromEnvironment('FEEDBACK_SERVER');

  /// Канал в Telegram, в сообщения которого идут обращения, когда сервер не задан
  /// или не ответил. Другой канал — при сборке: `--dart-define=FEEDBACK_TELEGRAM=…`.
  static const feedbackTelegram = String.fromEnvironment(
    'FEEDBACK_TELEGRAM',
    defaultValue: 'notcodeone',
  );
}
