import 'dart:ui';
import 'package:window_manager/window_manager.dart';

/// The main window, behind an interface so the lifecycle rules can be tested
/// without a real window.
abstract interface class WindowBackend {
  /// Prepares the window and shows it unless the app was started into the
  /// tray. [onClose] fires instead of the window closing.
  Future<void> start({
    required bool startHidden,
    required VoidCallback onClose,
  });

  Future<bool> isVisible();
  Future<bool> isFocused();
  Future<void> show();
  Future<void> hide();
  Future<void> focus();

  /// Closes the window for good and lets the process exit.
  Future<void> destroy();

  Future<void> dispose();
}

/// `window_manager` backing of [WindowBackend].
final class WindowManagerBackend with WindowListener implements WindowBackend {
  WindowManagerBackend({WindowManager? manager})
    : _manager = manager ?? windowManager;

  static const initialSize = Size(1040, 720);
  static const minimumSize = Size(880, 600);

  final WindowManager _manager;
  VoidCallback? _onClose;

  @override
  Future<void> start({
    required bool startHidden,
    required VoidCallback onClose,
  }) async {
    _onClose = onClose;
    _manager.addListener(this);
    // Closing the window keeps the app in the tray; only Quit really exits.
    await _manager.setPreventClose(true);
    await _manager.waitUntilReadyToShow(
      const WindowOptions(
        size: initialSize,
        minimumSize: minimumSize,
        center: true,
        title: 'Wayfork',
      ),
      () async {
        if (startHidden) return;
        await _manager.show();
        await _manager.focus();
      },
    );
  }

  @override
  Future<bool> isVisible() => _manager.isVisible();

  @override
  Future<bool> isFocused() => _manager.isFocused();

  @override
  Future<void> show() => _manager.show();

  @override
  Future<void> hide() => _manager.hide();

  @override
  Future<void> focus() => _manager.focus();

  @override
  Future<void> destroy() => _manager.destroy();

  @override
  Future<void> dispose() async => _manager.removeListener(this);

  @override
  void onWindowClose() => _onClose?.call();
}
