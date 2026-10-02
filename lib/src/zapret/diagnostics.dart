import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/win32.dart' as win;
import 'install.dart';

/// Насколько всё плохо.
enum CheckLevel {
  /// В порядке.
  ok,

  /// К сведению: может мешать, а может и нет.
  info,

  /// Стоит проверить.
  warning,

  /// Мешает работе zapret.
  problem,
}

/// Что можно сделать с найденной проблемой.
sealed class DiagnosticFix {
  const DiagnosticFix(this.label);

  /// Глагол на кнопке.
  final String label;
}

/// Запустить системную службу (BFE).
class StartServiceFix extends DiagnosticFix {
  const StartServiceFix(this.service) : super('Запустить');

  final String service;
}

/// Остановить и удалить службы других обходов, затем выгрузить WinDivert.
class RemoveServicesFix extends DiagnosticFix {
  const RemoveServicesFix(this.services) : super('Удалить');

  final List<String> services;
}

/// Выгрузить драйвер WinDivert, который остался без winws.exe.
class UnloadDriverFix extends DiagnosticFix {
  const UnloadDriverFix() : super('Выгрузить');
}

/// Скачать zapret заново.
class ReinstallFix extends DiagnosticFix {
  const ReinstallFix() : super('Переустановить');
}

/// Открыть ссылку, страницу параметров Windows или файл.
class OpenFix extends DiagnosticFix {
  const OpenFix(super.label, this.target, {this.parameters});

  final String target;
  final String? parameters;
}

/// Добавить в hosts записи из репозитория zapret.
class HostsBlockFix extends DiagnosticFix {
  const HostsBlockFix(this.content, {bool update = false}) : super(update ? 'Обновить' : 'Добавить');

  final String content;
}

class DiagnosticResult {
  const DiagnosticResult(this.id, this.title, this.level, this.detail, {this.fix});

  final String id;
  final String title;
  final CheckLevel level;
  final String detail;
  final DiagnosticFix? fix;
}

/// Всё, что диагностика читает из системы. В тестах — подделка.
abstract interface class DiagnosticsSystem {
  bool serviceRunning(String name);

  /// Все службы (и запущенные, и остановленные).
  List<win.ServiceEntry> services();
  bool processRunning(String exe);

  /// Адрес системного прокси, если он включён.
  String? proxyServer();

  /// Настроен ли DNS поверх HTTPS хотя бы для одного сетевого адаптера.
  bool secureDns();
  String? oneDrive();
  String? readHosts();
}

/// Настоящая система через Win32.
class WindowsDiagnosticsSystem implements DiagnosticsSystem {
  @override
  bool serviceRunning(String name) => win.queryService(name)?.running ?? false;

  @override
  List<win.ServiceEntry> services() => win.enumServices(activeOnly: false);

  @override
  bool processRunning(String exe) => win.findProcesses(exe).isNotEmpty;

  @override
  String? proxyServer() {
    const key = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    if (win.readRegistryDword(key, 'ProxyEnable', currentUser: true) != 1) return null;
    return win.readRegistryString(key, 'ProxyServer', currentUser: true) ?? 'адрес не указан';
  }

  @override
  bool secureDns() {
    const base = r'System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters';
    for (final iface in win.registrySubkeys(base)) {
      for (final server in win.registrySubkeys('$base\\$iface\\DohInterfaceSettings\\Doh')) {
        final flags = win.readRegistryDword('$base\\$iface\\DohInterfaceSettings\\Doh\\$server', 'DohFlags');
        if ((flags ?? 0) > 0) return true;
      }
      for (final server in win.registrySubkeys('$base\\$iface\\DohInterfaceSettings\\Doh6')) {
        final flags = win.readRegistryDword('$base\\$iface\\DohInterfaceSettings\\Doh6\\$server', 'DohFlags');
        if ((flags ?? 0) > 0) return true;
      }
      if ((win.readRegistryDword('$base\\$iface', 'DohFlags') ?? 0) > 0) return true;
    }
    return false;
  }

