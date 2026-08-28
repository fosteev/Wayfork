import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wayfork/core/app/log_file.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/store/store_repository.dart';

/// In-memory ring of log lines behind the Logs page plus the on-disk mirrors
/// `wayfork.log` / `runtime.log` under `%LOCALAPPDATA%\Wayfork\logs`
/// (docs/design/06-logging.md; docs/design/08-windows.md, "Filesystem
/// layout"). Without a directory it keeps the ring only (tests).
final class LogCenter extends ChangeNotifier {
  LogCenter({this.directory, this.echoToConsole = kDebugMode}) {
    final directory = this.directory;
    if (directory == null) return;
    _runtimeFile = _open(directory, runtimeFileName);
    _appFile = _open(directory, appFileName);
    final tail = _runtimeFile?.tail(ringCapacity) ?? const <String>[];
    _lines.addAll(tail.map(LogLineFormat.parse).whereType<LogLine>());
    _seen.addAll(_recentKeys());
  }

  static const ringCapacity = 10000;
  static const appSource = 'app';
  static const runtimeFileName = 'runtime';
  static const appFileName = 'wayfork';

  /// `%LOCALAPPDATA%\Wayfork\logs`.
  static Directory defaultDirectory() {
    final base = StoreRepository.defaultDirectory().path;
    final separator = Platform.pathSeparator;
    return Directory(
      base.endsWith(separator) ? '${base}logs' : '$base${separator}logs',
    );
  }

  final Directory? directory;

  /// Also `debugPrint` every app line (the debug console).
  final bool echoToConsole;

  final _lines = <LogLine>[];
  AppLogFile? _runtimeFile;
  AppLogFile? _appFile;
  LogLevel _minimumLevel = LogLevel.info;

  /// Keys of recently received service lines: `subscribe` replays the
  /// service's ring buffers, and the tail loaded from `runtime.log` overlaps
  /// with them.
  final _seen = <_LineKey>{};

  /// Oldest first, at most [ringCapacity] lines (trimmed in chunks).
  List<LogLine> get lines => UnmodifiableListView(_lines);

  /// Lines below this level are neither stored nor shown.
  LogLevel get minimumLevel => _minimumLevel;
  set minimumLevel(LogLevel level) {
    if (level == _minimumLevel) return;
    _minimumLevel = level;
    notifyListeners();
  }

  // App log

  void app(LogLevel level, String message) {
    if (echoToConsole) debugPrint('[wayfork ${level.jsonValue}] $message');
    final line = LogLine(
      ts: DateTime.now().toUtc(),
      source: appSource,
      level: level,
      message: message,
    );
    if (!_accepts(level)) return;
    _appFile?.append(LogLineFormat.format(line));
    _append([line]);
  }

  // Service stream

  void receive(List<LogLine> batch) {
    final fresh = <LogLine>[];
    for (final line in batch) {
      if (!_accepts(line.level)) continue;
      final key = _LineKey(line);
      if (!_seen.add(key)) continue;
      fresh.add(line);
      _runtimeFile?.append(LogLineFormat.format(line));
    }
    if (_seen.length > 20000) {
      _seen
        ..clear()
        ..addAll(_recentKeys());
    }
    _append(fresh);
  }

  void clear() {
    if (_lines.isEmpty) return;
    _lines.clear();
    notifyListeners();
  }

  /// Deletes rotated files older than the retention period.
  void prune({required int retentionDays}) {
    final directory = this.directory;
    if (directory == null) return;
    for (final name in const [runtimeFileName, appFileName]) {
      AppLogFile.prune(directory, name, retentionDays: retentionDays);
    }
  }

  void close() {
    _runtimeFile?.close();
    _appFile?.close();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }

  bool _accepts(LogLevel level) => level.rank <= _minimumLevel.rank;

  void _append(List<LogLine> fresh) {
    if (fresh.isEmpty) return;
    _lines.addAll(fresh);
    final overflow = _lines.length - ringCapacity;
    if (overflow > 1000) _lines.removeRange(0, overflow);
    notifyListeners();
  }

  Iterable<_LineKey> _recentKeys() => _lines
      .skip(_lines.length > 5000 ? _lines.length - 5000 : 0)
      .map(_LineKey.new);

  static AppLogFile? _open(Directory directory, String name) {
    try {
      return AppLogFile(directory, name);
    } on AppLogFileException {
      return null;
    }
  }
}

final class _LineKey {
  _LineKey(LogLine line)
    : ts = line.ts,
      source = line.source,
      message = line.message;

  final DateTime ts;
  final String source;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is _LineKey &&
      ts == other.ts &&
      source == other.source &&
      message == other.message;

  @override
  int get hashCode => Object.hash(ts, source, message);
}
