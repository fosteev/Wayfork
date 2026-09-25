part of 'app_model.dart';

// Connections by exit (F20, docs/design/06-logging.md, "Logs window ›
// Connections view"): the service only ever sends cumulative counters since
// Turn On (`TrafficSnapshot.exits`), so the app keeps a short ring of
// samples to answer *Last 5 min* and a baseline to answer *Reset* — both
// windows read the same cumulative wire data, never a fresh protocol round
// trip. Mirrors Wayfork/App/Model/AppModel+Exits.swift.

/// `Since Turn On` (from the service's counters, offset by the last *Reset*)
/// or `Last 5 min` (subtracted from the ring).
enum ExitsWindow { sinceTurnOn, last5Min }

enum ExitRowKind { tunnel, group, direct, blocked }

/// One row of the Connections table.
final class ExitRow {
  const ExitRow({
    required this.id,
    required this.kind,
    required this.name,
    required this.isDefault,
    this.usingMember,
    this.connections,
    this.reached,
    required this.failed,
    this.rate,
    this.lastFailureText,
    required this.isError,
  });

  final String id;
  final ExitRowKind kind;
  final String name;
  final bool isDefault;

  /// `using <member>` under a group's name.
  final String? usingMember;

  /// null renders `—` (log detail *Problems*, or the blocked row).
  final int? connections;
  final int? reached;
  final int failed;
  final double? rate;
  final String? lastFailureText;
  final bool isError;
}

final class ExitsTotals {
  const ExitsTotals({
    required this.connections,
    required this.reached,
    required this.failed,
    this.rate,
  });

  final int connections;
  final int reached;
  final int failed;
  final double? rate;
}

extension AppModelExits on AppModel {
  static const _ringWindow = FailedText.recentWindow;

  /// Rows for the table, in the fixed order: tunnels in the popover's
  /// order, groups after their members, *Not via any tunnel*, then the
  /// dimmed *Blocked by your list* row last.
  List<ExitRow> exitRows(ExitsWindow window) {
    if (!globalState.isRunning) return const [];
    final rows = <ExitRow>[];
    for (final tunnel in _store.tunnels.where((t) => t.isEnabled)) {
      rows.add(
        _exitRow(
          id: tunnel.id,
          kind: ExitRowKind.tunnel,
          name: tunnel.name,
          isDefault: tunnel.id == _store.defaultTunnelID,
          usingMember: null,
          window: window,
        ),
      );
    }
    for (final group in _store.groups.where((g) => g.isEnabled)) {
      final activeMember = _traffic?.groups[group.id]?.activeMember;
      final usingMember = activeMember == null
          ? null
          : _store.exitName(activeMember);
      rows.add(
        _exitRow(
          id: group.id,
          kind: ExitRowKind.group,
          name: group.name,
          isDefault: group.id == _store.defaultTunnelID,
          usingMember: usingMember,
          window: window,
        ),
      );
    }
    rows.add(
      _exitRow(
        id: 'direct',
        kind: ExitRowKind.direct,
        name: 'Not via any tunnel',
        isDefault: false,
        usingMember: null,
        window: window,
      ),
    );
    final blockedStats = _effectiveExitStats('direct', window);
    rows.add(
      ExitRow(
        id: 'blocked',
        kind: ExitRowKind.blocked,
        name: ExitsText.blockedLabel,
        isDefault: false,
        failed: blockedStats.blocked,
        isError: false,
      ),
    );
    return rows;
  }

  /// The bottom total row, blocked excluded.
  ExitsTotals exitsTotals(ExitsWindow window) {
    final rows = exitRows(
      window,
    ).where((row) => row.kind != ExitRowKind.blocked);
    final connections = rows.fold<int>(
      0,
      (sum, row) => sum + (row.connections ?? 0),
    );
    final reached = rows.fold<int>(0, (sum, row) => sum + (row.reached ?? 0));
    final failed = rows.fold<int>(0, (sum, row) => sum + row.failed);
    final anyOpenedKnown = rows.any((row) => row.connections != null);
    return ExitsTotals(
      connections: connections,
      reached: reached,
      failed: failed,
      rate: anyOpenedKnown && connections > 0
          ? math.min(1.0, failed / connections)
          : null,
    );
  }

  /// Whether `opened` is unavailable — sing-box's log level is above
  /// *Normal*: no match line has been seen since the last reset, or nothing
  /// has been seen yet and the setting says the lines will not come (the
  /// F19 pane's check).
  bool get exitsNeedNormalLogLevel {
    final traffic = _traffic;
    if (traffic != null && traffic.exits.isNotEmpty) {
      return traffic.exits.values.every((stats) => stats.opened == null);
    }
    return settings.logLevel != LogLevel.info &&
        settings.logLevel != LogLevel.debug;
  }

