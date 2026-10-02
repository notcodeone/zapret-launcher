import 'probe.dart';

enum ServiceHealth {
  /// Все адреса сервиса открываются.
  ok,

  /// Часть адресов не открывается.
  partial,

  /// Ни один адрес не открывается.
  down,
}

/// Итог быстрой проверки сети: открываются ли Discord, YouTube и другие сайты сейчас.
class NetworkReport {
  const NetworkReport({
    required this.checkedAt,
    required this.targets,
    required this.withZapret,
    this.strategyTitle,
  });

  final DateTime checkedAt;
  final List<TargetResult> targets;

  /// Был ли включён zapret во время проверки.
  final bool withZapret;
  final String? strategyTitle;

  /// Сервис → (открылось, всего), в порядке targets.txt.
  Map<String, (int ok, int total)> get byGroup {
    final map = <String, (int, int)>{};
    for (final t in targets) {
      final (ok, total) = map[t.target.group] ?? (0, 0);
      map[t.target.group] = (ok + (t.ok ? 1 : 0), total + 1);
    }
    return map;
  }

  ServiceHealth health(String group) {
    final v = byGroup[group];
    if (v == null) return ServiceHealth.ok;
    final (ok, total) = v;
    if (ok == total) return ServiceHealth.ok;
    return ok == 0 ? ServiceHealth.down : ServiceHealth.partial;
  }

  List<String> groupsWith(ServiceHealth h) =>
      [for (final g in byGroup.keys) if (health(g) == h) g];

  bool get allOk => targets.every((t) => t.ok);

  /// Провайдер подменяет ответы — обход тут не поможет.
  bool get spoofed => targets.any((t) => t.outcome == ProbeOutcome.spoofed);

  /// Нет сети вообще: ни один адрес не найден.
  bool get offline => targets.isNotEmpty && targets.every((t) => t.outcome == ProbeOutcome.noHost);
}
