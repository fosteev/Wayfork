import 'package:collection/collection.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/settings.dart';

final class DaemonInfo {
  const DaemonInfo({
    required this.version,
    required this.installPath,
    this.buildID,
    required this.singBoxVersion,
    required this.openVPNVersion,
  });

  factory DaemonInfo.fromJson(Map<String, Object?> json) => DaemonInfo(
    version: _string(json, 'version'),
    installPath: _string(json, 'installPath'),
    buildID: _optionalString(json, 'buildID'),
    singBoxVersion: _string(json, 'singBoxVersion'),
    openVPNVersion: _string(json, 'openVPNVersion'),
  );

  final String version;
  final String installPath;
  final String? buildID;
  final String singBoxVersion;
  final String openVPNVersion;

  Map<String, Object?> toJson() => {
    'version': version,
    'installPath': installPath,
    if (buildID != null) 'buildID': buildID,
    'singBoxVersion': singBoxVersion,
    'openVPNVersion': openVPNVersion,
  };

  @override
  bool operator ==(Object other) =>
      other is DaemonInfo &&
      version == other.version &&
      installPath == other.installPath &&
      buildID == other.buildID &&
      singBoxVersion == other.singBoxVersion &&
      openVPNVersion == other.openVPNVersion;

  @override
  int get hashCode => Object.hash(
    version,
    installPath,
    buildID,
    singBoxVersion,
    openVPNVersion,
  );
}

sealed class EngineState {
  const EngineState();

  const factory EngineState.stopped() = EngineStateStopped;
  const factory EngineState.starting() = EngineStateStarting;
  const factory EngineState.running({required DateTime since}) =
      EngineStateRunning;
  const factory EngineState.failed({required String reason}) =
      EngineStateFailed;

  bool get isRunning => this is EngineStateRunning;
  Map<String, Object?> toJson();

  static EngineState fromJson(Map<String, Object?> json) {
    if (json.containsKey('stopped')) return const EngineStateStopped();
    if (json.containsKey('starting')) return const EngineStateStarting();
    if (json['running'] case final Map<String, Object?> value) {
      return EngineStateRunning(since: _date(value, 'since'));
    }
    if (json['failed'] case final Map<String, Object?> value) {
      return EngineStateFailed(reason: _string(value, 'reason'));
    }
    throw const FormatException('Unknown engine state');
  }
}

final class EngineStateStopped extends EngineState {
  const EngineStateStopped();
  @override
  Map<String, Object?> toJson() => {'stopped': <String, Object?>{}};
  @override
  bool operator ==(Object other) => other is EngineStateStopped;
  @override
  int get hashCode => 0;
}

final class EngineStateStarting extends EngineState {
  const EngineStateStarting();
  @override
  Map<String, Object?> toJson() => {'starting': <String, Object?>{}};
  @override
  bool operator ==(Object other) => other is EngineStateStarting;
  @override
  int get hashCode => 1;
}

final class EngineStateRunning extends EngineState {
  const EngineStateRunning({required this.since});
  final DateTime since;
  @override
  Map<String, Object?> toJson() => {
    'running': <String, Object?>{'since': JsonCoding.encodeDate(since)},
  };
  @override
  bool operator ==(Object other) =>
      other is EngineStateRunning && since == other.since;
  @override
  int get hashCode => since.hashCode;
}

final class EngineStateFailed extends EngineState {
  const EngineStateFailed({required this.reason});
  final String reason;
  @override
  Map<String, Object?> toJson() => {
    'failed': <String, Object?>{'reason': reason},
  };
  @override
  bool operator ==(Object other) =>
      other is EngineStateFailed && reason == other.reason;
  @override
  int get hashCode => reason.hashCode;
}

sealed class TunnelState {
  const TunnelState();

  const factory TunnelState.disabled() = TunnelStateDisabled;
  const factory TunnelState.connecting({required int attempt}) =
      TunnelStateConnecting;
  const factory TunnelState.connected({
    required DateTime since,
    String? ip,
    required String interface,
  }) = TunnelStateConnected;
  const factory TunnelState.reconnecting({
    required int attempt,
    required double nextIn,
    String? reason,
  }) = TunnelStateReconnecting;
  const factory TunnelState.failed({
    required String reason,
    required bool permanent,
  }) = TunnelStateFailed;

  bool get isConnected => this is TunnelStateConnected;
  Map<String, Object?> toJson();

