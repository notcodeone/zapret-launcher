import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'pressable.dart';

/// Переключатель: дорожка 52 × 32, бегунок 24 одного размера в обоих положениях.
/// Включён — primary, выключен — серая дорожка.
class NcSwitch extends StatelessWidget {
  const NcSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onChanged != null;
    final duration = NcMotion.reduced(context)
        ? Duration.zero
        : NcMotion.segment;
    return Semantics(
      toggled: value,
      label: label,
      child: Pressable(
        onTap: enabled ? () => onChanged!(!value) : null,
        builder: (context, s) => Opacity(
          opacity: enabled ? 1 : .5,
          child: AnimatedContainer(
            duration: duration,
            curve: NcMotion.enter,
            width: 52,
            height: 32,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: value ? p.primary : p.switchOff,
              borderRadius: BorderRadius.circular(16),
              border: s.focused
                  ? Border.all(color: p.primary.withValues(alpha: .4), width: 2)
                  : null,
            ),
            child: AnimatedAlign(
              duration: duration,
              curve: NcMotion.enter,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? p.onPrimary : Colors.white,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NcSegment<T> {
  const NcSegment(this.value, this.label, {this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// Сегменты: подложка field с полями 3, выбранный вариант — «таблетка»
/// цвета карточки с тенью и жирным текстом. Для 2–4 взаимоисключающих вариантов.
class NcSegmented<T> extends StatelessWidget {
  const NcSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<NcSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final index = segments.indexWhere((s) => s.value == value);
    final duration = NcMotion.reduced(context)
        ? Duration.zero
        : NcMotion.segment;
    final n = segments.length;
    return Opacity(
      opacity: onChanged == null ? .6 : 1,
      child: Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: BorderRadius.circular(NcRadius.control),
        ),
        child: Stack(
          children: [
            if (index >= 0)
              AnimatedAlign(
                duration: duration,
                curve: NcMotion.enter,
                alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / n,
                  heightFactor: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(NcRadius.segment),
                      boxShadow: [
                        BoxShadow(
                          color: Color.fromRGBO(0, 0, 0, p.shadowAlpha + .03),
                          blurRadius: 6,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Row(
              children: [
                for (final s in segments)
                  Expanded(
                    child: Pressable(
                      onTap: onChanged == null
                          ? null
                          : () => onChanged!(s.value),
                      semanticLabel: s.label,
                      builder: (context, st) {
                        final selected = s.value == value;
                        final color = selected || st.hovered ? p.text : p.muted;
                        return Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (s.icon != null) ...[
                                Icon(s.icon, size: 15, color: color),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: AnimatedDefaultTextStyle(
                                  duration: duration,
                                  style: NcType.button.copyWith(
                                    color: color,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    fontFamily: NcType.family,
                                    fontFamilyFallback: NcType.fallback,
                                  ),
                                  child: Text(
                                    s.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Полоса прогресса: подложка field, заполнение primary, скругление 2.
class NcProgressBar extends StatelessWidget {
  const NcProgressBar({super.key, required this.value});

  /// От 0 до 1.
  final double value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        height: 4,
        color: p.field,
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0, 1)),
          duration: NcMotion.reduced(context)
              ? Duration.zero
              : NcMotion.cardAppear,
          curve: NcMotion.enter,
          builder: (context, v, _) => FractionallySizedBox(
            widthFactor: v,
            child: Container(color: p.primary),
          ),
        ),
      ),
    );
  }
}

/// Поле ввода: заливка field без видимой рамки; в фокусе — цвета карточки с рамкой
/// 2 pt primary. Рамка есть всегда (цвета заливки), поэтому текст не прыгает.
/// Ошибка — рамка danger и текст 12 pt под полем.
class NcTextField extends StatefulWidget {
  const NcTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.error,
    this.prefixIcon,
    this.minLines = 1,
    this.maxLines = 1,
    this.maxLength,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController? controller;
  final String? label;

  /// Подсказка внутри поля — реальный пример, а не повтор подписи.
  final String? hint;
  final String? error;
  final IconData? prefixIcon;
  final int minLines;
  final int maxLines;

  /// Сколько символов можно ввести; лишнее не вставится.
  final int? maxLength;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<NcTextField> createState() => _NcTextFieldState();
}

class _NcTextFieldState extends State<NcTextField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final focused = _focus.hasFocus;
    final hasError = widget.error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          NcFieldLabel(widget.label!),
          const SizedBox(height: 8),
        ],
        AnimatedContainer(
          duration: NcMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: focused ? p.card : p.field,
            borderRadius: BorderRadius.circular(NcRadius.control),
            border: Border.all(
              width: 2,
              color: hasError ? p.danger : (focused ? p.primary : p.field),
            ),
          ),
          child: Row(
            crossAxisAlignment: widget.maxLines == 1
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              if (widget.prefixIcon != null) ...[
                Icon(widget.prefixIcon, size: 16, color: p.muted),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  minLines: widget.minLines,
                  maxLines: widget.maxLines,
                  inputFormatters: [
                    if (widget.maxLength case final max?)
                      LengthLimitingTextInputFormatter(max),
                  ],
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  style: NcType.body.copyWith(color: p.text),
                  cursorColor: p.text,
                  decoration: InputDecoration.collapsed(
                    hintText: widget.hint,
                    hintStyle: NcType.body.copyWith(color: p.muted),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Text(widget.error!, style: TextStyle(fontSize: 12, color: p.danger)),
        ],
      ],
    );
  }
}

/// Подпись над полем: заглавными 11 pt muted с разрядкой 0,6.
class NcFieldLabel extends StatelessWidget {
  const NcFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: NcType.fieldLabel.copyWith(color: context.palette.muted),
    );
  }
}
