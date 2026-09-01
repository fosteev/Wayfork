import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/services/launch_at_login.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/app/services/notifier.dart';
import 'package:wayfork/core/app/global_state.dart';
import 'package:wayfork/core/app/import_export.dart';
import 'package:wayfork/core/app/recovery_backoff.dart';
import 'package:wayfork/core/app/rule_editing.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/app/traffic_format.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/ipc/service_client.dart';
import 'package:wayfork/core/ipc/service_connection.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/openvpn/openvpn_config_parser.dart';
import 'package:wayfork/core/plan/host_resolver.dart';
import 'package:wayfork/core/plan/runtime_plan_builder.dart';
import 'package:wayfork/core/plan/system_dns.dart';
import 'package:wayfork/core/rules/fake_ip.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';
import 'package:wayfork/core/rules/rule_validator.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:wayfork/core/singbox/sing_box_config_generator.dart';
import 'package:wayfork/core/store/store_repository.dart';
import 'package:wayfork/core/support/local_networks.dart';
import 'package:wayfork/core/version.dart';
import 'package:wayfork/core/vless/vless_uri_parser.dart';

part 'app_model_diagnostics.dart';
part 'app_model_import_export.dart';
part 'app_model_rules.dart';
part 'app_model_tunnels.dart';

/// Resolves OpenVPN server names to IPv4 addresses for the direct route rule.
typedef HostResolve =
    Future<Map<String, List<String>>> Function(Iterable<String> hosts);

/// Single owner of the app state: store, runtime status, service state and
/// the derived global state (docs/design/00-architecture.md, "Concurrency";
/// docs/design/02-ux.md; docs/design/08-windows.md, "Flutter app"). The port
/// of the macOS `AppModel`: the service is reached through [ServiceClient]
/// over the named pipe instead of XPC, and everything the UI must render
/// (alerts, navigation) is exposed as state and streams instead of being
/// shown from here.
final class AppModel extends ChangeNotifier {
  AppModel({
    required this._repository,
    required this._secrets,
    required ServiceClient client,
    required this.logs,
    this._notifier = const ConsoleNotifier(),
    LaunchAtLogin? launchAtLogin,
    this._resolveHosts = HostResolver.resolveIPv4,
    this._systemDns = SystemDns.snapshot,
    this._localNetworks = LocalNetwork.current,
    Stream<void>? networkChanges,
    String? installDir,
    this.appVersion = WayforkVersion.app,
    this.applyDebounce = const Duration(milliseconds: 300),
    this.startingTimeout = GlobalStateDerivation.startingTimeout,
    this.trafficStaleAfter = TrafficFormat.staleAfter,
    this.pulseInterval = const Duration(milliseconds: 600),
    this.connectTimeout = const Duration(seconds: 10),
    this.serviceStartupGrace = const Duration(seconds: 45),

    /// H2: the waits between automatic re-applies after the engine failed.
    List<Duration>? recoveryDelays,
    this._now = DateTime.now,
  }) : _recovery = RecoveryBackoff(delays: recoveryDelays),
       _client = client,
       _launchAtLogin = launchAtLogin ?? InMemoryLaunchAtLogin(),
       _installDirFallback =
           installDir ?? File(Platform.resolvedExecutable).parent.path {
    _startedAt = _now();
    _serviceState = client.state;
    _subscriptions.addAll([
      client.states.listen(_onClientState),
      client.statusChanged.listen(_handleStatus),
      client.logLines.listen(_handleLogLines),
      client.trafficChanged.listen(_handleTraffic),
      if (networkChanges != null)
        networkChanges.listen((_) => systemDNSChanged()),
    ]);
    for (final line in logs.lines) {
      if (line.source == _singBoxSource) fakeIPs.ingest(line.message);
    }
  }

  static const _singBoxSource = 'sing-box';

  final LogCenter logs;
  final String appVersion;
  final Duration applyDebounce;
  final Duration startingTimeout;
  final Duration trafficStaleAfter;
  final Duration pulseInterval;

  /// How long Turn On waits for the service connection.
  final Duration connectTimeout;

  /// How long after launch a missing pipe is reported as "the service is
  /// starting" instead of a broken installation.
  final Duration serviceStartupGrace;

  /// Which name got which fake IP, from sing-box's log (`FakeIP`,
  /// docs/design/02-ux.md).
  final fakeIPs = FakeIPIndex();

  final StoreStorage _repository;
  final SecretStore _secrets;
  final ServiceClient _client;
  final Notifier _notifier;
  final LaunchAtLogin _launchAtLogin;
  final HostResolve _resolveHosts;
  final SystemDnsSnapshot Function() _systemDns;
  final List<LocalNetwork> Function() _localNetworks;
  final String _installDirFallback;
  final RecoveryBackoff _recovery;
  final DateTime Function() _now;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _actions = StreamController<AppAction>.broadcast();

  // State

  Store _store = Store.empty;
  RuntimeStatus? _status;
  AppTransition? _transition;
  bool _desiredOn = false;
  ServiceClientState _serviceState = const ServiceClientState(
    ServiceClientPhase.disconnected,
  );
  late final DateTime _startedAt;
  bool _everConnected = false;
  String? _lastServiceProblem;
  DaemonInfo? _serviceInfo;
  TrafficSnapshot? _traffic;
  Set<String> _missingSecrets = const {};
  bool _iconPulse = false;
  bool _persistenceDisabled = false;
  RuntimePlan? _lastPlan;
  final _alerts = <AppAlert>[];

