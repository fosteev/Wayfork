import 'dart:io';

/// The filesystem reads [VersionedAppPath.heal] needs, kept behind an
/// interface so the self-heal logic can be tested with a fake instead of a
/// real disk.
abstract interface class AppFiles {
  /// Whether [filePath] exists (used for the `.exe` itself).
  bool exists(String filePath);

  /// The names (not full paths) of the subdirectories of [parentPath]; empty
  /// if it does not exist or cannot be listed.
  List<String> listDirectories(String parentPath);

  /// [filePath]'s last-modified time, or null if it cannot be read.
  DateTime? modified(String filePath);
}

/// [AppFiles] over the real disk.
final class IoAppFiles implements AppFiles {
  const IoAppFiles();

  @override
  bool exists(String filePath) => File(filePath).existsSync();

  @override
  List<String> listDirectories(String parentPath) {
    final directory = Directory(parentPath);
    if (!directory.existsSync()) return const [];
    try {
      return directory
          .listSync()
          .whereType<Directory>()
          .map((entry) => _basename(entry.path))
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  @override
  DateTime? modified(String filePath) {
    try {
      return File(filePath).statSync().modified;
    } on Object {
      return null;
    }
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('/', r'\');
    final parts = normalized.split(r'\');
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return path;
  }
}