  @override
  String? oneDrive() => Platform.environment['OneDrive'];

  @override
  String? readHosts() {
    try {
      return File(hostsPath).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }
}

String get hostsPath =>
    p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'drivers', 'etc', 'hosts');

/// Службы других обходов, которые занимают WinDivert (список из service.bat).
const conflictingServices = ['GoodbyeDPI', 'discordfix_zapret', 'winws1', 'winws2'];

/// Программы, которые мешают zapret: что искать в именах служб и где почитать.
const _knownConflicts = [
  (
    'killer',
    'Killer Networking',
    ['killer'],
    'Сетевые службы Killer конфликтуют с zapret. Отключите их или удалите Killer Control Center.',
    'https://github.com/Flowseal/zapret-discord-youtube/issues/2512#issuecomment-2821119513',
  ),
  (
    'intel',
    'Intel Connectivity Network Service',
    ['intel', 'connectivity', 'network'],
    'Служба Intel мешает обходу. Остановите её в «Службах» или удалите Intel Connectivity.',
    'https://github.com/ValdikSS/GoodbyeDPI/issues/541#issuecomment-2661670982',
  ),
  (
    'checkpoint',
    'Check Point',
    ['tracsrvwrapper'],
    'Check Point конфликтует с zapret. Попробуйте удалить его.',
    null,
  ),
  (
    'checkpoint',
    'Check Point',
    ['epwd'],
    'Check Point конфликтует с zapret. Попробуйте удалить его.',
    null,
  ),
  (
    'smartbyte',
    'SmartByte',
    ['smartbyte'],
    'SmartByte конфликтует с zapret. Отключите его службу или удалите программу.',
    null,
  ),
];

final _cyrillic = RegExp('[а-яА-ЯёЁ]');