  bool _bootstrapped = false;
  bool _shuttingDown = false;
  bool _attachedOnce = false;
  Completer<void>? _firstSettled;
  Future<void>? _attaching;
  Timer? _applyTimer;
  Future<void>? _applying;
  bool _applyAgain = false;
  Timer? _startingTimer;

  /// H2: pending automatic re-apply while the routing engine is down.
  Timer? _recoveryTimer;

  /// Set while an automatic re-apply runs: its failures are logged, not shown
  /// as alerts.
  bool _autoRecovering = false;
  Timer? _pulseTimer;
  Timer? _pruneTimer;
  Timer? _trafficStaleTimer;
  SystemDnsSnapshot? _appliedSystemDNS;
  ({DateTime at, List<LocalNetwork> networks})? _localNetworksCache;

  Store get store => _store;
  RuntimeStatus? get status => _status;
  AppTransition? get transition => _transition;

  /// The user wants routing on; survives service restarts until the user
  /// turns it off.
  bool get desiredOn => _desiredOn;
  ServiceClientState get serviceState => _serviceState;
  DaemonInfo? get serviceInfo => _serviceInfo;

  /// Latest traffic sample (F9); null while off and when no sample arrived
  /// for [trafficStaleAfter], so the UI shows `—` instead of stale figures.
  TrafficSnapshot? get traffic => _traffic;

  /// Tunnels whose OpenVPN body / VLESS UUID is not in the secret store
  /// (imported without secrets).
  Set<String> get missingSecrets => _missingSecrets;
  bool get iconPulse => _iconPulse;

  /// Set when `store.json` was written by a newer version: never overwrite it.
  bool get persistenceDisabled => _persistenceDisabled;
  RuntimePlan? get lastPlan => _lastPlan;

  /// Alerts waiting to be shown, oldest first.
  List<AppAlert> get alerts => UnmodifiableListView(_alerts);

  /// Navigation the UI should perform (✎ on a failed card, alert buttons).
  Stream<AppAction> get actions => _actions.stream;

  // Navigation state shared with the UI

  String? expandedTunnelID;
  TunnelField? pendingFocus;

  /// Last tunnel used by quick add.
  RuleTarget? quickAddTarget;

  // Derived

  GlobalState get globalState => GlobalStateDerivation.derive(
    store: _store,
    status: _status,
    transition: _transition,
    now: _now(),
  );

  ServiceIssue? get serviceIssue =>
      ServiceIssue.fromState(_serviceState, startingUp: _startingUp);

  /// True while a missing pipe still reads as "the service is coming up": the
  /// app has never reached it and it launched only moments ago — at login the
  /// app regularly wins the race against an auto-start service.
  bool get _startingUp =>
      !_everConnected && _now().difference(_startedAt) < serviceStartupGrace;

  /// The summary line of the tray flyout: the service problem when there is
  /// one that matters, else the routing summary.
  String get summary {
    final issue = serviceIssue;
    if (issue != null && (issue.needsRepair || _desiredOn)) {
      return '${issue.message} — ${issue.hint}';
    }
    return StatusText.summary(
      state: globalState,
      store: _store,
      missingSecrets: _missingSecrets,
    );
  }

  Settings get settings => _store.settings;

  /// Where the bundled binaries live: the service's install path once it
  /// reported one, else next to this executable.
  String get installDir => _serviceInfo?.installPath ?? _installDirFallback;

  Map<String, List<RuleIssue>> get ruleIssues =>
      RuleValidator.validate(_store, localNetworks: _cachedLocalNetworks);

  /// The machine's own networks for the "covers your LAN" chip (F11), looked
  /// up at most every 10 s — [ruleIssues] is evaluated per row render.
  List<LocalNetwork> get _cachedLocalNetworks {
    final cache = _localNetworksCache;
    final now = _now();
    if (cache != null &&
        now.difference(cache.at) < const Duration(seconds: 10)) {
      return cache.networks;
    }
    final networks = _localNetworks();
    _localNetworksCache = (at: now, networks: networks);
    return networks;
  }

  TunnelState? tunnelState(String id) => _status?.tunnels[id];

  /// Traffic figures of a tunnel; null when there is no fresh sample.
  TrafficCounters? trafficCounters(Tunnel tunnel) =>
      _traffic?.countersForTunnel(tunnel.id);

  TrafficCounters? get directTraffic => _traffic?.direct;

  int ruleCount(RuleTarget target) => _store.rulesFor(target).length;

  int ruleCountForTunnel(String tunnelID) =>
      _store.rulesForTunnel(tunnelID).length;

  TunnelPresentation card(Tunnel tunnel) => StatusText.card(
    tunnel: tunnel,
    state: tunnelState(tunnel.id),
    global: globalState,
    ruleCount: ruleCountForTunnel(tunnel.id),
    missingSecret: _missingSecrets.contains(tunnel.id),
    isDefault: effectiveDefaultTunnel?.id == tunnel.id,
  );