  static TunnelState fromJson(Map<String, Object?> json) {
    if (json.containsKey('disabled')) return const TunnelStateDisabled();
    if (json['connecting'] case final Map<String, Object?> value) {
      return TunnelStateConnecting(attempt: _int(value, 'attempt'));
    }
    if (json['connected'] case final Map<String, Object?> value) {
      return TunnelStateConnected(
        since: _date(value, 'since'),
        ip: _optionalString(value, 'ip'),
        interface: _string(value, 'interface'),
      );
    }
    if (json['reconnecting'] case final Map<String, Object?> value) {
      return TunnelStateReconnecting(
        attempt: _int(value, 'attempt'),
        nextIn: _double(value, 'nextIn'),
        reason: _optionalString(value, 'reason'),
      );
    }
    if (json['failed'] case final Map<String, Object?> value) {
      return TunnelStateFailed(
        reason: _string(value, 'reason'),
        permanent: _bool(value, 'permanent'),
      );
    }
    throw const FormatException('Unknown tunnel state');
  }
}

final class TunnelStateDisabled extends TunnelState {
  const TunnelStateDisabled();
  @override
  Map<String, Object?> toJson() => {'disabled': <String, Object?>{}};
  @override
  bool operator ==(Object other) => other is TunnelStateDisabled;
  @override
  int get hashCode => 0;
}

final class TunnelStateConnecting extends TunnelState {
  const TunnelStateConnecting({required this.attempt});
  final int attempt;
  @override
  Map<String, Object?> toJson() => {
    'connecting': <String, Object?>{'attempt': attempt},
  };
  @override
  bool operator ==(Object other) =>
      other is TunnelStateConnecting && attempt == other.attempt;
  @override
  int get hashCode => attempt.hashCode;
}

final class TunnelStateConnected extends TunnelState {
  const TunnelStateConnected({
    required this.since,
    this.ip,
    required this.interface,
  });
  final DateTime since;
  final String? ip;
  final String interface;
  @override
  Map<String, Object?> toJson() => {
    'connected': <String, Object?>{
      'since': JsonCoding.encodeDate(since),
      if (ip != null) 'ip': ip,
      'interface': interface,
    },
  };
  @override
  bool operator ==(Object other) =>
      other is TunnelStateConnected &&
      since == other.since &&
      ip == other.ip &&
      interface == other.interface;
  @override
  int get hashCode => Object.hash(since, ip, interface);
}

final class TunnelStateReconnecting extends TunnelState {
  const TunnelStateReconnecting({
    required this.attempt,
    required this.nextIn,
    this.reason,
  });
  final int attempt;
  final double nextIn;
  final String? reason;
  @override
  Map<String, Object?> toJson() => {
    'reconnecting': <String, Object?>{
      'attempt': attempt,
      'nextIn': nextIn,
      if (reason != null) 'reason': reason,
    },
  };
  @override
  bool operator ==(Object other) =>
      other is TunnelStateReconnecting &&
      attempt == other.attempt &&
      nextIn == other.nextIn &&
      reason == other.reason;
  @override
  int get hashCode => Object.hash(attempt, nextIn, reason);
}

final class TunnelStateFailed extends TunnelState {
  const TunnelStateFailed({required this.reason, required this.permanent});
  final String reason;
  final bool permanent;
  @override
  Map<String, Object?> toJson() => {
    'failed': <String, Object?>{'reason': reason, 'permanent': permanent},
  };
  @override
  bool operator ==(Object other) =>
      other is TunnelStateFailed &&
      reason == other.reason &&
      permanent == other.permanent;
  @override
  int get hashCode => Object.hash(reason, permanent);
}

sealed class ResolverOverrideState {
  const ResolverOverrideState();

  const factory ResolverOverrideState.off() = ResolverOverrideOff;
  const factory ResolverOverrideState.active({required String service}) =
      ResolverOverrideActive;
  factory ResolverOverrideState.shadowed({required List<String> manual}) =
      ResolverOverrideShadowed;
  const factory ResolverOverrideState.failed({required String reason}) =
      ResolverOverrideFailed;

  Map<String, Object?> toJson();

