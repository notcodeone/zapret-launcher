import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import 'pressable.dart';

/// Оповещение — новость или итог действия. Одна строка, одно действие-глагол.
@immutable
class ToastData {
  const ToastData(
    this.text, {
    this.icon = LucideIcons.circleCheck,
    this.actionLabel,
    this.onAction,
    this.duration = const Duration(seconds: 6),
  });

  /// Об обновлениях оповещение висит дольше — 10 секунд.
  const ToastData.update(
    this.text, {
    this.icon = LucideIcons.download,
    this.actionLabel,
    this.onAction,
  }) : duration = const Duration(seconds: 10);

  final String text;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
}

/// Очередь оповещений: несколько — по очереди.
class ToastController extends ChangeNotifier {
  final _queue = Queue<ToastData>();
  ToastData? _current;
  Timer? _timer;
  bool _hovered = false;

  ToastData? get current => _current;

  /// Несколько оповещений — по очереди. [urgent] — сменяет текущее сразу:
  /// «Вернуть» после удаления бесполезно через 6 секунд.
  void show(ToastData toast, {bool urgent = false}) {
    if (urgent) {
      _queue.addFirst(toast);
      if (_current != null) {
        dismiss();
        return;
      }
    } else {
      _queue.add(toast);
    }
    if (_current == null) _next();
  }

  void dismiss() {
    _timer?.cancel();
    _current = null;
    notifyListeners();
    // Даём прежнему уйти, прежде чем показать следующее.
    if (_queue.isNotEmpty) {
      Timer(NcMotion.toastOut + const Duration(milliseconds: 80), _next);
    }
  }

  /// Пока курсор над оповещением — не уходит.
  void setHovered(bool value) {
    _hovered = value;
    if (value) {
      _timer?.cancel();
    } else if (_current != null) {
      _arm(_current!.duration);
    }
  }

  void _next() {
    if (_queue.isEmpty || _current != null) return;
    _current = _queue.removeFirst();
    notifyListeners();
    if (!_hovered) _arm(_current!.duration);
  }

  void _arm(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, dismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Плашка цвета primary высотой 52 и шириной в окно.
class ToastBar extends StatelessWidget {
  const ToastBar({super.key, required this.data, required this.controller});

  final ToastData data;
  final ToastController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      onEnter: (_) => controller.setHovered(true),
      onExit: (_) => controller.setHovered(false),
      child: Container(
        height: NcSpace.fabHeight,
        padding: const EdgeInsets.only(left: 16, right: 8),
        decoration: BoxDecoration(
          color: p.primary,
          borderRadius: BorderRadius.circular(NcRadius.float),
          boxShadow: p.softShadow,
        ),
        child: Row(
          children: [
            Icon(data.icon, size: 18, color: p.onPrimary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                data.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NcType.body.copyWith(
                  color: p.onPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (data.actionLabel != null)
              _ToastAction(
                label: data.actionLabel!,
                onTap: () {
                  data.onAction?.call();
                  controller.dismiss();
                },
              ),
            Tooltip(
              message: 'Закрыть',
              child: Pressable(
                onTap: controller.dismiss,
                builder: (context, s) => AnimatedContainer(
                  duration: NcMotion.hover,
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.onPrimary.withValues(alpha: s.hovered ? .1 : 0),
                  ),
                  child: Icon(LucideIcons.x, size: 16, color: p.onPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToastAction extends StatelessWidget {
  const _ToastAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Pressable(
      onTap: onTap,
      builder: (context, s) => AnimatedContainer(
        duration: NcMotion.hover,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: p.onPrimary.withValues(
            alpha: s.pressed ? .16 : (s.hovered ? .12 : .08),
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: NcType.button.copyWith(
            color: p.onPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
