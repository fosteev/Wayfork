/// The "Launch at login" registration (docs/ROADMAP-windows.md WM3: the
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value). The registry
/// backend lands with the window lifecycle (WM3c); the model only needs the
/// interface.
abstract interface class LaunchAtLogin {
  bool get isEnabled;

  /// Registers or unregisters the app; throws when the system refuses.
  void setEnabled(bool enabled);
}

/// Remembers the flag in memory: the default until the registry backend
/// exists, and the test double.
final class InMemoryLaunchAtLogin implements LaunchAtLogin {
  InMemoryLaunchAtLogin({this._enabled = false, this.failure});

  bool _enabled;

  /// When set, [setEnabled] throws it (tests).
  Object? failure;

  @override
  bool get isEnabled => _enabled;

  @override
  void setEnabled(bool enabled) {
    final failure = this.failure;
    if (failure != null) throw failure;
    _enabled = enabled;
  }
}
