import 'package:flutter/material.dart';

import '../controller.dart';
import '../ui/ui.dart';
import '../zapret/install.dart';
import 'common.dart';

/// Кратко — для строки на главной: что из дополнительного обхода включено.
String bypassOptionsLine(AppController c) {
  final parts = [
    if (c.gameFilter.mode != GameFilterMode.disabled)
      'игровой фильтр — ${switch (c.gameFilter.mode) {
        GameFilterMode.all => 'TCP и UDP',
        GameFilterMode.tcp => 'TCP',
        GameFilterMode.udp => 'UDP',
        GameFilterMode.disabled => '',
      }}',
    if (c.ipsetMode != IpsetMode.none)
      'IPSet — ${c.ipsetMode == IpsetMode.loaded ? 'по списку' : 'все адреса'}',
  ];
  if (parts.isEmpty) return 'Выключены — нужны не всем.';
  final line = parts.join(', ');
  return '${line[0].toUpperCase()}${line.substring(1)}.';
}

/// Игровой фильтр и IPSet — то, что меняют реже стратегии и не всем нужно.
/// Профиль сети запоминает их вместе со стратегией.
class BypassOptionsPage extends StatelessWidget {
  const BypassOptionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final enabled = c.elevated && c.busy == null && c.install != null;
    final idle = c.busy == null;

    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Игровой фильтр и IPSet',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        const Appear(
          index: 0,
          child: PageTitle(
            'Игровой фильтр и IPSet',
            description:
                'Включайте, если со стратегией что-то всё равно не работает.',
          ),
        ),
        const SizedBox(height: 24),
        Appear(
          index: 1,
          child: NcSettingsCard(
            children: [
              NcSettingRow(
                title: 'Игровой фильтр',
                description:
                    'Обход и для игр — на портах выше 1023. Если всё работает, не включайте: '
                    'обход лишнего трафика может мешать другим программам.',
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
            ],
          ),
        ),
        const SizedBox(height: NcSpace.gapCards),
        Appear(
          index: 2,
          child: NcSettingsCard(
            children: [
              NcSettingRow(
                title: 'IPSet',
                description:
                    'Обход не только по доменам, но и по адресам серверов. «По списку» — '
                    'адреса из репозитория zapret, «Все адреса» — любые.',
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
              NcSettingRow(
                title: 'Список адресов',
                description: 'Свежие адреса серверов из репозитория zapret.',
                trailing: NcButton.gray(
                  label: 'Обновить',
                  loading: c.busy?.kind == 'ipset',
                  onPressed: idle && c.install != null
                      ? c.updateIpsetList
                      : null,
                ),
              ),
            ],
          ),
        ),
        if (!c.elevated) ...[
          const SizedBox(height: 12),
          const Appear(
            index: 3,
            child: StatusLine(
              tone: Tone.neutral,
              text: 'Меняются с правами администратора',
            ),
          ),
        ],
      ],
    );
  }
}
