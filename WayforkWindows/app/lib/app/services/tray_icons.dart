import 'package:wayfork/core/app/global_state.dart';

/// Which glyph the notification area shows (docs/design/02-ux.md, "Menu bar
/// icon"): four states plus the dimmed twin the controller alternates with
/// [TrayIcon.on] while an operation is in flight (the Windows stand-in for
/// `.symbolEffect(.pulse)`).
enum TrayIcon { off, on, pulse, degraded, error }

/// The theme the notification area is drawn in. A light taskbar needs the dark
/// glyph and the other way round, so the asset set is named after the taskbar,
/// not after the ink.
enum TrayTheme { light, dark }

abstract final class TrayIcons {
  static const assetDirectory = 'assets/tray';

  /// `assets/tray/<theme>/<icon>.ico`, the path
  /// `TrayManager.setIcon` resolves under `data/flutter_assets`.
  static String asset(TrayIcon icon, TrayTheme theme) =>
      '$assetDirectory/${theme.name}/${icon.name}.ico';

  /// The icon for a global state. A service that needs repairing wins over
  /// everything else: the app cannot route at all until it is fixed.
  static TrayIcon forState(
    GlobalState state, {
    required bool pulse,
    bool needsRepair = false,
  }) {
    if (needsRepair) return TrayIcon.error;
    return switch (state) {
      GlobalStateStarting() ||
      GlobalStateStopping() => pulse ? TrayIcon.pulse : TrayIcon.on,
      GlobalStateOn() => TrayIcon.on,
      GlobalStateDegraded() => TrayIcon.degraded,
      GlobalStateError() => TrayIcon.error,
      GlobalStateOff() => TrayIcon.off,
    };
  }
}
