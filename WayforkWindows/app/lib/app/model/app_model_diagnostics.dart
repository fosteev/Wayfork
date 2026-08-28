part of 'app_model.dart';

// What "Export Diagnostics" needs from the model (docs/design/06-logging.md).
// Building the bundle itself lives in `app/services/diagnostics_exporter.dart`:
// it reads log files and runs `ipconfig`, neither of which belongs here.

extension AppModelDiagnostics on AppModel {
  /// The service's own tails, listings and routes; null when it is not
  /// connected or does not answer.
  Future<DaemonDiagnostics?> collectDiagnostics() async {
    if (!_client.isConnected) return null;
    try {
      return await _client.collectDiagnostics();
    } on Object catch (error) {
      logs.app(
        LogLevel.warning,
        'diagnostics: the service did not answer: $error',
      );
      return null;
    }
  }

  /// The plan that was last applied, or a fresh one when Wayfork is off. The
  /// fresh one skips host resolution: it is only read, never applied.
  Future<RuntimePlan?> planForDiagnostics() async {
    final applied = _lastPlan;
    if (applied != null) return applied;
    try {
      final planSecrets = await PlanSecrets.load(_store, _secrets);
      return RuntimePlanBuilder.build(
        store: _store,
        secrets: planSecrets,
        installDir: installDir,
      ).plan;
    } on Object catch (error) {
      logs.app(LogLevel.warning, 'diagnostics: cannot build a plan: $error');
      return null;
    }
  }

  /// One line about the service for `system.txt`.
  String get serviceStateText {
    final message = _serviceState.message;
    return message == null
        ? _serviceState.phase.name
        : '${_serviceState.phase.name} ($message)';
  }
}
