import 'dart:io';

import 'package:wayfork/app/services/tray_icons.dart';
import 'package:wayfork/app/services/windows_registry.dart';

/// Which way round the notification area is painted. Windows has no API for
/// it; the value the shell itself reads is `SystemUsesLightTheme` (the app
/// theme, `AppsUseLightTheme`, is a different setting and does not move the
/// taskbar).
abstract final class SystemTheme {
  static const personalizeKey =
      r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
  static const systemUsesLightTheme = 'SystemUsesLightTheme';

  /// Defaults to a dark taskbar — the Windows 11 default and the safer guess,
  /// since a white glyph on a light taskbar disappears less often than the
  /// other way round on the stock theme.
  static TrayTheme trayTheme() {
    if (!Platform.isWindows) return TrayTheme.dark;
    final light = WindowsRegistry.readDword(
      personalizeKey,
      systemUsesLightTheme,
    );
    return light == 1 ? TrayTheme.light : TrayTheme.dark;
  }
}
