import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:wayfork/core/app/running_app.dart';
import 'package:win32/win32.dart';

/// Where the "Application…" picker gets its list (F10). Behind an interface
/// because the Win32 half below cannot run under `flutter test`.
abstract interface class RunningAppSource {
  /// The apps that own a window; with [includeBackground], every other process
  /// whose executable path can be read as well.
  Future<List<RunningApp>> list({bool includeBackground = false});
}

/// `EnumWindows` for the apps a user recognises — the same set as Task
/// Manager's *Apps* — and `EnumProcesses` for the background ones
/// (docs/design/08-windows.md, "App rules (F10) on Windows").
final class WindowsRunningApps implements RunningAppSource {
  /// Version info costs a file read, so the answer is kept per path for the
  /// lifetime of the picker.
  final _descriptions = <String, String?>{};

  @override
  Future<List<RunningApp>> list({bool includeBackground = false}) async {
    final windowed = <int>{};
    final processes = _fromWindows(windowed);
    if (includeBackground) processes.addAll(_fromProcesses(windowed));
    return RunningApps.collate(
      processes,
      exclude: [Platform.resolvedExecutable],
    );
  }

  /// Every visible, unowned, non-cloaked top-level window with a title. The
  /// PIDs behind them land in [windowed] so the process pass cannot count the
  /// same process twice.
  List<RunningProcess> _fromWindows(Set<int> windowed) {
    final found = <RunningProcess>[];
    final callback = NativeCallable<WNDENUMPROC>.isolateLocal((
      Pointer handle,
      int _,
    ) {
      final process = _appWindow(HWND(handle), windowed);
      if (process != null) found.add(process);
      return TRUE;
    }, exceptionalReturn: FALSE);
    try {
      EnumWindows(callback.nativeFunction, const LPARAM(0));
    } finally {
      callback.close();
    }
    return found;
  }

  RunningProcess? _appWindow(HWND window, Set<int> windowed) {
    if (!IsWindowVisible(window)) return null;
    if (GetWindow(window, GW_OWNER).value.address != 0) return null;
    if (GetWindowLongPtr(window, GWL_EXSTYLE).value & WS_EX_TOOLWINDOW != 0) {
      return null;
    }
    if (_isCloaked(window)) return null;
    final title = _title(window);
    if (title == null) return null;
    var pid = _pidOf(window);
    if (pid == null) return null;
    var path = _pathOf(pid);
    if (path == null) return null;
    if (_isFrameHost(path)) {
      // A store app is drawn by ApplicationFrameHost; the app itself is the
      // process behind the child CoreWindow. Without one there is nothing to
      // route, so the entry is dropped rather than shown as the host.
      final hosted = _hostedPid(window, pid);
      if (hosted == null) return null;
      pid = hosted;
      final hostedPath = _pathOf(hosted);
      if (hostedPath == null) return null;
      path = hostedPath;
    }
    // A process with several windows is still one process; the count the
    // picker shows would otherwise count windows.
    if (!windowed.add(pid)) return null;
    return RunningProcess(
      path: path,
      description: _descriptionOf(path),
      windowTitle: title,
    );
  }

  /// Everything else that is running, [windowed] excepted.
  List<RunningProcess> _fromProcesses(Set<int> windowed) {
    const capacity = 4096;
    final ids = calloc<Uint32>(capacity);
    final needed = calloc<Uint32>();
    try {
      final ok = EnumProcesses(ids, capacity * sizeOf<Uint32>(), needed).value;
      if (!ok) return const [];
      final count = needed.value ~/ sizeOf<Uint32>();
      final found = <RunningProcess>[];
      for (var index = 0; index < count; index++) {
        final pid = ids[index];
        // 0 is the idle process; 4 is System, and neither opens.
        if (pid == 0 || pid == 4 || windowed.contains(pid)) continue;
        final path = _pathOf(pid);
        if (path == null) continue;
        found.add(
          RunningProcess(path: path, description: _descriptionOf(path)),
        );
      }
      return found;
    } finally {
      calloc.free(needed);
      calloc.free(ids);
    }
  }

  /// A UWP window that is merely suspended is still enumerated; DWM knows it
  /// is not on screen.
  bool _isCloaked(HWND window) {
    final cloaked = calloc<Uint32>();
    try {
      DwmGetWindowAttribute(window, DWMWA_CLOAKED, cloaked, sizeOf<Uint32>());
      return cloaked.value != 0;
    } on Object {
      return false;
    } finally {
      calloc.free(cloaked);
    }
  }

