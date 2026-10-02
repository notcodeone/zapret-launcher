import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_info.dart';
import '../controller.dart';
import '../ui/ui.dart';
import '../zapret/releases.dart';
import 'common.dart';
import 'diagnostics_page.dart';
import 'networks_page.dart';

/// Автозапуск самого лаунчера — задача Планировщика заданий.
Widget _launcherAutostartRow(AppController c) {
  final state = c.launcherAutostart;
  final on = state?.registered ?? false;
  final elsewhere = on && state!.command != null && !state.matches(c.launcherPath);
  return NcSettingRow(
    title: 'Открывать при входе в Windows',
    description: 'Лаунчер запустится свёрнутым в трей — без запроса прав, через Планировщик заданий. '
        'Тогда сторож и профили сетей работают сразу после входа.',
    below: elsewhere
        ? StatusLine(tone: Tone.warning, text: 'Задача запускает другой файл: ${state.command}')
        : !c.elevated
            ? const StatusLine(tone: Tone.neutral, text: 'Включается с правами администратора')
            : null,
    trailing: elsewhere
        ? NcButton.gray(
            label: 'Исправить',
            onPressed: c.busy == null && c.elevated ? () => c.setLauncherAutostart(true) : null,
          )
        : NcSwitch(
            value: on,
            label: 'Открывать при входе в Windows',
            onChanged: state != null && c.elevated && c.busy == null ? c.setLauncherAutostart : null,
          ),
  );
}

