import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../ui/ui.dart';

/// Строки важного, общие для всех страниц: права, ошибка, чужой winws.exe.
List<Widget> importantRows(BuildContext context, AppController c) {
  final rows = <Widget>[
    if (!c.elevated)
      NoticeRow(
        kind: NoticeKind.danger,
        icon: LucideIcons.shieldAlert,
        title: 'Нужны права администратора',
        detail: 'Без них zapret не запустится и не остановится. '
            'Перезапустите лаунчер — Windows спросит разрешение.',
        action: NcButton.danger(label: 'Перезапустить', onPressed: c.restartElevated),
      ),
    if (c.error != null)
      NoticeRow(
        kind: NoticeKind.danger,
        icon: LucideIcons.circleAlert,
        title: c.error!.title,
        detail: c.error!.detail,
        onClose: c.dismissError,
      ),
    if (c.runningElsewhere)
      NoticeRow(
        kind: NoticeKind.decision,
        title: 'winws.exe запущен из другой папки',
        detail: '${c.runtime.activeRoot} — остановите его, чтобы запустить zapret из лаунчера.',
      ),
  ];
  return [
    for (final r in rows) ...[r, const SizedBox(height: 8)],
    if (rows.isNotEmpty) const SizedBox(height: 16),
  ];
}

/// Шапка с кнопкой настроек.
NcHeader appHeader(BuildContext context, AppController c,
    {String? title, VoidCallback? onBack, List<Widget> actions = const []}) {
  return NcHeader(
    title: title,
    onBack: onBack,
    status: c.busy,
    actions: actions,
  );
}

/// Подвал: рядом с версией лаунчера — тихая кнопка его обновления.
/// Обновления zapret — в оповещении и настройках, а то и сами.
NcFooter appFooter(AppController c) => NcFooter(
      trailing: c.launcherUpdateAvailable
          ? NcQuietButton(
              label: 'Обновить до ${c.launcherLatest!.version}',
              onPressed: c.busy == null ? c.updateLauncher : null,
            )
          : null,
    );