  static ResolverOverrideState fromJson(Map<String, Object?> json) {
    if (json.containsKey('off')) return const ResolverOverrideOff();
    if (json['active'] case final Map<String, Object?> value) {
      return ResolverOverrideActive(service: _string(value, 'service'));
    }
    if (json['shadowed'] case final Map<String, Object?> value) {
      return ResolverOverrideShadowed(
        manual: _list(
          value,
          'manual',
        ).map((item) => _stringValue(item, 'manual DNS')).toList(),
      );
    }
    if (json['failed'] case final Map<String, Object?> value) {
      return ResolverOverrideFailed(reason: _string(value, 'reason'));
    }
    throw const FormatException('Unknown resolver override state');
  }
}

final class ResolverOverrideOff extends ResolverOverrideState {
  const ResolverOverrideOff();
  @override
  Map<String, Object?> toJson() => {'off': <String, Object?>{}};
  @override
  bool operator ==(Object other) => other is ResolverOverrideOff;
  @override
  int get hashCode => 0;
}

final class ResolverOverrideActive extends ResolverOverrideState {
  const ResolverOverrideActive({required this.service});
  final String service;
  @override
  Map<String, Object?> toJson() => {
    'active': <String, Object?>{'service': service},
  };
  @override
  bool operator ==(Object other) =>
      other is ResolverOverrideActive && service == other.service;
  @override
  int get hashCode => service.hashCode;
}

final class ResolverOverrideShadowed extends ResolverOverrideState {
  ResolverOverrideShadowed({required List<String> manual})
    : manual = List.unmodifiable(manual);
  final List<String> manual;
  @override
  Map<String, Object?> toJson() => {
    'shadowed': <String, Object?>{'manual': manual},
  };
  @override
  bool operator ==(Object other) =>
      other is ResolverOverrideShadowed &&
      const ListEquality<String>().equals(manual, other.manual);
  @override
  int get hashCode => const ListEquality<String>().hash(manual);
}

final class ResolverOverrideFailed extends ResolverOverrideState {
  const ResolverOverrideFailed({required this.reason});
  final String reason;
  @override
  Map<String, Object?> toJson() => {
    'failed': <String, Object?>{'reason': reason},
  };
  @override
  bool operator ==(Object other) =>
      other is ResolverOverrideFailed && reason == other.reason;
  @override
  int get hashCode => reason.hashCode;
}

sealed class DaemonError implements Exception {
  const DaemonError();

  const factory DaemonError.binaryUntrusted({required String path}) =
      DaemonErrorBinaryUntrusted;
  const factory DaemonError.planInvalid({required String reason}) =
      DaemonErrorPlanInvalid;
  const factory DaemonError.configInvalid({required String output}) =
      DaemonErrorConfigInvalid;
  factory DaemonError.startFailed({required List<String> logTail}) =
      DaemonErrorStartFailed;
  const factory DaemonError.tunnelNotFound({required String id}) =
      DaemonErrorTunnelNotFound;
  const factory DaemonError.notRunning() = DaemonErrorNotRunning;
  const factory DaemonError.internalError({required String message}) =
      DaemonErrorInternal;

  Map<String, Object?> toJson();

  static DaemonError fromJson(Map<String, Object?> json) {
    Map<String, Object?> payload(String key) => _map(json[key], key);
    if (json.containsKey('binaryUntrusted')) {
      return DaemonErrorBinaryUntrusted(
        path: _string(payload('binaryUntrusted'), 'path'),
      );
    }
    if (json.containsKey('planInvalid')) {
      return DaemonErrorPlanInvalid(
        reason: _string(payload('planInvalid'), 'reason'),
      );
    }
    if (json.containsKey('configInvalid')) {
      return DaemonErrorConfigInvalid(
        output: _string(payload('configInvalid'), 'output'),
      );
    }
    if (json.containsKey('startFailed')) {
      return DaemonErrorStartFailed(
        logTail: _list(
          payload('startFailed'),
          'logTail',
        ).map((item) => _stringValue(item, 'log line')).toList(),
      );
    }
    if (json.containsKey('tunnelNotFound')) {
      return DaemonErrorTunnelNotFound(
        id: _string(payload('tunnelNotFound'), 'id'),
      );
    }
    if (json.containsKey('notRunning')) return const DaemonErrorNotRunning();
    if (json.containsKey('internalError')) {
      return DaemonErrorInternal(
        message: _string(payload('internalError'), 'message'),
      );
    }
    throw const FormatException('Unknown daemon error');
  }
}

final class DaemonErrorBinaryUntrusted extends DaemonError {
  const DaemonErrorBinaryUntrusted({required this.path});
  final String path;
  @override
  Map<String, Object?> toJson() => {
    'binaryUntrusted': {'path': path},
  };
  @override
  bool operator ==(Object other) =>
      other is DaemonErrorBinaryUntrusted && path == other.path;
  @override
  int get hashCode => path.hashCode;
}

