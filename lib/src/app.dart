import 'package:flutter/material.dart';

import 'app_info.dart';
import 'controller.dart';
import 'pages/autopick_page.dart';
import 'pages/bypass_options_page.dart';
import 'pages/diagnostics_page.dart';
import 'pages/home_page.dart';
import 'pages/lists_page.dart';
import 'pages/network_menu.dart';
import 'pages/networks_page.dart';
import 'pages/settings_page.dart';
import 'pages/strategies_page.dart';
import 'shell.dart';
import 'ui/ui.dart';

class ZapretLauncherApp extends StatefulWidget {
  const ZapretLauncherApp({
    super.key,
    this.controller,
    this.initialRoute,
    this.themeOverride,
  });

  /// Для тестов; в приложении контроллер создаётся здесь.
  final AppController? controller;

  /// Для отладки: открыть сразу эту страницу (/settings, /strategies) или тему.
  final String? initialRoute;
  final ThemeMode? themeOverride;

  @override
  State<ZapretLauncherApp> createState() => _ZapretLauncherAppState();
}

class _ZapretLauncherAppState extends State<ZapretLauncherApp> {
  late final ToastController _toasts =
      widget.controller?.toasts ?? ToastController();
  late final AppController _controller =
      widget.controller ?? (AppController(toasts: _toasts)..init());

  /// Трей и закрытие окна — только в настоящем приложении, не в тестах.
  DesktopShell? _shell;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _shell = DesktopShell(_controller)..init();
    }
  }

  @override
  void dispose() {
    _shell?.dispose();
    if (widget.controller == null) {
      _controller.dispose();
      _toasts.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
        title: AppInfo.name,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: widget.themeOverride ?? _controller.themeMode,
        builder: (context, child) => AppScope(
          controller: _controller,
          child: ToastScope(controller: _toasts, child: child!),
        ),
        initialRoute: widget.initialRoute,
        onGenerateRoute: (settings) => NcPageRoute<void>(
          builder: (_) => switch (settings.name) {
            '/settings' => const SettingsPage(),
            // /settings/general, /settings/zapret, /settings/network, /settings/updates.
            final String name when name.startsWith('/settings/') =>
              SettingsSectionPage(
                section: SettingsSection.values.firstWhere(
                  (s) => name == '/settings/${s.name}',
                  orElse: () => SettingsSection.general,
                ),
              ),
            '/strategies' => const StrategiesPage(),
            '/autopick' => const AutoPickPage(),
            '/diagnostics' => const DiagnosticsPage(),
            '/network' => const _OpenNetworkMenu(),
            '/lists' => const ListsPage(),
            '/networks' => const NetworksPage(),
            '/options' => const BypassOptionsPage(),
            _ => const HomePage(),
          },
        ),
      ),
    );
  }
}

/// Для отладки (--route=/network): главная с открытым меню проверки сети.
class _OpenNetworkMenu extends StatefulWidget {
  const _OpenNetworkMenu();

  @override
  State<_OpenNetworkMenu> createState() => _OpenNetworkMenuState();
}

class _OpenNetworkMenuState extends State<_OpenNetworkMenu> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showNetworkMenu(context);
    });
  }

  @override
  Widget build(BuildContext context) => const HomePage();
}
