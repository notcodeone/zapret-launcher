import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../ui/ui.dart';
import '../zapret/network.dart';
import 'autopick_page.dart';
import 'diagnostics_page.dart';

/// Кнопка проверки сети в шапке: точка — зелёная, жёлтая или красная.
Widget networkButton(BuildContext context, AppController c) {
  return NcIconButton(
    icon: LucideIcons.globe,
    tooltip: 'Проверка сети',
    badge: networkBadge(c),
    onPressed: () => showNetworkMenu(context),
  );
}

BadgeTone? networkBadge(AppController c) {
  final r = c.network;
  if (r == null) return c.checkingNetwork ? BadgeTone.pending : null;
  if (r.offline || r.groupsWith(ServiceHealth.down).isNotEmpty) {
    return BadgeTone.alarm;
  }
  if (r.groupsWith(ServiceHealth.partial).isNotEmpty || c.checkingNetwork) {
    return BadgeTone.pending;
  }
  return BadgeTone.ok;
}

/// Сводка одной строкой: «Всё открывается», «Discord не открывается».
String networkSummary(NetworkReport? r, {required bool checking}) {
  if (r == null) return checking ? 'Проверяю сеть…' : 'Сеть ещё не проверена';
  if (r.offline) return 'Нет интернета';
  final down = r.groupsWith(ServiceHealth.down);
  if (down.isNotEmpty) {
    return down.length == 1
        ? '${down.single} не открывается'
        : '${down.take(down.length - 1).join(', ')} и ${down.last} не открываются';
  }
  if (r.groupsWith(ServiceHealth.partial).isNotEmpty) {
    return 'Открывается не всё';
  }
  return 'Всё открывается';
}

String _time(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Меню-окно раскрывается от кнопки в шапке; под ним экран затемняется.
Future<void> showNetworkMenu(BuildContext context) {
  final c = AppScope.of(context);
  if (c.network == null && !c.checkingNetwork) c.checkNetwork();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Проверка сети',
    barrierColor: context.palette.scrim,
    transitionDuration: NcMotion.toastIn,
    transitionBuilder: (context, a, _, child) {
      final t = CurvedAnimation(
        parent: a,
        curve: NcMotion.enter,
        reverseCurve: NcMotion.exit,
      );
      return FadeTransition(
        opacity: t,
        child: ScaleTransition(
          alignment: Alignment.topRight,
          scale: Tween(begin: .96, end: 1.0).animate(t),
          child: child,
        ),
      );
    },
    pageBuilder: (context, _, _) => const _NetworkMenu(),
  );
}

class _NetworkMenu extends StatelessWidget {
  const _NetworkMenu();

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final r = c.network;

    void go(Widget page) {
      Navigator.of(context)
        ..pop()
        ..push(NcPageRoute<void>(builder: (_) => page));
    }

    final g = c.guard;
    var caption = '';
    if (r == null) {
      caption = 'Проверяю Discord, YouTube и другие сайты из targets.txt.';
    } else {
      final mode = r.withZapret
          ? (r.strategyTitle == null
                ? 'с zapret'
                : 'с zapret «${r.strategyTitle}»')
          : 'без zapret';
      caption = c.checkingNetwork
          ? 'Проверяю снова…'
          : 'Сайты проверены в ${_time(r.checkedAt)} $mode.';
    }
    if (g.countrySource != null) {
      caption += ' Страна — по данным ${g.countrySource}.';
    }

    // Заголовок — страна, как в окне сети ClaudeLauncher; без определения страны — сводка.
    final countryOn = c.settings.countryCheck;
    final title = !countryOn
        ? networkSummary(r, checking: c.checkingNetwork)
        : g.countryLabel ??
              (g.checkingCountry || g.countryCheckedAt == null
                  ? 'Определяю страну…'
                  : 'Страна не определена');

    final guardLine = !c.settings.networkGuard
        ? null
        : g.autoOff != null && !c.running
        ? (Tone.warning, 'Zapret выключен: сменилась сеть')
        : g.handling
        ? (Tone.info, 'Проверяю новую сеть')
        : c.elevated
        ? (Tone.success, 'Слежу за сетью')
        : (Tone.neutral, 'Слежение за сетью ждёт прав администратора');

    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(
          top: NcSpace.headerTop + NcSpace.headerHeight + 8,
          right: NcSpace.gutter,
          left: NcSpace.gutter,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(NcRadius.float),
                boxShadow: p.menuShadow,
                border: p.cardOutline,
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (countryOn) ...[
                              Icon(LucideIcons.earth, size: 20, color: p.text),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(title, style: NcType.dialogTitle),
                            ),
                          ],
                        ),
                        if (countryOn && r != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            [
                              if (c.currentNetworkName != null)
                                c.currentNetworkName!,
                              networkSummary(r, checking: c.checkingNetwork),
                            ].join(' · '),
                            style: NcType.body.copyWith(color: p.muted),
                          ),
                        ],
                        if (r != null && !r.offline) ...[
                          const SizedBox(height: 10),
                          for (final MapEntry(key: group, value: (ok, total))
                              in r.byGroup.entries)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: StatusLine(
                                tone: switch (r.health(group)) {
                                  ServiceHealth.ok => Tone.success,
                                  ServiceHealth.partial => Tone.warning,
                                  ServiceHealth.down => Tone.danger,
                                },
                                text: switch (r.health(group)) {
                                  ServiceHealth.ok => '$group — открывается',
                                  ServiceHealth.partial =>
                                    '$group — частично, $ok из $total',
                                  ServiceHealth.down =>
                                    '$group — не открывается',
                                },
                              ),
                            ),
                        ],
                        if (guardLine != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: StatusLine(
                              tone: guardLine.$1,
                              text: guardLine.$2,
                            ),
                          ),
                        if (r != null && r.spoofed)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Провайдер подменяет ответы части сайтов — включите защищённый DNS.',
                              style: NcType.caption.copyWith(color: p.warning),
                            ),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          caption,
                          style: NcType.caption.copyWith(
                            color: p.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, thickness: 1, color: p.divider),
                  _MenuItem(
                    icon: LucideIcons.refreshCw,
                    label: 'Проверить сеть',
                    busy: c.checkingNetwork,
                    onTap: c.busy == null && !c.checkingNetwork
                        ? c.checkNetwork
                        : null,
                  ),
                  Divider(height: 1, thickness: 1, color: p.divider),
                  _MenuItem(
                    icon: LucideIcons.wandSparkles,
                    label: 'Подобрать стратегию',
                    onTap: c.install == null
                        ? null
                        : () => go(const AutoPickPage()),
                  ),
                  Divider(height: 1, thickness: 1, color: p.divider),
                  _MenuItem(
                    icon: LucideIcons.stethoscope,
                    label: 'Диагностика',
                    onTap: () => go(const DiagnosticsPage()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пункт меню: значок 20, текст 14 pt, поля 16 × 13.
class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Pressable(
      onTap: onTap,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        color: s.pressed
            ? p.hoverTint(pressed: true)
            : s.hovered
            ? p.hoverTint()
            : p.hoverTint().withValues(alpha: 0),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 20,
              child: busy
                  ? Padding(
                      padding: const EdgeInsets.all(2),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.text,
                      ),
                    )
                  : Icon(
                      icon,
                      size: 20,
                      color: onTap == null ? p.muted : p.text,
                    ),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: NcType.body.copyWith(
                color: onTap == null && !busy ? p.muted : p.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
