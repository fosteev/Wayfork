import 'package:collection/collection.dart';
import 'package:wayfork/app/model/app_model.dart';

/// What a tray menu entry asks the app to do. Kept apart from the entries so
/// the controller can switch on it and the tests can compare it.
sealed class TrayCommand {
  const TrayCommand();

  const factory TrayCommand.toggle() = TrayCommandToggle;
  const factory TrayCommand.openWindow() = TrayCommandOpenWindow;
  const factory TrayCommand.quickAdd() = TrayCommandQuickAdd;
  const factory TrayCommand.reconnect([String? tunnelID]) =
      TrayCommandReconnect;
  const factory TrayCommand.showLogs() = TrayCommandShowLogs;
  const factory TrayCommand.showSettings() = TrayCommandShowSettings;
  const factory TrayCommand.repair() = TrayCommandRepair;
  const factory TrayCommand.quit() = TrayCommandQuit;
}

final class TrayCommandToggle extends TrayCommand {
  const TrayCommandToggle();

  @override
  bool operator ==(Object other) => other is TrayCommandToggle;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'toggle';
}

final class TrayCommandOpenWindow extends TrayCommand {
  const TrayCommandOpenWindow();

  @override
  bool operator ==(Object other) => other is TrayCommandOpenWindow;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'openWindow';
}

final class TrayCommandQuickAdd extends TrayCommand {
  const TrayCommandQuickAdd();

  @override
  bool operator ==(Object other) => other is TrayCommandQuickAdd;

  @override
  int get hashCode => 2;

  @override
  String toString() => 'quickAdd';
}

/// Restarts one OpenVPN tunnel, or every enabled one when [tunnelID] is null.
final class TrayCommandReconnect extends TrayCommand {
  const TrayCommandReconnect([this.tunnelID]);

  final String? tunnelID;

  @override
  bool operator ==(Object other) =>
      other is TrayCommandReconnect && tunnelID == other.tunnelID;

  @override
  int get hashCode => Object.hash(3, tunnelID);

  @override
  String toString() => 'reconnect(${tunnelID ?? 'all'})';
}

final class TrayCommandShowLogs extends TrayCommand {
  const TrayCommandShowLogs();

  @override
  bool operator ==(Object other) => other is TrayCommandShowLogs;

  @override
  int get hashCode => 4;

  @override
  String toString() => 'showLogs';
}

final class TrayCommandShowSettings extends TrayCommand {
  const TrayCommandShowSettings();

  @override
  bool operator ==(Object other) => other is TrayCommandShowSettings;

  @override
  int get hashCode => 5;

  @override
  String toString() => 'showSettings';
}

final class TrayCommandRepair extends TrayCommand {
  const TrayCommandRepair();

  @override
  bool operator ==(Object other) => other is TrayCommandRepair;

  @override
  int get hashCode => 6;

  @override
  String toString() => 'repair';
}

final class TrayCommandQuit extends TrayCommand {
  const TrayCommandQuit();

  @override
  bool operator ==(Object other) => other is TrayCommandQuit;

  @override
  int get hashCode => 7;

  @override
  String toString() => 'quit';
}

/// One row of the tray context menu, independent of `tray_manager` so the
/// menu can be built and compared without a plugin.
sealed class TrayMenuEntry {
  const TrayMenuEntry();
}

final class TrayMenuSeparator extends TrayMenuEntry {
  const TrayMenuSeparator();

  @override
  bool operator ==(Object other) => other is TrayMenuSeparator;

  @override
  int get hashCode => 0;

  @override
  String toString() => '---';
}

final class TrayMenuItem extends TrayMenuEntry {
  const TrayMenuItem({
    required this.key,
    required this.label,
    this.toolTip,
    this.enabled = true,
    this.checked,
    this.command,
    this.submenu,
  });

  /// Stable identifier; the native ids change on every rebuild.
  final String key;
  final String label;
  final String? toolTip;
  final bool enabled;

  /// Non-null turns the row into a check mark item.
  final bool? checked;
  final TrayCommand? command;
  final List<TrayMenuEntry>? submenu;

  static const _entries = ListEquality<TrayMenuEntry>();

  @override
  bool operator ==(Object other) =>
      other is TrayMenuItem &&
      key == other.key &&
      label == other.label &&
      toolTip == other.toolTip &&
      enabled == other.enabled &&
      checked == other.checked &&
      command == other.command &&
      (submenu == null) == (other.submenu == null) &&
      (submenu == null || _entries.equals(submenu!, other.submenu!));

  @override
  int get hashCode => Object.hash(
    key,
    label,
    toolTip,
    enabled,
    checked,
    command,
    submenu == null ? null : _entries.hash(submenu!),
  );

  @override
  String toString() => '$key(${enabled ? label : '$label, disabled'})';
}

/// Builds the tray context menu of the approved prototype
/// (docs/design/prototype/windows.html, board 2 — the right-click menu).
abstract final class TrayMenu {
  static const entryEquality = ListEquality<TrayMenuEntry>();

  static List<TrayMenuEntry> build(AppModel model) {
    final issue = model.serviceIssue;
    final busy = model.transition != null;
    return [
      TrayMenuItem(
        key: 'toggle',
        label: model.desiredOn ? 'Wayfork is On' : 'Wayfork is Off',
        checked: model.desiredOn,
        // The toggle is dead while starting or stopping, as in the popover.
        enabled: !busy,
        command: const TrayCommand.toggle(),
      ),
      TrayMenuItem(key: 'summary', label: model.summary, enabled: false),
      if (issue != null && issue.needsRepair)
        const TrayMenuItem(
          key: 'repair',
          label: 'Repair Installation',
          command: TrayCommand.repair(),
        ),
      const TrayMenuSeparator(),
      const TrayMenuItem(
        key: 'open',
        label: 'Open Wayfork…',
        command: TrayCommand.openWindow(),
      ),
      const TrayMenuItem(
        key: 'quickAdd',
        label: 'Route a domain…',
        command: TrayCommand.quickAdd(),
      ),
      const TrayMenuSeparator(),
      _reconnect(model),
      const TrayMenuItem(
        key: 'logs',
        label: 'Logs',
        command: TrayCommand.showLogs(),
      ),
      const TrayMenuItem(
        key: 'settings',
        label: 'Settings',
        command: TrayCommand.showSettings(),
      ),
      const TrayMenuSeparator(),
      const TrayMenuItem(
        key: 'quit',
        label: 'Quit Wayfork',
        command: TrayCommand.quit(),
      ),
    ];
  }

  /// Only OpenVPN tunnels have a process to restart; VLESS lives inside
  /// sing-box (docs/design/03-routing.md).
  static TrayMenuItem _reconnect(AppModel model) {
    final tunnels = model.store.tunnels
        .where((tunnel) => tunnel.isEnabled && tunnel.kind.isOpenVPN)
        .toList();
    final live = model.globalState.isRunning && tunnels.isNotEmpty;
    if (!live) {
      return const TrayMenuItem(
        key: 'reconnect',
        label: 'Reconnect',
        enabled: false,
      );
    }
    return TrayMenuItem(
      key: 'reconnect',
      label: 'Reconnect',
      submenu: [
        const TrayMenuItem(
          key: 'reconnect.all',
          label: 'All Tunnels',
          command: TrayCommand.reconnect(),
        ),
        const TrayMenuSeparator(),
        for (final tunnel in tunnels)
          TrayMenuItem(
            key: 'reconnect.${tunnel.id}',
            label: tunnel.name,
            toolTip: model.card(tunnel).detail,
            command: TrayCommand.reconnect(tunnel.id),
          ),
      ],
    );
  }
}
