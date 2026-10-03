import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controller.dart';
import '../ui/ui.dart';
import '../zapret/user_lists.dart';
import 'common.dart';

/// Сколько строк показываем без поиска: длинные списки рисовать целиком незачем.
const _maxRows = 200;

String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return '$n $one';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return '$n $few';
  return '$n $many';
}

String countLabel(UserListKind kind, int n) => kind.ip
    ? plural(n, 'адрес', 'адреса', 'адресов')
    : plural(n, 'сайт', 'сайта', 'сайтов');

/// Свои списки zapret: что обходить, что не трогать, какие адреса исключить.
class ListsPage extends StatefulWidget {
  const ListsPage({super.key, this.initial = UserListKind.bypass});

  final UserListKind initial;

  @override
  State<ListsPage> createState() => _ListsPageState();
}

class _ListsPageState extends State<ListsPage> {
  late UserListKind _kind = widget.initial;
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _add(AppController c) async {
    final entries = await showNcModal<List<String>>(
      context,
      label: 'Добавить',
      builder: (_) => _AddDialog(kind: _kind),
    );
    if (entries == null || entries.isEmpty) return;
    final (added, existing) = c.addEntries(_kind, entries);
    c.toasts.show(
      ToastData(
        added == 0
            ? (entries.length == 1
                  ? 'Уже есть в списке'
                  : 'Всё это уже есть в списке')
            : 'Добавлено: ${countLabel(_kind, added)}${existing > 0 ? ', уже были $existing' : ''}',
        icon: LucideIcons.listPlus,
      ),
    );
  }

