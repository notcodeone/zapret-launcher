import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app_info.dart';
import '../theme.dart';
import 'buttons.dart';

/// Статус занятия в шапке. Пока [kind] тот же (например, проценты),
/// текст меняется на месте; при смене вида — анимированная замена.
@immutable
class HeaderStatus {
  const HeaderStatus(this.kind, this.text);

  final String kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is HeaderStatus && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);
}

/// Шапка плавает над содержимым: карточка со скруглением 16, слева —
/// знак и название приложения, справа — кнопки-иконки. Пока приложение
/// что-то делает, вместо названия — индикатор и статус.
/// На внутренних страницах — стрелка «назад» и название раздела.
class NcHeader extends StatelessWidget {
  const NcHeader({
    super.key,
    this.title,
    this.onBack,
    this.status,
    this.actions = const [],
  });

  /// Название раздела на внутренней странице; null — главная.
  final String? title;
  final VoidCallback? onBack;
  final HeaderStatus? status;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final Widget lead;
    final String leadKey;
    if (status != null) {
      lead = _StatusLabel(status: status!);
      leadKey = 'status:${status!.kind}';
    } else if (title != null) {
      lead = Text(title!, style: NcType.header, maxLines: 1, overflow: TextOverflow.ellipsis);
      leadKey = 'title:$title';
    } else {
      lead = const _Brand();
      leadKey = 'brand';
    }

    return Container(
      height: NcSpace.headerHeight,
      padding: EdgeInsets.only(left: onBack != null ? 8 : 16, right: 8),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(NcRadius.float),
        boxShadow: p.softShadow,
        border: p.cardOutline,
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            NcIconButton(icon: LucideIcons.arrowLeft, tooltip: 'Назад', onPressed: onBack),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: ClipRect(
              child: _SlideSwitcher(
                childKey: leadKey,
                child: Align(alignment: Alignment.centerLeft, child: lead),
              ),
            ),
          ),
          for (final a in actions) ...[const SizedBox(width: 2), a],
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: p.primary,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(LucideIcons.zap, size: 15, color: p.onPrimary),
        ),
        const SizedBox(width: 10),
        const Text(AppInfo.name, style: NcType.header),
      ],
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status});

  final HeaderStatus status;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: p.text),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            status.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NcType.button.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: NcType.tabular,
            ),
          ),
        ),
      ],
    );
  }
}

/// Смена содержимого шапки: прежнее уходит вверх и гаснет, новое поднимается снизу.
class _SlideSwitcher extends StatelessWidget {
  const _SlideSwitcher({required this.childKey, required this.child});

  final String childKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = NcMotion.reduced(context);
    return AnimatedSwitcher(
      duration: NcMotion.headerStatus,
      switchInCurve: NcMotion.enter,
      switchOutCurve: NcMotion.exit,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        if (reduced) return FadeTransition(opacity: animation, child: child);
        final incoming = child.key == ValueKey(childKey);
        final offset = Tween<Offset>(
          begin: incoming ? const Offset(0, .6) : const Offset(0, -.6),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: KeyedSubtree(key: ValueKey(childKey), child: child),
    );
  }
}

/// Подвал: копирайт и версия слева, автор справа, 12,5 pt muted.
class NcFooter extends StatelessWidget {
  const NcFooter({super.key, this.trailing});

  /// Например, тихая кнопка «Обновить до …».
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = NcType.caption.copyWith(color: context.palette.muted);
    return SizedBox(
      height: NcSpace.footerHeight,
      // Слева копирайт (и кнопка обновления), справа автор; при нехватке места — многоточие.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 3,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text('© 2026 ${AppInfo.name} ${AppInfo.version}',
                      style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (trailing != null) ...[const SizedBox(width: 6), Flexible(child: trailing!)],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            flex: 2,
            child: Text('Designed by NotCode',
                style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