final class DaemonErrorPlanInvalid extends DaemonError {
  const DaemonErrorPlanInvalid({required this.reason});
  final String reason;
  @override
  Map<String, Object?> toJson() => {
    'planInvalid': {'reason': reason},
  };
  @override
  bool operator ==(Object other) =>
      other is DaemonErrorPlanInvalid && reason == other.reason;
  @override
  int get hashCode => reason.hashCode;
}

final class DaemonErrorConfigInvalid extends DaemonError {
  const DaemonErrorConfigInvalid({required this.output});
  final String output;
  @override
  Map<String, Object?> toJson() => {
    'configInvalid': {'output': output},
  };
  @override
  bool operator ==(Object other) =>
      other is DaemonErrorConfigInvalid && output == other.output;
  @override
  int get hashCode => output.hashCode;
}

final class DaemonErrorStartFailed extends DaemonError {
  DaemonErrorStartFailed({required List<String> logTail})
    : logTail = List.unmodifiable(logTail);
  final List<String> logTail;
  @override
  Map<String, Object?> toJson() => {
    'startFailed': {'logTail': logTail},
  };
  @override
  bool operator ==(Object other) =>
      other is DaemonErrorStartFailed &&
      const ListEquality<String>().equals(logTail, other.logTail);
  @override
  int get hashCode => const ListEquality<String>().hash(logTail);
}

final class DaemonErrorTunnelNotFound extends DaemonError {
  const DaemonErrorTunnelNotFound({required this.id});
  final String id;
  @override
  Map<String, Object?> toJson() => {
    'tunnelNotFound': {'id': id},
  };
  @override
  bool operator ==(Object other) =>
      other is DaemonErrorTunnelNotFound && id == other.id;
  @override
  int get hashCode => id.hashCode;
}

final class DaemonErrorNotRunning extends DaemonError {
  const DaemonErrorNotRunning();
  @override
  Map<String, Object?> toJson() => {'notRunning': <String, Object?>{}};
  @override
  bool operator ==(Object other) => other is DaemonErrorNotRunning;
  @override
  int get hashCode => 0;
}

final class DaemonErrorInternal extends DaemonError {
  const DaemonErrorInternal({required this.message});
  final String message;
  @override
  Map<String, Object?> toJson() => {
    'internalError': {'message': message},
  };
  @override
  bool operator ==(Object other) =>
      other is DaemonErrorInternal && message == other.message;
  @override
  int get hashCode => message.hashCode;
}

final class RuntimeStatus {
  RuntimeStatus({
    this.engine = const EngineStateStopped(),
    Map<String, TunnelState> tunnels = const {},
    this.planHash,
    Map<String, List<String>> discoveredDNS = const {},
    this.resolverOverride = const ResolverOverrideOff(),
  }) : tunnels = Map.unmodifiable(tunnels),
       discoveredDNS = Map.unmodifiable(
         discoveredDNS.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       );

  factory RuntimeStatus.fromJson(Map<String, Object?> json) => RuntimeStatus(
    engine: EngineState.fromJson(_map(json['engine'], 'engine')),
    tunnels: _objectMap(json['tunnels'], 'tunnels').map(
      (key, value) =>
          MapEntry(key, TunnelState.fromJson(_map(value, 'tunnel state'))),
    ),
    planHash: _optionalString(json, 'planHash'),
    discoveredDNS: json['discoveredDNS'] == null
        ? const {}
        : _objectMap(json['discoveredDNS'], 'discoveredDNS').map(
            (key, value) => MapEntry(
              key,
              _listValue(
                value,
                'DNS servers',
              ).map((item) => _stringValue(item, 'DNS server')).toList(),
            ),
          ),
    resolverOverride: json['resolverOverride'] == null
        ? const ResolverOverrideOff()
        : ResolverOverrideState.fromJson(
            _map(json['resolverOverride'], 'resolverOverride'),
          ),
  );

  static final stopped = RuntimeStatus();

  final EngineState engine;
  final Map<String, TunnelState> tunnels;
  final String? planHash;
  final Map<String, List<String>> discoveredDNS;
  final ResolverOverrideState resolverOverride;

