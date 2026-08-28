import 'dart:io';

import 'package:wayfork/app/services/launch_at_login.dart';
import 'package:wayfork/app/services/windows_registry.dart';

/// "Launch at login" as the `HKCU\…\Run` value of
/// docs/ROADMAP-windows.md WM3 — the Windows counterpart of the macOS
/// `SMAppService.mainApp` registration.
final class RegistryLaunchAtLogin implements LaunchAtLogin {
  RegistryLaunchAtLogin({String? executable, this.valueName = defaultValueName})
    : executable = executable ?? Platform.resolvedExecutable;

  static const runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const defaultValueName = 'Wayfork';

  /// Windows starts the app straight into the tray; the window opens only when
  /// the user asks for it (docs/design/02-ux.md, "Launch at login").
  static const minimizedFlag = '--minimized';

  final String executable;
  final String valueName;

  String get command => '"$executable" $minimizedFlag';

  /// Any value under the name counts, whatever path it holds: a stale path
  /// from an earlier install location is still the user's "yes", and
  /// [setEnabled] rewrites it on the next toggle.
  @override
  bool get isEnabled =>
      Platform.isWindows &&
      WindowsRegistry.readString(runKey, valueName) != null;

  @override
  void setEnabled(bool enabled) {
    if (!Platform.isWindows) {
      throw UnsupportedError('launch at login is a Windows registry value');
    }
    if (enabled) {
      WindowsRegistry.writeString(runKey, valueName, command);
    } else {
      WindowsRegistry.deleteValue(runKey, valueName);
    }
  }
}
