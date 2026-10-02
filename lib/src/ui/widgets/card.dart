import 'package:flutter/material.dart';

import '../theme.dart';
import 'pressable.dart';

/// Карточка — поверхность со скруглением 18 и мягкой тенью;
/// в тёмной теме — ещё и рамка 1 pt card-border.
///
/// При наведении карточка не приподнимается, а едва темнеет.
class NcCard extends StatelessWidget {
  const NcCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(NcSpace.cardPad),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = BorderRadius.circular(NcRadius.card);

    Widget surface(PressState? s) => Container(
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: radius,
            boxShadow: p.softShadow,
            border: s != null && s.focused
                ? Border.all(color: p.primary, width: 2)
                : p.cardOutline,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                Padding(padding: padding, child: child),
                if (s != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: NcMotion.hover,
                        color: s.pressed
                            ? p.hoverTint(pressed: true)
                            : s.hovered
                                ? p.hoverTint()
                                : p.hoverTint().withValues(alpha: 0),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );

    if (onTap == null) return surface(null);
    return Pressable(onTap: onTap, builder: (context, s) => surface(s));
  }
}

/// Карточка настроек: строки через разделитель divider 1 pt.
class NcSettingsCard extends StatelessWidget {
  const NcSettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: NcSpace.cardPad),
          child: Divider(height: 1, thickness: 1, color: p.divider),
        ));
      }
      rows.add(children[i]);
    }
    return NcCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }
}

/// Строка настроек: заголовок 15 pt 600, пояснение 12,5 pt muted, справа — элемент управления.
class NcSettingRow extends StatelessWidget {
  const NcSettingRow({
    super.key,
    required this.title,
    this.description,
    this.trailing,
    this.below,
    this.leading,
    this.onTap,
  });

  final String title;
  final String? description;
  final Widget? trailing;

  /// Строка статуса или ссылка под пояснением.
  final Widget? below;
  final Widget? leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget content(PressState? s) => AnimatedContainer(
          duration: NcMotion.hover,
          color: s == null
              ? Colors.transparent
              : s.pressed
                  ? p.hoverTint(pressed: true)
                  : s.hovered
                      ? p.hoverTint()
                      : p.hoverTint().withValues(alpha: 0),
          padding: const EdgeInsets.all(NcSpace.cardPad),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: NcType.rowTitle),
                    if (description != null) ...[
                      const SizedBox(height: 2),
                      Text(description!,
                          style: NcType.caption.copyWith(color: p.muted)),
                    ],
                    if (below != null) ...[const SizedBox(height: 6), below!],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 16), trailing!],
            ],
          ),
        );
    if (onTap == null) return content(null);
    return Pressable(onTap: onTap, builder: (context, s) => content(s));
  }
}