  TunnelRowSummary rowSummary(Tunnel tunnel) => StatusText.rowSummary(
    tunnel: tunnel,
    state: tunnelState(tunnel.id),
    global: globalState,
    missingSecret: _missingSecrets.contains(tunnel.id),
    isDefault: effectiveDefaultTunnel?.id == tunnel.id,
  );

  // Default tunnel (F8)

  /// The tunnel actually taking "everything else": set, enabled and with its
  /// secret.
  Tunnel? get effectiveDefaultTunnel => StatusText.effectiveDefaultTunnel(
    _store,
    missingSecrets: _missingSecrets,
  );

  DefaultTunnelIssue? get defaultTunnelIssue =>
      RuleValidator.defaultTunnelIssue(_store, missingSecrets: _missingSecrets);

  bool isDefaultTunnel(String id) => _store.defaultTunnelID == id;

  /// Only one tunnel can be the default; null clears it. A change restarts
  /// the routing engine (`route.final` changes), which the apply pipeline
  /// handles.
  Future<void> setDefaultTunnel(String? id) async {
    if (_store.defaultTunnelID == id) return;
    await update((store) => store.copyWith(defaultTunnelID: id));
    if (id != null) {
      logs.app(LogLevel.info, 'default tunnel: ${tunnelName(id)}');
    } else {
      logs.app(LogLevel.info, 'default tunnel cleared');
    }
  }

  /// Hint under the "Route everything else" toggle (docs/design/02-ux.md,
  /// "Tunnels").
  ({String text, bool isWarning}) defaultTunnelHint(Tunnel tunnel) {
    if (!isDefaultTunnel(tunnel.id)) {
      return (
        text: 'Domains without a rule use this tunnel instead of going direct.',
        isWarning: false,
      );
    }
    switch (defaultTunnelIssue) {
      case DefaultTunnelIssue.disabled:
        return (
          text: 'Disabled — everything else goes direct.',
          isWarning: true,
        );
      case DefaultTunnelIssue.missingSecret:
        final what = tunnel.kind.isOpenVPN ? 'Config' : 'UUID';
        return (
          text: '$what missing — everything else goes direct.',
          isWarning: true,
        );
      case DefaultTunnelIssue.missing || null:
        return (
          text:
              'Domains without a rule use this tunnel; add exceptions in '
              'Rules › Direct. While it is down, unmatched traffic is blocked.',
          isWarning: false,
        );
    }
  }

  /// Header hint of the Direct group in Rules.
  String get directGroupHint {
    final tunnel = effectiveDefaultTunnel;
    if (tunnel != null) {
      return 'Everything else goes through ${tunnel.name}; these domains '
          'stay direct';
    }
    return 'Overrides tunnel rules; everything unmatched already goes direct';
  }

  /// Discovered DNS for an OpenVPN tunnel (live status first, then the
  /// stored value).
  List<String> discoveredDNS(Tunnel tunnel) {
    final live = _status?.discoveredDNS[tunnel.id];
    if (live != null && live.isNotEmpty) return live;
    return tunnel.kind.openVPN?.discoveredDNS ?? const [];
  }

  // Alerts

  void dismissAlert(AppAlert alert) {
    if (_alerts.remove(alert)) notifyListeners();
  }

  /// Queues an alert for [AlertHost]. Public because the flows that live in
  /// the UI — the file pickers of the tunnel import — report their failures
  /// through the same queue as the model's own.
  void showAlert(AppAlert alert) {
    _alerts.add(alert);
    notifyListeners();
  }

  void _alert(AppAlert alert) => showAlert(alert);

  /// [notifyListeners] for the extensions in the part files.
  void _changed() => notifyListeners();

  /// Where the ✎ on a failed card leads.
  void perform(FailureAction action, Tunnel tunnel) {
    switch (action) {
      case FailureAction.editCredentials:
        _navigate(AppAction.openTunnel(tunnel.id, focus: TunnelField.username));
      case FailureAction.editKeyPassphrase:
        _navigate(
          AppAction.openTunnel(tunnel.id, focus: TunnelField.keyPassphrase),
        );
      case FailureAction.replaceConfig:
        _navigate(
          AppAction.openTunnel(
            tunnel.id,
            focus: tunnel.kind.isOpenVPN ? TunnelField.config : TunnelField.url,
          ),
        );
      case FailureAction.showLog:
        _navigate(AppAction.showLogs(source: 'openvpn:${tunnel.id}'));
      case FailureAction.exportDiagnostics:
        _navigate(const AppAction.exportDiagnostics());
      case FailureAction.repairInstallation:
        _navigate(const AppAction.repairInstallation());
    }
  }

  void _navigate(AppAction action) {
    if (action case AppActionOpenTunnel(:final tunnelID, :final focus)) {
      expandedTunnelID = tunnelID;
      pendingFocus = focus;
      notifyListeners();
    }
    _actions.add(action);
  }

