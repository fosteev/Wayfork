import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/service_client.dart';

/// Where the UI should take the user: emitted by the model for the ✎ on a
/// failed card, the buttons of an alert and the "repair installation" hint.
sealed class AppAction {
  const AppAction();

  const factory AppAction.openTunnel(String tunnelID, {TunnelField? focus}) =
      AppActionOpenTunnel;
  const factory AppAction.showLogs({String? source}) = AppActionShowLogs;
  const factory AppAction.exportDiagnostics() = AppActionExportDiagnostics;
  const factory AppAction.repairInstallation() = AppActionRepairInstallation;
  const factory AppAction.revealFile(String path) = AppActionRevealFile;

  /// Button title in an alert.
  String get title => switch (this) {
    AppActionOpenTunnel() => 'Edit Tunnel',
    AppActionShowLogs() => 'Show Log',
    AppActionExportDiagnostics() => 'Export Diagnostics…',
    AppActionRepairInstallation() => 'Repair Installation',
    AppActionRevealFile() => 'Show in Explorer',
  };
}

/// Field to focus when Tunnels opens on a tunnel (✎ from a failure).
enum TunnelField { name, username, password, keyPassphrase, config, url }

final class AppActionOpenTunnel extends AppAction {
  const AppActionOpenTunnel(this.tunnelID, {this.focus});

  final String tunnelID;
  final TunnelField? focus;

  @override
  bool operator ==(Object other) =>
      other is AppActionOpenTunnel &&
      tunnelID == other.tunnelID &&
      focus == other.focus;

  @override
  int get hashCode => Object.hash(tunnelID, focus);

  @override
  String toString() => 'openTunnel($tunnelID, $focus)';
}

final class AppActionShowLogs extends AppAction {
  const AppActionShowLogs({this.source});

  /// Source to preselect ("Show Log").
  final String? source;

  @override
  bool operator ==(Object other) =>
      other is AppActionShowLogs && source == other.source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => 'showLogs($source)';
}

final class AppActionExportDiagnostics extends AppAction {
  const AppActionExportDiagnostics();

  @override
  bool operator ==(Object other) => other is AppActionExportDiagnostics;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'exportDiagnostics';
}

final class AppActionRepairInstallation extends AppAction {
  const AppActionRepairInstallation();

  @override
  bool operator ==(Object other) => other is AppActionRepairInstallation;

  @override
  int get hashCode => 2;

  @override
  String toString() => 'repairInstallation';
}

final class AppActionRevealFile extends AppAction {
  const AppActionRevealFile(this.path);

  final String path;

  @override
  bool operator ==(Object other) =>
      other is AppActionRevealFile && path == other.path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'revealFile($path)';
}

enum AlertSeverity { info, warning, critical }

/// A modal message for flows that run outside any page (the macOS
/// `Alerts.show`); the UI renders it as a dialog and dismisses it through
/// `AppModel.dismissAlert`.
final class AppAlert {
  const AppAlert({
    required this.title,
    required this.message,
    this.severity = AlertSeverity.warning,
    this.action,
  });

  final String title;
  final String message;
  final AlertSeverity severity;

  /// The optional second button.
  final AppAction? action;

  @override
  bool operator ==(Object other) =>
      other is AppAlert &&
      title == other.title &&
      message == other.message &&
      severity == other.severity &&
      action == other.action;

  @override
  int get hashCode => Object.hash(title, message, severity, action);

  @override
  String toString() => 'AppAlert($title: $message)';
}

enum ServiceIssueKind {
  /// The pipe does not exist yet, but the app has only just started: the
  /// service comes up on its own schedule at boot, so this is "wait", not
  /// "repair" (docs/design/08-windows.md, "Installer").
  starting,

  /// The pipe does not exist: the service is not installed or not running.
  missing,

  /// The service speaks another protocol or plan version.
  versionMismatch,

  /// A connection was lost; the client is re-dialing.
  disconnected,
}

/// Why the app cannot talk to the service, for the General page and the
/// summary line (docs/design/02-ux.md, "Error catalogue": `helper.*` →
/// "repair installation").
final class ServiceIssue {
  const ServiceIssue(this.kind, {required this.message});

  final ServiceIssueKind kind;
  final String message;

  /// `missing` and `versionMismatch` are fixed by the installer's repair; a
  /// lost connection and a service still coming up fix themselves.
  bool get needsRepair =>
      kind == ServiceIssueKind.missing ||
      kind == ServiceIssueKind.versionMismatch;

  String get hint => switch (kind) {
    ServiceIssueKind.missing ||
    ServiceIssueKind.versionMismatch => 'Repair the installation',
    ServiceIssueKind.starting => 'Waiting for the Wayfork service…',
    ServiceIssueKind.disconnected => 'Reconnecting to the Wayfork service…',
  };

  /// [startingUp] is the app's own grace period: the service is auto-start, so
  /// right after a boot the app can be up first and the pipe simply is not
  /// there yet. Until the period is over that reads as "starting", not as a
  /// broken installation.
  static ServiceIssue? fromState(
    ServiceClientState state, {
    bool startingUp = false,
  }) => switch (state.phase) {
    ServiceClientPhase.serviceMissing when startingUp => const ServiceIssue(
      ServiceIssueKind.starting,
      message: 'The Wayfork service is starting',
    ),
    ServiceClientPhase.serviceMissing => ServiceIssue(
      ServiceIssueKind.missing,
      message: 'The Wayfork service is not running',
    ),
    ServiceClientPhase.versionMismatch => ServiceIssue(
      ServiceIssueKind.versionMismatch,
      message:
          'The Wayfork service does not match this app'
          '${state.hello == null ? '' : ' (service ${state.hello!.version})'}',
    ),
    ServiceClientPhase.disconnected => ServiceIssue(
      ServiceIssueKind.disconnected,
      message: state.message ?? 'Connection to the Wayfork service lost',
    ),
    ServiceClientPhase.connecting || ServiceClientPhase.connected => null,
  };

  @override
  bool operator ==(Object other) =>
      other is ServiceIssue && kind == other.kind && message == other.message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'ServiceIssue($kind: $message)';
}

/// Human-readable form of a service error for logs and alerts.
String describeDaemonError(DaemonError error) => switch (error) {
  DaemonErrorBinaryUntrusted(:final path) => 'binary untrusted: $path',
  DaemonErrorPlanInvalid(:final reason) => 'plan invalid: $reason',
  DaemonErrorConfigInvalid(:final output) =>
    'config invalid: ${output.split('\n').first}',
  DaemonErrorStartFailed(:final logTail) =>
    'start failed'
        '${logTail.isEmpty ? '' : ': ${logTail.last}'}',
  DaemonErrorTunnelNotFound(:final id) => 'tunnel not found: $id',
  DaemonErrorNotRunning() => 'not running',
  DaemonErrorInternal(:final message) => 'internal error: $message',
};
