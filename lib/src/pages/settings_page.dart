import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_info.dart';
import '../controller.dart';
import '../platform/win32.dart' as win;
import '../settings.dart';
import '../ui/ui.dart';
import '../zapret/releases.dart';
import 'common.dart';
import 'diagnostics_page.dart';
import 'networks_page.dart';

/// Тихая кнопка под пояснением строки: текст кнопки стоит на одной линии с пояснением.
Widget _inlineAction(String label, VoidCallback? onPressed) =>
    Transform.translate(
      offset: const Offset(-6, 0),
      child: NcQuietButton(label: label, onPressed: onPressed),
    );

/// Автозапуск самого лаунчера — задача Планировщика заданий.
Widget _launcherAutostartRow(AppController c) {
  final state = c.launcherAutostart;
  final on = state?.registered ?? false;
  final elsewhere =
      on && state!.command != null && !state.matches(c.launcherPath);
  return NcSettingRow(
    title: 'Открывать при входе в Windows',
    description: 'Свёрнутым в трей и без запроса прав — сторож и профили сетей работают сразу.',
    below: elsewhere
        ? StatusLine(
            tone: Tone.warning,
            text: 'Задача запускает другой файл: ${state.command}',
          )
        : !c.elevated
        ? const StatusLine(
            tone: Tone.neutral,
            text: 'Включается с правами администратора',
          )
        : null,
    trailing: elsewhere
        ? NcButton.gray(
            label: 'Исправить',
            onPressed: c.busy == null && c.elevated
                ? () => c.setLauncherAutostart(true)
                : null,
          )
        : NcSwitch(
            value: on,
            label: 'Открывать при входе в Windows',
            onChanged: state != null && c.elevated && c.busy == null
                ? c.setLauncherAutostart
                : null,
          ),
  );
}

/// Обновления: версии лаунчера и zapret рядом, у каждой — своя проверка.
class _UpdatesCard extends StatelessWidget {
  const _UpdatesCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final idle = c.busy == null;

    final String launcherLine;
    if (c.launcherUpdateAvailable) {
      launcherLine =
          'Установлена ${AppInfo.version}, вышла ${c.launcherLatest!.version}';
    } else if (c.launcherNoReleases) {
      launcherLine = 'Версия ${AppInfo.version}. Выпусков на GitHub пока нет';
    } else if (c.launcherLatest != null) {
      launcherLine = 'Версия ${AppInfo.version} — последняя';
    } else {
      launcherLine = 'Версия ${AppInfo.version}';
    }

    final install = c.install;
    final newest = c.newestZapretVersion;
    final String zapretLine;
    if (install == null) {
      zapretLine = 'Не установлен';
    } else if (c.updateAvailable) {
      zapretLine = 'Установлена ${install.version ?? '—'}, есть $newest';
    } else if (c.latest != null) {
      zapretLine = 'Версия ${install.version ?? '—'} — последняя';
    } else {
      zapretLine = 'Версия ${install.version ?? '—'}';
    }
    final previous = c.previousZapretVersion;
    final skipped =
        c.updateAvailable && newest == c.settings.skippedZapretVersion;

    return NcSettingsCard(
      children: [
        NcSettingRow(
          title: AppInfo.name,
          description: launcherLine,
          below: c.launcherUpdateAvailable
              ? _inlineAction('Что нового', c.openLauncherReleasePage)
              : null,
          trailing: c.launcherUpdateAvailable
              ? NcButton.gray(
                  label: 'Обновить до ${c.launcherLatest!.version}',
                  loading: c.busy?.kind == 'launcher',
                  onPressed: idle ? c.updateLauncher : null,
                )
              : NcButton.gray(
                  label: 'Проверить',
                  loading: c.checkingLauncher,
                  onPressed: idle ? () => c.checkLauncherUpdate() : null,
                ),
        ),
        NcSettingRow(
          title: 'Zapret',
          description: zapretLine,
          below: skipped
              ? StatusLine(
                  tone: Tone.warning,
                  text: 'С $newest обход не работал — сам её не ставлю',
                )
              : previous != null
              ? _inlineAction(
                  'Вернуть прежнюю — $previous',
                  idle && c.elevated ? () => c.rollbackZapret() : null,
                )
              : null,
          trailing: c.updateAvailable
              ? NcButton.gray(
                  label: 'Обновить до $newest',
                  loading:
                      c.busy?.kind == 'download' || c.busy?.kind == 'install',
                  onPressed: idle && c.elevated ? () => c.updateZapret() : null,
                )
              : NcButton.gray(
                  label: 'Проверить',
                  loading: c.checkingUpdates,
                  onPressed: idle ? () => c.checkUpdates() : null,
                ),
        ),
        NcSettingRow(
          title: 'Проверять обновления',
          description: 'Раз в 6 часов — и лаунчер, и zapret.',
          trailing: NcSwitch(
            value: c.settings.autoCheckUpdates,
            label: 'Проверять обновления',
            onChanged: c.setAutoCheckUpdates,
          ),
        ),
        NcSettingRow(
          title: 'Автообновление zapret',
          description: 'Если с новой версией сайты перестанут открываться — вернёт прежнюю.',
          below: !c.settings.autoUpdateZapret
              ? null
              : !c.builtin
              ? const StatusLine(
                  tone: Tone.neutral,
                  text: 'Только встроенный — своя папка не обновляется сама',
                )
              : !c.settings.autoCheckUpdates
              ? const StatusLine(
                  tone: Tone.neutral,
                  text: 'Работает, когда включена проверка обновлений',
                )
              : null,
          trailing: NcSwitch(
            value: c.settings.autoUpdateZapret,
            label: 'Автообновление zapret',
            onChanged: c.setAutoUpdateZapret,
          ),
        ),
      ],
    );
  }
}

