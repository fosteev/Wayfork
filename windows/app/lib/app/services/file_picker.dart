import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:file_selector_windows/file_selector_windows.dart';

/// The two common dialogs the tunnel import needs, behind an interface so the
/// import flow can be driven without a shell in tests.
abstract interface class FilePicker {
  /// Absolute path of the chosen file, or null when the dialog was cancelled.
  Future<String?> openFile({
    required String label,
    required List<String> extensions,
    String? confirmButtonText,
  });

  Future<String?> chooseDirectory({String? confirmButtonText});

  /// Absolute path to write to, or null when the dialog was cancelled. The
  /// caller may assume the extension of [suggestedName] is on it.
  Future<String?> saveFile({
    required String label,
    required List<String> extensions,
    required String suggestedName,
    String? confirmButtonText,
  });
}

/// `IFileSaveDialog` returns exactly what was typed: the plugin never calls
/// `SetDefaultExtension`, so a name typed without one comes back bare. Every
/// caller wants the extension, and Explorer needs it to pick an icon.
String withExtension(String path, String extension) {
  final suffix = extension.startsWith('.') ? extension : '.$extension';
  return path.toLowerCase().endsWith(suffix.toLowerCase())
      ? path
      : '$path$suffix';
}

/// `IFileOpenDialog` through `file_selector_windows`. The endorsed
/// `file_selector` facade is deliberately not a dependency: it would drag in
/// the Android, iOS, Linux, macOS and web implementations for an app that only
/// ever runs on Windows.
final class WindowsFilePicker implements FilePicker {
  WindowsFilePicker({FileSelectorPlatform? platform})
    : _platform = platform ?? FileSelectorWindows();

  final FileSelectorPlatform _platform;

  @override
  Future<String?> openFile({
    required String label,
    required List<String> extensions,
    String? confirmButtonText,
  }) async {
    final file = await _platform.openFile(
      acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
      confirmButtonText: confirmButtonText,
    );
    return file?.path;
  }

  @override
  Future<String?> chooseDirectory({String? confirmButtonText}) =>
      _platform.getDirectoryPathWithOptions(
        FileDialogOptions(confirmButtonText: confirmButtonText),
      );

  @override
  Future<String?> saveFile({
    required String label,
    required List<String> extensions,
    required String suggestedName,
    String? confirmButtonText,
  }) async {
    final location = await _platform.getSaveLocation(
      acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
      options: SaveDialogOptions(
        suggestedName: suggestedName,
        confirmButtonText: confirmButtonText,
      ),
    );
    final path = location?.path;
    if (path == null || extensions.isEmpty) return path;
    return withExtension(path, extensions.first);
  }
}
