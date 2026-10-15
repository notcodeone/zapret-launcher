abstract final class AppInfo {
  static const name = 'ZapretLauncher';
  static const version = '1.2.0';

  /// Сервер обращений из «Настройки» → «Обратная связь» (проект support-bot).
  /// Не ответил — обращение уходит в сообщения канала ([feedbackTelegram]).
  /// Другой адрес — при сборке: `--dart-define=FEEDBACK_SERVER=https://…`.
  static const feedbackServer = String.fromEnvironment(
    'FEEDBACK_SERVER',
    defaultValue: 'https://admin.notcode.one',
  );

  /// Канал в Telegram, в сообщения которого идут обращения, когда сервер не задан
  /// или недоступен. Другой канал — при сборке: `--dart-define=FEEDBACK_TELEGRAM=…`.
  static const feedbackTelegram = String.fromEnvironment(
    'FEEDBACK_TELEGRAM',
    defaultValue: 'notcodeone',
  );
}
