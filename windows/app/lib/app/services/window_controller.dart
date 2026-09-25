import 'dart:async';

import 'package:wayfork/app/services/window_backend.dart';

/// The window half of the tray lifecycle (docs/design/08-windows.md,
/// "Lifecycle"): closing hides, the tray shows, and only Quit really exits.
final class WindowController {
  WindowController(this._backend);

  final WindowBackend _backend;

  Future<void> start({bool startHidden = false}) => _backend.start(
    startHidden: startHidden,
    onClose: () => unawaited(hide()),
  );

  Future<void> showAndFocus() async {
    await _backend.show();
    await _backend.focus();
  }

  Future<void> hide() => _backend.hide();

  /// A left click on the tray icon: away when the window is in front, up and
  /// focused otherwise — a visible but buried window comes forward instead of
  /// disappearing.
  Future<void> toggle() async {
    if (await _backend.isVisible() && await _backend.isFocused()) {
      await hide();
      return;
    }
    await showAndFocus();
  }

  /// Tears the window down for good; the process ends after it.
  Future<void> quit() => _backend.destroy();

  Future<void> dispose() => _backend.dispose();
}
