import 'package:flutter/material.dart';

import '../theme.dart';
import 'pressable.dart';

enum NcButtonKind {
  /// Главное действие экрана или диалога. На экране — не больше одной.
  primary,

  /// «Отмена» и действия рядом с главной: без фона, при наведении — field.
  secondary,

  /// Рискованное решение: danger на danger-surface.
  danger,

  /// Действие внутри карточки: field, текст 600.
  gray,
}

/// Кнопка: высота 40 (крупная — 46), скругление 12.
class NcButton extends StatelessWidget {
  const NcButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = NcButtonKind.primary,
    this.icon,
    this.large = false,
    this.loading = false,
    this.expand = false,
  });

  const NcButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.large = false,
    this.loading = false,
    this.expand = false,
  }) : kind = NcButtonKind.secondary;

  const NcButton.gray({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.large = false,
    this.loading = false,
    this.expand = false,
  }) : kind = NcButtonKind.gray;

  const NcButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.large = false,
    this.loading = false,
    this.expand = false,
  }) : kind = NcButtonKind.danger;

  final String label;
  final VoidCallback? onPressed;
  final NcButtonKind kind;
  final IconData? icon;
  final bool large;
  final bool loading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null && !loading;

    late Color bg;
    late Color fg;
    late Color bgHover;
    switch (kind) {
      case NcButtonKind.primary:
        bg = p.primary;
        fg = p.onPrimary;
        bgHover = Color.alphaBlend(
          p.onPrimary.withValues(alpha: .07),
          p.primary,
        );
      case NcButtonKind.secondary:
        bg = p.field.withValues(alpha: 0);
        fg = p.text;
        bgHover = p.field;
      case NcButtonKind.danger:
        bg = p.dangerSurface;
        fg = p.danger;
        bgHover = Color.alphaBlend(
          p.danger.withValues(alpha: .07),
          p.dangerSurface,
        );
      case NcButtonKind.gray:
        bg = p.field;
        fg = p.text;
        bgHover = Color.alphaBlend(p.text.withValues(alpha: .07), p.field);
    }
    Color bgPressed = Color.alphaBlend(
      fg.withValues(alpha: .10),
      bg.a == 0 ? p.field : bg,
    );

    if (!enabled && !loading) {
      bg = p.field;
      fg = p.muted;
      bgHover = bg;
      bgPressed = bg;
    }

    final textStyle = (large ? NcType.buttonLarge : NcType.button).copyWith(
      color: fg,
      fontWeight: kind == NcButtonKind.gray ? FontWeight.w600 : null,
    );
    final padding = large
        ? const EdgeInsets.symmetric(horizontal: 18)
        : kind == NcButtonKind.gray
        ? const EdgeInsets.symmetric(horizontal: 14)
        : const EdgeInsets.symmetric(horizontal: 16);

    return Pressable(
      onTap: enabled ? onPressed : null,
      semanticLabel: label,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        height: large ? 46 : 40,
        padding: padding,
        decoration: BoxDecoration(
          color: s.pressed ? bgPressed : (s.hovered ? bgHover : bg),
          borderRadius: BorderRadius.circular(NcRadius.control),
          border: s.focused ? Border.all(color: p.primary, width: 2) : null,
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                ),
              )
            else if (icon != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(icon, size: 18, color: fg),
              ),
            Flexible(
              child: Text(
                label,
                style: textStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Цвет точки-бейджа на кнопке-иконке.
enum BadgeTone { ok, pending, alarm }

/// Кнопка-иконка: круг 36 без фона, фон field — только при наведении.
/// Подпись — во всплывающей подсказке.
class NcIconButton extends StatelessWidget {
  const NcIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.badge,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final BadgeTone? badge;

  /// Пока действие идёт, вместо значка крутится индикатор.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final badgeColor = switch (badge) {
      BadgeTone.ok => p.success,
      BadgeTone.pending => p.warning,
      BadgeTone.alarm => p.danger,
      null => null,
    };
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: busy ? null : onPressed,
        semanticLabel: tooltip,
        builder: (context, s) => AnimatedContainer(
          duration: NcMotion.hover,
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: s.pressed
                ? Color.alphaBlend(p.text.withValues(alpha: .05), p.field)
                : s.hovered
                ? p.field
                : p.field.withValues(alpha: 0),
            border: s.focused ? Border.all(color: p.primary, width: 2) : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              AnimatedSwitcher(
                duration: NcMotion.icon,
                child: busy
                    ? SizedBox.square(
                        key: const ValueKey('busy'),
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: p.text,
                        ),
                      )
                    : Icon(
                        icon,
                        key: ValueKey(icon),
                        size: 20,
                        color: onPressed == null
                            ? p.muted.withValues(alpha: .5)
                            : p.text,
                      ),
              ),
              Positioned(
                top: 5,
                right: 5,
                child: AnimatedScale(
                  duration: NcMotion.icon,
                  curve: NcMotion.enter,
                  scale: badgeColor == null ? 0 : 1,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: badgeColor ?? p.success,
                      border: Border.all(color: p.card, width: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Тихая текстовая кнопка: встраивается в строку текста или подвал. Скругление 6.
class NcQuietButton extends StatelessWidget {
  const NcQuietButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color,
    this.style,
    this.horizontalPadding = 6,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  /// Стиль текста; по умолчанию — пояснение 12,5 pt 500.
  final TextStyle? style;

  /// В ширину пробела — чтобы кнопка читалась как слово в строке текста.
  final double horizontalPadding;
  final String? semanticLabel;

  /// Ширина пробела в [style] — для [horizontalPadding].
  static double spaceWidth(BuildContext context, TextStyle style) =>
      (TextPainter(
        text: TextSpan(text: ' ', style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout()).width;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Pressable(
      onTap: onPressed,
      semanticLabel: semanticLabel ?? label,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: s.pressed
              ? Color.alphaBlend(p.text.withValues(alpha: .05), p.field)
              : s.hovered
              ? p.field
              : p.field.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(NcRadius.tag),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              style ??
              NcType.caption.copyWith(
                color: color ?? p.text,
                fontWeight: FontWeight.w500,
              ),
        ),
      ),
    );
  }
}