/// Проверки из раздела Run Diagnostics в service.bat.
/// [repoHosts] — файл hosts из репозитория zapret (null — не удалось скачать).
List<DiagnosticResult> diagnose(
  DiagnosticsSystem sys, {
  ZapretInstall? install,
  String? repoHosts,
}) {
  final out = <DiagnosticResult>[];
  final services = sys.services();
  bool hasService(String name) =>
      services.any((s) => s.name.toLowerCase() == name.toLowerCase());

  // Служба базовой фильтрации — без неё WinDivert не работает.
  out.add(sys.serviceRunning('BFE')
      ? const DiagnosticResult('bfe', 'Служба базовой фильтрации', CheckLevel.ok, 'Работает.')
      : const DiagnosticResult('bfe', 'Служба базовой фильтрации', CheckLevel.problem,
          'Служба BFE остановлена — без неё WinDivert и zapret не работают.',
          fix: StartServiceFix('BFE')));

  // Файлы zapret: их часто удаляет антивирус.
  if (install != null) {
    final missing = [
      for (final f in ['winws.exe', 'WinDivert.dll', 'WinDivert64.sys'])
        if (!File(p.join(install.binDir, f)).existsSync()) f,
    ];
    out.add(missing.isEmpty
        ? const DiagnosticResult('files', 'Файлы zapret', CheckLevel.ok, 'Все на месте.')
        : DiagnosticResult('files', 'Файлы zapret', CheckLevel.problem,
            'Нет ${missing.join(', ')} — скорее всего, их удалил антивирус. '
            'Добавьте папку zapret в исключения антивируса и переустановите zapret.',
            fix: const ReinstallFix()));

    final path = install.root.path;
    final oneDrive = sys.oneDrive();
    if (oneDrive != null &&
        oneDrive.isNotEmpty &&
        p.isWithin(oneDrive.toLowerCase(), path.toLowerCase())) {
      out.add(DiagnosticResult('path', 'Папка zapret', CheckLevel.problem,
          'Zapret лежит в OneDrive ($path). Перенесите его в обычную папку, например C:\\zapret.'));
    } else if (_cyrillic.hasMatch(path)) {
      out.add(DiagnosticResult('path', 'Папка zapret', CheckLevel.warning,
          'В пути есть русские буквы ($path). Если обход не работает, перенесите zapret, '
          'например в C:\\zapret.'));
    }
  }

  // Другие обходы занимают WinDivert.
  final conflicts = [for (final s in conflictingServices) if (hasService(s)) s];
  out.add(conflicts.isEmpty
      ? const DiagnosticResult('conflicts', 'Другие обходы блокировок', CheckLevel.ok, 'Не найдены.')
      : DiagnosticResult('conflicts', 'Другие обходы блокировок', CheckLevel.problem,
          'Установлены службы ${conflicts.join(', ')}. Они занимают WinDivert, '
          'и zapret с ними не работает.',
          fix: RemoveServicesFix(conflicts)));

  // Драйвер остался после другой программы.
  final winwsRunning = sys.processRunning('winws.exe');
  final driverActive = sys.serviceRunning('WinDivert') || sys.serviceRunning('WinDivert14');
  if (!winwsRunning && driverActive) {
    out.add(const DiagnosticResult('windivert', 'Драйвер WinDivert', CheckLevel.warning,
        'Драйвер загружен, а winws.exe не запущен — его держит другая программа '
        'или он остался после неё.',
        fix: UnloadDriverFix()));
  }

  // Программы, которые мешают.
  final found = <String>{};
  if (sys.processRunning('AdguardSvc.exe')) {
    found.add('adguard');
    out.add(const DiagnosticResult('adguard', 'AdGuard', CheckLevel.problem,
        'AdGuard может ломать Discord вместе с zapret. Выключите его фильтрацию трафика.',
        fix: OpenFix('Подробнее', 'https://github.com/Flowseal/zapret-discord-youtube/issues/417')));
  }
  final active = [for (final s in services) if (s.state == win.ServiceState.running) s];
  for (final (id, title, words, detail, link) in _knownConflicts) {
    if (found.contains(id)) continue;
    final hit = active.any((s) {
      final text = '${s.name} ${s.displayName}'.toLowerCase();
      return words.every(text.contains);
    });
    if (!hit) continue;
    found.add(id);
    out.add(DiagnosticResult(id, title, CheckLevel.problem, detail,
        fix: link == null ? null : OpenFix('Подробнее', link)));
  }
  if (found.isEmpty) {
    out.add(const DiagnosticResult('software', 'Программы, которые мешают zapret', CheckLevel.ok,
        'AdGuard, Killer, Intel Connectivity, Check Point и SmartByte не найдены.'));
  }

  // VPN.
  final vpn = [
    for (final s in active)
      if ('${s.name} ${s.displayName}'.toLowerCase().contains('vpn'))
        s.displayName.isEmpty ? s.name : s.displayName,
  ];
  out.add(vpn.isEmpty
      ? const DiagnosticResult('vpn', 'VPN', CheckLevel.ok, 'Службы VPN не запущены.')
      : DiagnosticResult('vpn', 'VPN', CheckLevel.warning,
          'Запущены: ${vpn.join(', ')}. Некоторые VPN мешают zapret — выключите их на время.'));

  // Прокси.
  final proxy = sys.proxyServer();
  out.add(proxy == null
      ? const DiagnosticResult('proxy', 'Системный прокси', CheckLevel.ok, 'Выключен.')
      : DiagnosticResult('proxy', 'Системный прокси', CheckLevel.warning,
          'Включён: $proxy. Если вы им не пользуетесь — выключите.',
          fix: const OpenFix('Открыть параметры', 'ms-settings:network-proxy')));

  // Защищённый DNS.
  out.add(sys.secureDns()
      ? const DiagnosticResult('dns', 'Защищённый DNS', CheckLevel.ok, 'Настроен в Windows.')
      : const DiagnosticResult('dns', 'Защищённый DNS', CheckLevel.info,
          'В Windows не настроен. Включите его в браузере (Cloudflare или Google) или в параметрах '
          'Windows 11 — иначе провайдер может подменять адреса сайтов.'));

  // hosts.
  final hosts = sys.readHosts();
  if (hosts != null) {
    final lower = hosts.toLowerCase();
    final youtube = hosts
        .split(RegExp(r'\r?\n'))
        .any((l) => !l.trimLeft().startsWith('#') && RegExp(r'youtube\.com|youtu\.be').hasMatch(l.toLowerCase()));
    if (youtube) {
      out.add(DiagnosticResult('hosts-youtube', 'Записи YouTube в hosts', CheckLevel.warning,
          'В файле hosts есть адреса youtube.com или youtu.be — из-за них YouTube может не открываться.',
          fix: OpenFix('Открыть hosts', 'notepad.exe', parameters: hostsPath)));
    }
    if (repoHosts != null) {
      final status = hostsBlockStatus(lower, repoHosts);
      out.add(switch (status) {
        HostsStatus.upToDate => const DiagnosticResult('hosts-repo', 'Адреса для Telegram и Discord',
            CheckLevel.ok, 'Записи из репозитория zapret есть в hosts.'),
        HostsStatus.outdated => DiagnosticResult('hosts-repo', 'Адреса для Telegram и Discord',
            CheckLevel.info, 'Записи из репозитория zapret в hosts устарели.',
            fix: HostsBlockFix(repoHosts, update: true)),
        HostsStatus.missing => DiagnosticResult('hosts-repo', 'Адреса для Telegram и Discord',
            CheckLevel.info,
            'В hosts нет адресов из репозитория zapret. Они помогают веб-версии Telegram '
            'и голосовым каналам Discord.',
            fix: HostsBlockFix(repoHosts)),
      });
    }
  }

  return out;
}

