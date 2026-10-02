import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Состояние нажимаемого элемента для построения подсветки.
class PressState {
  const PressState({
    required this.hovered,
    required this.pressed,
    required this.focused,
    required this.enabled,
  });

  final bool hovered;
  final bool pressed;
  final bool focused;
  final bool enabled;
}

/// Основа всех нажимаемых элементов: наведение, нажатие, фокус с клавиатуры.
///
/// Вместо «ряби» Material — заливка цветом текста, как в дизайн-системе.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
    this.semanticLabel,
  });

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, PressState state) builder;
  final MouseCursor cursor;
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onTap != null;

  void _activate() => widget.onTap?.call();

  @override
  Widget build(BuildContext context) {
    final state = PressState(
      hovered: _enabled && _hovered,
      pressed: _enabled && _pressed,
      focused: _enabled && _focused,
      enabled: _enabled,
    );
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled ? widget.cursor : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTap: _enabled ? _activate : null,
          child: widget.builder(context, state),
        ),
      ),
    );
  }
}
