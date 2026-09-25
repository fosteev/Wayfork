import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/services/diagnostics_exporter.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

import '../core/diagnostics/zip_reader.dart';
import 'fakes.dart';

void main() {
  late Harness h;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wayfork-diagnostics');
    h = Harness(logDirectory: directory);
  });

  tearDown(() async {
    await h.dispose();
    await directory.delete(recursive: true);
  });

  String path(String name) => '${directory.path}${Platform.pathSeparator}$name';

  DiagnosticsExporter exporter() => DiagnosticsExporter(
    shell: (command) async => 'output of $command',
    now: () => DateTime(2026, 8, 28, 15, 30, 45),
  );

  test('the bundle carries the report, the plan, the logs and the service '
      'files', () async {
    h.service.status = RuntimeStatus.stopped;
    await h.start();
    h.model.logs.app(LogLevel.error, 'something to find in the tail');

    final target = path('bundle.zip');
    expect(
      await exporter().export(
        h.model,
        path: target,
        includeServerAddresses: false,
      ),
      isTrue,
    );

    final files = unzip(File(target).readAsBytesSync());
    expect(
      files.keys,
      containsAll([
        'wayfork-diagnostics/system.txt',
        'wayfork-diagnostics/store.json',
        'wayfork-diagnostics/sing-box.json',
        'wayfork-diagnostics/wayfork.log',
        'wayfork-diagnostics/daemon/daemon.log',
        'wayfork-diagnostics/daemon/routes.txt',
      ]),
    );
    final report = utf8.decode(files['wayfork-diagnostics/system.txt']!);
    for (final command in DiagnosticsExporter.commands) {
      expect(report, contains('## $command\noutput of $command'));
    }
    expect(report, contains('Wayfork ${h.model.appVersion}'));
    expect(report, contains('service: connected'));
    expect(
      utf8.decode(files['wayfork-diagnostics/wayfork.log']!),
      contains('something to find in the tail'),
    );
    expect(
      utf8.decode(files['wayfork-diagnostics/daemon/daemon.log']!),
      'line',
      reason: 'what the fake service reported',
    );
    expect(
      utf8.decode(files['wayfork-diagnostics/store.json']!),
      isNot(contains('vpn.example.com')),
    );
    expect(
      utf8.decode(files['wayfork-diagnostics/sing-box.json']!),
      isNot(contains('host.example.com')),
    );
  });

  test('server addresses stay when they are asked for', () async {
    await h.start();
    final target = path('with-servers.zip');
    await exporter().export(
      h.model,
      path: target,
      includeServerAddresses: true,
    );

    final files = unzip(File(target).readAsBytesSync());
    expect(
      utf8.decode(files['wayfork-diagnostics/store.json']!),
      contains('vpn.example.com'),
    );
  });

  test('an unreachable service still yields a bundle', () async {
    h.service.available = false;
    await h.start();

    final target = path('offline.zip');
    expect(
      await exporter().export(
        h.model,
        path: target,
        includeServerAddresses: false,
      ),
      isTrue,
    );
    final files = unzip(File(target).readAsBytesSync());
    expect(
      files.keys,
      isNot(contains('wayfork-diagnostics/daemon/daemon.log')),
    );
    expect(
      utf8.decode(files['wayfork-diagnostics/system.txt']!),
      contains('daemon: unknown'),
    );
  });

  test('a path that cannot be written is reported, not thrown', () async {
    await h.start();
    expect(
      await exporter().export(
        h.model,
        path: path('missing${Platform.pathSeparator}bundle.zip'),
        includeServerAddresses: false,
      ),
      isFalse,
    );
    expect(h.model.alerts.single.title, 'Export failed');
  });
}
