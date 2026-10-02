import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import 'pressable.dart';

/// Смысл статуса. Цвет — только для смысла; рядом всегда слово.
enum Tone {
  /// Работает, доступно, защищено.
  success,

  /// Ждёт решения пользователя, проверяется.
  warning,

  /// Ждёт ответа, идёт процесс.
  info,

  /// Ошибка, тревога.
  danger,

  /// Неактивно, выключено.
  neutral,
}

extension ToneColor on Tone {
  Color color(Palette p) => switch (this) {
        Tone.success => p.success,
        Tone.warning => p.warning,
        Tone.info => p.info,
        Tone.danger => p.danger,
        Tone.neutral => p.muted,
      };
}

/// Строка статуса — точка 7 pt и подпись 12,5 pt 500 того же цвета.
/// Подпись переносится, точка остаётся у первой строки.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.tone, required this.text});

  final Tone tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = tone.color(context.palette);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5, right: 6),
          child: AnimatedContainer(
            duration: NcMotion.icon,
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        Flexible(
          child: AnimatedDefaultTextStyle(
            duration: NcMotion.icon,
            style: NcType.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
              fontFamily: NcType.family,
              fontFamilyFallback: NcType.fallback,
            ),
            child: Text(text),
          ),
        ),
      ],
    );
  }
}

/// Метка — серая «таблетка» 11,5 pt с полями 7 × 2 и скруглением 6.
class NcTag extends StatelessWidget {
  const NcTag(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(NcRadius.tag),
      ),
      child: Text(text, style: NcType.tag.copyWith(color: p.muted)),
    );
  }
}

enum NoticeKind {
  /// Сработала защита, ошибка, запуск невозможен — красная строка.
  danger,

  /// Нужно решение — серая с оранжевым значком.
  decision,

  /// К сведению — серая с серым значком.
  info,
}

/// Строка важного — над содержимым страницы, компактно: значок 18,
/// заголовок в одну строку 13,5 pt 600, подробность второй строкой;
/// по нажатию строка раскрывается целиком.
class NoticeRow extends StatefulWidget {
  const NoticeRow({
    super.key,
    required this.kind,
    required this.title,
    this.detail,
    this.icon,
    this.action,
    this.onClose,
  });

  final NoticeKind kind;
  final String title;
  final String? detail;
  final IconData? icon;

  /// Кнопка действия — показывается справа.
  final Widget? action;

  /// Крестик — только там, где строку можно убрать.
  final VoidCallback? onClose;

  @override
  State<NoticeRow> createState() => _NoticeRowState();
}

class _NoticeRowState extends State<NoticeRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (bg, iconColor, defaultIcon) = switch (widget.kind) {
      NoticeKind.danger => (p.dangerSurface, p.danger, LucideIcons.shieldAlert),
      NoticeKind.decision => (p.field, p.warning, LucideIcons.triangleAlert),
      NoticeKind.info => (p.field, p.muted, LucideIcons.info),
    };
    final titleColor = widget.kind == NoticeKind.danger ? p.danger : p.text;
    final detailColor = widget.kind == NoticeKind.danger
        ? p.danger.withValues(alpha: .85)
        : p.muted;

    return Pressable(
      onTap: widget.detail == null ? null : () => setState(() => _expanded = !_expanded),
      cursor: SystemMouseCursors.click,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: s.hovered ? Color.alphaBlend(p.hoverTint(), bg) : bg,
          borderRadius: BorderRadius.circular(NcRadius.notice),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(widget.icon ?? defaultIcon, size: 18, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedSize(
                duration: NcMotion.icon,
                alignment: Alignment.topLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: _expanded ? null : 1,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      style: NcType.button.copyWith(
                          fontWeight: FontWeight.w600, color: titleColor),
                    ),
                    if (widget.detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.detail!,
                        maxLines: _expanded ? null : 1,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                        style: NcType.caption.copyWith(color: detailColor),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (widget.action != null) ...[const SizedBox(width: 10), widget.action!],
            if (widget.onClose != null) ...[
              const SizedBox(width: 4),
              _CloseButton(onTap: widget.onClose!, color: p.muted),
            ],
          ],
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap, required this.color});

  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: 'Убрать',
      child: Pressable(
        onTap: onTap,
        builder: (context, s) => AnimatedContainer(
          duration: NcMotion.hover,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: s.hovered ? p.text.withValues(alpha: .06) : p.text.withValues(alpha: 0),
          ),
          child: Icon(LucideIcons.x, size: 16, color: color),
        ),
      ),
    );
  }
}
