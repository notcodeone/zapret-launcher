import 'dart:async';

import 'package:flutter/painting.dart';

import 'controller.dart';
import 'platform/win32.dart' as win;
import 'platform/window.dart';
import 'ui/brand.dart';
import 'ui/theme.dart';

/// Окно и значок в трее: закрытие в трей, меню значка, уведомления, выход.
class DesktopShell {
  DesktopShell(this._c, {WindowChannel? window}) : _w = window ?? WindowChannel();

  final AppController _c;
  final WindowChannel _w;

  static const _idStatus = 9;
  static const _idOpen = 1;
  static const _idToggle = 2;
  static const _idQuit = 3;

  String? _iconKey;
  String? _tooltip;
  String? _menuKey;
  bool _syncing = false;
  bool _dirty = false;
  bool _quitting = false;

  Future<void> init() async {
    _w
      ..onCloseRequested = _onClose
      ..onTrayMenu = _onMenu;
    _c
      ..quitHandler = quit
      ..onBackgroundNotice = _notifyIfHidden;
    await _w.setInterceptClose(true);
    await _sync();
    _c.addListener(_sync);
  }

  void dispose() {
    _c.removeListener(_sync);
    _w
      ..onCloseRequested = null
      ..onTrayMenu = null;
  }

  /// Выход: подбор останавливается, zapret остаётся как был, значок убирается.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    await _c.prepareToQuit();
    await _w.removeTray();
    await _w.quit();
  }

  Future<void> _onClose() async {
    if (!_c.settings.closeToTray) return quit();
    await _w.hide();
    if (!_c.settings.trayHintShown) {
      _c.markTrayHintShown();
      await _w.balloon(
        'ZapretLauncher в трее',
        'Окно закрыто, но лаунчер работает и следит за zapret. '
            'Выйти — правой кнопкой по значку.',
      );
    }
  }

  void _onMenu(int id) {
    switch (id) {
      case _idOpen:
        _w.show();
      case _idToggle:
        _c.toggle();
      case _idQuit:
        quit();
    }
  }

  Future<void> _notifyIfHidden(String title, String text) async {
    if (!await _w.isVisible()) await _w.balloon(title, text);
  }

  String get _statusText {
    final busy = _c.busy;
    if (busy != null) return busy.text;
    if (_c.install == null) return 'Zapret не установлен';
    if (_c.running) {
      final s = _c.strategy?.title;
      return s == null ? 'Zapret работает' : 'Zapret работает — «$s»';
    }
    if (_c.guard.autoOff != null) return 'Zapret выключен — сменилась сеть';
    return 'Zapret выключен';
  }

  /// Перерисовывает значок, подсказку и меню, только если они изменились.
  Future<void> _sync() async {
    if (_quitting) return;
    if (_syncing) {
      _dirty = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _dirty = false;
        await _syncOnce();
      } while (_dirty && !_quitting);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    final status = _statusText;
    var tooltip = 'ZapretLauncher\n$status';
    if (tooltip.length > 120) tooltip = '${tooltip.substring(0, 119)}…';

    // Значок — под цвет панели задач: на тёмной светлый квадрат, на светлой тёмный.
    final lightTaskbar = win.readRegistryDword(
            r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
            'SystemUsesLightTheme',
            currentUser: true) ==
        1;
    final alarm = _c.error != null;
    final busy = _c.busy != null;
    final running = _c.running;
    final size = await _w.trayIconSize();
    final iconKey = '$size|$lightTaskbar|$running|$busy|$alarm';

    if (iconKey != _iconKey || tooltip != _tooltip) {
      final p = lightTaskbar ? Palette.light : Palette.dark;
      final dot = alarm
          ? p.danger
          : busy
              ? p.warning
              : running
                  ? p.success
                  : null;
      // Выключен — знак приглушён.
      final fade = running || busy ? 1.0 : .6;
      final rgba = await BrandMark.renderRgba(
        size,
        background: p.primary.withValues(alpha: fade),
        foreground: p.onPrimary,
        dot: dot,
        dotRing: lightTaskbar ? const Color(0xFFEEEEEE) : const Color(0xFF1C1C1C),
      );
      await _w.setTray(rgba: rgba, size: size, tooltip: tooltip);
      _iconKey = iconKey;
      _tooltip = tooltip;
    }

    final canToggle = _c.elevated && !busy && _c.strategy != null && !_c.runningElsewhere;
    final menu = [
      TrayMenuEntry(_idStatus, status, enabled: false),
      const TrayMenuEntry.separator(),
      const TrayMenuEntry(_idOpen, 'Открыть ZapretLauncher', isDefault: true),
      TrayMenuEntry(_idToggle, running ? 'Выключить zapret' : 'Включить zapret', enabled: canToggle),
      const TrayMenuEntry.separator(),
      const TrayMenuEntry(_idQuit, 'Выход'),
    ];
    final menuKey = menu.map((e) => '${e.id}:${e.label}:${e.enabled}').join('|');
    if (menuKey != _menuKey) {
      await _w.setTrayMenu(menu);
      _menuKey = menuKey;
    }
  }
}
