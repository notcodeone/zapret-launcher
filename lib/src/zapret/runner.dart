import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/win32.dart' as win;
import 'install.dart';
import 'strategy.dart';

/// Имя службы и значение в реестре — как у service.bat, чтобы лаунчер
/// и оригинальные скрипты видели одно и то же.
const serviceName = 'zapret';
const _serviceRegKey = r'System\CurrentControlSet\Services\zapret';
const _serviceRegValue = 'zapret-discord-youtube';

class ZapretException implements Exception {
  const ZapretException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message: $detail';
}

class WinwsProcess {
  const WinwsProcess(this.pid, this.path);

  final int pid;
  final String? path;
}

/// Что сейчас запущено.
class RuntimeStatus {
  const RuntimeStatus({
    required this.processes,
    required this.service,
    required this.serviceStrategy,
  });

  final List<WinwsProcess> processes;

  /// Служба zapret, если установлена.
  final win.ServiceInfo? service;

  /// Стратегия, из которой поставлена служба (имя файла без .bat).
  final String? serviceStrategy;

  bool get running => processes.isNotEmpty;
  bool get serviceInstalled => service != null;
  bool get serviceRunning => service?.running ?? false;

  /// Папка zapret, из которой запущен winws.exe или поставлена служба.
  String? get activeRoot {
    for (final proc in processes) {
      if (proc.path != null) return p.dirname(p.dirname(proc.path!));
    }
    final bin = serviceBinary;
    return bin == null ? null : p.dirname(p.dirname(bin));
  }

  /// Путь к winws.exe из командной строки службы.
  String? get serviceBinary {
    final cmd = service?.binaryPath;
    if (cmd == null) return null;
    final m = RegExp(r'^\s*"([^"]+)"|^\s*(\S+)').firstMatch(cmd);
    return m?.group(1) ?? m?.group(2);
  }
}

class ZapretRunner {
  /// Когда лаунчер последний раз запустил winws.exe — после этого он перечитал списки.
  DateTime? lastStart;

  RuntimeStatus status() {
    final procs = [
      for (final e in win.findProcesses('winws.exe'))
        WinwsProcess(e.pid, win.processImagePath(e.pid)),
    ];
    final svc = win.queryService(serviceName);
    return RuntimeStatus(
      processes: procs,
      service: svc,
      serviceStrategy: svc == null
          ? null
          : win.readRegistryString(_serviceRegKey, _serviceRegValue),
    );
  }