/// Разделы настроек — как в ClaudeLauncher: короткий список, за ним — страница
/// раздела. Значок и название перелетают из строки списка в заголовок страницы.
enum SettingsSection {
  general('Основные', LucideIcons.settings2),
  zapret('Zapret', LucideIcons.zap),
  network('Сеть', LucideIcons.globe),
  updates('Обновления', LucideIcons.refreshCw);

  const SettingsSection(this.title, this.icon);

  final String title;
  final IconData icon;
}

/// Список разделов; под каждым — коротко, что в нём сейчас.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;

    void open(Widget page) =>
        Navigator.of(context).push(NcPageRoute<void>(builder: (_) => page));

    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Настройки',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        const Appear(index: 0, child: PageTitle('Настройки')),
        const SizedBox(height: 24),
        Appear(
          index: 1,
          child: NcSettingsCard(
            children: [
              for (final s in SettingsSection.values)
                _SectionRow(
                  icon: _SectionIcon(section: s),
                  title: _SectionTitle(section: s),
                  summary: _summary(c, s),
                  attention:
                      s == SettingsSection.updates &&
                      (c.launcherUpdateAvailable || c.updateAvailable),
                  onTap: () => open(SettingsSectionPage(section: s)),
                ),
            ],
          ),
        ),
        const SizedBox(height: NcSpace.gapCards),
        Appear(
          index: 2,
          child: NcSettingsCard(
            children: [
              _SectionRow(
                icon: Icon(LucideIcons.stethoscope, size: 22, color: p.text),
                title: const Text('Диагностика', style: NcType.rowTitle),
                summary: 'Что мешает zapret: другие обходы, VPN, прокси, DNS.',
                onTap: () => open(const DiagnosticsPage()),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Appear(
          index: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${AppInfo.name} — неофициальный лаунчер. Zapret и его стратегии '
                'делает Flowseal; встроенный zapret взят из его репозитория, '
                'обновления — тоже только оттуда.',
                style: NcType.caption.copyWith(color: p.muted),
              ),
              const SizedBox(height: 4),
              _inlineAction(
                'github.com/$zapretRepo',
                () => win.shellExecute('https://github.com/$zapretRepo'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Подпись раздела в списке — его состояние одной строкой.
  static String _summary(AppController c, SettingsSection s) {
    switch (s) {
      case SettingsSection.general:
        return 'Тема, открытие при входе в Windows, трей';
      case SettingsSection.zapret:
        return [
          c.builtin ? 'Встроенный' : 'Своя папка',
          ?c.install?.version,
          c.autostart ? '· службой Windows' : '· как general.bat',
        ].join(' ');
      case SettingsSection.network:
        if (!c.settings.networkGuard) return 'Слежение за сетью выключено';
        final country = c.settings.countryCheck ? c.guard.countryLabel : null;
        return country == null
            ? 'Слежу за сетью'
            : 'Слежу за сетью · сейчас $country';
      case SettingsSection.updates:
        if (c.launcherUpdateAvailable) {
          return 'Вышел ${AppInfo.name} ${c.launcherLatest!.version}';
        }
        if (c.updateAvailable) return 'Есть zapret ${c.newestZapretVersion}';
        if (!c.settings.autoCheckUpdates) {
          return 'Версия ${AppInfo.version}, проверка выключена';
        }
        if (c.launcherLatest != null) {
          return 'Версия ${AppInfo.version} — последняя';
        }
        return 'Версия ${AppInfo.version} и проверка новых';
    }
  }
}

/// Строка раздела: значок, название и подпись, стрелка.
class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.icon,
    required this.title,
    required this.summary,
    required this.onTap,
    this.attention = false,
  });

  final Widget icon;
  final Widget title;
  final String summary;
  final VoidCallback onTap;

  /// Подпись — оранжевым: есть обновление.
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Pressable(
      onTap: onTap,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        color: s.pressed
            ? p.hoverTint(pressed: true)
            : s.hovered
            ? p.hoverTint()
            : p.hoverTint().withValues(alpha: 0),
        padding: const EdgeInsets.fromLTRB(NcSpace.cardPad, 14, 12, 14),
        child: Row(
          children: [
            SizedBox(width: 28, child: Center(child: icon)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: 2),
                  Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NcType.caption.copyWith(
                      color: attention ? p.warning : p.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(LucideIcons.chevronRight, size: 20, color: p.muted),
          ],
        ),
      ),
    );
  }
}

/// Значок раздела: 0 — в строке списка, 1 — в заголовке страницы.
class _SectionIcon extends StatelessWidget {
  const _SectionIcon({required this.section, this.t = 0});

  final SettingsSection section;
  final double t;

  @override
  Widget build(BuildContext context) => _LerpHero(
    tag: 'settings-icon-${section.name}',
    t: t,
    builder: (t, color) => Icon(section.icon, size: 22 + 6 * t, color: color),
  );
}

/// Название раздела: 0 — в строке списка (15 pt 600), 1 — в заголовке страницы (30 pt 700).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.section, this.t = 0});

  final SettingsSection section;
  final double t;

  @override
  Widget build(BuildContext context) => _LerpHero(
    tag: 'settings-title-${section.name}',
    t: t,
    builder: (t, color) => Text(
      section.title,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      style: TextStyle.lerp(
        NcType.rowTitle,
        NcType.pageTitle,
        t,
      )!.copyWith(color: color),
    ),
  );
}

