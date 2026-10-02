import 'package:flutter/services.dart';

/// Пункт меню значка в трее.
class TrayMenuEntry {
  const TrayMenuEntry(this.id, this.label, {this.enabled = true, this.isDefault = false})
      : separator = false;

  const TrayMenuEntry.separator()
      : id = 0,
        label = '',
        enabled = false,
        isDefault = false,
        separator = true;

  final int id;
  final String label;
  final bool enabled;
  final bool isDefault;
  final bool separator;

  Map<String, Object> toMap() => {
        'id': id,
        'label': label,
        'enabled': enabled,
        'default': isDefault,
        'separator': separator,
      };
}

/// Окно и значок в трее — канал к C++ раннеру (windows/runner/flutter_window.cpp).
/// Без раннера (в тестах) вызовы ничего не делают.
class WindowChannel {
  WindowChannel() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('zapret_launcher/window');

  /// Нажали крестик (если включён перехват закрытия).
  VoidCallback? onCloseRequested;

  /// Выбран пункт меню в трее.
  ValueChanged<int>? onTrayMenu;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'closeRequested':
        onCloseRequested?.call();
      case 'trayMenu':
        onTrayMenu?.call(call.arguments as int);
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> show() => _invoke('show');
  Future<void> hide() => _invoke('hide');

  /// Закрыть окно и выйти из приложения.
  Future<void> quit() => _invoke('quit');
  Future<bool> isVisible() async => await _invoke<bool>('isVisible') ?? true;
  Future<void> setInterceptClose(bool value) => _invoke('setInterceptClose', value);

  /// Размер значка в трее в пикселях для текущего масштаба экрана.
  Future<int> trayIconSize() async => await _invoke<int>('trayIconSize') ?? 16;

  Future<void> setTray({required Uint8List rgba, required int size, required String tooltip}) =>
      _invoke('setTray', {'icon': rgba, 'size': size, 'tooltip': tooltip});

  Future<void> setTrayMenu(List<TrayMenuEntry> items) =>
      _invoke('setTrayMenu', [for (final i in items) i.toMap()]);

  Future<void> removeTray() => _invoke('removeTray');

  /// Всплывающее уведомление у значка.
  Future<void> balloon(String title, String text) =>
      _invoke('balloon', {'title': title, 'text': text});
}
