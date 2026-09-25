import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:wayfork/app/services/tray_menu.dart';

typedef TrayCommandSink = void Function(TrayCommand command);

/// The notification-area icon, behind an interface so the controller can be
/// driven without the plugin (and without a Windows message loop) in tests.
abstract interface class TrayBackend {
  /// Creates the icon and starts delivering events.
  Future<void> start({
    required VoidCallback onActivate,
    required VoidCallback onMenuRequested,
    required TrayCommandSink onCommand,
  });

  /// [asset] is a Flutter asset path; the plugin resolves it under
  /// `data/flutter_assets`.
  Future<void> setIcon(String asset);

  Future<void> setToolTip(String toolTip);
  Future<void> setMenu(List<TrayMenuEntry> entries);

  /// Shows the context menu at the cursor.
  Future<void> popUpMenu();

  Future<void> dispose();
}

/// `tray_manager` backing of [TrayBackend]. Left click activates, right click
/// pops the menu — on Windows the plugin reports both and pops nothing by
/// itself.
final class TrayManagerBackend with tray.TrayListener implements TrayBackend {
  TrayManagerBackend({tray.TrayManager? manager})
    : _manager = manager ?? tray.trayManager;

  final tray.TrayManager _manager;
  VoidCallback? _onActivate;
  VoidCallback? _onMenuRequested;
  TrayCommandSink? _onCommand;

  @override
  Future<void> start({
    required VoidCallback onActivate,
    required VoidCallback onMenuRequested,
    required TrayCommandSink onCommand,
  }) async {
    _onActivate = onActivate;
    _onMenuRequested = onMenuRequested;
    _onCommand = onCommand;
    _manager.addListener(this);
  }

  @override
  Future<void> setIcon(String asset) => _manager.setIcon(asset);

  @override
  Future<void> setToolTip(String toolTip) => _manager.setToolTip(toolTip);

  @override
  Future<void> setMenu(List<TrayMenuEntry> entries) =>
      _manager.setContextMenu(tray.Menu(items: _items(entries)));

  @override
  Future<void> popUpMenu() => _manager.popUpContextMenu();

  @override
  Future<void> dispose() async {
    _manager.removeListener(this);
    await _manager.destroy();
  }

  List<tray.MenuItem> _items(List<TrayMenuEntry> entries) => [
    for (final entry in entries)
      switch (entry) {
        TrayMenuSeparator() => tray.MenuItem.separator(),
        TrayMenuItem(:final submenu?) => tray.MenuItem.submenu(
          key: entry.key,
          label: entry.label,
          toolTip: entry.toolTip,
          disabled: !entry.enabled,
          submenu: tray.Menu(items: _items(submenu)),
        ),
        TrayMenuItem(checked: final checked?) => tray.MenuItem.checkbox(
          key: entry.key,
          label: entry.label,
          toolTip: entry.toolTip,
          checked: checked,
          disabled: !entry.enabled,
          onClick: (_) => _dispatch(entry.command),
        ),
        TrayMenuItem() => tray.MenuItem(
          key: entry.key,
          label: entry.label,
          toolTip: entry.toolTip,
          disabled: !entry.enabled,
          onClick: (_) => _dispatch(entry.command),
        ),
      },
  ];

  void _dispatch(TrayCommand? command) {
    if (command != null) _onCommand?.call(command);
  }

  @override
  void onTrayIconMouseDown() => _onActivate?.call();

  @override
  void onTrayIconRightMouseDown() => _onMenuRequested?.call();
}
