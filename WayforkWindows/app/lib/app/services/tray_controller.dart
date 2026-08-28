import 'dart:async';

import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/system_theme.dart';
import 'package:wayfork/app/services/tray_backend.dart';
import 'package:wayfork/app/services/tray_icons.dart';
import 'package:wayfork/app/services/tray_menu.dart';
import 'package:wayfork/app/services/window_controller.dart';
import 'package:wayfork/app/ui/app_actions.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/core/model/settings.dart';

/// Drives the notification-area icon from the model: the glyph of
/// docs/design/02-ux.md ("Menu bar icon"), the summary as the tooltip and the
/// context menu of the approved prototype.
final class TrayController {
  TrayController({
    required this.model,
    required this.backend,
    required this.window,
    required this.navigator,
    required this.actions,
    required this.onQuit,
    this.theme = SystemTheme.trayTheme,
    this.refreshInterval = const Duration(seconds: 10),
  });

  /// `NOTIFYICONDATA.szTip` holds 128 UTF-16 units, terminator included.
  static const toolTipLimit = 127;

  final AppModel model;
  final TrayBackend backend;
  final WindowController window;
  final AppNavigator navigator;
  final AppActionHandler actions;

  /// Everything the app must do before the process ends.
  final Future<void> Function() onQuit;

  final TrayTheme Function() theme;

  /// The model does not notify when the notification area switches between
  /// light and dark, so the icon is re-read on a slow tick as well.
  final Duration refreshInterval;

  Timer? _timer;
  bool _refreshing = false;
  bool _refreshAgain = false;
  String? _icon;
  String? _toolTip;
  List<TrayMenuEntry>? _menu;

  Future<void> start() async {
    await backend.start(
      onActivate: () => unawaited(window.toggle()),
      onMenuRequested: _showMenu,
      onCommand: (command) => unawaited(run(command)),
    );
    await refresh();
    model.addListener(_onModelChanged);
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
  }

  /// Pushes icon, tooltip and menu when they changed. Serialised: the backend
  /// is asynchronous and the model can notify while a push is in flight.
  ///
  /// A shell that refuses the icon (`Shell_NotifyIcon` fails while Explorer is
  /// restarting, or there is no shell at all) is logged and forgotten: the app
  /// still routes, and the next refresh tries again.
  Future<void> refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        try {
          await _push();
        } on Object catch (error) {
          _forget();
          model.logs.app(LogLevel.warning, 'tray icon: $error');
        }
      } while (_refreshAgain);
    } finally {
      _refreshing = false;
    }
  }

  /// Drops the de-duplication state so a failed push is retried in full.
  void _forget() {
    _icon = null;
    _toolTip = null;
    _menu = null;
  }

  Future<void> _push() async {
    final issue = model.serviceIssue;
    final icon = TrayIcons.asset(
      TrayIcons.forState(
        model.globalState,
        pulse: model.iconPulse,
        needsRepair: issue != null && issue.needsRepair,
      ),
      theme(),
    );
    if (icon != _icon) {
      _icon = icon;
      await backend.setIcon(icon);
    }
    final toolTip = _toolTipText();
    if (toolTip != _toolTip) {
      _toolTip = toolTip;
      await backend.setToolTip(toolTip);
    }
    final menu = TrayMenu.build(model);
    final previous = _menu;
    if (previous == null || !TrayMenu.entryEquality.equals(previous, menu)) {
      _menu = menu;
      await backend.setMenu(menu);
    }
  }

  String _toolTipText() {
    final text = 'Wayfork — ${model.summary}';
    return text.length <= toolTipLimit
        ? text
        : '${text.substring(0, toolTipLimit - 1)}…';
  }

  void _showMenu() {
    // The menu is already current; refresh() only pushes on a change.
    unawaited(
      refresh().then((_) => backend.popUpMenu()).catchError((Object error) {
        model.logs.app(LogLevel.warning, 'tray menu: $error');
      }),
    );
  }

  Future<void> run(TrayCommand command) async {
    switch (command) {
      case TrayCommandToggle():
        await model.toggle();
      case TrayCommandOpenWindow():
        await window.showAndFocus();
      case TrayCommandQuickAdd():
        navigator.quickAdd();
        await window.showAndFocus();
      case TrayCommandReconnect(:final tunnelID):
        await (tunnelID == null
            ? model.reconnectAll()
            : model.reconnect(tunnelID));
      case TrayCommandShowLogs():
        navigator.showLogs();
        await window.showAndFocus();
      case TrayCommandShowSettings():
        navigator.go(AppPage.general);
        await window.showAndFocus();
      case TrayCommandRepair():
        await actions.handle(const AppAction.repairInstallation());
      case TrayCommandQuit():
        await onQuit();
    }
  }

  void _onModelChanged() => unawaited(refresh());

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    model.removeListener(_onModelChanged);
    await backend.dispose();
  }
}
