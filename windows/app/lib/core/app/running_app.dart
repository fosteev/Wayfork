import 'package:wayfork/core/rules/rule_pattern.dart';

/// One process as Win32 reported it, before the picker folds the several PIDs
/// of one executable into a single entry (docs/design/08-windows.md, "App rules
/// (F10) on Windows").
final class RunningProcess {
  const RunningProcess({
    required this.path,
    this.description,
    this.windowTitle,
  });

  /// Full path of the executable — what an app rule matches on.
  final String path;

  /// `FileDescription` from the file's version info, when it carries one.
  final String? description;

  /// Title of the window this process was found through; null when it came
  /// from the process list instead, which is what marks it a background one.
  final String? windowTitle;
}

/// An entry of the "Application…" picker (F10): one executable, however many
/// processes are running it.
final class RunningApp {
  const RunningApp({
    required this.path,
    required this.name,
    this.windowTitle,
    this.hasWindow = false,
    this.instances = 1,
  });

  final String path;

  /// `FileDescription` when the file has one ("Google Chrome"), the file name
  /// without `.exe` otherwise.
  final String name;

  /// Title of one of its windows, null for a background process.
  final String? windowTitle;

  /// Whether any of its processes owns a real window — those come first, and
  /// they are what the user thinks of as "running applications".
  final bool hasWindow;

  /// How many processes share this executable (Chrome is dozens).
  final int instances;

  @override
  bool operator ==(Object other) =>
      other is RunningApp &&
      path == other.path &&
      name == other.name &&
      windowTitle == other.windowTitle &&
      hasWindow == other.hasWindow &&
      instances == other.instances;

  @override
  int get hashCode =>
      Object.hash(path, name, windowTitle, hasWindow, instances);

  @override
  String toString() => 'RunningApp($name, $path, x$instances)';
}

/// The pure half of the picker: everything between what Win32 enumerated and
/// what the list shows.
abstract final class RunningApps {
  /// Folds [processes] into one entry per executable, drops [exclude] (the
  /// running Wayfork, which routing itself makes no sense for) and orders the
  /// result: windowed apps first, then by name.
  static List<RunningApp> collate(
    Iterable<RunningProcess> processes, {
    Iterable<String> exclude = const [],
  }) {
    final skip = {for (final path in exclude) path.toLowerCase()};
    final byPath = <String, RunningApp>{};
    for (final process in processes) {
      final path = process.path.trim();
      if (path.isEmpty) continue;
      final key = path.toLowerCase();
      if (skip.contains(key)) continue;
      final title = _clean(process.windowTitle);
      final existing = byPath[key];
      if (existing == null) {
        byPath[key] = RunningApp(
          path: path,
          name: _name(path, process.description),
          windowTitle: title,
          hasWindow: process.windowTitle != null,
          instances: 1,
        );
        continue;
      }
      byPath[key] = RunningApp(
        path: existing.path,
        name: existing.name,
        windowTitle: existing.windowTitle ?? title,
        hasWindow: existing.hasWindow || process.windowTitle != null,
        instances: existing.instances + 1,
      );
    }
    final apps = byPath.values.toList();
    apps.sort((a, b) {
      if (a.hasWindow != b.hasWindow) return a.hasWindow ? -1 : 1;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0
          ? byName
          : a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    return apps;
  }

  /// Substring match over the name, the path and the window title, so both
  /// "chrome" and "Program Files" find something.
  static List<RunningApp> search(Iterable<RunningApp> apps, String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return apps.toList();
    return [
      for (final app in apps)
        if (app.name.toLowerCase().contains(needle) ||
            app.path.toLowerCase().contains(needle) ||
            (app.windowTitle?.toLowerCase().contains(needle) ?? false))
          app,
    ];
  }

  static String _name(String path, String? description) {
    final cleaned = _clean(description);
    return cleaned ?? RulePattern.appName(path);
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
