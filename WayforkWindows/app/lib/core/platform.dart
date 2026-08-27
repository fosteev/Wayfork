import 'package:wayfork/core/rules/rule_pattern_error.dart';
import 'package:wayfork/core/support/regex_escape.dart';

final class WayforkPlatform {
  const WayforkPlatform._(this.tunInterface, this._windows);

  static const windows = WayforkPlatform._('Wayfork', true);
  static const macOS = WayforkPlatform._('utun100', false);

  final String tunInterface;
  final bool _windows;

  String openVPNInterface(int slot) =>
      _windows ? 'Wayfork-${slot + 1}' : 'utun${101 + slot}';

  String openVPNBinaryPath(String directory) => _windows
      ? '$directory\\bin\\openvpn.exe'
      : '$directory/Contents/Resources/bin/openvpn';

  String normalizeAppPath(String raw) {
    if (_windows) return _normalizeWindowsAppPath(raw);
    return _normalizeMacOSAppPath(raw);
  }

  /// sing-box reports the on-disk case on Windows, so the process regex is
  /// case-insensitive there. A macOS bundle regex covers every executable in
  /// the bundle while excluding similarly prefixed bundle names.
  String appPathRegex(String pattern) =>
      _windows ? '(?i)^${escapeRegex(pattern)}\$' : '^${escapeRegex(pattern)}/';

  String appName(String pattern) {
    final parts = _windows
        ? pattern.split(RegExp(r'[\\/]'))
        : pattern.split('/');
    final name = parts.isEmpty ? pattern : parts.last;
    final suffix = _windows ? '.exe' : '.app';
    return name.toLowerCase().endsWith(suffix) && name.length > suffix.length
        ? name.substring(0, name.length - suffix.length)
        : name;
  }

  static String _normalizeMacOSAppPath(String raw) {
    var value = raw.trim();
    if (value.toLowerCase().startsWith('file://')) {
      try {
        final uri = Uri.parse(value);
        if (uri.scheme.toLowerCase() != 'file') {
          throw const FormatException();
        }
        value = uri.toFilePath(windows: false);
      } on Object {
        throw const RulePatternException(RulePatternError.notAnApplication);
      }
    }
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) {
      throw const RulePatternException(RulePatternError.empty);
    }
    if (!value.startsWith('/') ||
        value.length <= 4 ||
        !value.toLowerCase().endsWith('.app') ||
        value.contains('/../') ||
        value.contains('/./')) {
      throw const RulePatternException(RulePatternError.notAnApplication);
    }
    return value;
  }

  static String _normalizeWindowsAppPath(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      throw const RulePatternException(RulePatternError.empty);
    }
    if (value.toLowerCase().startsWith('file:')) {
      try {
        final uri = Uri.parse(value);
        if (uri.scheme.toLowerCase() != 'file') {
          throw const FormatException();
        }
        value = uri.toFilePath(windows: true);
      } on Object {
        throw const RulePatternException(RulePatternError.notAnApplication);
      }
    }
    value = value.replaceAll('/', r'\');
    while (value.endsWith(r'\') && !_isDriveRoot(value)) {
      value = value.substring(0, value.length - 1);
    }
    final driveAbsolute = RegExp(r'^[A-Za-z]:\\').hasMatch(value);
    final uncAbsolute = RegExp(r'^\\\\[^\\]+\\[^\\]+\\').hasMatch(value);
    final components = value.split(r'\');
    final fileName = components.isEmpty ? '' : components.last;
    if ((!driveAbsolute && !uncAbsolute) ||
        fileName.length <= 4 ||
        !fileName.toLowerCase().endsWith('.exe') ||
        components.any((component) => component == '.' || component == '..')) {
      throw const RulePatternException(RulePatternError.notAnApplication);
    }
    return value;
  }

  static bool _isDriveRoot(String value) =>
      RegExp(r'^[A-Za-z]:\\$').hasMatch(value);
}