  Map<String, Object?> toJson() => {
    'engine': engine.toJson(),
    'tunnels': tunnels.map((key, value) => MapEntry(key, value.toJson())),
    if (planHash != null) 'planHash': planHash,
    'discoveredDNS': discoveredDNS,
    'resolverOverride': resolverOverride.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is RuntimeStatus &&
      engine == other.engine &&
      const MapEquality<String, TunnelState>().equals(tunnels, other.tunnels) &&
      planHash == other.planHash &&
      const DeepCollectionEquality().equals(
        discoveredDNS,
        other.discoveredDNS,
      ) &&
      resolverOverride == other.resolverOverride;

  @override
  int get hashCode => Object.hash(
    engine,
    const MapEquality<String, TunnelState>().hash(tunnels),
    planHash,
    const DeepCollectionEquality().hash(discoveredDNS),
    resolverOverride,
  );
}

final class LogLine {
  LogLine({
    DateTime? ts,
    required this.source,
    required this.level,
    required this.message,
  }) : ts = (ts ?? DateTime.now()).toUtc();

  factory LogLine.fromJson(Map<String, Object?> json) => LogLine(
    ts: _date(json, 'ts'),
    source: _string(json, 'source'),
    level: LogLevel.fromJson(json['level']),
    message: _string(json, 'message'),
  );

  final DateTime ts;
  final String source;
  final LogLevel level;
  final String message;

  Map<String, Object?> toJson() => {
    'ts': JsonCoding.encodeDate(ts),
    'source': source,
    'level': level.jsonValue,
    'message': message,
  };

  @override
  bool operator ==(Object other) =>
      other is LogLine &&
      ts == other.ts &&
      source == other.source &&
      level == other.level &&
      message == other.message;
  @override
  int get hashCode => Object.hash(ts, source, level, message);
}

final class ApplyResult {
  const ApplyResult({required this.ok, this.error});

  factory ApplyResult.fromJson(Map<String, Object?> json) => ApplyResult(
    ok: _bool(json, 'ok'),
    error: json['error'] == null
        ? null
        : DaemonError.fromJson(_map(json['error'], 'error')),
  );

  static const success = ApplyResult(ok: true);
  static ApplyResult failure(DaemonError error) =>
      ApplyResult(ok: false, error: error);

  final bool ok;
  final DaemonError? error;

  Map<String, Object?> toJson() => {
    'ok': ok,
    if (error != null) 'error': error!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ApplyResult && ok == other.ok && error == other.error;
  @override
  int get hashCode => Object.hash(ok, error);
}

final class DaemonDiagnostics {
  DaemonDiagnostics({
    required List<String> daemonLogTail,
    required Map<String, List<String>> childLogTails,
    required List<String> runDirectoryListing,
    required this.routes,
  }) : daemonLogTail = List.unmodifiable(daemonLogTail),
       childLogTails = Map.unmodifiable(
         childLogTails.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       ),
       runDirectoryListing = List.unmodifiable(runDirectoryListing);

  factory DaemonDiagnostics.fromJson(Map<String, Object?> json) =>
      DaemonDiagnostics(
        daemonLogTail: _strings(json, 'daemonLogTail'),
        childLogTails: _objectMap(json['childLogTails'], 'childLogTails').map(
          (key, value) => MapEntry(
            key,
            _listValue(
              value,
              key,
            ).map((item) => _stringValue(item, key)).toList(),
          ),
        ),
        runDirectoryListing: _strings(json, 'runDirectoryListing'),
        routes: _string(json, 'routes'),
      );

  final List<String> daemonLogTail;
  final Map<String, List<String>> childLogTails;
  final List<String> runDirectoryListing;
  final String routes;

  Map<String, Object?> toJson() => {
    'daemonLogTail': daemonLogTail,
    'childLogTails': childLogTails,
    'runDirectoryListing': runDirectoryListing,
    'routes': routes,
  };

  @override
  bool operator ==(Object other) =>
      other is DaemonDiagnostics &&
      const ListEquality<String>().equals(daemonLogTail, other.daemonLogTail) &&
      const DeepCollectionEquality().equals(
        childLogTails,
        other.childLogTails,
      ) &&
      const ListEquality<String>().equals(
        runDirectoryListing,
        other.runDirectoryListing,
      ) &&
      routes == other.routes;
  @override
  int get hashCode => const DeepCollectionEquality().hash(toJson());
}

final class TrafficCounters {
  const TrafficCounters({
    this.downBytesPerSecond = 0,
    this.upBytesPerSecond = 0,
    this.downTotal = 0,
    this.upTotal = 0,
    this.connections = 0,
  });