  // Bootstrap

  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    logs.app(LogLevel.info, 'Wayfork $appVersion starting');
    try {
      final result = await _repository.load();
      _store = result.store;
      final backup = result.corruptBackup;
      if (backup != null) {
        logs.app(
          LogLevel.error,
          'store.json was unreadable; backup at ${backup.path}',
        );
        _alert(
          AppAlert(
            title: 'Settings were reset',
            message:
                'Settings file was unreadable and has been reset. A backup '
                'is at ${backup.path}.',
            action: AppAction.revealFile(backup.path),
          ),
        );
      }
    } on StoreRepositoryException catch (error) {
      _persistenceDisabled = true;
      logs.app(
        LogLevel.error,
        'store.json schema ${error.found} is newer than supported '
        '${error.supported}',
      );
      _alert(
        AppAlert(
          title: 'Settings from a newer Wayfork',
          message:
              'The settings file was written by a newer Wayfork (schema '
              '${error.found}; this version supports ${error.supported}). '
              'Wayfork will not modify it; update the app to use these '
              'settings.',
          severity: AlertSeverity.critical,
        ),
      );
    } on Object catch (error) {
      logs.app(LogLevel.error, 'cannot load store: $error');
    }
    try {
      await _secrets.removeOrphans(_store);
    } on Object catch (error) {
      logs.app(LogLevel.warning, 'cannot prune orphaned secrets: $error');
    }
    await recomputeMissingSecrets();
    logs.minimumLevel = _store.settings.logLevel;
    logs.prune(retentionDays: _store.settings.logRetentionDays);
    _scheduleDailyPrune();
    _syncLaunchAtLogin();
    notifyListeners();
    _firstSettled = Completer<void>();
    _client.start();
    if (_client.isConnected && _attaching == null) _attachAsync();
    await _firstSettled!.future.timeout(connectTimeout, onTimeout: () {});
    if (_store.settings.connectOnLaunch && !_desiredOn) {
      await turnOn();
    }
    notifyListeners();
  }

  void _settleFirst() {
    final settled = _firstSettled;
    if (settled != null && !settled.isCompleted) settled.complete();
  }

  void _scheduleDailyPrune() {
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(const Duration(days: 1), (_) {
      logs.prune(retentionDays: _store.settings.logRetentionDays);
    });
  }

  // On / off

  Future<void> toggle() => _desiredOn ? turnOff() : turnOn();

  Future<void> turnOn() async {
    if (_desiredOn || _transition != null) return;
    logs.app(LogLevel.info, 'Turn On requested');
    _cancelRecovery();
    _desiredOn = true;
    _setTransition(AppTransition.starting(since: _now()));
    notifyListeners();
    try {
      await _ensureConnected();
    } on ServiceException catch (error) {
      _turnOnFailed(error.message);
      return;
    } on TimeoutException {
      _turnOnFailed(
        _serviceState.message ?? 'the Wayfork service did not answer in time',
      );
      return;
    }
    if (!_desiredOn) return; // turned off while waiting
    await applyNow();
    _startStartingTimeout();
    notifyListeners();
  }

  void _turnOnFailed(String message) {
    logs.app(LogLevel.error, 'Turn On failed: $message');
    _desiredOn = false;
    _setTransition(null);
    _alert(
      AppAlert(
        title: "Can't reach the Wayfork service",
        message: message,
        action: const AppAction.repairInstallation(),
      ),
    );
    notifyListeners();
  }

  Future<void> turnOff() async {
    logs.app(LogLevel.info, 'Turn Off requested');
    _desiredOn = false;
    _cancelRecovery();
    _applyTimer?.cancel();
    _applyTimer = null;
    _applyAgain = false;
    _startingTimer?.cancel();
    _setTransition(const AppTransition.stopping());
    notifyListeners();
    // An apply already on the wire must land before the stop.
    await _applying;
    if (_client.isConnected) {
      try {
        final result = await _client.stopEngine();
        final error = result.error;
        if (!result.ok && error != null) {
          logs.app(
            LogLevel.error,
            'stop failed: ${describeDaemonError(error)}',
          );
        }
        _status = await _client.getStatus();
      } on Object catch (error) {
        logs.app(LogLevel.error, 'stop failed: ${_describe(error)}');
        _status = null;
      }
    } else {
      _status = null;
    }
    _clearTraffic();
    _setTransition(null);
    notifyListeners();
  }

  /// Quit: stop everything, flush the store, close the pipe.
  Future<void> shutdown() async {
    _shuttingDown = true;
    if (_desiredOn || _status?.engine.isRunning == true) {
      await turnOff();
    }
    if (!_persistenceDisabled) {
      try {
        await _repository.flush();
      } on Object catch (error) {
        logs.app(LogLevel.error, 'cannot save store: $error');
      }
    }
    await _client.stop();
  }

  Future<void> reconnect(String tunnelID) async {
    if (!_client.isConnected) return;
    logs.app(
      LogLevel.info,
      'reconnect requested for ${_store.tunnel(tunnelID)?.name ?? '?'}',
    );
    try {
      final result = await _client.reconnect(tunnelID);
      final error = result.error;
      if (!result.ok && error != null) {
        logs.app(LogLevel.warning, 'reconnect: ${describeDaemonError(error)}');
      }
    } on Object catch (error) {
      logs.app(LogLevel.error, 'reconnect failed: ${_describe(error)}');
    }
  }

  /// Restarts every enabled OpenVPN tunnel (the tray's "Reconnect · All
  /// Tunnels"); VLESS has no process of its own to restart.
  Future<void> reconnectAll() async {
    for (final tunnel in _store.tunnels) {
      if (!tunnel.isEnabled || !tunnel.kind.isOpenVPN) continue;
      await reconnect(tunnel.id);
    }
  }

  void _setTransition(AppTransition? transition) {
    _transition = transition;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _iconPulse = false;
    if (transition == null) return;
    _pulseTimer = Timer.periodic(pulseInterval, (_) {
      _iconPulse = !_iconPulse;
      notifyListeners();
    });
  }

  void _startStartingTimeout() {
    _startingTimer?.cancel();
    _startingTimer = Timer(startingTimeout, () {
      if (_transition is AppTransitionStarting) {
        _setTransition(null);
        notifyListeners();
      }
    });
  }

  // Service connection

  void _onClientState(ServiceClientState state) {
    final wasAttached = _serviceInfo != null;
    _serviceState = state;
    switch (state.phase) {
      case ServiceClientPhase.connected:
        _everConnected = true;
        _lastServiceProblem = null;
        _attachAsync();
      case ServiceClientPhase.connecting:
        break;
      case ServiceClientPhase.serviceMissing:
      case ServiceClientPhase.versionMismatch:
      case ServiceClientPhase.disconnected:
        if (wasAttached && !_shuttingDown) {
          _logServiceProblem(
            'service connection lost: ${state.message ?? state.phase.name}',
          );
        } else if (state.phase != ServiceClientPhase.disconnected) {
          _logServiceProblem(state.message ?? state.phase.name);
        }
        _serviceInfo = null;
        _status = null;
        _clearTraffic();
        _settleFirst();
    }
    notifyListeners();
  }

  /// The client re-dials every few seconds, so the same "pipe is not there"
  /// would fill the log while the service is still coming up. One line per
  /// problem is enough; the next different one, or the reconnect, starts a new
  /// streak.
  void _logServiceProblem(String message) {
    if (message == _lastServiceProblem) return;
    _lastServiceProblem = message;
    logs.app(LogLevel.warning, message);
  }

  void _attachAsync() {
    if (_attaching != null) return;
    final attach = _attach();
    _attaching = attach;
    attach.whenComplete(() {
      if (identical(_attaching, attach)) _attaching = null;
    });
  }

  /// After every successful hello: mirror the service, then re-apply when
  /// it does not run the plan we expect.
  Future<void> _attach() async {
    final DaemonInfo info;
    final RuntimeStatus status;
    try {
      info = await _client.getInfo();
      status = await _client.getStatus();
    } on Object catch (error) {
      logs.app(
        LogLevel.warning,
        'service handshake failed: ${_describe(error)}',
      );
      _settleFirst();
      return;
    }
    if (!_client.isConnected) {
      _settleFirst();
      return;
    }
    _serviceInfo = info;
    logs.app(
      LogLevel.info,
      'service ${info.version} connected at ${info.installPath} '
      '(sing-box ${info.singBoxVersion}, openvpn ${info.openVPNVersion})',
    );
    if (info.version != appVersion) {
      logs.app(
        LogLevel.warning,
        'service version ${info.version} differs from app $appVersion',
      );
    }
    _handleStatus(status);
    final engine = status.engine;
    final running =
        engine is EngineStateRunning || engine is EngineStateStarting;
    if (!_attachedOnce) {
      // App (re)launch while the service may still be routing: mirror it.
      _attachedOnce = true;
      if (running && !_desiredOn) {
        _desiredOn = true;
        logs.app(LogLevel.info, 'reattached to a running service');
      }
    }
    if (_desiredOn) {
      final expected = _lastPlan?.planHash;
      if (!running) {
        logs.app(LogLevel.info, 'service is idle; applying the current plan');
        await applyNow();
      } else if (expected != null && status.planHash != expected) {
        logs.app(
          LogLevel.info,
          'service runs plan ${_short(status.planHash)}, expected '
          '${_short(expected)}; re-applying',
        );
        await applyNow();
      } else if (expected != null) {
        logs.app(
          LogLevel.debug,
          'service already runs plan ${_short(expected)}',
        );
      }
    }
    _settleFirst();
    notifyListeners();
  }

  /// Waits for the connection and the handshake; throws [ServiceException]
  /// when the service is missing or incompatible, [TimeoutException] after
  /// [connectTimeout].
  Future<void> _ensureConnected() async {
    if (!_client.isConnected) {
      _client.retryNow();
      await _client.states
          .firstWhere((state) {
            switch (state.phase) {
              case ServiceClientPhase.connected:
                return true;
              case ServiceClientPhase.serviceMissing:
              case ServiceClientPhase.versionMismatch:
                throw ServiceException(
                  ServiceErrorKind.notConnected,
                  state.message ?? state.phase.name,
                );
              case ServiceClientPhase.connecting:
              case ServiceClientPhase.disconnected:
                return false;
            }
          })
          .timeout(connectTimeout);
    }
    final attaching = _attaching;
    if (attaching != null) await attaching.timeout(connectTimeout);
    if (!_client.isConnected) {
      throw ServiceException(
        ServiceErrorKind.notConnected,
        _serviceState.message ?? 'not connected to the Wayfork service',
      );
    }
  }

  // Status

  void _handleStatus(RuntimeStatus status) {
    final old = _status;
    _status = status;
    _syncDiscoveredDNS(status);
    if (status.resolverOverride != old?.resolverOverride) {
      _logResolverOverride(status.resolverOverride, old?.resolverOverride);
    }
    if (!status.engine.isRunning) _clearTraffic();
    if (_transition is AppTransitionStarting &&
        globalState != const GlobalState.starting()) {
      _startingTimer?.cancel();
      _setTransition(null);
    }
    if (_desiredOn &&
        _transition == null &&
        status.engine is EngineStateStopped &&
        old != null &&
        old.engine is! EngineStateStopped) {
      // The service stopped on its own (restart after crash): reflect it.
      logs.app(LogLevel.warning, 'service reports stopped');
    }
    for (final MapEntry(key: id, value: state) in status.tunnels.entries) {
      if (state is! TunnelStateFailed || !state.permanent) continue;
      if (old?.tunnels[id] == state) continue;
      final name = _store.tunnel(id)?.name ?? id;
      logs.app(LogLevel.error, 'tunnel $name failed: ${state.reason}');
      _notify(
        id: 'tunnel-$id',
        title: '$name failed',
        body: StatusText.failureMessage(state.reason),
      );
    }
    final engine = status.engine;
    if (engine.isRunning && old?.engine.isRunning != true) _cancelRecovery();
    if (engine is EngineStateFailed && old?.engine != engine) {
      logs.app(LogLevel.error, 'routing engine failed: ${engine.reason}');
      _handleEngineFailure(engine.reason);
    }
    notifyListeners();
  }

  // Engine failure recovery (H2)

  /// The engine is down for good as far as the service is concerned: say so
  /// once, then keep re-applying with backoff while the user wants routing on
  /// (docs/design/05-daemon.md, "Engine failure recovery").
  void _handleEngineFailure(String reason) {
    final message = StatusText.failureMessage(reason);
    if (!_recovery.isRecovering) {
      _notify(
        id: 'engine',
        title: 'Routing engine failed',
        body: _desiredOn ? '$message Wayfork keeps retrying.' : message,
      );
    }
    if (!_desiredOn || _recoveryTimer != null) return;
    _scheduleRecovery();
  }

  void _scheduleRecovery() {
    final delay = _recovery.nextDelay();
    logs.app(
      LogLevel.info,
      'routing engine down; re-applying in ${delay.inSeconds} s',
    );
    _recoveryTimer = Timer(delay, () async {
      _recoveryTimer = null;
      if (!_desiredOn || _status?.engine.isRunning == true) return;
      _autoRecovering = true;
      try {
        await applyNow();
      } finally {
        _autoRecovering = false;
      }
      // The service pushes a new `failed` only when it got as far as starting
      // sing-box, so the next attempt is armed from here either way.
      if (_desiredOn &&
          _recoveryTimer == null &&
          _status?.engine.isRunning != true) {
        _scheduleRecovery();
      }
    });
  }

  /// Stops the retries and clears the streak: the engine is up, or the user
  /// took over.
  void _cancelRecovery() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recovery.reset();
  }

  void _handleLogLines(List<LogLine> lines) {
    logs.receive(lines);
    for (final line in lines) {
      if (line.source == _singBoxSource) fakeIPs.ingest(line.message);
    }
  }

  // Traffic (F9)

  void _handleTraffic(TrafficSnapshot snapshot) {
    if (!_desiredOn || _status?.engine.isRunning != true) return;
    _traffic = snapshot;
    _trafficStaleTimer?.cancel();
    _trafficStaleTimer = Timer(trafficStaleAfter, () {
      _traffic = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void _clearTraffic() {
    _trafficStaleTimer?.cancel();
    _trafficStaleTimer = null;
    _traffic = null;
  }

  /// F12: the service's hold on the system resolver, as it changes.
  void _logResolverOverride(
    ResolverOverrideState state,
    ResolverOverrideState? previous,
  ) {
    switch (state) {
      case ResolverOverrideOff():
        if (previous != null && previous is! ResolverOverrideOff) {
          logs.app(LogLevel.info, 'system resolver restored');
        }
      case ResolverOverrideActive(:final service):
        logs.app(
          LogLevel.info,
          'system resolver is Wayfork '
          '(${SingBoxConfigGenerator.resolverAddress}) via $service',
        );
      case ResolverOverrideShadowed(:final manual):
        logs.app(
          LogLevel.warning,
          'manual DNS ${manual.join(', ')} shadows Wayfork\'s resolver: '
          'clear it so that every app is routed by domain',
        );
      case ResolverOverrideFailed(:final reason):
        logs.app(LogLevel.warning, 'system resolver override failed: $reason');
    }
  }

  void _syncDiscoveredDNS(RuntimeStatus status) {
    for (final MapEntry(key: id, value: servers)
        in status.discoveredDNS.entries) {
      final tunnel = _store.tunnel(id);
      final meta = tunnel?.kind.openVPN;
      if (tunnel == null || meta == null) continue;
      if (const ListEquality<String>().equals(meta.discoveredDNS, servers)) {
        continue;
      }
      logs.app(
        LogLevel.info,
        '${tunnel.name} pushed DNS ${servers.join(', ')}',
      );
      unawaited(
        update(
          (store) => store.copyWith(
            tunnels: [
              for (final t in store.tunnels)
                if (t.id == tunnel.id)
                  t.copyWith(
                    kind: TunnelKindOpenVPN(
                      _copyMeta(meta, discoveredDNS: servers),
                    ),
                  )
                else
                  t,
            ],
          ),
        ),
      );
    }
  }

  void _notify({
    required String id,
    required String title,
    required String body,
  }) {
    if (!_store.settings.notifyOnTunnelFailure) return;
    unawaited(_notifier.post(id: id, title: title, body: body));
  }

  // Store changes and apply

  /// Every store mutation goes through here: persist (debounced) and
  /// re-apply while on.
  Future<void> update(Store Function(Store store) mutate) async {
    final changed = mutate(_store);
    if (changed == _store) return;
    final tunnelsChanged = !const ListEquality<Tunnel>().equals(
      changed.tunnels,
      _store.tunnels,
    );
    _store = changed;
    if (!_persistenceDisabled) _repository.save(changed);
    if (tunnelsChanged) await recomputeMissingSecrets();
    logs.minimumLevel = changed.settings.logLevel;
    secretsChanged();
    notifyListeners();
  }

  /// Call after secret writes too: they change the plan without touching the
  /// store.
  void secretsChanged() {
    if (!_desiredOn) return;
    _scheduleApply();
  }

  /// The TUN address while the service is asked to be the system resolver
  /// (F12).
  String? get _resolverOverrideAddress => _store.settings.overrideSystemDNS
      ? SingBoxConfigGenerator.resolverAddress
      : null;

  /// Re-applies when the system resolvers or the default gateway changed: the
  /// resolvers are routed into the TUN (docs/design/03-routing.md). Called by
  /// the network-change stream; harmless when nothing changed.
  void systemDNSChanged() {
    if (!_desiredOn) return;
    final snapshot = _systemDns();
    final override = _resolverOverrideAddress;
    final applied = _appliedSystemDNS;
    if (applied != null &&
        const ListEquality<String>().equals(
          snapshot.effectiveServers(override),
          applied.effectiveServers(override),
        ) &&
        snapshot.router == applied.router) {
      return;
    }
    logs.app(
      LogLevel.info,
      'system DNS changed: ${snapshot.effectiveServers(override).join(', ')} '
      '(gateway ${snapshot.router ?? 'none'})',
    );
    _scheduleApply();
  }

  void _scheduleApply() {
    _applyTimer?.cancel();
    _applyTimer = Timer(applyDebounce, () {
      _applyTimer = null;
      unawaited(applyNow());
    });
  }

  /// Store → plan → `apply` (docs/design/00-architecture.md, "Runtime plan").
  /// Applies are serialised; a call during an apply queues one more run.
  Future<void> applyNow() {
    _applyTimer?.cancel();
    _applyTimer = null;
    final running = _applying;
    if (running != null) {
      _applyAgain = true;
      return running;
    }
    final done = Completer<void>();
    _applying = done.future;
    unawaited(
      _runApplies().whenComplete(() {
        _applying = null;
        done.complete();
      }),
    );
    return done.future;
  }

  Future<void> _runApplies() async {
    do {
      _applyAgain = false;
      await _apply();
    } while (_applyAgain);
  }

  Future<void> _apply() async {
    if (!_desiredOn || !_client.isConnected) return;
    final PlanSecrets planSecrets;
    try {
      planSecrets = await PlanSecrets.load(_store, _secrets);
    } on Object catch (error) {
      logs.app(LogLevel.error, 'cannot read secrets: $error');
      _alert(
        AppAlert(
          title: 'Secrets error',
          message: 'Cannot read tunnel secrets: $error',
        ),
      );
      return;
    }
    final hosts = HostResolver.openVPNHosts(_store);
    final resolved = await _resolveHosts(hosts);
    for (final host in hosts) {
      if (resolved[host] == null) {
        logs.app(
          LogLevel.warning,
          'cannot resolve $host: its OpenVPN server is matched by name only',
        );
      }
    }
    final systemDNS = _systemDns();
    final override = _resolverOverrideAddress;
    _appliedSystemDNS = systemDNS;
    for (final resolver in systemDNS.unroutable(overrideAddress: override)) {
      logs.app(
        LogLevel.warning,
        'system resolver $resolver is the default gateway and cannot be '
        'routed into the TUN: its queries bypass hijack-dns, domain rules '
        'rely on sniffing',
      );
    }
    final result = RuntimePlanBuilder.build(
      store: _store,
      secrets: planSecrets,
      installDir: installDir,
      resolvedServerAddresses: resolved,
      systemDNSServers: systemDNS.routable(overrideAddress: override),
      networkResolvers: systemDNS.networkServers,
    );
    for (final warning in result.warnings) {
      if (warning case PlanWarningMissingSecret(:final tunnelID)) {
        logs.app(
          LogLevel.warning,
          '${_store.tunnel(tunnelID)?.name ?? '?'} skipped: secret missing',
        );
      }
    }
    _lastPlan = result.plan;
    final openVPN = result.plan.openVPN.length;
    final vless = result.routedTunnels.length - openVPN;
    final effective = systemDNS.effectiveServers(override);
    logs.app(
      LogLevel.info,
      'apply: plan ${_short(result.plan.planHash)} ($openVPN openvpn, '
      '$vless vless, ${StatusText.activeRuleCount(_store)} rules; system '
      'dns ${effective.isEmpty ? 'none' : effective.join(' ')}, gateway '
      '${systemDNS.router ?? 'none'})',
    );
    if (!_desiredOn || !_client.isConnected) return;
    try {
      final reply = await _client.apply(result.plan);
      final error = reply.error;
      if (!reply.ok && error != null) _handleApplyError(error);
    } on ServiceException catch (error) {
      logs.app(LogLevel.error, 'apply failed: ${error.message}');
      if (error.kind != ServiceErrorKind.notConnected) {
        _alert(
          AppAlert(
            title: "Can't reach the Wayfork service",
            message: error.message,
            action: const AppAction.repairInstallation(),
          ),
        );
      }
    }
    notifyListeners();
  }

  void _handleApplyError(DaemonError error) {
    logs.app(LogLevel.error, 'apply rejected: ${describeDaemonError(error)}');
    switch (error) {
      case DaemonErrorConfigInvalid(:final output):
        final first = output
            .split('\n')
            .firstWhere(
              (line) => line.isNotEmpty,
              orElse: () => 'unknown error',
            );
        _alert(
          AppAlert(
            title: 'Routing config rejected',
            message:
                'Routing config rejected: $first\n\nThis should not happen '
                'with generated configs; please export diagnostics and '
                'report it.',
            action: const AppAction.exportDiagnostics(),
          ),
        );
      case DaemonErrorStartFailed():
        // An automatic retry (H2) reports through the tray, the log and the one
        // notification of the streak; only the user's own apply gets an alert.
        if (_autoRecovering) break;
        _alert(
          const AppAlert(
            title: 'Routing engine failed to start',
            message:
                'Routing engine failed to start. Another VPN may be active.',
            action: AppAction.showLogs(source: _singBoxSource),
          ),
        );
      case DaemonErrorBinaryUntrusted(:final path):
        _alert(
          AppAlert(
            title: 'Bundled binary rejected',
            message:
                'The service refused to run $path: signature validation '
                'failed.',
            severity: AlertSeverity.critical,
            action: const AppAction.repairInstallation(),
          ),
        );
      case DaemonErrorPlanInvalid(:final reason):
        _alert(AppAlert(title: 'Plan rejected', message: reason));
      case DaemonErrorTunnelNotFound() ||
          DaemonErrorNotRunning() ||
          DaemonErrorInternal():
        _alert(
          AppAlert(title: 'Service error', message: describeDaemonError(error)),
        );
    }
  }

  // Secrets bookkeeping

  Future<void> recomputeMissingSecrets() async {
    final missing = <String>{};
    for (final tunnel in _store.tunnels) {
      final key = SecretKey(
        tunnel.kind.isOpenVPN ? SecretKind.ovpn : SecretKind.uuid,
        tunnel.id,
      );
      String? value;
      try {
        value = await _secrets.read(key);
      } on Object {
        value = null;
      }
      if (value == null) missing.add(tunnel.id);
    }
    if (const SetEquality<String>().equals(missing, _missingSecrets)) return;
    _missingSecrets = Set.unmodifiable(missing);
    notifyListeners();
  }

  // Settings

  Future<void> updateSettings(
    Settings Function(Settings settings) mutate,
  ) async {
    final before = _store.settings;
    await update((store) => store.copyWith(settings: mutate(store.settings)));
    final after = _store.settings;
    if (before.launchAtLogin != after.launchAtLogin) {
      try {
        _launchAtLogin.setEnabled(after.launchAtLogin);
      } on Object catch (error) {
        logs.app(LogLevel.error, 'launch at login: $error');
        _alert(AppAlert(title: 'Launch at login', message: '$error'));
        final actual = _launchAtLogin.isEnabled;
        await update(
          (store) => store.copyWith(
            settings: store.settings.copyWith(launchAtLogin: actual),
          ),
        );
      }
    }
    if (before.logRetentionDays != after.logRetentionDays) {
      logs.prune(retentionDays: after.logRetentionDays);
    }
  }

  void _syncLaunchAtLogin() {
    final actual = _launchAtLogin.isEnabled;
    if (_store.settings.launchAtLogin != actual) {
      unawaited(
        update(
          (store) => store.copyWith(
            settings: store.settings.copyWith(launchAtLogin: actual),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _applyTimer?.cancel();
    _startingTimer?.cancel();
    _recoveryTimer?.cancel();
    _pulseTimer?.cancel();
    _pruneTimer?.cancel();
    _trafficStaleTimer?.cancel();
    unawaited(_actions.close());
    super.dispose();
  }

  static String _short(String? hash) => hash == null
      ? 'none'
      : hash.substring(0, hash.length < 8 ? hash.length : 8);

  static String _describe(Object error) => switch (error) {
    ServiceException(:final message) => message,
    _ => '$error',
  };

  static OpenVPNMeta _copyMeta(
    OpenVPNMeta meta, {
    TunnelDNS? dns,
    List<String>? discoveredDNS,
  }) => OpenVPNMeta(
    remotes: meta.remotes,
    needsCredentials: meta.needsCredentials,
    needsKeyPassphrase: meta.needsKeyPassphrase,
    dns: dns ?? meta.dns,
    discoveredDNS: discoveredDNS ?? meta.discoveredDNS,
    configHash: meta.configHash,
  );
}
