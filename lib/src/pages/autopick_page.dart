import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../ui/ui.dart';
import '../zapret/probe.dart';
import 'common.dart';

/// Примерное время на одну стратегию: запуск, проверка сайтов, остановка.
const _perStrategy = Duration(seconds: 6);

/// Подбор стратегии: перебрать все и найти ту, с которой открываются сайты.
class AutoPickPage extends StatelessWidget {
  const AutoPickPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final report = c.probeReport;
    final progress = c.probeProgress;
    final strategies = c.install?.strategies.length ?? 0;
    final canStart =
        c.elevated && c.busy == null && !c.runningElsewhere && strategies > 0;

    Widget? fab;
    if (c.probing) {
      fab = NcFab(
        icon: LucideIcons.square,
        label: 'Остановить',
        onPressed: c.cancelAutoPick,
      );
    } else if (report?.best != null) {
      final best = report!.best!.strategy!;
      final active = c.running && c.strategy?.id == best.id;
      if (!active) {
        fab = NcFab(
          icon: LucideIcons.power,
          label: 'Включить «${best.title}»',
          onPressed: c.busy == null && c.elevated
              ? () => c.applyStrategy(best)
              : null,
        );
      }
    } else if (report == null) {
      fab = NcFab(
        icon: LucideIcons.play,
        label: 'Начать',
        onPressed: canStart ? c.autoPick : null,
      );
    }

    var i = 0;
    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Подбор стратегии',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      fab: fab,
      children: [
        ...importantRows(context, c, admin: true),
        Appear(
          index: i++,
          child: PageTitle(
            'Подбор стратегии',
            description:
                'Лаунчер по очереди включит каждую стратегию и проверит, открываются ли сайты.\n'
                'Займёт ${_minutes((strategies + 1) * _perStrategy.inSeconds)} — '
                'интернет в это время может пропадать.',
          ),
        ),
        const SizedBox(height: 24),
        if (c.probing) ...[
          Appear(
            index: i++,
            child: _ProgressCard(progress: progress),
          ),
          if (progress?.baseline != null) ...[
            const SizedBox(height: NcSpace.gapCards),
            Appear(
              index: i++,
              child: _BaselineCard(result: progress!.baseline!),
            ),
          ],
          if (progress != null && progress.results.isNotEmpty) ...[
            const SizedBox(height: 16),
            const SectionTitle('Проверено'),
            const SizedBox(height: 12),
            NcSettingsCard(
              children: [
                for (final r in progress.results.reversed)
                  _ResultRow(result: r),
              ],
            ),
          ],
        ] else if (report != null)
          ..._reportView(context, c, report, () => i++)
        else
          Appear(
            index: i++,
            child: _IntroCard(targets: c.probeTargets),
          ),
      ],
    );
  }

  List<Widget> _reportView(
    BuildContext context,
    AppController c,
    AutoPickReport report,
    int Function() next,
  ) {
    final best = report.best;
    final spoofed = report.baseline.targets.where(
      (t) => t.outcome == ProbeOutcome.spoofed,
    );
    final clean = report.baseline.okCount == report.baseline.total;
    return [
      if (clean) ...[
        const NoticeRow(
          kind: NoticeKind.info,
          title: 'Сайты открываются и без обхода',
          detail:
              'Блокировок не видно: возможно, включён VPN или провайдер сейчас их не блокирует. '
              'Сравнить стратегии в таком случае не получится.',
        ),
        const SizedBox(height: 8),
      ],
      if (report.cancelled) ...[
        const NoticeRow(
          kind: NoticeKind.info,
          title: 'Проверка остановлена',
          detail: 'Ниже — стратегии, которые успели проверить.',
        ),
        const SizedBox(height: 8),
      ],
      if (spoofed.isNotEmpty) ...[
        NoticeRow(
          kind: NoticeKind.decision,
          title: 'Провайдер подменяет ответы сайтов',
          detail:
              'Чужой сертификат у ${spoofed.map((t) => t.target.url.host).join(', ')}. '
              'Обход это не исправит — включите Secure DNS в Windows или браузере.',
        ),
        const SizedBox(height: 8),
      ],
      if (best == null && !report.cancelled && !clean) ...[
        const NoticeRow(
          kind: NoticeKind.decision,
          title: 'Ни одна стратегия не помогла',
          detail:
              'Попробуйте IPSet «Все адреса» или игровой фильтр на главной '
              'и запустите подбор ещё раз.',
        ),
        const SizedBox(height: 8),
      ],
      if (best != null)
        Appear(
          index: next(),
          child: _BestCard(result: best, controller: c),
        ),
      const SizedBox(height: NcSpace.gapCards),
      Appear(
        index: next(),
        child: _BaselineCard(result: report.baseline),
      ),
      if (report.results.isNotEmpty) ...[
        const SizedBox(height: 16),
        Appear(index: next(), child: const SectionTitle('Все стратегии')),
        const SizedBox(height: 4),
        Appear(
          index: next(),
          child: Text(
            'Нажмите на стратегию, чтобы включить её.',
            style: NcType.caption.copyWith(color: context.palette.muted),
          ),
        ),
        const SizedBox(height: 12),
        Appear(
          index: next(),
          child: NcSettingsCard(
            children: [
              for (final r in report.ranked)
                _ResultRow(
                  result: r,
                  best: identical(r, best),
                  active:
                      c.running &&
                      c.busy == null &&
                      c.strategy?.id == r.strategy?.id,
                  onTap: r.failedToStart || c.busy != null || !c.elevated
                      ? null
                      : () => c.applyStrategy(r.strategy!),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: NcButton.gray(
          label: 'Проверить ещё раз',
          icon: LucideIcons.rotateCw,
          onPressed: c.elevated && c.busy == null && !c.runningElsewhere
              ? c.autoPick
              : null,
        ),
      ),
    ];
  }
}

String _minutes(int seconds) {
  if (seconds < 60) return 'меньше минуты';
  final m = (seconds / 60).ceil();
  // После «около» — родительный падеж: около 1 минуты, около 3 минут.
  final word = m % 10 == 1 && m % 100 != 11 ? 'минуты' : 'минут';
  return 'около $m $word';
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.targets});

  final List<ProbeTarget> targets;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final groups = <String, int>{};
    for (final t in targets) {
      groups[t.group] = (groups[t.group] ?? 0) + 1;
    }
    return NcCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Что проверяем', style: NcType.rowTitle),
          const SizedBox(height: 4),
          Text(
            '${groups.keys.join(', ')} — ${targets.length} адресов из targets.txt. '
            'Сайт считается открытым, если ответил и отдал данные: так видна и блокировка, '
            'и «заморозка» соединения после 16–20 КБ.',
            style: NcType.caption.copyWith(color: p.muted),
          ),
          const SizedBox(height: 10),
          Text(
            'Голосовые каналы Discord и видео через QUIC так проверить нельзя.',
            style: NcType.caption.copyWith(color: p.muted),
          ),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});

  final AutoPickProgress? progress;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pr = progress;
    final total = pr?.total ?? 1;
    final done = pr?.baseline == null
        ? 0
        : (pr!.current == null ? total : pr.index);
    final title = pr?.current != null
        ? 'Проверяю «${pr!.current!.title}»'
        : pr?.baseline == null
        ? 'Проверяю сайты без обхода'
        : 'Подвожу итоги';
    final left = (total - done) * _perStrategy.inSeconds;
    return NcCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: NcType.rowTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$done из $total',
                style: NcType.caption.copyWith(
                  color: p.muted,
                  fontFeatures: NcType.tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          NcProgressBar(
            value: (done + (pr?.baseline == null ? 0 : .5)) / (total + 1),
          ),
          const SizedBox(height: 8),
          Text(
            left <= 0 ? 'Почти готово' : 'Осталось ${_minutes(left)}',
            style: NcType.caption.copyWith(color: p.muted),
          ),
        ],
      ),
    );
  }
}

