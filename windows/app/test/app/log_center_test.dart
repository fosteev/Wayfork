import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/core/app/log_file.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

LogLine line(
  String message, {
  LogLevel level = LogLevel.info,
  String source = 'sing-box',
  DateTime? ts,
}) => LogLine(
  ts: ts ?? DateTime.utc(2026, 8, 28, 12),
  source: source,
  level: level,
  message: message,
);

void main() {
  group('LogCenter', () {
    test('keeps app and service lines above the minimum level', () {
      final logs = LogCenter();
      var notified = 0;
      logs.addListener(() => notified += 1);
      logs.app(LogLevel.info, 'starting');
      logs.app(LogLevel.debug, 'hidden');
      logs.receive([line('started'), line('chatter', level: LogLevel.debug)]);
      expect(logs.lines.map((l) => l.message), ['starting', 'started']);
      expect(logs.lines.first.source, LogCenter.appSource);
      expect(notified, 2);

      logs.minimumLevel = LogLevel.debug;
      logs.app(LogLevel.debug, 'shown');
      expect(logs.lines.last.message, 'shown');
      logs.clear();
      expect(logs.lines, isEmpty);
      logs.dispose();
    });

    test('drops replayed service lines', () {
      final logs = LogCenter();
      logs.receive([line('a'), line('b')]);
      // `subscribe` after a reconnect replays the service ring buffer.
      logs.receive([line('a'), line('b'), line('c')]);
      expect(logs.lines.map((l) => l.message), ['a', 'b', 'c']);
      // Same text at another time is a new line.
      logs.receive([line('c', ts: DateTime.utc(2026, 8, 28, 12, 0, 1))]);
      expect(logs.lines, hasLength(4));
      logs.dispose();
    });

    test('trims the ring in chunks', () {
      final logs = LogCenter();
      void add(int i) => logs.receive([
        line('$i', ts: DateTime.utc(2026).add(Duration(seconds: i))),
      ]);
      // Up to 1000 lines over capacity are tolerated, then a chunk goes.
      for (var i = 0; i < LogCenter.ringCapacity + 1000; i++) {
        add(i);
      }
      expect(logs.lines.length, LogCenter.ringCapacity + 1000);
      add(LogCenter.ringCapacity + 1000);
      expect(logs.lines.length, LogCenter.ringCapacity);
      expect(logs.lines.first.message, '1001');
      expect(logs.lines.last.message, '${LogCenter.ringCapacity + 1000}');
      logs.dispose();
    });

    test('mirrors to the files and reloads the runtime tail', () {
      final directory = Directory.systemTemp.createTempSync('wayfork-logs-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final logs = LogCenter(directory: directory);
      logs.app(LogLevel.warning, 'own line');
      logs.receive([line('service line'), line('second')]);
      logs.dispose();

      final appFile = File('${directory.path}/wayfork.log');
      final runtimeFile = File('${directory.path}/runtime.log');
      expect(appFile.readAsStringSync(), contains('app WARNING own line'));
      expect(runtimeFile.readAsStringSync().trim().split('\n'), [
        '2026-08-28T12:00:00.000Z sing-box INFO service line',
        '2026-08-28T12:00:00.000Z sing-box INFO second',
      ]);

      // A fresh center shows the runtime tail and does not duplicate it when
      // the service replays the same lines.
      final reloaded = LogCenter(directory: directory);
      expect(reloaded.lines.map((l) => l.message), ['service line', 'second']);
      reloaded.receive([line('second'), line('third')]);
      expect(reloaded.lines.map((l) => l.message), [
        'service line',
        'second',
        'third',
      ]);
      reloaded.dispose();
    });

    test('prunes rotated files of both logs', () {
      final directory = Directory.systemTemp.createTempSync('wayfork-logs-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final old = DateTime.now().subtract(const Duration(days: 30));
      for (final name in [
        'runtime-20260701-120000',
        'wayfork-20260701-120000',
      ]) {
        File('${directory.path}/$name.log')
          ..createSync()
          ..setLastModifiedSync(old);
      }
      final logs = LogCenter(directory: directory);
      logs.prune(retentionDays: 7);
      expect(AppLogFile.rotatedFiles(directory, 'runtime'), isEmpty);
      expect(AppLogFile.rotatedFiles(directory, 'wayfork'), isEmpty);
      logs.dispose();
    });
  });
}