/// Обновления лаунчера и zapret.
class _UpdatesCard extends StatelessWidget {
  const _UpdatesCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final idle = c.busy == null;
    final String launcherLine;
    if (c.launcherUpdateAvailable) {
      launcherLine = 'Установлена ${AppInfo.version}, вышла ${c.launcherLatest!.version}';
    } else if (c.launcherNoReleases) {
      launcherLine = 'Версия ${AppInfo.version}. Релизов на GitHub пока нет';
    } else if (c.launcherLatest != null) {
      launcherLine = 'Версия ${AppInfo.version} — последняя';
    } else {
      launcherLine = 'Версия ${AppInfo.version}';
    }
    return NcSettingsCard(children: [
      NcSettingRow(
        title: AppInfo.name,
        description: launcherLine,
        below: c.launcherUpdateAvailable
            ? Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const StatusLine(tone: Tone.warning, text: 'Есть обновление'),
                  NcQuietButton(label: 'Что нового', onPressed: c.openLauncherReleasePage),
                ],
              )
            : null,
        trailing: c.launcherUpdateAvailable
            ? NcButton.gray(
                label: 'Обновить до ${c.launcherLatest!.version}',
                loading: c.busy?.kind == 'launcher',
                onPressed: idle ? c.updateLauncher : null,
              )
            : NcButton.gray(
                label: 'Проверить',
                loading: c.checkingLauncher || c.checkingUpdates,
                onPressed: idle ? c.checkAllUpdates : null,
              ),
      ),
      NcSettingRow(
        title: 'Проверять обновления',
        description: 'Раз в 6 часов спрашивать, вышли ли новые версии лаунчера и zapret.',
        trailing: NcSwitch(
          value: c.settings.autoCheckUpdates,
          label: 'Проверять обновления',
          onChanged: c.setAutoCheckUpdates,
        ),
      ),
      NcSettingRow(
        title: 'Обновлять zapret сам',
        description: 'Новая версия zapret ставится сама. Если с ней Discord или YouTube перестанут '
            'открываться — лаунчер вернёт прежнюю и эту больше не поставит.',
        below: c.settings.autoUpdateZapret && !c.settings.autoCheckUpdates
            ? const StatusLine(tone: Tone.neutral, text: 'Работает, когда включена проверка обновлений')
            : null,
        trailing: NcSwitch(
          value: c.settings.autoUpdateZapret,
          label: 'Обновлять zapret сам',
          onChanged: c.setAutoUpdateZapret,
        ),
      ),
    ]);
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

    final String versionLine;
    if (install == null) {
      versionLine = 'Не установлен';
    } else if (c.updateAvailable) {
      versionLine = 'Установлен ${install.version ?? '—'}, вышел ${c.latest!.version}';
    } else if (c.latest != null) {
      versionLine = 'Установлен ${install.version ?? '—'} — последняя версия';
    } else {
      versionLine = 'Установлен ${install.version ?? '—'}';
    }

    return NcPage(
      header: appHeader(context, c, title: 'Настройки', onBack: () => Navigator.of(context).pop()),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        const Appear(index: 0, child: PageTitle('Настройки')),
        const SizedBox(height: 24),
        Appear(
          index: 1,
          child: NcSettingsCard(children: [
            NcSettingRow(
              title: 'Тема',
              below: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: NcSegmented<ThemeMode>(
                  value: c.themeMode,
                  onChanged: c.setThemeMode,
                  segments: const [
                    NcSegment(ThemeMode.system, 'Как в системе', icon: LucideIcons.monitor),
                    NcSegment(ThemeMode.light, 'Светлая', icon: LucideIcons.sun),
                    NcSegment(ThemeMode.dark, 'Тёмная', icon: LucideIcons.moon),
                  ],
                ),
              ),
            ),
            _launcherAutostartRow(c),
            NcSettingRow(
              title: 'Сворачивать в трей',
              description: 'Крестик прячет окно, а лаунчер остаётся в трее и следит за zapret.',
              trailing: NcSwitch(
                value: c.settings.closeToTray,
                label: 'Сворачивать в трей',
                onChanged: c.setCloseToTray,
              ),
            ),
            NcSettingRow(
              title: 'Следить за zapret',
              description: 'Если winws.exe закроется сам, лаунчер запустит его снова. '
                  'Служба Windows перезапускается сама, даже без лаунчера.',
              trailing: NcSwitch(
                value: c.settings.watchdog,
                label: 'Следить за zapret',
                onChanged: c.setWatchdog,
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        const Appear(index: 2, child: SectionTitle('Сеть')),
        const SizedBox(height: 12),
        Appear(
          index: 2,
          child: NcSettingsCard(children: [
            NcSettingRow(
              title: 'Следить за сетью',
              description: 'Сменилась сеть или страна — лаунчер проверит, нужен ли обход. '
                  'Выключит zapret, если сайты открываются и так (например, включили VPN), '
                  'и включит снова, когда блокировки вернутся.',
              below: c.settings.networkGuard && !c.elevated
                  ? const StatusLine(tone: Tone.neutral, text: 'Работает с правами администратора')
                  : null,
              trailing: NcSwitch(
                value: c.settings.networkGuard,
                label: 'Следить за сетью',
                onChanged: c.setNetworkGuard,
              ),
            ),
            NcSettingRow(
              title: 'Определять страну',
              description: 'По IP-адресу через открытые сервисы: country.is, Cloudflare, ipwho.is. '
                  'Без страны лаунчер судит только по тому, открываются ли сайты.',
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
              trailing: Icon(LucideIcons.chevronRight, size: 20, color: p.muted),
              onTap: () => Navigator.of(context)
                  .push(NcPageRoute<void>(builder: (_) => const NetworksPage())),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        const Appear(index: 2, child: SectionTitle('Обновления')),
        const SizedBox(height: 12),
        Appear(index: 2, child: _UpdatesCard(controller: c)),
        const SizedBox(height: 16),
        const Appear(index: 2, child: SectionTitle('Zapret')),
        const SizedBox(height: 12),
        Appear(
          index: 3,
          child: NcSettingsCard(children: [
            NcSettingRow(
              title: 'Версия',
              description: versionLine,
              below: c.updateAvailable
                  ? StatusLine(
                      tone: Tone.warning,
                      text: c.latest!.version == c.settings.skippedZapretVersion
                          ? 'С ${c.latest!.version} обход не работал — сам её не ставлю'
                          : 'Есть обновление',
                    )
                  : null,
              trailing: c.updateAvailable
                  ? NcButton.gray(
                      label: 'Обновить до ${c.latest!.version}',
                      loading: c.busy?.kind == 'download' || c.busy?.kind == 'install',
                      onPressed: idle && c.elevated ? () => c.installLatest() : null,
                    )
                  : NcButton.gray(
                      label: 'Проверить',
                      loading: c.checkingUpdates,
                      onPressed: idle ? () => c.checkUpdates() : null,
                    ),
            ),
            if (c.previousZapretVersion != null)
              NcSettingRow(
                title: 'Прежняя версия',
                description: 'Zapret ${c.previousZapretVersion} сохранён после обновления. '
                    'Если с новой версией сайты не открываются — верните его.',
                trailing: NcButton.gray(
                  label: 'Вернуть',
                  icon: LucideIcons.undo2,
                  loading: c.busy?.kind == 'rollback',
                  onPressed: idle && c.elevated ? () => c.rollbackZapret() : null,
                ),
              ),
            NcSettingRow(
              title: 'Папка',
              description: install?.root.path ?? 'Не выбрана',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (install != null)
                    NcIconButton(
                      icon: LucideIcons.externalLink,
                      tooltip: 'Открыть папку',
                      onPressed: c.openZapretFolder,
                    ),
                  const SizedBox(width: 4),
                  NcButton.gray(
                    label: 'Изменить',
                    onPressed: idle && !c.running ? c.chooseFolder : null,
                  ),
                ],
              ),
            ),
            NcSettingRow(
              title: 'Репозиторий zapret',
              description: 'github.com/$zapretRepo — лаунчер скачивает zapret только отсюда.',
              trailing: NcIconButton(
                icon: LucideIcons.externalLink,
                tooltip: 'Открыть страницу релиза',
                onPressed: c.openReleasePage,
              ),
            ),
          ]),
        ),
        const SizedBox(height: NcSpace.gapCards),
        Appear(
          index: 4,
          child: NcSettingsCard(children: [
            NcSettingRow(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.field),
                child: Icon(LucideIcons.stethoscope, size: 20, color: p.text),
              ),
              title: 'Диагностика',
              description: 'Что может мешать zapret: другие обходы, VPN, прокси, DNS, hosts.',
              trailing: Icon(LucideIcons.chevronRight, size: 20, color: p.muted),
              onTap: () => Navigator.of(context)
                  .push(NcPageRoute<void>(builder: (_) => const DiagnosticsPage())),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Appear(
          index: 5,
          child: Text(
            '${AppInfo.name} — неофициальный лаунчер. Zapret и его стратегии делает Flowseal; '
            'лаунчер только запускает их.',
            style: NcType.caption.copyWith(color: p.muted),
          ),
        ),
      ],
    );
  }
}
