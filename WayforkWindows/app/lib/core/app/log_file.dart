import 'dart:convert';
import 'dart:io';

import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

/// One line of `runtime.log` / `wayfork.log` (docs/design/06-logging.md).
abstract final class LogLineFormat {
  /// ISO-8601 UTC with milliseconds, source, upper-cased level, message.
  static String format(LogLine line) {
    final message = line.message.replaceAll(RegExp(r'[\r\n]'), ' ');
    return '${timestamp(line.ts)} ${line.source} '
        '${line.level.jsonValue.toUpperCase()} $message';
  }

  /// `2026-08-25T12:00:00.123Z`.
  static String timestamp(DateTime date) {
    final utc = date.toUtc();
    String pad(int value, int width) => value.toString().padLeft(width, '0');
    return '${pad(utc.year, 4)}-${pad(utc.month, 2)}-${pad(utc.day, 2)}T'
        '${pad(utc.hour, 2)}:${pad(utc.minute, 2)}:${pad(utc.second, 2)}.'
        '${pad(utc.millisecond, 3)}Z';
  }

  /// Parses a line produced by [format]; malformed and non-canonical lines
  /// return null.
  static LogLine? parse(String text) {
    if (text.isEmpty || text.contains('\n') || text.contains('\r')) return null;
    final parts = _split(text, 3);
    if (parts.length != 4 ||
        parts[0].isEmpty ||
        parts[1].isEmpty ||
        parts[2].isEmpty) {
      return null;
    }
    final DateTime date;
    try {
      date = DateTime.parse(parts[0]).toUtc();
    } on FormatException {
      return null;
    }
    if (timestamp(date) != parts[0]) return null;
    final levelText = parts[2];
    if (levelText != levelText.toUpperCase()) return null;
    final LogLevel level;
    try {
      level = LogLevel.fromJson(levelText.toLowerCase());
    } on FormatException {
      return null;
    }
    return LogLine(ts: date, source: parts[1], level: level, message: parts[3]);
  }

  /// Splits on single spaces at most [maxSplits] times, keeping empty pieces.
  static List<String> _split(String text, int maxSplits) {
    final parts = <String>[];
    var start = 0;
    while (parts.length < maxSplits) {
      final index = text.indexOf(' ', start);
      if (index < 0) break;
      parts.add(text.substring(start, index));
      start = index + 1;
    }
    parts.add(text.substring(start));
    return parts;
  }
}

enum AppLogFileError { invalidConfiguration, openFailed }

final class AppLogFileException implements Exception {
  const AppLogFileException(this.kind, {this.message});

  final AppLogFileError kind;
  final String? message;

  @override
  String toString() =>
      message == null ? 'AppLogFileException($kind)' : '$kind: $message';
}

/// Append-only app log with timestamped size rotation and age-based retention.
/// The directory lives under `%LOCALAPPDATA%`, which is private to the user by
/// its inherited ACL, so no explicit permissions are set.
final class AppLogFile {
  AppLogFile(this.directory, this.name, {this.maxBytes = defaultMaxBytes})
    : file = File(_join(directory.path, '$name.log')) {
    if (name.isEmpty || maxBytes <= 0) {
      throw const AppLogFileException(AppLogFileError.invalidConfiguration);
    }
    try {
      directory.createSync(recursive: true);
      _open();
    } on FileSystemException catch (error) {
      throw AppLogFileException(
        AppLogFileError.openFailed,
        message: error.message,
      );
    }
  }

  static const defaultMaxBytes = 5 * 1024 * 1024;

  final Directory directory;
  final String name;
  final int maxBytes;
  final File file;

  RandomAccessFile? _handle;
  int _byteCount = 0;
  bool _isClosed = false;

  void append(String text) {
    if (_isClosed) return;
    final bytes = utf8.encode('$text\n');
    if (_byteCount > 0 && _byteCount + bytes.length > maxBytes) _rotate();
    final handle = _handle;
    if (handle == null) return;
    try {
      handle.writeFromSync(bytes);
      _byteCount += bytes.length;
    } on FileSystemException {
      // A log line that cannot be written is dropped, like the macOS app.
    }
  }

