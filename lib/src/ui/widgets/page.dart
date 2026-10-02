import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'header.dart';
import 'pressable.dart';
import 'toast.dart';

/// Даёт страницам общий [ToastController].
class ToastScope extends InheritedNotifier<ToastController> {
  const ToastScope({super.key, required ToastController controller, required super.child})
      : super(notifier: controller);

  static ToastController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ToastScope>()!.notifier!;
}

/// Окно — одна колонка: плавающая шапка сверху и подвал снизу.
/// Содержимое прокручивается под ними, уходя в затемнение.
class NcPage extends StatelessWidget {
  const NcPage({
    super.key,
    required this.header,
    required this.children,
    this.fab,
    this.footer = const NcFooter(),
  });

  final Widget header;
  final List<Widget> children;

  /// Главное действие страницы — в правом нижнем углу над подвалом.
  final Widget? fab;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final toasts = ToastScope.of(context);
    const top = NcSpace.headerTop + NcSpace.headerHeight;
    final bottomReserve = NcSpace.footerHeight +
        (fab != null ? NcSpace.fabHeight + NcSpace.fabGap : 0) +
        16;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                    NcSpace.gutter, top + 24, NcSpace.gutter, bottomReserve),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
          // Затемнение под шапкой и над подвалом.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top + 16,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, .55, 1],
                    colors: [p.background, p.background, p.background.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: NcSpace.footerHeight + 28,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    stops: const [0, .55, 1],
                    colors: [p.background, p.background, p.background.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: NcSpace.headerTop,
            left: NcSpace.gutter,
            right: NcSpace.gutter,
            child: header,
          ),
          Positioned(
            left: NcSpace.gutter,
            right: NcSpace.gutter,
            bottom: 0,
            child: footer,
          ),
          Positioned(
            left: NcSpace.gutter,
            right: NcSpace.gutter,
            bottom: NcSpace.footerHeight + NcSpace.fabGap,
            child: _BottomSlot(fab: fab, toasts: toasts),
          ),
        ],
      ),
    );
  }
}

/// Пока на экране оповещение, кнопка уходит вниз и гаснет: её место занимает оповещение.
class _BottomSlot extends StatelessWidget {
  const _BottomSlot({required this.fab, required this.toasts});

  final Widget? fab;
  final ToastController toasts;

  @override
  Widget build(BuildContext context) {
    final toast = toasts.current;
    final reduced = NcMotion.reduced(context);
    return SizedBox(
      height: NcSpace.fabHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (fab != null)
            Align(
              alignment: Alignment.bottomRight,
              child: AnimatedSlide(
                duration: reduced ? Duration.zero : NcMotion.fabHide,
                curve: toast != null ? NcMotion.exit : NcMotion.enter,
                offset: toast != null ? const Offset(0, .5) : Offset.zero,
                child: AnimatedOpacity(
                  duration: NcMotion.fabHide,
                  opacity: toast != null ? 0 : 1,
                  child: IgnorePointer(ignoring: toast != null, child: fab),
                ),
              ),
            ),
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: NcMotion.toastIn,
              reverseDuration: NcMotion.toastOut,
              switchInCurve: NcMotion.enter,
              switchOutCurve: NcMotion.exit,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: reduced
                    ? child
                    : SlideTransition(
                        position: Tween(begin: const Offset(0, .35), end: Offset.zero)
                            .animate(animation),
                        child: child,
                      ),
              ),
              child: toast == null
                  ? const SizedBox.shrink(key: ValueKey('none'))
                  : ToastBar(key: ObjectKey(toast), data: toast, controller: toasts),
            ),
          ),
        ],
      ),
    );
  }
}

/// Кнопка главного действия страницы: высота 52, скругление 16, с тенью.
class NcFab extends StatelessWidget {
  const NcFab({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null;
    // Неактивная — как неактивная кнопка: field и muted.
    final bg = enabled ? p.primary : p.field;
    final fg = enabled ? p.onPrimary : p.muted;
    return Pressable(
      onTap: onPressed,
      semanticLabel: label,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        height: NcSpace.fabHeight,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            fg.withValues(alpha: s.pressed ? .1 : (s.hovered ? .07 : 0)),
            bg,
          ),
          borderRadius: BorderRadius.circular(NcRadius.float),
          boxShadow: enabled ? p.softShadow : null,
          border: s.focused ? Border.all(color: p.onPrimary, width: 2) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NcType.buttonLarge.copyWith(color: fg)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Заголовок страницы 30 pt и пояснение — по предложению на строку.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: NcType.pageTitle),
        if (description != null) ...[
          const SizedBox(height: 8),
          Text(description!, style: NcType.body.copyWith(color: context.palette.muted)),
        ],
      ],
    );
  }
}

/// Подзаголовок раздела 22 pt.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Text(title, style: NcType.section);
}

