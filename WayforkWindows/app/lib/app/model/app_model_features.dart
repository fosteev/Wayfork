part of 'app_model.dart';

// F14 latency, F15 recent hosts, F17 local proxy ports, F18 block list and
// F19 failed connections on the app side.

extension AppModelFeatures on AppModel {
  // Latency (F14)

  /// Latest probe of a tunnel; null before the first round or without a fresh
  /// sample.
  LatencySample? latency(Tunnel tunnel) => _traffic?.latency[tunnel.id];

  // Recent hosts (F15)

  /// How far back the flyout and the Rules strip look.
  static const recentWindow = Duration(minutes: 5);

  /// Rows worth showing right now, newest first: within the window, not
  /// hidden, not already covered by an active domain rule.
  List<RecentHost> get recentHosts {
    final traffic = _traffic;
    if (!globalState.isRunning || traffic == null) return const [];
    return RecentFilter.visible(
      traffic.recentHosts,
      sampledAt: traffic.sampledAt,
      window: recentWindow,
      hidden: hiddenRecentHosts,
      store: _store,
    );
  }

  /// Where the listed flows went: the default tunnel's or group's name, or
  /// null for direct.
  String? get recentExitName => StatusText.effectiveDefaultExitName(
    _store,
    missingSecrets: _missingSecrets,
  );

  /// Targets a row can be routed to: every tunnel and group except the default
  /// one, then Direct.
  List<RuleTarget> get recentTargets {
    final defaultID = recentExitName == null ? null : _store.defaultTunnelID;
    return [
      for (final tunnel in _store.tunnels)
        if (tunnel.isEnabled && tunnel.id != defaultID)
          RuleTargetTunnel(tunnel.id),
      for (final group in _store.groups)
        if (group.isEnabled && group.id != defaultID) RuleTargetGroup(group.id),
      const RuleTargetDirect(),
    ];
  }

  /// The pattern *Route via* creates for a row.
  String recentRulePattern(String host) => RulePattern.registrableDomain(host);

  /// Creates the suffix rule and drops the row.
  Future<String?> routeRecent(String host, {required RuleTarget via}) async {
    final message = await addRule(
      pattern: recentRulePattern(host),
      match: RuleMatch.suffix,
      target: via,
    );
    if (message != null) return message;
    hideRecent(host);
    return null;
  }

  /// Hides a row until the next Turn On.
  void hideRecent(String host) {
    hiddenRecentHosts.add(host);
    _changed();
  }

  // Local proxy (F17)

  /// Turns the port on or off; the first turn-on picks the lowest free port.
  Future<void> setLocalProxy(String exitID, {required bool enabled}) async {
    await update((store) {
      final port =
          store.localProxyOfExit(exitID)?.port ??
          store.nextFreeLocalProxyPort();
      return _withLocalProxy(
        store,
        exitID,
        LocalProxy(isEnabled: enabled, port: port),
      );
    });
    final name = _store.exitName(exitID);
    if (name != null) {
      logs.app(LogLevel.info, 'local proxy ${enabled ? 'on' : 'off'}: $name');
    }
  }

  /// Changes the port. Returns an error message, or null when it went through.
  Future<String?> setLocalProxyPort(String exitID, String text) async {
    final problem = LocalProxyText.portProblem(
      text,
      store: _store,
      excluding: exitID,
    );
    if (problem != null) return problem;
    final port = int.parse(text.trim());
    await update((store) {
      final enabled = store.localProxyOfExit(exitID)?.isEnabled ?? false;
      return _withLocalProxy(
        store,
        exitID,
        LocalProxy(isEnabled: enabled, port: port),
      );
    });
    return null;
  }

  /// The service could not bind this exit's port (`proxy.portInUse`).
  bool isLocalProxyPortTaken(String exitID) =>
      _status?.proxyPortInUse.contains(exitID) ?? false;

  Store _withLocalProxy(Store store, String id, LocalProxy proxy) {
    if (store.tunnel(id) != null) {
      return store.copyWith(
        tunnels: [
          for (final tunnel in store.tunnels)
            if (tunnel.id == id) tunnel.copyWith(localProxy: proxy) else tunnel,
        ],
      );
    }
    return store.copyWith(
      groups: [
        for (final group in store.groups)
          if (group.id == id) group.copyWith(localProxy: proxy) else group,
      ],
    );
  }

  // Block list (F18)

