import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../ui/ui.dart';
import '../zapret/probe.dart';
import 'autopick_page.dart';
import 'common.dart';

String _autoPickLine(AppController c) {
  final best = c.probeReport?.best;
  if (best != null) {
    return 'Последний подбор: лучшая — «${best.strategy!.title}», '
        '${best.okCount} из ${best.total} сайтов.';
  }
  return 'Лаунчер проверит все стратегии и найдёт ту, с которой открываются Discord и YouTube.';
}

/// Итог стратегии в последнем подборе — вместо имени файла: так видно, какую брать.
String? _resultLine(StrategyResult? r) {
  if (r == null) return null;
  if (r.failedToStart) return 'В подборе не запустилась';
  return 'В подборе: ${r.okCount} из ${r.total} сайтов';
}

/// Выбор стратегии. Если zapret работает, он сразу перезапускается с новой.
class StrategiesPage extends StatelessWidget {
  const StrategiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final strategies = c.install?.strategies ?? const [];
    final selected = c.strategy?.id;
    final enabled = c.busy == null && (c.elevated || !c.running);
    final results = {
      for (final r in c.probeReport?.results ?? const <StrategyResult>[])
        if (r.strategy != null) r.strategy!.id: r,
    };

    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Стратегии',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        const Appear(
          index: 0,
          child: PageTitle(
            'Стратегии',
            description:
                'Какая сработает, зависит от провайдера. Не открываются '
                'Discord или YouTube — выберите другую или подберите автоматически.',
          ),
        ),
        const SizedBox(height: 24),
        Appear(
          index: 1,
          child: NcSettingsCard(
            children: [
              NcSettingRow(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.field,
                  ),
                  child: Icon(
                    LucideIcons.wandSparkles,
                    size: 20,
                    color: p.text,
                  ),
                ),
                title: 'Подобрать автоматически',
                description: _autoPickLine(c),
                below: c.probing
                    ? StatusLine(
                        tone: Tone.info,
                        text: c.busy?.text ?? 'Идёт проверка',
                      )
                    : null,
                trailing: Icon(
                  LucideIcons.chevronRight,
                  size: 20,
                  color: p.muted,
                ),
                onTap: () => Navigator.of(
                  context,
                ).push(NcPageRoute<void>(builder: (_) => const AutoPickPage())),
              ),
            ],
          ),
        ),
        const SizedBox(height: NcSpace.gapCards),
        Appear(
          index: 2,
          child: NcSettingsCard(
            children: [
              for (final s in strategies)
                NcSettingRow(
                  title: s.title,
                  description: _resultLine(results[s.id]),
                  below: s.id == selected && c.running && c.busy == null
                      ? const StatusLine(tone: Tone.success, text: 'Работает')
                      : null,
                  trailing: AnimatedOpacity(
                    duration: NcMotion.icon,
                    opacity: s.id == selected ? 1 : 0,
                    child: Icon(LucideIcons.check, size: 20, color: p.text),
                  ),
                  onTap: enabled ? () => c.selectStrategy(s) : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
