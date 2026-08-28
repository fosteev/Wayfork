import 'package:wayfork/core/app/log_file.dart';
import 'package:wayfork/core/diagnostics/diagnostics_sanitizer.dart';
import 'package:wayfork/core/diagnostics/zip_writer.dart';
import 'package:wayfork/core/ipc/payloads.dart';

/// What goes into `wayfork-diagnostics-<stamp>.zip` (docs/design/06-logging.md,
/// "Export Diagnostics"). The port of the macOS `DiagnosticsExporter`, split so
/// that the file list is pure: reading the logs, running `ipconfig` and writing
/// the archive stay in the app layer.
final class DiagnosticsInput {
  const DiagnosticsInput({
    required this.systemReport,
    required this.storeJSON,
    this.singBoxConfig,
    this.ruleSets = const {},
    this.logs = const {},
    this.daemon,
    this.includeServerAddresses = false,
  });

  /// `system.txt`, already rendered by [DiagnosticsReport.systemReport].
  final String systemReport;

  /// The store as `StoreCodec.encode` writes it; sanitized here.
  final String storeJSON;

  /// The generated `sing-box.json` and its rule-set files, when a plan could
  /// be built at all.
  final String? singBoxConfig;
  final Map<String, String> ruleSets;

  /// Tails of the app's own log files, keyed by file name (`runtime.log`).
  final Map<String, List<int>> logs;

  /// What the service reported, when it was reachable.
  final DaemonDiagnostics? daemon;

  final bool includeServerAddresses;
}

abstract final class DiagnosticsReport {
  /// The single directory inside the archive, like `ditto --keepParent`.
  static const root = 'wayfork-diagnostics';

  /// How much of each log file is copied, as on macOS.
  static const maxLogBytes = 5 * 1024 * 1024;

  /// `wayfork-diagnostics-20260828-153000.zip`.
  static String suggestedFileName(DateTime now) {
    String pad(int value) => value.toString().padLeft(2, '0');
    final local = now.toLocal();
    return 'wayfork-diagnostics-${local.year}${pad(local.month)}'
        '${pad(local.day)}-${pad(local.hour)}${pad(local.minute)}'
        '${pad(local.second)}.zip';
  }

  /// `system.txt`: the header, then one section per command that was run.
  static String systemReport({
    required String appVersion,
    required String windowsVersion,
    required String serviceState,
    required DaemonInfo? serviceInfo,
    required DateTime generatedAt,
    required Map<String, String> commands,
  }) {
    final sections = <String>[
      [
        'Wayfork $appVersion',
        'Windows $windowsVersion',
        'service: $serviceState',
        'daemon: ${serviceInfo?.version ?? 'unknown'} at '
            '${serviceInfo?.installPath ?? '?'}',
        'sing-box: ${serviceInfo?.singBoxVersion ?? 'unknown'}',
        'openvpn: ${serviceInfo?.openVPNVersion ?? 'unknown'}',
        'generated: ${LogLineFormat.timestamp(generatedAt)}',
      ].join('\n'),
      for (final MapEntry(:key, :value) in commands.entries)
        '## $key\n${value.trimRight()}',
    ];
    return '${sections.join('\n\n')}\n';
  }

  /// The archive's files, in the order they are written.
  static List<ZipEntry> entries(DiagnosticsInput input) {
    final options = SanitizerOptions(
      includeServerAddresses: input.includeServerAddresses,
    );
    final entries = <ZipEntry>[
      ZipEntry.text('$root/system.txt', input.systemReport),
      ZipEntry.text(
        '$root/store.json',
        _sanitize(input.storeJSON, options: options),
      ),
    ];
    final config = input.singBoxConfig;
    if (config != null) {
      entries.add(
        ZipEntry.text(
          '$root/sing-box.json',
          _sanitize(config, options: options),
        ),
      );
      for (final MapEntry(:key, :value) in input.ruleSets.entries) {
        entries.add(ZipEntry.text('$root/${_fileName(key)}', value));
      }
    }
    for (final MapEntry(:key, :value) in input.logs.entries) {
      entries.add(ZipEntry('$root/${_fileName(key)}', value));
    }
    final daemon = input.daemon;
    if (daemon != null) {
      entries.add(
        ZipEntry.text(
          '$root/daemon/daemon.log',
          daemon.daemonLogTail.join('\n'),
        ),
      );
      for (final MapEntry(:key, :value) in daemon.childLogTails.entries) {
        entries.add(
          ZipEntry.text('$root/daemon/${_fileName(key)}.log', value.join('\n')),
        );
      }
      entries.add(
        ZipEntry.text(
          '$root/daemon/run-listing.txt',
          daemon.runDirectoryListing.join('\n'),
        ),
      );
      entries.add(ZipEntry.text('$root/daemon/routes.txt', daemon.routes));
    }
    return entries;
  }

  /// The last [maxBytes] of a log file, cut at the first line break so the
  /// bundle never starts mid-line.
  static List<int> tail(List<int> bytes, {int maxBytes = maxLogBytes}) {
    if (bytes.length <= maxBytes) return bytes;
    final tail = bytes.sublist(bytes.length - maxBytes);
    const newline = 0x0A;
    final index = tail.indexOf(newline);
    return index < 0 ? tail : tail.sublist(index + 1);
  }

  /// A document that is not valid JSON any more (a truncated write, a config
  /// the generator never produced) is still worth having in the bundle.
  static String _sanitize(String text, {required SanitizerOptions options}) {
    try {
      return DiagnosticsSanitizer.sanitizeJSON(text, options: options);
    } on FormatException {
      return '// not valid JSON, omitted: it could not be sanitized\n';
    }
  }

  /// Rule-set and child-log names come from the plan and from the service;
  /// nothing may turn them into a path.
  static String _fileName(String name) {
    final flat = name.replaceAll(RegExp(r'[\\/]'), '_').trim();
    return flat.isEmpty || flat == '.' || flat == '..' ? 'unnamed' : flat;
  }
}