  factory TrafficCounters.fromJson(Map<String, Object?> json) =>
      TrafficCounters(
        downBytesPerSecond: _double(json, 'downBytesPerSecond'),
        upBytesPerSecond: _double(json, 'upBytesPerSecond'),
        downTotal: _int(json, 'downTotal'),
        upTotal: _int(json, 'upTotal'),
        connections: _int(json, 'connections'),
      );

  static const zero = TrafficCounters();

  final double downBytesPerSecond;
  final double upBytesPerSecond;
  final int downTotal;
  final int upTotal;
  final int connections;

  bool get isIdle => downBytesPerSecond == 0 && upBytesPerSecond == 0;

  Map<String, Object?> toJson() => {
    'downBytesPerSecond': downBytesPerSecond,
    'upBytesPerSecond': upBytesPerSecond,
    'downTotal': downTotal,
    'upTotal': upTotal,
    'connections': connections,
  };

  @override
  bool operator ==(Object other) =>
      other is TrafficCounters &&
      downBytesPerSecond == other.downBytesPerSecond &&
      upBytesPerSecond == other.upBytesPerSecond &&
      downTotal == other.downTotal &&
      upTotal == other.upTotal &&
      connections == other.connections;
  @override
  int get hashCode => Object.hash(
    downBytesPerSecond,
    upBytesPerSecond,
    downTotal,
    upTotal,
    connections,
  );
}

final class TrafficSnapshot {
  TrafficSnapshot({
    required this.sampledAt,
    required this.interval,
    required Map<String, TrafficCounters> tunnels,
    required this.direct,
  }) : tunnels = Map.unmodifiable(tunnels);

  factory TrafficSnapshot.fromJson(Map<String, Object?> json) =>
      TrafficSnapshot(
        sampledAt: _date(json, 'sampledAt'),
        interval: _double(json, 'interval'),
        tunnels: _objectMap(json['tunnels'], 'tunnels').map(
          (key, value) =>
              MapEntry(key, TrafficCounters.fromJson(_map(value, key))),
        ),
        direct: TrafficCounters.fromJson(_map(json['direct'], 'direct')),
      );

  final DateTime sampledAt;
  final double interval;
  final Map<String, TrafficCounters> tunnels;
  final TrafficCounters direct;

  TrafficCounters countersForTunnel(String id) =>
      tunnels[id] ?? TrafficCounters.zero;

  Map<String, Object?> toJson() => {
    'sampledAt': JsonCoding.encodeDate(sampledAt),
    'interval': interval,
    'tunnels': tunnels.map((key, value) => MapEntry(key, value.toJson())),
    'direct': direct.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is TrafficSnapshot &&
      sampledAt == other.sampledAt &&
      interval == other.interval &&
      const MapEquality<String, TrafficCounters>().equals(
        tunnels,
        other.tunnels,
      ) &&
      direct == other.direct;
  @override
  int get hashCode => Object.hash(
    sampledAt,
    interval,
    const MapEquality<String, TrafficCounters>().hash(tunnels),
    direct,
  );
}

abstract final class IpcCodec {
  static String encode(Object? value) {
    final Object? tree;
    if (value == null ||
        value is num ||
        value is bool ||
        value is String ||
        value is List ||
        value is Map) {
      tree = value;
    } else {
      tree = (value as dynamic).toJson() as Object?;
    }
    return JsonCoding.encodeCompact(tree);
  }

  static Object? decode(String text) => JsonCoding.decode(text);
}

DateTime _date(Map<String, Object?> json, String key) =>
    JsonCoding.decodeDate(_string(json, key));

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object');
}

Map<String, Object?> _objectMap(Object? value, String name) =>
    _map(value, name);

List<Object?> _list(Map<String, Object?> json, String key) =>
    _listValue(json[key], key);

List<Object?> _listValue(Object? value, String name) {
  if (value is List<Object?>) return value;
  throw FormatException('$name must be an array');
}

List<String> _strings(Map<String, Object?> json, String key) =>
    _list(json, key).map((item) => _stringValue(item, key)).toList();

String _string(Map<String, Object?> json, String key) =>
    _stringValue(json[key], key);

String _stringValue(Object? value, String name) {
  if (value is String) return value;
  throw FormatException('$name must be a string');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('$key must be a string or null');
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key must be an integer');
}

double _double(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  throw FormatException('$key must be a number');
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}
