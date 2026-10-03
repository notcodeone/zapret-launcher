import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../location/country.dart';
import '../location/profiles.dart';
import '../ui/ui.dart';
import '../zapret/install.dart';
import '../zapret/strategy.dart';
import 'common.dart';

String _seen(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'сегодня';
  if (diff == 1) return 'вчера';
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  return '${d.day} ${months[d.month - 1]}';
}

String _strategyTitle(AppController c, String? id) =>
    c.install?.strategyById(id)?.title ?? id ?? 'не выбрана';

/// Сети: стратегия для каждого провайдера.
class NetworksPage extends StatelessWidget {
  const NetworksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final g = c.guard;
    final current = c.currentProfile;

    var i = 0;
    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Сети',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        Appear(
          index: i++,
          child: const PageTitle(
            'Сети',
            description:
                'Для каждого провайдера — своя стратегия: лаунчер помнит её '
                'и переключает сам.',
          ),
        ),
        const SizedBox(height: 24),
        Appear(
          index: i++,
          child: NcSettingsCard(
            children: [
              NcSettingRow(
                title: 'Помнить стратегию для каждой сети',
                description:
                    'Стратегия, игровой фильтр и IPSet вернутся сами, когда вы снова '
                    'окажетесь в этой сети.',
                trailing: NcSwitch(
                  value: c.profilesEnabled,
                  label: 'Помнить стратегию для каждой сети',
                  onChanged: c.setProfilesEnabled,
                ),
              ),
            ],
          ),
        ),
        if (c.profilesEnabled) ...[
          const SizedBox(height: NcSpace.gapCards),
          Appear(
            index: i++,
            child: NcCard(
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p.field,
                    ),
                    child: Icon(LucideIcons.router, size: 20, color: p.text),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.asn == null
                              ? (g.providerCheckedAt == null
                                    ? 'Определяю сеть…'
                                    : 'Сеть не определена')
                              : 'Сейчас: ${c.currentNetworkName}',
                          style: NcType.rowTitle,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          g.asn == null
                              ? 'Провайдера узнаём по IP через ipwho.is или ipapi.co.'
                              : [
                                  if (g.isp != null) g.isp!,
                                  g.asn!,
                                  if (g.country != null)
                                    countryName(g.country!),
                                ].join(' · '),
                          style: NcType.caption.copyWith(color: p.muted),
                        ),
                        if (g.asn != null) ...[
                          const SizedBox(height: 6),
                          current == null
                              ? const StatusLine(
                                  tone: Tone.warning,
                                  text: 'Новая сеть — своей стратегии нет',
                                )
                              : StatusLine(
                                  tone: Tone.success,
                                  text: current.zapretOff
                                      ? 'Профиль «${current.name}»: zapret не нужен'
                                      : 'Профиль «${current.name}»: «${_strategyTitle(c, current.strategy)}»',
                                ),
                        ],
                      ],
                    ),
                  ),
                  if (g.asn != null && current == null && c.install != null)
                    NcButton.gray(
                      label: 'Запомнить',
                      onPressed: c.rememberCurrentNetwork,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Appear(index: i++, child: const SectionTitle('Запомненные')),
          const SizedBox(height: 12),
          if (c.profiles.isEmpty)
            Appear(
              index: i++,
              child: NcCard(
                child: Text(
                  'Пока ни одной. Выберите стратегию или включите zapret — сеть запомнится сама.',
                  style: NcType.caption.copyWith(color: p.muted),
                ),
              ),
            )
          else
            Appear(
              index: i++,
              child: NcSettingsCard(
                children: [
                  for (final profile in c.profiles)
                    NcSettingRow(
                      title: profile.name,
                      description: [
                        profile.zapretOff
                            ? 'zapret не нужен'
                            : '«${_strategyTitle(c, profile.strategy)}»',
                        if (profile.isp != null && profile.isp != profile.name)
                          profile.isp!,
                        'была ${_seen(profile.lastSeen)}',
                      ].join(' · '),
                      below: profile.asn == g.asn
                          ? const StatusLine(
                              tone: Tone.success,
                              text: 'Вы сейчас в этой сети',
                            )
                          : null,
                      trailing: Icon(
                        LucideIcons.chevronRight,
                        size: 20,
                        color: p.muted,
                      ),
                      onTap: () => Navigator.of(context).push(
                        NcPageRoute<void>(
                          builder: (_) => ProfilePage(asn: profile.asn),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// Профиль одной сети.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.asn});

  final String asn;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final AppController _c;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _c = AppScope.read(context);
    _name = TextEditingController(text: _c.profileFor(widget.asn)?.name ?? '');
  }

  @override
  void dispose() {
    // Название сохраняем, когда закончили печатать, а не на каждую букву.
    // После кадра: во время разборки дерева виджетов уведомлять нельзя.
    final c = _c, asn = widget.asn, name = _name.text;
    Future.microtask(() => c.renameProfile(asn, name));
    _name.dispose();
    super.dispose();
  }

  Future<void> _delete(AppController c, NetworkProfile profile) async {
    final ok = await showNcDialog(
      context,
      title: 'Забыть сеть «${profile.name}»?',
      message:
          'Лаунчер забудет её стратегию и настройки. Когда вы снова окажетесь в этой сети, '
          'он предложит подобрать стратегию.',
      confirmLabel: 'Забыть',
      danger: true,
    );
    if (!ok || !mounted) return;
    c.deleteProfile(profile.asn);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final profile = c.profileFor(widget.asn);
    if (profile == null) {
      return NcPage(
        header: appHeader(
          context,
          c,
          title: 'Сеть',
          onBack: () => Navigator.of(context).pop(),
        ),
        children: const [PageTitle('Сети больше нет')],
      );
    }
    final isCurrent = profile.asn == c.guard.asn;

    return NcPage(
      header: appHeader(
        context,
        c,
        title: profile.name,
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        Appear(
          index: 0,
          child: PageTitle(
            profile.name,
            description: [
              if (profile.isp != null) profile.isp!,
              profile.asn,
              if (profile.country != null) countryName(profile.country!),
            ].join(' · '),
          ),
        ),
        const SizedBox(height: 24),
        Appear(
          index: 1,
          child: NcTextField(
            controller: _name,
            label: 'Название',
            hint: 'Например, Дом',
            onSubmitted: (v) => c.renameProfile(profile.asn, v),
          ),
        ),
        const SizedBox(height: 16),
        Appear(
          index: 2,
          child: NcSettingsCard(
            children: [
              NcSettingRow(
                title: 'Zapret здесь не нужен',
                description:
                    'Например, в офисе с корпоративным VPN. В этой сети лаунчер выключит zapret, '
                    'а в другой — включит снова.',
                // Отметка текущей сети выключает zapret сразу; при смене сети — только сторож.
                below: profile.zapretOff && !c.settings.networkGuard
                    ? const StatusLine(
                        tone: Tone.neutral,
                        text: 'При смене сети переключит, когда включено «Следить за сетью»',
                      )
                    : null,
                trailing: NcSwitch(
                  value: profile.zapretOff,
                  label: 'Zapret здесь не нужен',
                  onChanged: (v) => c.setProfileZapretOff(profile.asn, v),
                ),
              ),
              if (!profile.zapretOff) ...[
                NcSettingRow(
                  title: 'Стратегия',
                  description:
                      '«${_strategyTitle(c, profile.strategy)}»'
                      '${isCurrent ? ' — работает сейчас' : ''}',
                  trailing: Icon(
                    LucideIcons.chevronRight,
                    size: 20,
                    color: p.muted,
                  ),
                  onTap: c.install == null
                      ? null
                      : () => Navigator.of(context).push(
                          NcPageRoute<void>(
                            builder: (_) => StrategyPickerPage(
                              title: 'Стратегия для «${profile.name}»',
                              selected: profile.strategy,
                              onSelected: (s) =>
                                  c.setProfileStrategy(profile.asn, s),
                            ),
                          ),
                        ),
                ),
                NcSettingRow(
                  title: 'Игровой фильтр',
                  description: switch (profile.gameFilter) {
                    GameFilterMode.disabled => 'Выключен',
                    GameFilterMode.all => 'TCP и UDP',
                    GameFilterMode.tcp => 'TCP',
                    GameFilterMode.udp => 'UDP',
                  },
                ),
                NcSettingRow(
                  title: 'IPSet',
                  description: switch (profile.ipset) {
                    IpsetMode.none => 'Выключен',
                    IpsetMode.loaded => 'По списку',
                    IpsetMode.any => 'Все адреса',
                  },
                  below: Text(
                    isCurrent
                        ? 'Фильтр и IPSet меняются на главной — профиль запомнит.'
                        : 'Фильтр и IPSet запомнятся, когда поменяете их на главной в этой сети.',
                    style: NcType.caption.copyWith(color: p.muted),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: NcButton.danger(
            label: 'Забыть сеть',
            icon: LucideIcons.trash2,
            onPressed: () => _delete(c, profile),
          ),
        ),
      ],
    );
  }
}

/// Выбор стратегии без запуска — для профиля другой сети.
class StrategyPickerPage extends StatelessWidget {
  const StrategyPickerPage({
    super.key,
    required this.title,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final String? selected;
  final ValueChanged<Strategy> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Стратегия',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      children: [
        Appear(index: 0, child: PageTitle(title)),
        const SizedBox(height: 24),
        Appear(
          index: 1,
          child: NcSettingsCard(
            children: [
              for (final s in c.install?.strategies ?? const <Strategy>[])
                NcSettingRow(
                  title: s.title,
                  trailing: s.id == selected
                      ? Icon(LucideIcons.check, size: 20, color: p.text)
                      : null,
                  onTap: () {
                    onSelected(s);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