  void _remove(AppController c, String entry) {
    final kind = _kind;
    final index = c.userList(kind).entries.indexOf(entry);
    c.removeEntry(kind, entry);
    c.toasts.show(
      ToastData(
        '${kind.ip ? entry : domainToUnicode(entry)} убран из списка',
        icon: LucideIcons.listX,
        actionLabel: 'Вернуть',
        onAction: () => c.restoreEntry(kind, entry, index),
      ),
      urgent: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    final p = context.palette;
    final hasInstall = c.install != null;
    final list = c.userList(_kind);
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? list.entries
        : [
            for (final e in list.entries)
              if (e.contains(q) || domainToUnicode(e).contains(q)) e,
          ];
    final shown = filtered.take(_maxRows).toList();

    final description = switch (_kind) {
      UserListKind.bypass =>
        'Zapret обходит блокировку этих сайтов и их поддоменов — '
            'вдобавок к стандартному списку.',
      UserListKind.exclude =>
        'Эти сайты zapret не трогает, даже если они есть в стандартном '
            'списке. Помогает, если обход ломает какой-то сайт.',
      UserListKind.ipExclude =>
        'Адреса и подсети, которые zapret не трогает в режиме IPSet. '
            'Например, локальная сеть или сервер игры.',
    };

    var i = 0;
    return NcPage(
      header: appHeader(
        context,
        c,
        title: 'Свои списки',
        onBack: () => Navigator.of(context).pop(),
      ),
      footer: appFooter(c),
      fab: NcFab(
        icon: LucideIcons.plus,
        label: 'Добавить',
        onPressed: hasInstall ? () => _add(c) : null,
      ),
      children: [
        ...importantRows(context, c),
        if (c.listsChanged) ...[
          NoticeRow(
            kind: NoticeKind.decision,
            icon: LucideIcons.rotateCw,
            title: 'Списки изменились',
            detail: 'Перезапустите zapret, чтобы изменения точно применились.',
            action: NcButton.gray(
              label: 'Перезапустить',
              loading: c.busy?.kind == 'restart',
              onPressed: c.busy == null && c.elevated ? c.applyLists : null,
            ),
          ),
          const SizedBox(height: 24),
        ],
        Appear(
          index: i++,
          child: const PageTitle(
            'Свои списки',
            description: 'Дополняют стандартные списки zapret и сохраняются при его обновлении.',
          ),
        ),
        const SizedBox(height: 24),
        Appear(
          index: i++,
          child: NcSegmented<UserListKind>(
            value: _kind,
            onChanged: (k) => setState(() {
              _kind = k;
              _search.clear();
              _query = '';
            }),
            segments: const [
              NcSegment(UserListKind.bypass, 'Обходить'),
              NcSegment(UserListKind.exclude, 'Не трогать'),
              NcSegment(UserListKind.ipExclude, 'IP-адреса'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Appear(
          index: i++,
          child: Text(
            description,
            style: NcType.caption.copyWith(color: p.muted),
          ),
        ),
        const SizedBox(height: 16),
        // Сколько записей и файл — тихой строкой: главное здесь сам список и «Добавить».
        if (hasInstall && list.entries.isNotEmpty) ...[
          Appear(
            index: i++,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    countLabel(_kind, list.entries.length),
                    style: NcType.rowTitle,
                  ),
                ),
                NcQuietButton(
                  label: 'Импорт',
                  onPressed: () => c.importList(_kind),
                ),
                NcQuietButton(
                  label: 'Экспорт',
                  onPressed: () => c.exportList(_kind),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (list.entries.length > 8) ...[
          NcTextField(
            controller: _search,
            hint: _kind.ip ? 'Найти адрес' : 'Найти сайт',
            prefixIcon: LucideIcons.search,
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 12),
        ],
        if (!hasInstall)
          const _EmptyCard(
            title: 'Zapret не установлен',
            text: 'Списки лежат в папке zapret — сначала установите его на главной.',
          )
        else if (list.entries.isEmpty)
          Appear(
            index: i++,
            child: _EmptyCard(
              title: 'Здесь пока пусто',
              text:
                  'Добавьте ${_kind.ip ? 'адрес' : 'сайт'} кнопкой «Добавить» '
                  'или возьмите список из текстового файла.',
              action: NcButton.gray(
                label: 'Импорт из файла',
                icon: LucideIcons.fileDown,
                onPressed: () => c.importList(_kind),
              ),
            ),
          )
        else if (filtered.isEmpty)
          Text(
            'Ничего не нашлось',
            style: NcType.caption.copyWith(color: p.muted),
          )
        else ...[
          Appear(
            index: i++,
            child: NcSettingsCard(
              children: [
                for (final e in shown)
                  _EntryRow(
                    entry: e,
                    ip: _kind.ip,
                    onRemove: () => _remove(c, e),
                  ),
              ],
            ),
          ),
          if (filtered.length > shown.length) ...[
            const SizedBox(height: 8),
            Text(
              'И ещё ${filtered.length - shown.length} — уточните поиск.',
              style: NcType.caption.copyWith(color: p.muted),
            ),
          ],
        ],
        if (_kind == UserListKind.bypass &&
            hasInstall &&
            c.standardListSize > 0) ...[
          const SizedBox(height: 16),
          Text(
            'Стандартный список zapret — ${plural(c.standardListSize, 'сайт', 'сайта', 'сайтов')}. '
            'Он обновляется вместе с zapret, менять его не нужно.',
            style: NcType.caption.copyWith(color: p.muted),
          ),
        ],
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.ip,
    required this.onRemove,
  });

  final String entry;
  final bool ip;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final unicode = ip ? entry : domainToUnicode(entry);
    return Padding(
      padding: const EdgeInsets.fromLTRB(NcSpace.cardPad, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  unicode,
                  style: NcType.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // Русский домен zapret видит в punycode — показываем и его.
                if (unicode != entry)
                  Text(
                    entry,
                    style: NcType.caption.copyWith(
                      color: context.palette.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          NcIconButton(
            icon: LucideIcons.x,
            tooltip: 'Убрать',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.title, required this.text, this.action});

  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return NcCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: NcType.rowTitle),
          const SizedBox(height: 4),
          Text(
            text,
            style: NcType.caption.copyWith(color: context.palette.muted),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

/// Добавление: можно вставить сразу много — по строкам, через запятую, ссылками.
class _AddDialog extends StatefulWidget {
  const _AddDialog({required this.kind});

  final UserListKind kind;

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  final _text = TextEditingController();
  ParsedEntries _parsed = const ParsedEntries([], []);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ip = widget.kind.ip;
    final invalid = _parsed.invalid;
    final count = _parsed.entries.length;
    return NcDialogFrame(
      title: ip ? 'Добавить адреса' : 'Добавить сайты',
      actions: [
        NcDialogButton(
          label: 'Отмена',
          kind: NcDialogButtonKind.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        NcDialogButton(
          label: 'Добавить',
          onPressed: count == 0
              ? null
              : () => Navigator.of(context).pop(_parsed.entries),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            ip
                ? 'По одному на строке или через запятую. Можно с маской подсети.'
                : 'По одному на строке или через запятую. Можно вставить ссылки — '
                      'лаунчер оставит только домен.',
            style: NcType.body.copyWith(color: p.muted),
          ),
          const SizedBox(height: 16),
          NcTextField(
            controller: _text,
            label: ip ? 'Адреса' : 'Сайты',
            hint: ip ? 'Например, 192.168.0.0/16' : 'Например, discord.com',
            minLines: 3,
            maxLines: 6,
            autofocus: true,
            error: invalid.isEmpty
                ? null
                : '${ip ? 'Не похоже на адрес' : 'Не похоже на домен'}: '
                      '${invalid.take(3).join(', ')}${invalid.length > 3 ? ' и ещё ${invalid.length - 3}' : ''}',
            onChanged: (v) => setState(() => _parsed = parseEntries(v, ip: ip)),
          ),
          if (count > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Будет добавлено: ${countLabel(widget.kind, count)}',
              style: NcType.caption.copyWith(color: p.muted),
            ),
          ],
        ],
      ),
    );
  }
}