  /// The last [maxLines] lines, oldest first, reading at most [maxBytes] from
  /// the end of the current file.
  List<String> tail(int maxLines, {int maxBytes = defaultMaxBytes}) {
    if (maxLines <= 0 || maxBytes <= 0 || _isClosed) return const [];
    final RandomAccessFile reader;
    try {
      reader = file.openSync();
    } on FileSystemException {
      return const [];
    }
    try {
      final size = reader.lengthSync();
      final length = size < maxBytes ? size : maxBytes;
      if (length <= 0) return const [];
      final start = size - length;
      reader.setPositionSync(start);
      var bytes = reader.readSync(length);
      if (start > 0) {
        reader.setPositionSync(start - 1);
        final previous = reader.readSync(1);
        if (previous.isEmpty || previous[0] != 0x0A) {
          final newline = bytes.indexOf(0x0A);
          if (newline < 0) return const [];
          bytes = bytes.sublist(newline + 1);
        }
      }
      final lines = utf8.decode(bytes, allowMalformed: true).split('\n');
      if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
      return lines.length > maxLines
          ? lines.sublist(lines.length - maxLines)
          : lines;
    } on FileSystemException {
      return const [];
    } finally {
      reader.closeSync();
    }
  }

  void close() {
    if (_isClosed) return;
    _isClosed = true;
    _closeHandle();
  }

  /// Rotated files of [name] in [directory], oldest first by name.
  static List<File> rotatedFiles(Directory directory, String name) {
    final prefix = '$name-';
    if (!directory.existsSync()) return const [];
    final files = directory.listSync().whereType<File>().where((file) {
      final base = _basename(file.path);
      return base.startsWith(prefix) && base.endsWith('.log');
    }).toList();
    files.sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));
    return files;
  }

  /// Deletes rotated files older than [retentionDays] (all of them when the
  /// retention is zero or negative); returns what was deleted.
  static List<File> prune(
    Directory directory,
    String name, {
    required int retentionDays,
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(
      Duration(days: retentionDays),
    );
    final deleted = <File>[];
    for (final file in rotatedFiles(directory, name)) {
      bool shouldDelete;
      if (retentionDays <= 0) {
        shouldDelete = true;
      } else {
        try {
          shouldDelete = file.lastModifiedSync().isBefore(cutoff);
        } on FileSystemException {
          shouldDelete = false;
        }
      }
      if (!shouldDelete) continue;
      try {
        file.deleteSync();
        deleted.add(file);
      } on FileSystemException {
        // Keep going; a locked file is retried on the next prune.
      }
    }
    return deleted;
  }

  void _open() {
    final handle = file.openSync(mode: FileMode.append);
    _handle = handle;
    _byteCount = handle.lengthSync();
  }

  void _closeHandle() {
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    try {
      handle.closeSync();
    } on FileSystemException {
      // Nothing left to do with a handle that refuses to close.
    }
  }

  void _rotate() {
    _closeHandle();
    try {
      file.renameSync(_availableRotatedPath());
    } on FileSystemException {
      // Rename failed: keep appending to the current file.
    }
    try {
      _open();
    } on FileSystemException {
      _byteCount = 0;
    }
  }

  String _availableRotatedPath() {
    final now = DateTime.now().toUtc();
    String pad(int value, int width) => value.toString().padLeft(width, '0');
    final stem =
        '$name-${pad(now.year, 4)}${pad(now.month, 2)}${pad(now.day, 2)}-'
        '${pad(now.hour, 2)}${pad(now.minute, 2)}${pad(now.second, 2)}';
    var candidate = _join(directory.path, '$stem.log');
    var suffix = 1;
    while (File(candidate).existsSync()) {
      candidate = _join(directory.path, '$stem-$suffix.log');
      suffix += 1;
    }
    return candidate;
  }

  static String _join(String directory, String name) =>
      directory.endsWith(Platform.pathSeparator)
      ? '$directory$name'
      : '$directory${Platform.pathSeparator}$name';

  static String _basename(String path) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}