/// Hero, который в полёте плавно меняется от строки списка (0) к заголовку
/// страницы (1): размер шрифта и значка.
class _LerpHero extends StatelessWidget {
  const _LerpHero({required this.tag, required this.t, required this.builder});

  final String tag;
  final double t;
  final Widget Function(double t, Color color) builder;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hero(
      tag: tag,
      flightShuttleBuilder: (_, animation, _, _, _) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeInOutCubic,
        );
        return AnimatedBuilder(
          animation: curved,
          // Рамка Hero в полёте меняется не в такт шрифту — вписываем.
          builder: (context, _) => Material(
            type: MaterialType.transparency,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: builder(curved.value, p.text),
            ),
          ),
        );
      },
      child: Material(
        type: MaterialType.transparency,
        child: builder(t, p.text),
      ),
    );
  }
}

/// Страница раздела: значок с названием и карточки раздела.
class SettingsSectionPage extends StatelessWidget {
  const SettingsSectionPage({super.key, required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final cards = switch (section) {
      SettingsSection.general => _general(c),
      SettingsSection.zapret => _zapret(c),
      SettingsSection.network => _network(context, c),
      SettingsSection.updates => [_UpdatesCard(controller: c)],
    };
    return NcPage(
      header: appHeader(
        context,
        c,
        title: section.title,
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        Row(
          children: [
            _SectionIcon(section: section, t: 1),
            const SizedBox(width: 12),
            Flexible(child: _SectionTitle(section: section, t: 1)),
          ],
        ),
        for (final (i, card) in cards.indexed) ...[
          SizedBox(height: i == 0 ? 24 : NcSpace.gapCards),
          Appear(index: i + 1, child: card),
        ],
      ],
    );
  }

  // ── Основные ──

  List<Widget> _general(AppController c) => [
    NcSettingsCard(
      children: [
        NcSettingRow(
          title: 'Тема',
          below: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: NcSegmented<ThemeMode>(
              value: c.themeMode,
              onChanged: c.setThemeMode,
              segments: const [
                NcSegment(
                  ThemeMode.system,
                  'Как в системе',
                  icon: LucideIcons.monitor,
                ),
                NcSegment(ThemeMode.light, 'Светлая', icon: LucideIcons.sun),
                NcSegment(ThemeMode.dark, 'Тёмная', icon: LucideIcons.moon),
              ],
            ),
          ),
        ),
      ],
    ),
    NcSettingsCard(
      children: [
        _launcherAutostartRow(c),
        NcSettingRow(
          title: 'Сворачивать в трей',
          description: 'Крестик прячет окно, а не закрывает лаунчер.',
          trailing: NcSwitch(
            value: c.settings.closeToTray,
            label: 'Сворачивать в трей',
            onChanged: c.setCloseToTray,
          ),
        ),
      ],
    ),
  ];

  // ── Zapret ──

