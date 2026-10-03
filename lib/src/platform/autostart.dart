import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Задача Планировщика есть: какой файл она запускает.
class AutostartState {
  const AutostartState({required this.registered, this.command});

  static const off = AutostartState(registered: false);

  final bool registered;

  /// Путь к exe из задачи; null — не удалось прочитать (нет прав).
  final String? command;

  /// Задача запускает этот самый лаунчер.
  bool matches(String exe) =>
      command != null && p.equals(p.normalize(command!), p.normalize(exe));
}

class AutostartException implements Exception {
  const AutostartException(this.message, [this.detail]);

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message: $detail';
}

/// Автозапуск лаунчера при входе в Windows — задача Планировщика заданий
/// с наивысшими правами: так лаунчер стартует без запроса UAC.
/// Создать или удалить такую задачу можно только с правами администратора.
class LauncherAutostart {
  const LauncherAutostart();

  static const taskName = 'ZapretLauncher';

  /// Аргументы запуска: сразу в трей.
  static const arguments = '--minimized';

  String get _taskFile => p.join(
    Platform.environment['SystemRoot'] ?? r'C:\Windows',
    'System32',
    'Tasks',
    taskName,
  );

  Future<AutostartState> query() async {
    final r = await Process.run('schtasks', ['/Query', '/TN', taskName]);
    if (r.exitCode != 0) return AutostartState.off;
    // Файл задачи — XML в UTF-16; читается только с правами администратора.
    try {
      final xml = _decodeUtf16(File(_taskFile).readAsBytesSync());
      final m = RegExp(r'<Command>([^<]*)</Command>').firstMatch(xml);
      final command = m == null
          ? null
          : _unescape(m[1]!).replaceAll('"', '').trim();
      return AutostartState(registered: true, command: command);
    } on FileSystemException {
      return const AutostartState(registered: true);
    }
  }

  /// Создаёт или заменяет задачу для [exe].
  Future<void> enable(String exe) async {
    final dir = await Directory.systemTemp.createTemp('zapret-launcher-task-');
    try {
      final xmlFile = File(p.join(dir.path, 'task.xml'));
      // Планировщик ждёт UTF-16 с BOM — как в его собственном экспорте.
      final xml = taskXml(exe: exe, user: currentUser());
      xmlFile.writeAsBytesSync([
        0xFF,
        0xFE,
        for (final u in xml.codeUnits) ...[u & 0xFF, u >> 8],
      ]);
      final r = await Process.run('schtasks', [
        '/Create',
        '/TN',
        taskName,
        '/XML',
        xmlFile.path,
        '/F',
      ]);
      if (r.exitCode != 0) {
        throw AutostartException(
          'Не удалось создать задачу в Планировщике',
          '${r.stderr}'.trim().ifEmpty('код ${r.exitCode}'),
        );
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<void> disable() async {
    final r = await Process.run('schtasks', ['/Delete', '/TN', taskName, '/F']);
    if (r.exitCode != 0 && (await query()).registered) {
      throw AutostartException(
        'Не удалось удалить задачу из Планировщика',
        '${r.stderr}'.trim().ifEmpty('код ${r.exitCode}'),
      );
    }
  }

  /// Пользователь, для которого задача: тот, кто вошёл в Windows.
  static String currentUser() {
    final env = Platform.environment;
    final user = env['USERNAME'] ?? '';
    final domain = env['USERDOMAIN'];
    return domain == null || domain.isEmpty ? user : '$domain\\$user';
  }

  /// Задача: при входе пользователя, с наивысшими правами, без ограничения по времени
  /// (по умолчанию Планировщик останавливает задачи через 72 часа) и при работе от батареи.
  static String taskXml({required String exe, required String user}) {
    final e = const HtmlEscape(HtmlEscapeMode.element);
    return '''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>ZapretLauncher: start minimized to tray at logon.</Description>
    <URI>\\$taskName</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>${e.convert(user)}</UserId>
      <Delay>PT5S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>${e.convert(user)}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"${e.convert(exe)}"</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>${e.convert(p.dirname(exe))}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
''';
  }

  static String _decodeUtf16(List<int> bytes) {
    var start = 0;
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) start = 2;
    if (start == 0) return utf8.decode(bytes, allowMalformed: true);
    return String.fromCharCodes([
      for (var i = start; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ]);
  }

  static String _unescape(String s) => s
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
