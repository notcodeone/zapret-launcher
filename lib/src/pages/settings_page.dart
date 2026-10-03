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

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final install = c.install;
    final idle = c.busy == null;
    // Пока zapret работает, переезд в другую папку — это перезапуск, а он без прав не выйдет.
    final canMove = idle && (c.elevated || !c.running);
    var i = 0;

    List<Widget> section(String title, Widget card) => [
      const SizedBox(height: 24),
      Appear(index: i, child: SectionTitle(title)),
      const SizedBox(height: 12),
      Appear(index: i++, child: card),
    ];

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
        Appear(index: i++, child: const PageTitle('Настройки')),
        ...section(
          'Лаунчер',
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
                      NcSegment(
                        ThemeMode.light,
                        'Светлая',
                        icon: LucideIcons.sun,
                      ),
                      NcSegment(
                        ThemeMode.dark,
                        'Тёмная',
                        icon: LucideIcons.moon,
                      ),
                    ],
                  ),
                ),
              ),
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
        ),
        ...section(
          'Zapret',
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
        ),
        ...section(
          'Сеть',
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
              NcSettingRow(
                title: 'Сети',
                description: c.profilesEnabled
                    ? (c.profiles.isEmpty
                          ? 'Своя стратегия для каждого провайдера — запомнится сама.'
                          : 'Запомнено: ${c.profiles.length}. Сейчас — ${c.currentNetworkName ?? 'сеть не определена'}.')
                    : 'Своя стратегия для каждого провайдера — выключено.',
                trailing: Icon(
                  LucideIcons.chevronRight,
                  size: 20,
                  color: p.muted,
                ),
                onTap: () => Navigator.of(
                  context,
                ).push(NcPageRoute<void>(builder: (_) => const NetworksPage())),
              ),
            ],
          ),
        ),
        ...section('Обновления', _UpdatesCard(controller: c)),
        const SizedBox(height: 24),
        Appear(
          index: i++,
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
                  child: Icon(LucideIcons.stethoscope, size: 20, color: p.text),
                ),
                title: 'Диагностика',
                description: 'Что мешает zapret: другие обходы, VPN, прокси, DNS, hosts.',
                trailing: Icon(
                  LucideIcons.chevronRight,
                  size: 20,
                  color: p.muted,
                ),
                onTap: () => Navigator.of(context).push(
                  NcPageRoute<void>(builder: (_) => const DiagnosticsPage()),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Appear(
          index: i++,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${AppInfo.name} — неофициальный лаунчер. Zapret и его стратегии делает Flowseal; '
                'встроенный zapret взят из его репозитория, обновления — тоже только оттуда.',
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
}
