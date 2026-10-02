import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../location/country.dart';
import '../location/network_guard.dart';
import '../settings.dart';
import '../ui/ui.dart';
import '../zapret/install.dart';
import '../zapret/network.dart';
import 'autopick_page.dart';
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
      header: appHeader(context, c, actions: [
        if (install != null) networkButton(context, c),
        NcIconButton(
          icon: LucideIcons.settings,
          tooltip: 'Настройки',
          badge: c.updateAvailable ? BadgeTone.pending : null,
          onPressed: () => Navigator.of(context)
              .push(NcPageRoute<void>(builder: (_) => const SettingsPage())),
        ),
      ]),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        ..._autoOffRow(c),
        ..._newNetworkRow(context, c),
        ..._blockedRow(context, c),
        Appear(
          index: i++,
          child: const PageTitle(
            'Обход блокировок',
            description: 'Discord и YouTube работают без VPN, пока включён zapret.',
          ),
        ),
        const SizedBox(height: 24),
        if (install == null)
          Appear(index: i++, child: _InstallCard(controller: c))
        else ...[
          Appear(index: i++, child: _StatusCard(controller: c)),
          const SizedBox(height: NcSpace.gapCards),
          Appear(
            index: i++,
            child: NcSettingsCard(children: [
              NcSettingRow(
                title: 'Стратегия',
                description: c.strategy == null
                    ? 'Нет ни одной стратегии'
                    : '«${c.strategy!.title}» — если сайты не открываются, попробуйте другую.',
                trailing: Icon(LucideIcons.chevronRight, size: 20, color: context.palette.muted),
                onTap: () => Navigator.of(context)
                    .push(NcPageRoute<void>(builder: (_) => const StrategiesPage())),
              ),
              NcSettingRow(
                title: 'Свои списки',
                description: _listsLine(c),
                below: c.listsChanged
                    ? const StatusLine(tone: Tone.warning, text: 'Нужен перезапуск')
                    : null,
                trailing: Icon(LucideIcons.chevronRight, size: 20, color: context.palette.muted),
                onTap: () => Navigator.of(context)
                    .push(NcPageRoute<void>(builder: (_) => const ListsPage())),
              ),
            ]),
          ),
          const SizedBox(height: NcSpace.gapCards),
          Appear(index: i++, child: _OptionsCard(controller: c)),
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
        onPressed: c.busy == null && c.elevated && c.strategy != null ? c.start : null,
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
      detail: 'Своей стратегии для неё нет — сейчас «${c.strategy?.title}» из прошлой сети. '
          'Крестик — оставить её для этой сети.',
      action: NcButton.gray(
        label: 'Подобрать',
        onPressed: () =>
            Navigator.of(context).push(NcPageRoute<void>(builder: (_) => const AutoPickPage())),
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
  if (r == null || !r.withZapret || !c.running || c.busy != null || r.offline) return const [];
  if (r.strategyTitle != null && r.strategyTitle != c.strategy?.title) return const [];
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
            Navigator.of(context).push(NcPageRoute<void>(builder: (_) => const AutoPickPage())),
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
      text = '${c.settings.zapretDir ?? 'Своя папка'} — её переместили или удалили. '
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
          onPressed: idle ? () => c.setZapretSource(ZapretSource.builtin) : null,
        ),
      ];
    } else if (bundled != null) {
      title = 'Zapret ещё не распакован';
      text = 'Zapret $bundled встроен в лаунчер — скачивать ничего не нужно. '
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
      text = 'Лаунчер скачает последнюю версию из репозитория автора — '
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

/// Главная карточка: работает ли zapret и кнопка включения.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final p = context.palette;
    final busyKind = c.busy?.kind;

    final (Tone tone, String status) = switch ((busyKind, c.running)) {
      ('start' || 'restart', _) => (Tone.info, 'Запускается'),
      ('stop', _) => (Tone.info, 'Останавливается'),
      (_, true) => (Tone.success, 'Работает'),
      _ => (Tone.neutral, 'Выключен'),
    };

    final String mode;
    if (c.running && c.runtime.serviceRunning) {
      mode = 'Служба Windows: включается вместе с системой.';
    } else if (c.running) {
      mode = 'Работает до перезагрузки, даже если закрыть лаунчер.';
    } else if (c.guard.autoOff != null) {
      mode = 'Выключен лаунчером — сменилась сеть.';
    } else if (c.autostart) {
      mode = 'Служба Windows установлена, но остановлена.';
    } else {
      mode = 'Сайты открываются как обычно — без обхода.';
    }

    return NcCard(
      child: Row(
        children: [
          AnimatedContainer(
            duration: NcMotion.icon,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.running ? p.success : p.field,
            ),
            child: Icon(
              c.running ? LucideIcons.shieldCheck : LucideIcons.shieldOff,
              size: 20,
              color: c.running ? Colors.white : p.muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Zapret', style: NcType.rowTitle),
                    StatusLine(tone: tone, text: status),
                  ],
                ),
                const SizedBox(height: 2),
                Text(mode, style: NcType.caption.copyWith(color: p.muted)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          NcButton(
            label: c.running ? 'Выключить' : 'Включить',
            icon: LucideIcons.power,
            loading: busyKind == 'start' || busyKind == 'stop' || busyKind == 'restart',
            onPressed: c.elevated && c.busy == null && c.strategy != null && !c.runningElsewhere
                ? c.toggle
                : null,
          ),
        ],
      ),
    );
  }
}

/// Настройки обхода: автозапуск, игровой фильтр, IPSet.
class _OptionsCard extends StatelessWidget {
  const _OptionsCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final enabled = c.elevated && c.busy == null;
    return NcSettingsCard(children: [
      NcSettingRow(
        title: 'Включать zapret вместе с Windows',
        description: 'Zapret работает как служба Windows и включается сам после перезагрузки.',
        trailing: NcSwitch(
          value: c.autostart,
          label: 'Включать zapret вместе с Windows',
          onChanged: enabled && !c.runningElsewhere ? c.setAutostart : null,
        ),
      ),
      NcSettingRow(
        title: 'Игровой фильтр',
        description: 'Обход и для игр: порты выше 1023. Если всё работает — не включайте.',
        below: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: NcSegmented<GameFilterMode>(
            value: c.gameFilter.mode,
            onChanged: enabled ? c.setGameFilterMode : null,
            segments: const [
              NcSegment(GameFilterMode.disabled, 'Выкл'),
              NcSegment(GameFilterMode.all, 'TCP и UDP'),
              NcSegment(GameFilterMode.tcp, 'TCP'),
              NcSegment(GameFilterMode.udp, 'UDP'),
            ],
          ),
        ),
      ),
      NcSettingRow(
        title: 'IPSet',
        description: 'Обходить блокировки не только по доменам, но и по адресам серверов.',
        below: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: NcSegmented<IpsetMode>(
            value: c.ipsetMode,
            onChanged: enabled ? c.setIpsetMode : null,
            segments: const [
              NcSegment(IpsetMode.none, 'Выкл'),
              NcSegment(IpsetMode.loaded, 'По списку'),
              NcSegment(IpsetMode.any, 'Все адреса'),
            ],
          ),
        ),
      ),
    ]);
  }
}
