import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../ui/ui.dart';
import '../zapret/diagnostics.dart';
import 'common.dart';

/// Диагностика: проверки из service.bat с исправлениями в один клик.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  @override
  void initState() {
    super.initState();
    // Каждый раз при открытии — свежая проверка.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.of(context).runDiagnostics();
    });
  }

  Future<void> _fix(AppController c, DiagnosticFix fix) async {
    if (await _confirm(fix)) await c.applyFix(fix);
  }

  /// Изменения в системе — только после подтверждения.
  Future<bool> _confirm(DiagnosticFix fix) {
    return switch (fix) {
      RemoveServicesFix(:final services) => showNcDialog(
          context,
          title: 'Удалить ${services.join(', ')}?',
          message: 'Службы остановятся и удалятся из Windows. Если вы пользуетесь этими '
              'программами, они перестанут работать.',
          confirmLabel: 'Удалить',
          danger: true,
        ),
      HostsBlockFix() => showNcDialog(
          context,
          title: 'Изменить hosts?',
          message: 'В файл hosts добавятся адреса из репозитория zapret: GitHub, Telegram и '
              'голосовые каналы Discord. Прежний файл сохранится рядом — hosts.zapret-launcher.bak.',
          confirmLabel: fix.label,
        ),
      ReinstallFix() => showNcDialog(
          context,
          title: 'Переустановить zapret?',
          message: 'Лаунчер скачает zapret заново. Ваши списки и настройки сохранятся. '
              'Если файлы удалил антивирус, сначала добавьте папку zapret в его исключения.',
          confirmLabel: 'Переустановить',
        ),
      _ => Future.value(true),
    };
  }

  Future<void> _clearDiscord(AppController c) async {
    final ok = await showNcDialog(
      context,
      title: 'Очистить кэш Discord?',
      message: 'Discord закроется, если открыт. Вход в аккаунт сохранится.',
      confirmLabel: 'Очистить',
    );
    if (ok) await c.clearDiscordCache();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final results = c.diagnostics;
    final attention = [for (final r in results ?? const <DiagnosticResult>[]) if (r.level != CheckLevel.ok) r]
      ..sort((a, b) => b.level.index.compareTo(a.level.index));
    final fine = [for (final r in results ?? const <DiagnosticResult>[]) if (r.level == CheckLevel.ok) r];
    final idle = c.busy == null;

    bool fixEnabled(DiagnosticFix fix) => idle && (fix is OpenFix || c.elevated);

    var i = 0;
    return NcPage(
      header: appHeader(context, c,
          title: 'Диагностика',
          onBack: () => Navigator.of(context).pop(),
          actions: [
            NcIconButton(
              icon: LucideIcons.refreshCw,
              tooltip: 'Проверить ещё раз',
              busy: c.diagnosing,
              onPressed: c.runDiagnostics,
            ),
          ]),
      footer: appFooter(c),
      children: [
        ...importantRows(context, c),
        Appear(
          index: i++,
          child: const PageTitle(
            'Диагностика',
            description: 'Что может мешать zapret — те же проверки, что в service.bat.',
          ),
        ),
        const SizedBox(height: 24),
        if (results == null)
          Appear(
            index: i++,
            child: NcCard(
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: p.text),
                  ),
                  const SizedBox(width: 12),
                  const Text('Проверяю систему…', style: NcType.rowTitle),
                ],
              ),
            ),
          )
        else ...[
          if (attention.isEmpty)
            Appear(
              index: i++,
              child: NcCard(
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: p.success),
                      child: const Icon(LucideIcons.check, size: 20, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Ничего не мешает', style: NcType.rowTitle),
                          const SizedBox(height: 2),
                          Text(
                            'Если сайты всё равно не открываются — подберите другую стратегию.',
                            style: NcType.caption.copyWith(color: p.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Appear(index: i++, child: const SectionTitle('Требует внимания')),
            const SizedBox(height: 12),
            Appear(
              index: i++,
              child: NcSettingsCard(children: [
                for (final r in attention)
                  NcSettingRow(
                    title: r.title,
                    description: r.detail,
                    below: StatusLine(
                      tone: switch (r.level) {
                        CheckLevel.problem => Tone.danger,
                        CheckLevel.warning => Tone.warning,
                        _ => Tone.neutral,
                      },
                      text: switch (r.level) {
                        CheckLevel.problem => 'Мешает',
                        CheckLevel.warning => 'Стоит проверить',
                        _ => 'К сведению',
                      },
                    ),
                    trailing: r.fix == null
                        ? null
                        : NcButton.gray(
                            label: r.fix!.label,
                            onPressed: fixEnabled(r.fix!) ? () => _fix(c, r.fix!) : null,
                          ),
                  ),
              ]),
            ),
          ],
          if (fine.isNotEmpty) ...[
            const SizedBox(height: 16),
            Appear(index: i++, child: const SectionTitle('В порядке')),
            const SizedBox(height: 12),
            Appear(
              index: i++,
              child: NcSettingsCard(children: [
                for (final r in fine)
                  NcSettingRow(
                    title: r.title,
                    description: r.detail,
                    trailing: Icon(LucideIcons.check, size: 20, color: p.success),
                  ),
              ]),
            ),
          ],
        ],
        const SizedBox(height: 16),
        Appear(index: i++, child: const SectionTitle('Инструменты')),
        const SizedBox(height: 12),
        Appear(
          index: i++,
          child: NcSettingsCard(children: [
            NcSettingRow(
              title: 'Кэш Discord',
              description: 'Помогает, если после включения zapret Discord не грузится '
                  'или висит на подключении.',
              trailing: NcButton.gray(
                label: 'Очистить',
                onPressed: idle ? () => _clearDiscord(c) : null,
              ),
            ),
            NcSettingRow(
              title: 'Список адресов IPSet',
              description: 'Свежие адреса серверов из репозитория zapret.',
              trailing: NcButton.gray(
                label: 'Обновить',
                loading: c.busy?.kind == 'ipset',
                onPressed: idle && c.install != null ? c.updateIpsetList : null,
              ),
            ),
          ]),
        ),
      ],
    );
  }
}
