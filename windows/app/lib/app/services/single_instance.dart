import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Keeps a second launch from taking over the tray icon and the service pipe.
/// The first process owns a session-local named event; a later one hands the
/// focus to the window that already exists and exits
/// (docs/ROADMAP-windows.md WM3, "single-instance guard").
abstract final class SingleInstance {
  /// Session-local on purpose: the store, the secrets and the tray icon are
  /// per user, so one instance per logged-in session is the right unit, and
  /// `Global\` would need a privilege ordinary accounts do not have.
  static const eventName = r'Local\Wayfork.SingleInstance';

  /// The class the Flutter runner registers (`windows/runner/win32_window.cpp`)
  /// and the title `windows/runner/main.cpp` gives the window.
  static const windowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';
  static const windowTitle = 'Wayfork';

  /// Held for the process lifetime: Windows drops the named object when the
  /// last handle to it closes.
  static HANDLE? _handle;

  static bool get holdsInstance => _handle != null;

  /// True when this process may run. Off Windows there is nothing to guard.
  static bool acquire({String name = eventName}) {
    if (!Platform.isWindows) return true;
    final pointer = name.toPcwstr();
    try {
      final result = CreateEvent(null, true, false, pointer);
      final handle = result.value;
      if (result.error == ERROR_ALREADY_EXISTS) {
        if (handle.address != 0) CloseHandle(handle);
        return false;
      }
      // A failure to create the event says nothing about other instances;
      // refusing to start would be worse than a second icon.
      if (handle.address == 0) return true;
      _handle = handle;
      return true;
    } finally {
      free(pointer);
    }
  }

  /// Brings the running instance's window to the front. Best effort: it is
  /// usually hidden in the tray, which is what `SW_SHOW` undoes.
  ///
  /// The Flutter runner creates this process's own window before Dart `main`
  /// runs, so the search has to walk past every window that belongs to us —
  /// otherwise a second launch would raise itself and leave the first
  /// instance where it was. Our own window is never shown (the runner only
  /// shows it on the first frame, which we never reach).
  static bool activateExisting({
    String className = windowClass,
    String title = windowTitle,
  }) {
    if (!Platform.isWindows) return false;
    final classPointer = className.toPcwstr();
    final titlePointer = title.toPcwstr();
    final owner = calloc<Uint32>();
    try {
      final self = GetCurrentProcessId();
      HWND? previous;
      while (true) {
        final window = FindWindowEx(
          null,
          previous,
          classPointer,
          titlePointer,
        ).value;
        if (window.address == 0) return false;
        previous = window;
        GetWindowThreadProcessId(window, owner);
        if (owner.value == self) continue;
        ShowWindow(window, SW_SHOW);
        ShowWindow(window, SW_RESTORE);
        SetForegroundWindow(window);
        return true;
      }
    } finally {
      calloc.free(owner);
      free(titlePointer);
      free(classPointer);
    }
  }

  /// Releases the event; the next launch becomes the owner.
  static void release() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    CloseHandle(handle);
  }
}
