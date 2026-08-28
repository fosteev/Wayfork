import 'dart:convert';
import 'dart:io';

import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/core/diagnostics/diagnostics_report.dart';
import 'package:wayfork/core/diagnostics/zip_writer.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';

/// Runs one command line and returns its output, errors included.
typedef DiagnosticsShell = Future<String> Function(String commandLine);

/// "Export Diagnostics" (docs/design/06-logging.md): the impure half of
/// [DiagnosticsReport] — the log files, the three Windows commands that stand
/// in for the macOS `ifconfig`/`route`/`scutil` block, and the write itself.
final class DiagnosticsExporter {
  const DiagnosticsExporter({
    this.shell = runDiagnosticsCommand,
    this.now = DateTime.now,
  });

  /// Section title → command line, in the order `system.txt` lists them.
  static const commands = <String>[
    'ipconfig /all',
    'route print -4',
    'netsh interface ipv4 show dnsservers',
  ];

  final DiagnosticsShell shell;
  final DateTime Function() now;

  String suggestedFileName() => DiagnosticsReport.suggestedFileName(now());

  /// Writes the bundle to [path]; false means an alert was queued.
  Future<bool> export(
    AppModel model, {
    required String path,
    required bool includeServerAddresses,
  }) async {
    try {
      final daemon = await model.collectDiagnostics();
      final plan = await model.planForDiagnostics();
      final generatedAt = now();
      final input = DiagnosticsInput(
        systemReport: DiagnosticsReport.systemReport(
          appVersion: model.appVersion,
          windowsVersion: Platform.operatingSystemVersion,
          serviceState: model.serviceStateText,
          serviceInfo: model.serviceInfo,
          generatedAt: generatedAt,
          commands: {
            for (final command in commands) command: await shell(command),
          },
        ),
        storeJSON: StoreCodec.encode(model.store),
        singBoxConfig: plan?.singBox.config,
        ruleSets: plan?.singBox.ruleSets ?? const {},
        logs: _logTails(model.logs),
        daemon: daemon,
        includeServerAddresses: includeServerAddresses,
      );
      final bytes = ZipWriter.build(
        DiagnosticsReport.entries(input),
        modified: generatedAt,
      );
      await File(path).writeAsBytes(bytes, flush: true);
      model.logs.app(LogLevel.info, 'diagnostics exported to $path');
      return true;
    } on Object catch (error) {
      model.logs.app(LogLevel.error, 'diagnostics export failed: $error');
      model.showAlert(AppAlert(title: 'Export failed', message: '$error'));
      return false;
    }
  }

  /// The tail of every log file the app writes itself; the service's own are
  /// in `daemon/`. A file that is not there yet is simply left out, and so is
  /// everything when the log centre keeps no files at all.
  static Map<String, List<int>> _logTails(LogCenter logs) {
    final directory = logs.directory;
    if (directory == null) return const {};
    final tails = <String, List<int>>{};
    for (final name in const [
      LogCenter.runtimeFileName,
      LogCenter.appFileName,
    ]) {
      final file = File('${directory.path}${Platform.pathSeparator}$name.log');
      try {
        if (!file.existsSync()) continue;
        tails['$name.log'] = DiagnosticsReport.tail(file.readAsBytesSync());
      } on FileSystemException {
        continue;
      }
    }
    return tails;
  }
}

/// `cmd.exe` with the console code page switched to UTF-8, so a localised
/// `ipconfig` does not land in the bundle as mojibake.
Future<String> runDiagnosticsCommand(String commandLine) async {
  if (!Platform.isWindows) return '(not run: Windows only)';
  try {
    const decoder = Utf8Codec(allowMalformed: true);
    final result = await Process.run(
      'cmd.exe',
      ['/c', 'chcp 65001>nul & $commandLine'],
      stdoutEncoding: decoder,
      stderrEncoding: decoder,
    );
    return '${result.stdout}${result.stderr}';
  } on Object catch (error) {
    return '(failed to run: $error)';
  }
}