class _BestCard extends StatelessWidget {
  const _BestCard({required this.result, required this.controller});

  final StrategyResult result;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final active =
        controller.running && controller.strategy?.id == result.strategy?.id;
    return NcCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(shape: BoxShape.circle, color: p.success),
            child: const Icon(
              LucideIcons.trophy,
              size: 20,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Лучшая — «${result.strategy!.title}»',
                  style: NcType.rowTitle,
                ),
                const SizedBox(height: 2),
                Text(
                  '${_openLine(result)} · отклик ${result.averageLatency.inMilliseconds} мс',
                  style: NcType.caption.copyWith(color: p.muted),
                ),
                const SizedBox(height: 8),
                _GroupDots(result: result),
                if (active) ...[
                  const SizedBox(height: 8),
                  const StatusLine(tone: Tone.success, text: 'Включена'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BaselineCard extends StatelessWidget {
  const _BaselineCard({required this.result});

  final StrategyResult result;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return NcCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Без обхода', style: NcType.rowTitle),
          const SizedBox(height: 2),
          Text(
            _openLine(result),
            style: NcType.caption.copyWith(color: p.muted),
          ),
          const SizedBox(height: 8),
          _GroupDots(result: result),
        ],
      ),
    );
  }
}

String _openLine(StrategyResult r) =>
    'Открываются ${r.okCount} из ${r.total} сайтов';

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    this.best = false,
    this.active = false,
    this.onTap,
  });

  final StrategyResult result;
  final bool best;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return NcSettingRow(
      title: result.strategy!.title,
      description: result.failedToStart
          ? 'Не запустилась'
          : '${_openLine(result)} · ${result.averageLatency.inMilliseconds < 100000 ? '${result.averageLatency.inMilliseconds} мс' : 'нет ответа'}',
      below: result.failedToStart
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _GroupDots(result: result),
                if (active) ...[
                  const SizedBox(height: 6),
                  const StatusLine(tone: Tone.success, text: 'Включена'),
                ],
              ],
            ),
      trailing: best ? const NcTag('Лучшая') : null,
      onTap: onTap,
    );
  }
}

/// По сервисам: «Discord 4/4», точка — зелёная, оранжевая или красная.
class _GroupDots extends StatelessWidget {
  const _GroupDots({required this.result});

  final StrategyResult result;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final MapEntry(key: group, value: (ok, total))
            in result.byGroup.entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ok == total
                      ? p.success
                      : (ok == 0 ? p.danger : p.warning),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$group $ok/$total',
                style: NcType.caption.copyWith(
                  color: p.muted,
                  fontWeight: FontWeight.w500,
                  fontFeatures: NcType.tabular,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
