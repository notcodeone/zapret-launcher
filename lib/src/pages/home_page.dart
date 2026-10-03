import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../location/country.dart';
import '../location/network_guard.dart';
import '../settings.dart';
import '../ui/ui.dart';
import '../zapret/network.dart';
import 'autopick_page.dart';
import 'bypass_options_page.dart';
import '../zapret/user_lists.dart';
import 'common.dart';
import 'lists_page.dart';
import 'network_menu.dart';
import 'settings_page.dart';
import 'strategies_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final install = c.install;
    var i = 0;

    return NcPage(
      header: appHeader(
        context,
        c,
        actions: [
          if (install != null) networkButton(context, c),
          NcIconButton(
            icon: LucideIcons.settings,
            tooltip: 'Настройки',
            badge: c.updateAvailable ? BadgeTone.pending : null,
            onPressed: () => Navigator.of(context)
                .push(NcPageRoute<void>(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c, admin: true),
        ..._autoOffRow(c),
        ..._newNetworkRow(context, c),
        ..._blockedRow(context, c),
        // Главное — состояние и одна кнопка; как именно обходить — на своих страницах.
        if (install == null)
          Appear(
            index: i++,
            child: _InstallCard(controller: c),
          )
        else ...[
          Appear(
            index: i++,
            child: _StatusCard(controller: c),
          ),
          const SizedBox(height: NcSpace.gapCards),
          Appear(
            index: i++,
            child: NcSettingsCard(
              children: [
                _NavRow(
                  icon: LucideIcons.slidersHorizontal,
                  title: 'Стратегия',
                  description: c.strategy == null
                      ? 'Нет ни одной стратегии'
                      : '«${c.strategy!.title}». Не открываются сайты — подберите другую.',
                  page: const StrategiesPage(),
                ),
                _NavRow(
                  icon: LucideIcons.listChecks,
                  title: 'Свои списки',
                  description: _listsLine(c),
                  below: c.listsChanged
                      ? const StatusLine(
                          tone: Tone.warning,
                          text: 'Нужен перезапуск',
                        )
                      : null,
                  page: const ListsPage(),
                ),
                _NavRow(
                  icon: LucideIcons.gamepad2,
                  title: 'Игровой фильтр и IPSet',
                  description: bypassOptionsLine(c),
                  page: const BypassOptionsPage(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Сторож сети выключил zapret сам — объясняем почему и даём включить вручную.
List<Widget> _autoOffRow(AppController c) {
  final off = c.guard.autoOff;
  if (off == null || c.running) return const [];
  final (title, detail) = switch (off.reason) {
    AutoOffReason.countryChanged => (
      'Zapret выключен: сменилась страна',
      '${off.from == null ? '' : countryName(off.from!)} → '
          '${off.to == null ? 'неизвестно' : countryName(off.to!)}: Discord и YouTube '
          'открываются и так. Включу снова, когда блокировки вернутся.',
    ),
    AutoOffReason.servicesOpen => (
      'Zapret выключен: обход не нужен',
      'В этой сети Discord и YouTube открываются и так. Включу снова, если блокировки вернутся.',
    ),
    AutoOffReason.profile => (
      'Zapret выключен: сеть «${off.network ?? 'эта'}»',
      'В профиле этой сети отмечено, что zapret не нужен. В другой сети включу снова.',
    ),
  };
  return [
    NoticeRow(
      kind: NoticeKind.info,
      icon: LucideIcons.globe,
      title: title,
      detail: detail,
      action: NcButton.gray(
        label: 'Включить',
        onPressed: c.busy == null && c.elevated && c.strategy != null
            ? c.start
            : null,
      ),
    ),
    const SizedBox(height: 24),
  ];
}

/// Новая сеть — своей стратегии для неё нет: подобрать или оставить как есть.
List<Widget> _newNetworkRow(BuildContext context, AppController c) {
  if (!c.isNewNetwork || c.busy != null) return const [];
  return [
    NoticeRow(
      kind: NoticeKind.decision,
      icon: LucideIcons.router,
      title: 'Новая сеть: ${c.currentNetworkName}',
      detail:
          'Своей стратегии для неё нет — сейчас «${c.strategy?.title}» из прошлой сети. '
          'Крестик — оставить её для этой сети.',
      action: NcButton.gray(
        label: 'Подобрать',
        onPressed: () =>
            Navigator.of(context)
                .push(NcPageRoute<void>(builder: (_) => const AutoPickPage())),
      ),
      onClose: c.rememberCurrentNetwork,
    ),
    const SizedBox(height: 24),
  ];
}

String _listsLine(AppController c) {
  final bypass = c.userList(UserListKind.bypass).entries.length;
  final exclude = c.userList(UserListKind.exclude).entries.length;
  if (bypass == 0 && exclude == 0) return 'Свои сайты для обхода и исключения.';
  return [
    if (bypass > 0) 'обходить — $bypass',
    if (exclude > 0) 'не трогать — $exclude',
  ].join(', ').replaceFirstMapped(RegExp('^.'), (m) => m[0]!.toUpperCase());
}

/// zapret включён, а Discord или YouTube не открываются — стоит сменить стратегию.
List<Widget> _blockedRow(BuildContext context, AppController c) {
  final r = c.network;
  if (r == null || !r.withZapret || !c.running || c.busy != null || r.offline) {
    return const [];
  }
  if (r.strategyTitle != null && r.strategyTitle != c.strategy?.title) {
    return const [];
  }
  final bad = [
    for (final g in const ['Discord', 'YouTube'])
      if (r.byGroup.containsKey(g) && r.health(g) != ServiceHealth.ok) g,
  ];
  if (bad.isEmpty) return const [];
  return [
    NoticeRow(
      kind: NoticeKind.decision,
      title: bad.length == 1
          ? '${bad.single} не открывается с «${r.strategyTitle}»'
          : 'Discord и YouTube не открываются с «${r.strategyTitle}»',
      detail: 'Подберите другую стратегию — лаунчер проверит все по очереди.',
      action: NcButton.gray(
        label: 'Подобрать',
        onPressed: () =>
            Navigator.of(context)
                .push(NcPageRoute<void>(builder: (_) => const AutoPickPage())),
      ),
    ),
    const SizedBox(height: 24),
  ];
}

/// zapret ещё не готов: распаковать встроенный, скачать или указать папку.
/// Встроенный распаковывается сам при запуске — карточка видна, только если не вышло.
class _InstallCard extends StatelessWidget {
  const _InstallCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final p = context.palette;
    final idle = c.busy == null;
    final installing = c.busy?.kind == 'download' || c.busy?.kind == 'install';
    final bundled = c.bundledVersion;

    final String title;
    final String text;
    final List<Widget> buttons;
    if (!c.builtin) {
      title = 'Папка zapret не найдена';
      text =
          '${c.settings.zapretDir ?? 'Своя папка'} — её переместили или удалили. '
          'Укажите папку заново или вернитесь к встроенному zapret.';
      buttons = [
        NcButton(
          label: 'Указать папку',
          icon: LucideIcons.folderOpen,
          onPressed: idle ? c.chooseFolder : null,
        ),
        NcButton.secondary(
          label: 'Встроенный zapret',
          icon: LucideIcons.package,
          loading: installing,
          onPressed: idle
              ? () => c.setZapretSource(ZapretSource.builtin)
              : null,
        ),
      ];
    } else if (bundled != null) {
      title = 'Zapret ещё не распакован';
      text =
          'Zapret $bundled встроен в лаунчер — скачивать ничего не нужно. '
          'Если zapret уже есть на компьютере, можно указать его папку.';
      buttons = [
        NcButton(
          label: 'Распаковать zapret $bundled',
          icon: LucideIcons.packageOpen,
          loading: installing,
          onPressed: idle ? c.installBundled : null,
        ),
        NcButton.secondary(
          label: 'Указать папку',
          icon: LucideIcons.folderOpen,
          onPressed: idle ? c.chooseFolder : null,
        ),
      ];
    } else {
      // Сборка без встроенного zapret (из исходников без tool/fetch_zapret.ps1).
      final version = c.latest?.version;
      title = 'Zapret не установлен';
      text =
          'Лаунчер скачает последнюю версию из репозитория автора — '
          'Flowseal/zapret-discord-youtube на GitHub. '
          'Если zapret уже есть на компьютере, укажите его папку.';
      buttons = [
        NcButton(
          label: version == null ? 'Скачать zapret' : 'Скачать zapret $version',
          icon: LucideIcons.download,
          loading: installing,
          onPressed: idle ? c.installLatest : null,
        ),
        NcButton.secondary(
          label: 'Указать папку',
          icon: LucideIcons.folderOpen,
          onPressed: idle ? c.chooseFolder : null,
        ),
      ];
    }

    return NcCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: NcType.rowTitle),
          const SizedBox(height: 4),
          Text(text, style: NcType.caption.copyWith(color: p.muted)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: buttons),
        ],
      ),
    );
  }
}

/// Главная карточка: состояние zapret крупно и одна большая кнопка.
/// Как запускать (службой или как general.bat) — в настройках.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final p = context.palette;
    final busyKind = c.busy?.kind;
    final starting = busyKind == 'start' || busyKind == 'restart';
    final stopping = busyKind == 'stop';
    final title = c.strategy == null ? '' : '«${c.strategy!.title}»';

    final String headline;
    final String mode;
    if (starting) {
      headline = 'Zapret запускается';
      mode = 'Стратегия $title.';
    } else if (stopping) {
      headline = 'Zapret выключается';
      mode = 'Сайты снова пойдут без обхода.';
    } else if (c.running) {
      headline = 'Zapret работает';
      mode = c.runtime.serviceRunning
          ? 'Стратегия $title. Служба Windows — включится и после перезагрузки.'
          : 'Стратегия $title. До перезагрузки, даже если закрыть лаунчер.';
    } else {
      headline = 'Zapret выключен';
      if (c.guard.autoOff != null) {
        mode = 'Выключен лаунчером: в этой сети обход не нужен.';
      } else if (c.autostart) {
        mode = 'Служба Windows: включится сам после перезагрузки.';
      } else {
        mode = 'Включите — Discord и YouTube откроются без VPN.';
      }
    }
    final on = c.running && !stopping;

    return NcCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NcSpace.cardPad,
              20,
              NcSpace.cardPad,
              NcSpace.cardPad,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    AnimatedContainer(
                      duration: NcMotion.icon,
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: on ? p.success : p.field,
                      ),
                      child: Icon(
                        on ? LucideIcons.shieldCheck : LucideIcons.shieldOff,
                        size: 24,
                        color: on ? Colors.white : p.muted,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(headline, style: NcType.section),
                          const SizedBox(height: 2),
                          Text(
                            mode,
                            style: NcType.caption.copyWith(color: p.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                NcButton(
                  kind: c.running ? NcButtonKind.gray : NcButtonKind.primary,
                  label: c.running ? 'Выключить' : 'Включить',
                  icon: LucideIcons.power,
                  large: true,
                  expand: true,
                  loading: starting || stopping,
                  onPressed:
                      c.elevated &&
                          c.busy == null &&
                          c.strategy != null &&
                          !c.runningElsewhere
                      ? () => _toggle(context, c)
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Первое включение — сначала спросим, как запускать zapret.
  static Future<void> _toggle(BuildContext context, AppController c) async {
    if (c.running || !c.needsRunModeChoice) return c.toggle();
    final service = await showRunModeDialog(context);
    if (service != null) await c.startFirstTime(service: service);
  }
}

/// Как запускать zapret: как general.bat (процессом до перезагрузки) или службой
/// Windows. true — службой; null — передумали.
Future<bool?> showRunModeDialog(BuildContext context) {
  var service = false;
  return showNcModal<bool>(
    context,
    label: 'Как запускать zapret',
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => NcDialogFrame(
        title: 'Как запускать zapret?',
        actions: [
          NcDialogButton(
            label: 'Отмена',
            kind: NcDialogButtonKind.cancel,
            onPressed: () => Navigator.of(context).pop(),
          ),
          NcDialogButton(
            label: 'Включить',
            onPressed: () => Navigator.of(context).pop(service),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Поменять можно потом в настройках.',
              style: NcType.body.copyWith(color: context.palette.muted),
            ),
            const SizedBox(height: 16),
            _RunModeOption(
              icon: LucideIcons.squareTerminal,
              title: 'Как general.bat',
              text: 'Работает до перезагрузки. Потом включите снова — здесь или из трея.',
              selected: !service,
              onTap: () => setState(() => service = false),
            ),
            const SizedBox(height: 8),
            _RunModeOption(
              icon: LucideIcons.serverCog,
              title: 'Службой Windows',
              text:
                  'Включается вместе с Windows и работает даже без лаунчера — '
                  'как установка службы в service.bat.',
              selected: service,
              onTap: () => setState(() => service = true),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Вариант в диалоге выбора: значок, название, пояснение; выбранный — в рамке.
class _RunModeOption extends StatelessWidget {
  const _RunModeOption({
    required this.icon,
    required this.title,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Pressable(
      onTap: onTap,
      semanticLabel: title,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected || s.hovered ? p.field : p.field.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(NcRadius.control),
          border: Border.all(
            color: selected || s.focused ? p.primary : p.divider,
            width: selected || s.focused ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: p.text),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: NcType.rowTitle),
                  const SizedBox(height: 2),
                  Text(text, style: NcType.caption.copyWith(color: p.muted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected ? LucideIcons.circleCheck : LucideIcons.circle,
              size: 20,
              color: selected ? p.text : p.muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка-переход на страницу: значок в круге, пояснение и стрелка.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.page,
    this.below,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget page;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return NcSettingRow(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(shape: BoxShape.circle, color: p.field),
        child: Icon(icon, size: 18, color: p.text),
      ),
      title: title,
      description: description,
      below: below,
      trailing: Icon(LucideIcons.chevronRight, size: 20, color: p.muted),
      onTap: () =>
          Navigator.of(context).push(NcPageRoute<void>(builder: (_) => page)),
    );
  }
}
