import 'package:flutter/foundation.dart';
import 'package:wayfork/app/services/tray_backend.dart';
import 'package:wayfork/app/services/tray_menu.dart';
import 'package:wayfork/app/services/window_backend.dart';

/// Records what the tray was asked to display and replays its events.
final class FakeTrayBackend implements TrayBackend {
  final icons = <String>[];
  final toolTips = <String>[];
  final menus = <List<TrayMenuEntry>>[];
  int popUps = 0;
  int disposals = 0;

  /// Thrown by [setIcon] when set (a shell that refuses the icon).
  Object? iconFailure;

  VoidCallback? _onActivate;
  VoidCallback? _onMenuRequested;
  TrayCommandSink? _onCommand;

  List<TrayMenuEntry> get menu => menus.isEmpty ? const [] : menus.last;
  String? get icon => icons.isEmpty ? null : icons.last;
  String? get toolTip => toolTips.isEmpty ? null : toolTips.last;

  void activate() => _onActivate?.call();
  void requestMenu() => _onMenuRequested?.call();
  void send(TrayCommand command) => _onCommand?.call(command);

  /// Clicks the entry with this key, submenus included.
  void click(String key) {
    final item = _find(menu, key);
    if (item == null) throw StateError('no tray item "$key"');
    final command = item.command;
    if (command == null) throw StateError('tray item "$key" has no command');
    send(command);
  }

  TrayMenuItem? _find(List<TrayMenuEntry> entries, String key) {
    for (final entry in entries) {
      if (entry is! TrayMenuItem) continue;
      if (entry.key == key) return entry;
      final submenu = entry.submenu;
      if (submenu == null) continue;
      final found = _find(submenu, key);
      if (found != null) return found;
    }
    return null;
  }

  @override
  Future<void> start({
    required VoidCallback onActivate,
    required VoidCallback onMenuRequested,
    required TrayCommandSink onCommand,
  }) async {
    _onActivate = onActivate;
    _onMenuRequested = onMenuRequested;
    _onCommand = onCommand;
  }

  @override
  Future<void> setIcon(String asset) async {
    final failure = iconFailure;
    if (failure != null) throw failure;
    icons.add(asset);
  }

  @override
  Future<void> setToolTip(String toolTip) async => toolTips.add(toolTip);

  @override
  Future<void> setMenu(List<TrayMenuEntry> entries) async => menus.add(entries);

  @override
  Future<void> popUpMenu() async => popUps += 1;

  @override
  Future<void> dispose() async => disposals += 1;
}

/// A window that only remembers whether it is up and in front.
final class FakeWindowBackend implements WindowBackend {
  bool visible = false;
  bool focused = false;
  bool destroyed = false;
  int disposals = 0;
  VoidCallback? _onClose;

  /// The user pressed the caption's close button.
  void close() => _onClose?.call();

  @override
  Future<void> start({
    required bool startHidden,
    required VoidCallback onClose,
  }) async {
    _onClose = onClose;
    visible = !startHidden;
    focused = visible;
  }

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<bool> isFocused() async => focused;

  @override
  Future<void> show() async {
    visible = true;
  }

  @override
  Future<void> hide() async {
    visible = false;
    focused = false;
  }

  @override
  Future<void> focus() async {
    focused = true;
  }

  @override
  Future<void> destroy() async {
    destroyed = true;
    visible = false;
  }

  @override
  Future<void> dispose() async => disposals += 1;
}