  List<Widget> _zapret(AppController c) {
    final install = c.install;
    final idle = c.busy == null;
    // Пока zapret работает, переезд в другую папку — это перезапуск, а он без прав не выйдет.
    final canMove = idle && (c.elevated || !c.running);
    return [
      NcSettingsCard(
        children: [
          NcSettingRow(
            title: 'Как запускать',
            description: c.autostart
                ? 'Службой Windows — включается вместе с системой и работает без лаунчера.'
                : 'Как general.bat — работает до перезагрузки.',
            below: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: NcSegmented<bool>(
                    value: c.autostart,
                    onChanged:
                        c.elevated &&
                            idle &&
                            install != null &&
                            !c.runningElsewhere
                        ? c.setAutostart
                        : null,
                    segments: const [
                      NcSegment(
                        false,
                        'Как general.bat',
                        icon: LucideIcons.squareTerminal,
                      ),
                      NcSegment(
                        true,
                        'Службой Windows',
                        icon: LucideIcons.serverCog,
                      ),
                    ],
                  ),
                ),
                if (!c.elevated) ...[
                  const SizedBox(height: 6),
                  const StatusLine(
                    tone: Tone.neutral,
                    text: 'Меняется с правами администратора',
                  ),
                ],
              ],
            ),
          ),
          NcSettingRow(
            title: 'Следить за zapret',
            description: 'Закрылся winws.exe — лаунчер запустит его снова.',
            trailing: NcSwitch(
              value: c.settings.watchdog,
              label: 'Следить за zapret',
              onChanged: c.setWatchdog,
            ),
          ),
        ],
      ),
      NcSettingsCard(
        children: [
          NcSettingRow(
            title: 'Откуда zapret',
            description: c.builtin
                ? 'Встроенный — идёт с лаунчером и обновляется сам.'
                : 'Своя папка — запускается как есть и сама не обновляется.',
            below: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: NcSegmented<ZapretSource>(
                value: c.zapretSource,
                onChanged: canMove ? c.setZapretSource : null,
                segments: const [
                  NcSegment(
                    ZapretSource.builtin,
                    'Встроенный',
                    icon: LucideIcons.package,
                  ),
                  NcSegment(
                    ZapretSource.custom,
                    'Своя папка',
                    icon: LucideIcons.folderOpen,
                  ),
                ],
              ),
            ),
          ),
          NcSettingRow(
            title: 'Папка',
            description:
                install?.root.path ??
                (c.builtin
                    ? c.builtinZapretDir
                    : c.settings.zapretDir ?? 'Не выбрана'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (install != null)
                  NcIconButton(
                    icon: LucideIcons.externalLink,
                    tooltip: 'Открыть папку',
                    onPressed: c.openZapretFolder,
                  ),
                // Папку встроенного выбирает лаунчер; своя — меняется.
                if (!c.builtin) ...[
                  const SizedBox(width: 4),
                  NcButton.gray(
                    label: 'Изменить',
                    onPressed: canMove ? c.chooseFolder : null,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ];
  }

  // ── Сеть ──

  List<Widget> _network(BuildContext context, AppController c) {
    final p = context.palette;
    return [
      NcSettingsCard(
        children: [
          NcSettingRow(
            title: 'Следить за сетью',
            description:
                'В новой сети проверит, нужен ли обход: выключит zapret, если сайты '
                'открываются и так (например, с VPN), и включит, когда блокировки вернутся.',
            below: c.settings.networkGuard && !c.elevated
                ? const StatusLine(
                    tone: Tone.neutral,
                    text: 'Работает с правами администратора',
                  )
                : null,
            trailing: NcSwitch(
              value: c.settings.networkGuard,
              label: 'Следить за сетью',
              onChanged: c.setNetworkGuard,
            ),
          ),
          NcSettingRow(
            title: 'Определять страну',
            description: 'По IP через country.is, Cloudflare и ipwho.is.',
            below: c.settings.countryCheck && c.guard.countryLabel != null
                ? StatusLine(
                    tone: Tone.neutral,
                    text: 'Сейчас: ${c.guard.countryLabel}',
                  )
                : null,
            trailing: NcSwitch(
              value: c.settings.countryCheck,
              label: 'Определять страну',
              onChanged: c.setCountryCheck,
            ),
          ),
        ],
      ),
      NcSettingsCard(
        children: [
          NcSettingRow(
            title: 'Сети',
            description: c.profilesEnabled
                ? (c.profiles.isEmpty
                      ? 'Своя стратегия для каждого провайдера — запомнится сама.'
                      : 'Запомнено: ${c.profiles.length}. Сейчас — ${c.currentNetworkName ?? 'сеть не определена'}.')
                : 'Своя стратегия для каждого провайдера — выключено.',
            trailing: Icon(LucideIcons.chevronRight, size: 20, color: p.muted),
            onTap: () => Navigator.of(context)
                .push(NcPageRoute<void>(builder: (_) => const NetworksPage())),
          ),
        ],
      ),
    ];
  }
}
