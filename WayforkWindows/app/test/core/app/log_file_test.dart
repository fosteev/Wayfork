import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/log_file.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

void main() {
  final reference = DateTime.utc(2026, 8, 25, 12, 0, 0, 123);

  test('log line format formats and parses', () {
    final line = LogLine(
      ts: reference,
      source: 'sing-box',
      level: LogLevel.info,
      message: 'message',
    );
    final text = LogLineFormat.format(line);
    expect(text, '2026-08-25T12:00:00.123Z sing-box INFO message');
    expect(LogLineFormat.parse(text), line);

    final spaced = LogLine(
      ts: reference,
      source: 'openvpn:3f2a…',
      level: LogLevel.warning,
      message: 'message with spaces',
    );
    expect(LogLineFormat.parse(LogLineFormat.format(spaced)), spaced);

    final multiline = LogLine(
      ts: reference,
      source: 'app',
      level: LogLevel.error,
      message: 'first\nsecond\r\nthird',
    );
    expect(
      LogLineFormat.format(multiline),
      '2026-08-25T12:00:00.123Z app ERROR first second  third',
    );
  });

  test('log line format rejects malformed lines', () {
    expect(LogLineFormat.parse(''), isNull);
    expect(LogLineFormat.parse('garbage'), isNull);
    expect(
      LogLineFormat.parse('2026-08-25T12:00:00.123Z sing-box TRACE message'),
      isNull,
    );
    expect(
      LogLineFormat.parse('2026-08-25T12:00:00.123Z sing-box info message'),
      isNull,
    );
    expect(
      LogLineFormat.parse('2026-08-25T12:00:00Z sing-box INFO message'),
      isNull,
    );
    expect(LogLineFormat.parse('2026-08-25T12:00:00.123Z  INFO m'), isNull);
  });

  group('AppLogFile', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('wayfork-log-');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    test('rotates without losing lines', () {
      final log = AppLogFile(
        Directory('${directory.path}/nested'),
        'runtime',
        maxBytes: 100,
      );
      final lines = [for (var i = 0; i < 5; i++) '$i-${'x' * 58}'];
      for (final line in lines) {
        log.append(line);
      }
      log.close();

      expect(log.file.readAsStringSync(), '${lines.last}\n');
      final rotated = AppLogFile.rotatedFiles(log.directory, 'runtime');
      expect(rotated, isNotEmpty);
      final stored = [
        for (final file in [...rotated, log.file])
          ...file.readAsStringSync().split('\n').where((l) => l.isNotEmpty),
      ];
      expect(stored..sort(), lines..sort());
    });

    test('returns the tail oldest first', () {
      final log = AppLogFile(directory, 'runtime');
      addTearDown(log.close);
      for (var index = 0; index < 10; index++) {
        log.append('line-$index');
      }
      expect(log.tail(3), ['line-7', 'line-8', 'line-9']);
      expect(log.tail(0), isEmpty);
      expect(log.tail(100), hasLength(10));
      // A byte window that starts mid-line drops the partial first line.
      expect(log.tail(10, maxBytes: 10), ['line-9']);
    });

    test('reopens the existing file and keeps appending', () {
      AppLogFile(directory, 'runtime')
        ..append('first')
        ..close();
      final log = AppLogFile(directory, 'runtime')..append('second');
      addTearDown(log.close);
      expect(log.tail(5), ['first', 'second']);
    });

    test('prunes only expired rotations', () {
      final current = File('${directory.path}/runtime.log')..createSync();
      final old = File('${directory.path}/runtime-20260815-120000.log')
        ..createSync();
      final recent = File('${directory.path}/runtime-20260824-120000.log')
        ..createSync();
      final other = File('${directory.path}/wayfork-20260815-120000.log')
        ..createSync();
      final now = reference;
      old.setLastModifiedSync(now.subtract(const Duration(days: 10)));
      recent.setLastModifiedSync(now.subtract(const Duration(days: 1)));
      other.setLastModifiedSync(now.subtract(const Duration(days: 10)));

      final deleted = AppLogFile.prune(
        directory,
        'runtime',
        retentionDays: 7,
        now: now,
      );
      // Compare by name: `listSync` reports `\` on Windows, the test built
      // the path with `/`.
      expect(deleted.map((f) => f.uri.pathSegments.last), [
        old.uri.pathSegments.last,
      ]);
      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      expect(current.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);

      expect(
        AppLogFile.prune(directory, 'runtime', retentionDays: 0, now: now),
        hasLength(1),
      );
      expect(recent.existsSync(), isFalse);
    });

    test('rejects an invalid configuration', () {
      expect(
        () => AppLogFile(directory, '', maxBytes: 10),
        throwsA(isA<AppLogFileException>()),
      );
      expect(
        () => AppLogFile(directory, 'runtime', maxBytes: 0),
        throwsA(isA<AppLogFileException>()),
      );
    });
  });
}