  /// What this build ships (`rulesets\block-ads.srs` + sidecar next to the
  /// install directory).
  BlockListInfo get blockList {
    final listPath = WayforkPlatform.windows.blockListPath(installDir);
    if (!File(listPath).existsSync()) return BlockListInfo.missing;
    final sidecar = File(
      '${listPath.substring(0, listPath.length - '.srs'.length)}.json',
    );
    try {
      final decoded = JsonCoding.decode(sidecar.readAsStringSync());
      if (decoded is Map<String, Object?>) {
        return BlockListInfo.fromSidecar(decoded);
      }
    } on Object {
      // A missing or odd sidecar only costs the count in the hint.
    }
    return const BlockListInfo(isAvailable: true);
  }

  /// The service's count since local midnight; null while it cannot count.
  int? get blockedToday => _traffic?.blockedToday;

  /// The counter needs sing-box's `info` lines.
  bool get blockCountingPossible =>
      settings.logLevel == LogLevel.info || settings.logLevel == LogLevel.debug;

  String get blockListHint => BlockListText.hint(
    info: blockList,
    isEnabled: settings.blockList.isEnabled,
    blockedToday: blockedToday,
    isRunning: globalState.isRunning,
    countingPossible: blockCountingPossible,
    appVersion: appVersion,
  );

  Future<void> setBlockList({required bool enabled}) async {
    await updateSettings(
      (settings) => settings.copyWith(
        blockList: settings.blockList.copyWith(isEnabled: enabled),
      ),
    );
    logs.app(LogLevel.info, 'block list ${enabled ? 'on' : 'off'}');
  }

  /// Adds a *Never block* site. Returns an error message, or null when it
  /// went through.
  Future<String?> addBlockException(String input) async {
    final String host;
    try {
      host = BlockListText.normalizeException(input);
    } on RulePatternException catch (error) {
      return RuleEditing.patternMessage(error.kind);
    }
    if (settings.blockList.exceptions.contains(host)) {
      return '$host is already on the list';
    }
    await updateSettings(
      (settings) => settings.copyWith(
        blockList: settings.blockList.copyWith(
          exceptions: [...settings.blockList.exceptions, host],
        ),
      ),
    );
    return null;
  }

  Future<void> removeBlockException(String host) => updateSettings(
    (settings) => settings.copyWith(
      blockList: settings.blockList.copyWith(
        exceptions: settings.blockList.exceptions
            .where((h) => h != host)
            .toList(),
      ),
    ),
  );

  // Can't reach (F19)

  /// Rows for the pane, newest first; empty while off.
  List<FailedHost> get failedHosts {
    final traffic = _traffic;
    if (!globalState.isRunning || traffic == null) return const [];
    return traffic.failedHosts
        .where((row) => !hiddenFailedHosts.contains(row.id))
        .toList();
  }

  /// Rows younger than `FailedText.recentWindow`, for the flyout line.
  int get recentFailedCount {
    final traffic = _traffic;
    if (traffic == null) return 0;
    final cutoff = traffic.sampledAt.subtract(FailedText.recentWindow);
    return failedHosts.where((row) => !row.lastSeen.isBefore(cutoff)).length;
  }

  /// When the current engine run started — the pane's `since`.
  DateTime? get failedSince => switch (_status?.engine) {
    EngineStateRunning(:final since) => since,
    _ => null,
  };

  /// The reason in the user's words for one row.
  String failedReason(FailedHost row) =>
      FailedText.reason(row.reason, exitName: _store.exitName(row.exit));

  /// `direct`, the tunnel or group name, or `—` for a blocked lookup.
  String failedVia(FailedHost row) {
    if (row.exit.isEmpty) return '—';
    if (row.exit == 'direct') return 'direct';
    return _store.exitName(row.exit) ?? row.exit;
  }

  void hideFailed(FailedHost row) {
    hiddenFailedHosts.add(row.id);
    _changed();
  }

  /// *Route via* on a row: a suffix rule for the registrable domain, like
  /// Recent.
  Future<String?> routeFailed(FailedHost row, {required RuleTarget via}) async {
    final message = await addRule(
      pattern: RulePattern.registrableDomain(row.host),
      match: RuleMatch.suffix,
      target: via,
    );
    if (message != null) return message;
    hideFailed(row);
    return null;
  }

  /// *Never block* on a row whose reason is the list.
  Future<void> neverBlockFailed(FailedHost row) async {
    final host = row.host.endsWith('.')
        ? row.host.substring(0, row.host.length - 1)
        : row.host;
    if (await addBlockException(host) == null) hideFailed(row);
  }

  /// Whether a row can become a domain rule: a name that reached an outbound
  /// (an address or a blocked lookup cannot).
  bool canRouteFailed(FailedHost row) =>
      row.exit.isNotEmpty && row.host.contains(RegExp('[a-zA-Z]'));
}
