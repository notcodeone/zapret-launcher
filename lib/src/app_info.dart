abstract final class AppInfo {
  static const name = 'ZapretLauncher';
  static const version = '0.5.0';

  /// Сервер обращений из «Настройки» → «Обратная связь» (проект support-bot).
  /// Другой адрес — при сборке: `--dart-define=FEEDBACK_SERVER=https://…`.
  static const feedbackServer = String.fromEnvironment(
    'FEEDBACK_SERVER',
    defaultValue: 'https://admin.notcode.one',
  );
}