  /// When the window in `.sinceTurnOn` started: the last *Reset*, or Turn
  /// On.
  DateTime? get exitsSince => _exitsResetAt ?? failedSince;

  /// F19 rows that went through one exit, for the expanded section under a
  /// row.
  List<FailedHost> failedHostsForExit(String id) {
    final exit = id == 'blocked' ? '' : id;
    return failedHosts.where((row) => row.exit == exit).toList();
  }

  /// *Reset* on the Connections view: the counters read zero from here on,
  /// in `.sinceTurnOn`; `.last5Min` is unaffected (it is already a short
  /// window).
  void resetExits() {
    _exitsBaseline = _traffic?.exits ?? const {};
    _exitsResetAt = DateTime.now();
    _changed();
  }

  /// Whether a tunnel's or group's exit failed at least once in the last 5
  /// minutes.
  bool exitHasRecentFailures(String id) =>
      _effectiveExitStats(id, ExitsWindow.last5Min).failed > 0;

  // Sampling

  /// Fed from every traffic snapshot; trimmed to a bit over the ring
  /// window.
  void recordExitsSample(TrafficSnapshot snapshot) {
    _exitsRing.add((snapshot.sampledAt, snapshot.exits));
    final cutoff = snapshot.sampledAt.subtract(_ringWindow * 1.2);
    while (_exitsRing.length > 1 && _exitsRing[1].$1.isBefore(cutoff)) {
      _exitsRing.removeAt(0);
    }
  }

  /// Turn On: the service's counters start over, so does the app's
  /// tracking of them.
  void resetExitsTracking() {
    _exitsRing.clear();
    _exitsBaseline = null;
    _exitsResetAt = null;
  }

  // Pieces

  ExitRow _exitRow({
    required String id,
    required ExitRowKind kind,
    required String name,
    required bool isDefault,
    required String? usingMember,
    required ExitsWindow window,
  }) {
    final stats = _effectiveExitStats(id, window);
    final connections = stats.opened;
    final reached = connections == null
        ? null
        : math.max(0, connections - stats.failed);
    // Clamped: an error without its match line (log detail switched
    // mid-run) can put failed above opened.
    final rate = connections == null
        ? null
        : (connections > 0 ? math.min(1.0, stats.failed / connections) : 0.0);
    final exitName = _store.exitName(id) ?? name;
    final lastFailureText = ExitsText.lastFailure(
      stats,
      exitName: exitName,
      now: _traffic?.sampledAt ?? DateTime.now(),
    );
    return ExitRow(
      id: id,
      kind: kind,
      name: name,
      isDefault: isDefault,
      usingMember: usingMember,
      connections: connections,
      reached: reached,
      failed: stats.failed,
      rate: rate,
      lastFailureText: lastFailureText,
      isError: stats.failed > 0,
    );
  }

  /// The counters for one exit under the chosen window: `.sinceTurnOn`
  /// offset by the last *Reset*, `.last5Min` subtracted from the ring.
  ExitStats _effectiveExitStats(String id, ExitsWindow window) {
    final current = _traffic?.exits[id] ?? const ExitStats();
    switch (window) {
      case ExitsWindow.sinceTurnOn:
        final baseline = _exitsBaseline?[id];
        if (baseline == null) return current;
        return ExitStats(
          opened: _subtractExit(current.opened, baseline.opened),
          failed: math.max(0, current.failed - baseline.failed),
          blocked: math.max(0, current.blocked - baseline.blocked),
          lastFailure: current.lastFailure,
          lastFailedAt: current.lastFailedAt,
        );
      case ExitsWindow.last5Min:
        final now = _traffic?.sampledAt;
        if (now == null) return current;
        final cutoff = now.subtract(_ringWindow);
        final atOrAfterCutoff = _exitsRing.firstWhereOrNull(
          (sample) => !sample.$1.isBefore(cutoff),
        );
        final old =
            atOrAfterCutoff?.$2[id] ??
            (_exitsRing.isEmpty ? null : _exitsRing.first.$2[id]);
        if (old == null) return current;
        final recentFailure =
            current.lastFailedAt != null &&
            !current.lastFailedAt!.isBefore(cutoff);
        return ExitStats(
          opened: _subtractExit(current.opened, old.opened),
          failed: math.max(0, current.failed - old.failed),
          blocked: math.max(0, current.blocked - old.blocked),
          lastFailure: recentFailure ? current.lastFailure : null,
          lastFailedAt: recentFailure ? current.lastFailedAt : null,
        );
    }
  }

  int? _subtractExit(int? current, int? baseline) {
    if (current == null) return null;
    return math.max(0, current - (baseline ?? 0));
  }
}