  /// Запуск winws.exe отдельным процессом. Работает до выключения
  /// или перезагрузки компьютера, даже если лаунчер закрыт.
  Future<void> startProcess(
    ZapretInstall install,
    Strategy strategy,
    GameFilter filter,
  ) async {
    final args = await _prepare(install, strategy, filter);
    if (win.findProcesses('winws.exe').isNotEmpty) {
      throw const ZapretException('winws.exe уже запущен');
    }
    try {
      await Process.start(
        install.winws.path,
        args,
        workingDirectory: install.binDir,
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (e) {
      throw ZapretException(
        'Не удалось запустить winws.exe',
        detail: e.message,
      );
    }
    await _expectRunning();
    lastStart = DateTime.now();
  }

  /// Служба Windows с автозапуском — как «Install Service» в service.bat.
  /// [start] false — только поставить: включится вместе с Windows или кнопкой.
  Future<void> installService(
    ZapretInstall install,
    Strategy strategy,
    GameFilter filter, {
    bool start = true,
  }) async {
    final args = await _prepare(install, strategy, filter);
    await removeService(cleanupDriver: false);
    try {
      win.createService(
        name: serviceName,
        displayName: 'zapret',
        binaryPath: buildCommandLine(install.winws.path, args),
        description: 'Zapret DPI bypass software',
        // Сторож без лаунчера: упавший winws.exe Windows запустит сама.
        restartOnFailure: true,
      );
      win.writeRegistryString(_serviceRegKey, _serviceRegValue, strategy.id);
      if (start) win.startService(serviceName);
    } on win.Win32Exception catch (e) {
      throw ZapretException(e.operation, detail: 'код ${e.code}');
    }
    if (!start) return;
    await _expectRunning();
    lastStart = DateTime.now();
  }

  /// Запускает уже установленную службу.
  Future<void> startService() async {
    try {
      win.startService(serviceName);
    } on win.Win32Exception catch (e) {
      throw ZapretException(e.operation, detail: 'код ${e.code}');
    }
    await _expectRunning();
    lastStart = DateTime.now();
  }

  /// Останавливает службу (если есть) и все процессы winws.exe.
  Future<void> stopAll() async {
    final svc = win.queryService(serviceName);
    if (svc != null && svc.state != win.ServiceState.stopped) {
      try {
        win.stopService(serviceName);
      } on win.Win32Exception catch (e) {
        throw ZapretException(e.operation, detail: 'код ${e.code}');
      }
      await _waitServiceStopped(serviceName);
    }
    for (final e in win.findProcesses('winws.exe')) {
      try {
        win.terminateProcess(e.pid);
      } on win.Win32Exception catch (err) {
        throw ZapretException(
          'Не удалось остановить winws.exe',
          detail: 'код ${err.code}',
        );
      }
    }
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (win.findProcesses('winws.exe').isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (win.findProcesses('winws.exe').isNotEmpty) {
      throw const ZapretException('winws.exe не закрылся');
    }
  }

  /// Удаляет службу zapret; с [cleanupDriver] — ещё и драйвер WinDivert,
  /// чтобы файлы zapret освободились (нужно перед обновлением).
  Future<void> removeService({bool cleanupDriver = true}) async {
    try {
      if (win.queryService(serviceName) != null) {
        if (win.queryService(serviceName)!.state != win.ServiceState.stopped) {
          win.stopService(serviceName);
          await _waitServiceStopped(serviceName);
        }
        win.deleteService(serviceName);
        await _waitServiceGone(serviceName);
      }
      if (cleanupDriver) await unloadDriver();
    } on win.Win32Exception catch (e) {
      throw ZapretException(e.operation, detail: 'код ${e.code}');
    }
  }

  /// Останавливает и удаляет чужие службы (другие обходы, которые держат WinDivert).
  Future<void> removeServices(List<String> names) async {
    for (final name in names) {
      final svc = win.queryService(name);
      if (svc == null) continue;
      try {
        if (svc.state != win.ServiceState.stopped) {
          win.stopService(name);
          await _waitServiceStopped(name);
        }
        win.deleteService(name);
      } on win.Win32Exception catch (e) {
        throw ZapretException(
          'Не удалось удалить службу $name',
          detail: 'код ${e.code}',
        );
      }
    }
  }

  /// Выгружает драйвер WinDivert, если winws.exe не запущен.
  Future<void> unloadDriver() async {
    if (win.findProcesses('winws.exe').isNotEmpty) return;
    for (final name in const ['WinDivert', 'WinDivert14']) {
      final svc = win.queryService(name);
      if (svc == null) continue;
      try {
        if (svc.state != win.ServiceState.stopped) {
          win.stopService(name);
          await _waitServiceStopped(name);
        }
        win.deleteService(name);
      } on win.Win32Exception {
        // Драйвер может быть занят другой программой — не мешаем ей.
      }
    }
  }

  /// Подготовка перед запуском: файл winws.exe на месте, списки есть, TCP timestamps включены.
  void prepare(ZapretInstall install) {
    if (!install.winws.existsSync()) {
      throw const ZapretException(
        'Нет файла bin\\winws.exe',
        detail: 'Его мог удалить антивирус. Переустановите zapret',
      );
    }
    install.ensureUserLists();
    _enableTcpTimestamps();
  }

  /// Быстрый запуск для подбора стратегии: ждёт только появления процесса.
  /// false — winws.exe не запустился или сразу закрылся.
  Future<bool> startForProbe(
    ZapretInstall install,
    Strategy strategy,
    GameFilter filter,
  ) async {
    final List<String> args;
    try {
      args = await install.argsFor(strategy, filter);
      await Process.start(
        install.winws.path,
        args,
        workingDirectory: install.binDir,
        mode: ProcessStartMode.detached,
      );
    } on FormatException {
      return false;
    } on ProcessException {
      return false;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (win.findProcesses('winws.exe').isNotEmpty) {
        // Даём драйверу WinDivert подняться и winws.exe — прочитать списки.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        return win.findProcesses('winws.exe').isNotEmpty;
      }
    }
    return false;
  }

  /// Завершает все процессы winws.exe, не трогая службу. Ошибки не бросает.
  Future<void> killProcesses() async {
    for (final e in win.findProcesses('winws.exe')) {
      try {
        win.terminateProcess(e.pid);
      } on win.Win32Exception {
        // Проверим ниже, закрылся ли он.
      }
    }
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (win.findProcesses('winws.exe').isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<List<String>> _prepare(
    ZapretInstall install,
    Strategy strategy,
    GameFilter filter,
  ) async {
    prepare(install);
    try {
      return await install.argsFor(strategy, filter);
    } on FormatException catch (e) {
      throw ZapretException(
        'Не удалось прочитать стратегию ${strategy.title}',
        detail: e.message,
      );
    }
  }

  /// service.bat включает TCP timestamps перед каждым запуском — без них
  /// часть стратегий не работает.
  void _enableTcpTimestamps() {
    Process.start('netsh', const [
      'interface',
      'tcp',
      'set',
      'global',
      'timestamps=enabled',
    ], mode: ProcessStartMode.detached).ignore();
  }

  Future<void> _expectRunning() async {
    // winws.exe с неверными аргументами или без драйвера закрывается почти сразу.
    final deadline = DateTime.now().add(const Duration(milliseconds: 2500));
    var seen = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final alive = win.findProcesses('winws.exe').isNotEmpty;
      if (alive) seen = true;
      if (seen && !alive) break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (win.findProcesses('winws.exe').isEmpty) {
      throw const ZapretException(
        'winws.exe закрылся сразу после запуска',
        detail: 'Возможно, его блокирует антивирус или драйвер WinDivert занят другой программой',
      );
    }
  }

  Future<void> _waitServiceStopped(String name) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final s = win.queryService(name);
      if (s == null || s.state == win.ServiceState.stopped) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw ZapretException('Служба $name не остановилась за 10 секунд');
  }

  Future<void> _waitServiceGone(String name) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (win.queryService(name) == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
