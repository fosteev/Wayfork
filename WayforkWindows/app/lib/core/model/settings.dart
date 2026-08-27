import 'package:collection/collection.dart';

enum LogLevel implements Comparable<LogLevel> {
  error('error', 0),
  warning('warning', 1),
  info('info', 2),
  debug('debug', 3);

  const LogLevel(this.jsonValue, this.rank);

  final String jsonValue;
  final int rank;

  static LogLevel fromJson(Object? value) {
    if (value is String) {
      for (final level in values) {
        if (level.jsonValue == value) return level;
      }
    }
    throw FormatException('Unknown log level: $value');
  }

  int get openVPNVerbosity => switch (this) {
    LogLevel.debug => 4,
    LogLevel.info => 3,
    LogLevel.warning || LogLevel.error => 1,
  };

  String get singBoxLevel => switch (this) {
    LogLevel.debug => 'debug',
    LogLevel.info => 'info',
    LogLevel.warning => 'warn',
    LogLevel.error => 'error',
  };

  @override
  int compareTo(LogLevel other) => rank.compareTo(other.rank);

  bool operator <(LogLevel other) => compareTo(other) < 0;
}

sealed class DirectDNS {
  const DirectDNS();

  factory DirectDNS.fromJson(Map<String, Object?> json) {
    if (json['system'] is Map<String, Object?>) {
      return const DirectDNSSystem();
    }
    final custom = json['custom'];
    if (custom case {'servers': final List<Object?> servers}) {
      return DirectDNSCustom(servers.map(_string).toList());
    }
    throw const FormatException('Direct DNS must be system or custom');
  }

  Map<String, Object?> toJson();
}

final class DirectDNSSystem extends DirectDNS {
  const DirectDNSSystem();

  @override
  Map<String, Object?> toJson() => {'system': <String, Object?>{}};

  @override
  bool operator ==(Object other) => other is DirectDNSSystem;

  @override
  int get hashCode => 0;
}

final class DirectDNSCustom extends DirectDNS {
  DirectDNSCustom(List<String> servers) : servers = List.unmodifiable(servers);

  final List<String> servers;

  @override
  Map<String, Object?> toJson() => {
    'custom': <String, Object?>{'servers': servers},
  };

  @override
  bool operator ==(Object other) =>
      other is DirectDNSCustom &&
      const ListEquality<String>().equals(servers, other.servers);

  @override
  int get hashCode => const ListEquality<String>().hash(servers);
}

final class Settings {
  const Settings({
    this.launchAtLogin = false,
    this.connectOnLaunch = false,
    this.autoReconnect = true,
    this.notifyOnTunnelFailure = true,
    this.directDNS = const DirectDNSSystem(),
    this.overrideSystemDNS = true,
    this.logLevel = LogLevel.info,
    this.logRetentionDays = 7,
  });

  factory Settings.fromJson(Map<String, Object?> json) => Settings(
    launchAtLogin: _boolOr(json, 'launchAtLogin', false),
    connectOnLaunch: _boolOr(json, 'connectOnLaunch', false),
    autoReconnect: _boolOr(json, 'autoReconnect', true),
    notifyOnTunnelFailure: _boolOr(json, 'notifyOnTunnelFailure', true),
    directDNS: json['directDNS'] == null
        ? const DirectDNSSystem()
        : DirectDNS.fromJson(_map(json['directDNS'], 'directDNS')),
    overrideSystemDNS: _boolOr(json, 'overrideSystemDNS', true),
    logLevel: json['logLevel'] == null
        ? LogLevel.info
        : LogLevel.fromJson(json['logLevel']),
    logRetentionDays: _intOr(json, 'logRetentionDays', 7),
  );

  final bool launchAtLogin;
  final bool connectOnLaunch;
  final bool autoReconnect;
  final bool notifyOnTunnelFailure;
  final DirectDNS directDNS;
  final bool overrideSystemDNS;
  final LogLevel logLevel;
  final int logRetentionDays;

  Map<String, Object?> toJson() => {
    'launchAtLogin': launchAtLogin,
    'connectOnLaunch': connectOnLaunch,
    'autoReconnect': autoReconnect,
    'notifyOnTunnelFailure': notifyOnTunnelFailure,
    'directDNS': directDNS.toJson(),
    'overrideSystemDNS': overrideSystemDNS,
    'logLevel': logLevel.jsonValue,
    'logRetentionDays': logRetentionDays,
  };

  Settings copyWith({
    bool? launchAtLogin,
    bool? connectOnLaunch,
    bool? autoReconnect,
    bool? notifyOnTunnelFailure,
    DirectDNS? directDNS,
    bool? overrideSystemDNS,
    LogLevel? logLevel,
    int? logRetentionDays,
  }) => Settings(
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    connectOnLaunch: connectOnLaunch ?? this.connectOnLaunch,
    autoReconnect: autoReconnect ?? this.autoReconnect,
    notifyOnTunnelFailure: notifyOnTunnelFailure ?? this.notifyOnTunnelFailure,
    directDNS: directDNS ?? this.directDNS,
    overrideSystemDNS: overrideSystemDNS ?? this.overrideSystemDNS,
    logLevel: logLevel ?? this.logLevel,
    logRetentionDays: logRetentionDays ?? this.logRetentionDays,
  );

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      launchAtLogin == other.launchAtLogin &&
      connectOnLaunch == other.connectOnLaunch &&
      autoReconnect == other.autoReconnect &&
      notifyOnTunnelFailure == other.notifyOnTunnelFailure &&
      directDNS == other.directDNS &&
      overrideSystemDNS == other.overrideSystemDNS &&
      logLevel == other.logLevel &&
      logRetentionDays == other.logRetentionDays;

  @override
  int get hashCode => Object.hash(
    launchAtLogin,
    connectOnLaunch,
    autoReconnect,
    notifyOnTunnelFailure,
    directDNS,
    overrideSystemDNS,
    logLevel,
    logRetentionDays,
  );
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object');
}

String _string(Object? value) {
  if (value is String) return value;
  throw FormatException('Expected a string, found ${value.runtimeType}');
}

bool _boolOr(Map<String, Object?> json, String key, bool fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

int _intOr(Map<String, Object?> json, String key, int fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is int) return value;
  throw FormatException('$key must be an integer');
}
