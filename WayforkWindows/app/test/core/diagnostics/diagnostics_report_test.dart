import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/diagnostics/diagnostics_report.dart';
import 'package:wayfork/core/diagnostics/zip_writer.dart';
import 'package:wayfork/core/ipc/payloads.dart';

String textOf(List<ZipEntry> entries, String name) =>
    utf8.decode(entries.firstWhere((entry) => entry.name == name).bytes);

void main() {
  const storeJSON =
      '{"tunnels": [{"name": "office", "uuid": "secret-uuid", '
      '"server": "vpn.example.com"}]}';

  test('the bundle carries the store, the plan and the service files', () {
    final entries = DiagnosticsReport.entries(
      DiagnosticsInput(
        systemReport: 'Wayfork 0.1.0\n',
        storeJSON: storeJSON,
        singBoxConfig: '{"outbounds": [{"server": "vpn.example.com"}]}',
        ruleSets: const {'rule-set-office.json': '{"rules": []}'},
        logs: {'runtime.log': utf8.encode('runtime line\n')},
        daemon: DaemonDiagnostics(
          daemonLogTail: const ['first', 'second'],
          childLogTails: const {
            'sing-box': ['sniffed'],
          },
          runDirectoryListing: const ['sing-box.json'],
          routes: '0.0.0.0/0 via Wayfork',
        ),
      ),
    );

    expect(entries.map((entry) => entry.name), [
      'wayfork-diagnostics/system.txt',
      'wayfork-diagnostics/store.json',
      'wayfork-diagnostics/sing-box.json',
      'wayfork-diagnostics/rule-set-office.json',
      'wayfork-diagnostics/runtime.log',
      'wayfork-diagnostics/daemon/daemon.log',
      'wayfork-diagnostics/daemon/sing-box.log',
      'wayfork-diagnostics/daemon/run-listing.txt',
      'wayfork-diagnostics/daemon/routes.txt',
    ]);
    expect(
      textOf(entries, 'wayfork-diagnostics/daemon/daemon.log'),
      'first\nsecond',
    );
    expect(
      textOf(entries, 'wayfork-diagnostics/daemon/routes.txt'),
      '0.0.0.0/0 via Wayfork',
    );
    expect(
      textOf(entries, 'wayfork-diagnostics/runtime.log'),
      'runtime line\n',
    );
  });

  test('secrets go, server addresses are placeholders unless asked for', () {
    final sanitized = DiagnosticsReport.entries(
      const DiagnosticsInput(systemReport: '', storeJSON: storeJSON),
    );
    expect(
      textOf(sanitized, 'wayfork-diagnostics/store.json'),
      allOf(
        contains('<redacted>'),
        contains('server-1'),
        isNot(contains('secret-uuid')),
        isNot(contains('vpn.example.com')),
      ),
    );

    final kept = DiagnosticsReport.entries(
      const DiagnosticsInput(
        systemReport: '',
        storeJSON: storeJSON,
        includeServerAddresses: true,
      ),
    );
    expect(
      textOf(kept, 'wayfork-diagnostics/store.json'),
      allOf(contains('vpn.example.com'), contains('<redacted>')),
    );
  });

  test('a document that is not JSON any more is noted, not dropped', () {
    final entries = DiagnosticsReport.entries(
      const DiagnosticsInput(systemReport: '', storeJSON: '{"tunnels": ['),
    );
    expect(
      textOf(entries, 'wayfork-diagnostics/store.json'),
      contains('not valid JSON'),
    );
  });

  test('names from the plan and the service cannot become paths', () {
    final entries = DiagnosticsReport.entries(
      DiagnosticsInput(
        systemReport: '',
        storeJSON: '{}',
        singBoxConfig: '{}',
        ruleSets: const {'../rule-set.json': '{}'},
        daemon: DaemonDiagnostics(
          daemonLogTail: const [],
          childLogTails: const {
            r'..\openvpn': ['line'],
          },
          runDirectoryListing: const [],
          routes: '',
        ),
      ),
    );
    expect(
      entries.map((entry) => entry.name),
      containsAll([
        'wayfork-diagnostics/.._rule-set.json',
        'wayfork-diagnostics/daemon/.._openvpn.log',
      ]),
    );
  });

  test('a log tail is cut at a line break', () {
    final bytes = utf8.encode('first line\nsecond line\nthird line\n');
    expect(
      utf8.decode(DiagnosticsReport.tail(bytes, maxBytes: 20)),
      'third line\n',
    );
    expect(DiagnosticsReport.tail(bytes, maxBytes: 4096), bytes);
  });

  test('the suggested name stamps the local time', () {
    expect(
      DiagnosticsReport.suggestedFileName(DateTime(2026, 8, 28, 9, 5, 3)),
      'wayfork-diagnostics-20260828-090503.zip',
    );
  });

  test('system.txt names the versions and every command that ran', () {
    final report = DiagnosticsReport.systemReport(
      appVersion: '0.1.0',
      windowsVersion: '10.0.26100',
      serviceState: 'ready',
      serviceInfo: DaemonInfo(
        version: '0.1.0',
        installPath: r'C:\Program Files\Wayfork',
        singBoxVersion: '1.13.0',
        openVPNVersion: '2.6.14',
      ),
      generatedAt: DateTime.utc(2026, 8, 28, 12, 0, 0, 123),
      commands: const {'ipconfig /all': 'Windows IP Configuration\n\n'},
    );
    expect(report, contains('Wayfork 0.1.0'));
    expect(report, contains('Windows 10.0.26100'));
    expect(report, contains('service: ready'));
    expect(report, contains(r'daemon: 0.1.0 at C:\Program Files\Wayfork'));
    expect(report, contains('sing-box: 1.13.0'));
    expect(report, contains('openvpn: 2.6.14'));
    expect(report, contains('generated: 2026-08-28T12:00:00.123Z'));
    expect(report, contains('## ipconfig /all\nWindows IP Configuration\n'));
    expect(report, endsWith('\n'));
  });

  test('system.txt reports the traffic sample with one-way UDP counts', () {
    final report = DiagnosticsReport.systemReport(
      appVersion: '0.1.0',
      windowsVersion: '10.0.26100',
      serviceState: 'ready',
      serviceInfo: null,
      generatedAt: DateTime.utc(2026, 9, 1),
      commands: const {},
      traffic: TrafficSnapshot(
        sampledAt: DateTime.utc(2026, 9, 1, 12, 0, 5),
        interval: 1,
        tunnels: const {
          'aa-1': TrafficCounters(
            downTotal: 1048576,
            upTotal: 20480,
            connections: 3,
            oneWayUDPFlows: 2,
          ),
        },
        direct: const TrafficCounters(downTotal: 512, connections: 1),
      ),
      tunnelNames: const {'aa-1': 'Work'},
    );
    expect(report, contains('## traffic'));
    expect(report, contains('sampled 2026-09-01T12:00:05.000Z'));
    expect(
      report,
      contains(
        'Work (t-aa-1): ↓ 1.0 MB ↑ 20 KB · 3 connections · '
        '2 one-way UDP flows',
      ),
    );
    expect(report, contains('Direct: ↓ 512 B ↑ 0 B · 1 connection'));
    expect(report, isNot(contains('Direct: ↓ 512 B ↑ 0 B · 1 connection ·')));
  });

  test('an unreachable service leaves the versions unknown', () {
    final report = DiagnosticsReport.systemReport(
      appVersion: '0.1.0',
      windowsVersion: '10.0.26100',
      serviceState: 'disconnected (the pipe is not there)',
      serviceInfo: null,
      generatedAt: DateTime.utc(2026, 8, 28),
      commands: const {},
    );
    expect(report, contains('daemon: unknown at ?'));
    expect(report, contains('sing-box: unknown'));
  });
}