  String? _title(HWND window) {
    final length = GetWindowTextLength(window).value;
    if (length <= 0) return null;
    final buffer = wsalloc(length + 1);
    try {
      final copied = GetWindowText(window, buffer, length + 1).value;
      if (copied <= 0) return null;
      final text = buffer.toDartString(length: copied).trim();
      return text.isEmpty ? null : text;
    } finally {
      free(buffer);
    }
  }

  int? _pidOf(HWND window) {
    final pid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(window, pid);
      return pid.value == 0 ? null : pid.value;
    } finally {
      calloc.free(pid);
    }
  }

  /// The PID of the `CoreWindow` [frame] hosts, when it hosts one.
  int? _hostedPid(HWND frame, int framePid) {
    int? hosted;
    final callback = NativeCallable<WNDENUMPROC>.isolateLocal((
      Pointer handle,
      int _,
    ) {
      final child = HWND(handle);
      if (_classOf(child) != 'Windows.UI.Core.CoreWindow') return TRUE;
      final pid = _pidOf(child);
      if (pid == null || pid == framePid) return TRUE;
      hosted = pid;
      return FALSE;
    }, exceptionalReturn: FALSE);
    try {
      EnumChildWindows(frame, callback.nativeFunction, const LPARAM(0));
    } finally {
      callback.close();
    }
    return hosted;
  }

  String _classOf(HWND window) {
    const capacity = 256;
    final buffer = wsalloc(capacity);
    try {
      final copied = GetClassName(window, buffer, capacity).value;
      return copied <= 0 ? '' : buffer.toDartString(length: copied);
    } finally {
      free(buffer);
    }
  }

  /// Null when the process is gone or its path is not readable — a protected
  /// process, or one of another user. Nothing worth routing hides there.
  String? _pathOf(int pid) {
    final process = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      false,
      pid,
    ).value;
    if (process.address == 0) return null;
    final size = calloc<Uint32>()..value = _pathCapacity;
    final buffer = wsalloc(_pathCapacity);
    try {
      final ok = QueryFullProcessImageName(
        process,
        PROCESS_NAME_WIN32,
        buffer,
        size,
      ).value;
      if (!ok || size.value == 0) return null;
      return buffer.toDartString(length: size.value);
    } finally {
      free(buffer);
      calloc.free(size);
      CloseHandle(process);
    }
  }

  String? _descriptionOf(String path) =>
      _descriptions.putIfAbsent(path.toLowerCase(), () => _description(path));

  /// `FileDescription` from the version info — "Google Chrome" where the file
  /// name only says "chrome".
  static String? _description(String path) {
    final name = path.toPcwstr();
    try {
      final size = GetFileVersionInfoSize(name, null).value;
      if (size == 0) return null;
      final data = calloc<Uint8>(size);
      final buffer = calloc<Pointer>();
      final length = calloc<Uint32>();
      try {
        if (!GetFileVersionInfo(name, size, data).value) return null;
        for (final language in _languages(data, buffer, length)) {
          final key = '\\StringFileInfo\\$language\\FileDescription'.toPcwstr();
          try {
            if (!VerQueryValue(data, key, buffer, length)) continue;
            if (length.value == 0) continue;
            final text = PWSTR(
              buffer.value.cast<Utf16>(),
            ).toDartString().trim();
            if (text.isNotEmpty) return text;
          } finally {
            free(key);
          }
        }
        return null;
      } finally {
        calloc.free(length);
        calloc.free(buffer);
        calloc.free(data);
      }
    } finally {
      free(name);
    }
  }

  /// The translations the file declares, then the two common defaults for the
  /// files that declare none or label theirs wrong.
  static List<String> _languages(
    Pointer<Uint8> data,
    Pointer<Pointer> buffer,
    Pointer<Uint32> length,
  ) {
    final key = r'\VarFileInfo\Translation'.toPcwstr();
    final found = <String>[];
    try {
      if (VerQueryValue(data, key, buffer, length)) {
        final pairs = buffer.value.cast<Uint16>();
        // Each translation is a language and a code page, one WORD each.
        final count = length.value ~/ (2 * sizeOf<Uint16>());
        for (var index = 0; index < count; index++) {
          found.add(_hex(pairs[index * 2]) + _hex(pairs[index * 2 + 1]));
        }
      }
    } finally {
      free(key);
    }
    return found..addAll(const ['040904b0', '040904e4']);
  }

  static String _hex(int value) => value.toRadixString(16).padLeft(4, '0');

  static bool _isFrameHost(String path) =>
      path.toLowerCase().endsWith(r'\applicationframehost.exe');

  /// `MAX_PATH` is the old limit; long paths need the extended one.
  static const _pathCapacity = 32768;
}