// ── hosts ───────────────────────────────────────────────────────────────────

const hostsBegin = '# --- zapret-discord-youtube: добавлено ZapretLauncher ---';
const hostsEnd = '# --- /zapret-discord-youtube ---';

enum HostsStatus { upToDate, outdated, missing }

List<String> _meaningfulLines(String text) => [
      for (final l in text.split(RegExp(r'\r?\n')))
        if (l.trim().isNotEmpty && !l.trimLeft().startsWith('#')) l.trim(),
    ];

/// Как service.bat: записи на месте, если в hosts есть первая и последняя строки из репозитория.
HostsStatus hostsBlockStatus(String hosts, String repo) {
  final lines = _meaningfulLines(repo);
  if (lines.isEmpty) return HostsStatus.upToDate;
  final lower = hosts.toLowerCase();
  if (lower.contains(lines.first.toLowerCase()) && lower.contains(lines.last.toLowerCase())) {
    return HostsStatus.upToDate;
  }
  return lower.contains(hostsBegin.toLowerCase()) ? HostsStatus.outdated : HostsStatus.missing;
}

/// Заменяет наш блок в hosts на свежий или дописывает его в конец.
String mergeHostsBlock(String hosts, String repo) {
  final block = [hostsBegin, ..._meaningfulLines(repo), hostsEnd].join('\r\n');
  final start = hosts.indexOf(hostsBegin);
  final end = hosts.indexOf(hostsEnd);
  if (start >= 0 && end > start) {
    return hosts.substring(0, start) + block + hosts.substring(end + hostsEnd.length);
  }
  final sep = hosts.isEmpty || hosts.endsWith('\n') ? '' : '\r\n';
  return '$hosts$sep\r\n$block\r\n';
}

// ── Кэш Discord ─────────────────────────────────────────────────────────────

/// Установки Discord: процесс и папка в %APPDATA% — как в service.bat.
const discordInstalls = [
  ('Discord.exe', 'discord'),
  ('DiscordPTB.exe', 'discordptb'),
  ('DiscordCanary.exe', 'discordcanary'),
  ('DiscordDevelopment.exe', 'discorddevelopment'),
];

const discordCacheDirs = ['Cache', 'Code Cache', 'GPUCache'];