/// Карточки поднимаются по очереди: снизу на 8 % с проявлением,
/// задержка 60 + 40 × номер мс.
class Appear extends StatefulWidget {
  const Appear({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: NcMotion.cardAppear);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: NcMotion.enter);
  Timer? _delay;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.status == AnimationStatus.dismissed && _delay == null) {
      if (NcMotion.reduced(context)) {
        _c.value = 1;
      } else {
        _delay = Timer(Duration(milliseconds: 60 + 40 * widget.index), _c.forward);
      }
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: FractionalTranslation(
          translation: Offset(0, .08 * (1 - _t.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Переход между страницами по общей оси: новая въезжает справа на 12 %
/// и проявляется, прежняя уезжает влево и гаснет. Назад — наоборот.
class NcPageRoute<T> extends PageRouteBuilder<T> {
  NcPageRoute({required WidgetBuilder builder})
      : super(
          transitionDuration: NcMotion.pageIn,
          reverseTransitionDuration: NcMotion.pageOut,
          pageBuilder: (context, _, _) => builder(context),
          transitionsBuilder: (context, animation, secondary, child) {
            if (NcMotion.reduced(context)) {
              return FadeTransition(opacity: animation, child: child);
            }
            final inCurve = CurvedAnimation(
                parent: animation, curve: NcMotion.enter, reverseCurve: NcMotion.exit);
            final outCurve = CurvedAnimation(
                parent: secondary, curve: NcMotion.enter, reverseCurve: NcMotion.exit);
            return SlideTransition(
              position: Tween(begin: const Offset(.12, 0), end: Offset.zero).animate(inCurve),
              child: FadeTransition(
                opacity: inCurve,
                child: SlideTransition(
                  position:
                      Tween(begin: Offset.zero, end: const Offset(-.12, 0)).animate(outCurve),
                  child: FadeTransition(
                    opacity: Tween<double>(begin: 1, end: 0).animate(outCurve),
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
}

/// Показывает модальное окно по центру: экран под ним затемняется (scrim),
/// окно проявляется с лёгким увеличением. [dismissible] — закрывается кликом мимо и Esc.
Future<T?> showNcModal<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String label,
  bool dismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: label,
    barrierColor: context.palette.scrim,
    transitionDuration: NcMotion.toastIn,
    transitionBuilder: (context, a, _, child) {
      final t = CurvedAnimation(parent: a, curve: NcMotion.enter, reverseCurve: NcMotion.exit);
      return FadeTransition(
        opacity: t,
        child: ScaleTransition(scale: Tween(begin: .96, end: 1.0).animate(t), child: child),
      );
    },
    pageBuilder: (context, _, _) => PopScope(
      canPop: dismissible,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(NcSpace.gutter),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: Material(type: MaterialType.transparency, child: builder(context)),
          ),
        ),
      ),
    ),
  );
}

/// Окно диалога: поля 24, скругление 22, заголовок 20 pt, внизу — крупные кнопки на всю ширину.
class NcDialogFrame extends StatelessWidget {
  const NcDialogFrame({super.key, required this.title, required this.child, required this.actions});

  final String title;
  final Widget child;

  /// Слева «Отмена», справа действие.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(NcRadius.dialog),
        boxShadow: p.menuShadow,
        border: p.cardOutline,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: NcType.dialogTitle),
          const SizedBox(height: 10),
          child,
          const SizedBox(height: 24),
          Row(
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: actions[i]),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

enum NcDialogButtonKind { cancel, primary, danger }

/// Крупная кнопка диалога, высота 46.
class NcDialogButton extends StatelessWidget {
  const NcDialogButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = NcDialogButtonKind.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final NcDialogButtonKind kind;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    var (bg, hover, fg) = switch (kind) {
      NcDialogButtonKind.cancel => (p.field.withValues(alpha: 0), p.field, p.text),
      NcDialogButtonKind.primary => (
          p.primary,
          Color.alphaBlend(p.onPrimary.withValues(alpha: .07), p.primary),
          p.onPrimary,
        ),
      NcDialogButtonKind.danger => (
          p.dangerSurface,
          Color.alphaBlend(p.danger.withValues(alpha: .07), p.dangerSurface),
          p.danger,
        ),
    };
    if (onPressed == null) (bg, hover, fg) = (p.field, p.field, p.muted);
    return Pressable(
      onTap: onPressed,
      semanticLabel: label,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: s.hovered || s.pressed ? hover : bg,
          borderRadius: BorderRadius.circular(NcRadius.control),
          border: s.focused ? Border.all(color: p.primary, width: 2) : null,
        ),
        child: Text(label, style: NcType.buttonLarge.copyWith(color: fg)),
      ),
    );
  }
}

/// Диалог — только когда без ответа нельзя. Заголовок — вопрос или название,
/// текст — последствия.
Future<bool> showNcDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Отмена',
  bool danger = false,
  bool dismissible = true,
}) async {
  final result = await showNcModal<bool>(
    context,
    label: title,
    dismissible: dismissible,
    builder: (context) => NcDialogFrame(
      title: title,
      actions: [
        NcDialogButton(
          label: cancelLabel,
          kind: NcDialogButtonKind.cancel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        NcDialogButton(
          label: confirmLabel,
          kind: danger ? NcDialogButtonKind.danger : NcDialogButtonKind.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
      child: Text(message, style: NcType.body.copyWith(color: context.palette.muted)),
    ),
  );
  return result ?? false;
}