import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/rules/app_files.dart';
import 'package:wayfork/core/support/regex_escape.dart';

/// Windows app rules point at an absolute `.exe` path, but an auto-updater
/// often carries the version in a path component: Squirrel installs into
/// `app-<ver>` next to the stable `Update.exe`, MSIX unpacks into
/// `WindowsApps\<Name>_<ver>_<arch>__<hash>`. Both make a rule stop matching
/// the moment the app updates.
///
/// [regex] widens a stored path's versioned *folder* components (never the
/// final `.exe` name) into a `process_path_regex` that matches any sibling
/// version; [key] normalizes the same path so two versions of the same app
/// compare equal for duplicate detection. Everything else in the path is
/// matched or compared literally. macOS bundle paths (no `\`) pass through
/// both untouched, since they have no versioned components to find.
abstract final class VersionedAppPath {
  /// A whole path component that is nothing but a Squirrel version folder,
  /// e.g. `app-1.0.9255`, `APP-2.0.1-beta`.
  static final RegExp _squirrel = RegExp(
    r'^app-\d+(\.\d+)+.*$',
    caseSensitive: false,
  );

  /// A whole path component that is an MSIX package folder, e.g.
  /// `Contoso.App_1.2.3.0_x64__8wekyb3d8bbwe`. Group 1 is the package name,
  /// group 4 the arch, group 5 the publisher hash; the version (group 2) is
  /// the only part that is allowed to vary between siblings.
  static final RegExp _msix = RegExp(
    r'^(.+)_(\d+(\.\d+){1,3})_([A-Za-z0-9]+)__([a-z0-9]+)$',
    caseSensitive: false,
  );

  /// Whether [component] — one `\`-separated segment of a path, never the
  /// final `.exe` name — is a Squirrel or MSIX versioned folder.
  static bool isVersionedComponent(String component) =>
      _squirrel.hasMatch(component) || _msix.hasMatch(component);

  /// The RE2-compatible middle of a `process_path_regex` for [path]: every
  /// component escaped literally, except a versioned folder component (not
  /// the final `.exe` name), which is widened to match any sibling version.
  /// Callers wrap this in the usual `(?i)^...$`. Contains no lookarounds or
  /// backreferences.
  static String regex(String path) {
    final components = path.split(r'\');
    final lastIndex = components.length - 1;
    return [
      for (var i = 0; i < components.length; i++)
        i == lastIndex
            ? escapeRegex(components[i])
            : _componentRegex(components[i]),
    ].join(r'\\');
  }

  /// [path] lowercased, with every versioned folder component (not the
  /// final `.exe` name) replaced by a placeholder that is stable across
  /// versions but distinguishes different MSIX packages. Two paths that
  /// differ only in a version folder compare equal; anything else must
  /// match exactly.
  static String key(String path) {
    final components = path.split(r'\');
    final lastIndex = components.length - 1;
    return [
      for (var i = 0; i < components.length; i++)
        i == lastIndex
            ? components[i].toLowerCase()
            : (_placeholder(components[i]) ?? components[i].toLowerCase()),
    ].join(r'\');
  }

  static String _componentRegex(String component) {
    if (_squirrel.hasMatch(component)) return r'app-\d[^\\]*';
    final msix = _msix.firstMatch(component);
    if (msix == null) return escapeRegex(component);
    final name = escapeRegex(msix.group(1)!);
    final arch = escapeRegex(msix.group(4)!);
    final hash = escapeRegex(msix.group(5)!);
    return '${name}_'
        r'[^_\\]+'
        '_${arch}__$hash';
  }

  static String? _placeholder(String component) {
    if (_squirrel.hasMatch(component)) return '\u0000squirrel\u0000';
    final msix = _msix.firstMatch(component);
    if (msix == null) return null;
    final name = msix.group(1)!.toLowerCase();
    final arch = msix.group(4)!.toLowerCase();
    final hash = msix.group(5)!.toLowerCase();
    return '\u0000msix:$name:$arch:$hash\u0000';
  }

  /// Every enabled or disabled app rule with a versioned folder component
  /// gets repointed at the newest (by modification time, not version string —
  /// Squirrel and MSIX sort differently) existing sibling build, its own
  /// included. An old build that is still on disk counts too: Squirrel keeps
  /// the previous `app-<ver>` around after an update. Rules whose path has no
  /// versioned folder component, or whose parent cannot be listed (MSIX's
  /// `WindowsApps` without admin rights), are left alone; the widened [regex]
  /// matches them anyway. Returns [store] itself when nothing changed, so a
  /// caller's `update` sees a no-op.
  static Store heal(Store store, AppFiles files) {
    List<Rule>? healedRules;
    for (var index = 0; index < store.rules.length; index++) {
      final rule = store.rules[index];
      if (!rule.match.isApp) continue;
      final healedPath = _healPath(rule.pattern, files);
      if (healedPath == null || healedPath == rule.pattern) continue;
      healedRules ??= [...store.rules];
      healedRules[index] = rule.copyWith(pattern: healedPath);
    }
    return healedRules == null ? store : store.copyWith(rules: healedRules);
  }

  /// The newest existing sibling build of [path] ([path] itself included),
  /// or null when [path] has no versioned folder component or no sibling
  /// exists.
  static String? _healPath(String path, AppFiles files) {
    final components = path.split(r'\');
    final lastIndex = components.length - 1;
    var versionedIndex = -1;
    for (var i = 0; i < lastIndex; i++) {
      if (isVersionedComponent(components[i])) {
        versionedIndex = i;
        break;
      }
    }
    if (versionedIndex < 0) return null;
    final parent = components.sublist(0, versionedIndex).join(r'\');
    final targetKey = key(path);
    String? bestPath;
    DateTime? bestModified;
    for (final sibling in files.listDirectories(parent)) {
      final candidate = [...components];
      candidate[versionedIndex] = sibling;
      final candidatePath = candidate.join(r'\');
      if (key(candidatePath) != targetKey || !files.exists(candidatePath)) {
        continue;
      }
      final modified = files.modified(candidatePath);
      if (modified == null) continue;
      if (bestModified == null || modified.isAfter(bestModified)) {
        bestModified = modified;
        bestPath = candidatePath;
      }
    }
    return bestPath;
  }
}
