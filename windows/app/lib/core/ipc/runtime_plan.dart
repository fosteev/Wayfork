import 'package:collection/collection.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/hashing.dart';

final class RuntimePlan {
  RuntimePlan({
    this.version = currentVersion,
    required this.singBox,
    required List<OpenVPNRuntime> openVPN,
    this.autoReconnect = true,
    this.logLevel = LogLevel.info,
    this.overrideSystemDNS = true,
  }) : openVPN = List.unmodifiable(openVPN);

  factory RuntimePlan.fromJson(Map<String, Object?> json) => RuntimePlan(
    version: _int(json, 'version'),
    singBox: SingBoxPlan.fromJson(_map(json['singBox'], 'singBox')),
    openVPN: _list(json, 'openVPN')
        .map((value) => OpenVPNRuntime.fromJson(_map(value, 'OpenVPN runtime')))
        .toList(),
    autoReconnect: json['autoReconnect'] == null
        ? true
        : _bool(json, 'autoReconnect'),
    logLevel: json['logLevel'] == null
        ? LogLevel.info
        : LogLevel.fromJson(json['logLevel']),
    overrideSystemDNS: json['overrideSystemDNS'] == null
        ? true
        : _bool(json, 'overrideSystemDNS'),
  );

  static const currentVersion = 1;
  static const maxTunnels = Tunnel.maxSlots;
  static const maxConfigBytes = 1048576;

  final int version;
  final SingBoxPlan singBox;
  final List<OpenVPNRuntime> openVPN;
  final bool autoReconnect;
  final LogLevel logLevel;
  final bool overrideSystemDNS;

  String get planHash {
    final parts = <String>[singBox.configHash];
    final fileNames = singBox.ruleSets.keys.toList()..sort();
    for (final fileName in fileNames) {
      parts.add(
        '$fileName=${Hashing.sha256Hex(singBox.ruleSets[fileName] ?? '')}',
      );
    }
    for (final runtime in openVPN) {
      parts.add('${runtime.id}=${runtime.configHash}');
    }
    parts.add('overrideSystemDNS=$overrideSystemDNS');
    return Hashing.sha256Hex(parts.join('\n'));
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'singBox': singBox.toJson(),
    'openVPN': openVPN.map((value) => value.toJson()).toList(),
    'autoReconnect': autoReconnect,
    'logLevel': logLevel.jsonValue,
    'overrideSystemDNS': overrideSystemDNS,
  };

  @override
  bool operator ==(Object other) =>
      other is RuntimePlan &&
      version == other.version &&
      singBox == other.singBox &&
      const ListEquality<OpenVPNRuntime>().equals(openVPN, other.openVPN) &&
      autoReconnect == other.autoReconnect &&
      logLevel == other.logLevel &&
      overrideSystemDNS == other.overrideSystemDNS;

  @override
  int get hashCode => Object.hash(
    version,
    singBox,
    const ListEquality<OpenVPNRuntime>().hash(openVPN),
    autoReconnect,
    logLevel,
    overrideSystemDNS,
  );
}

final class SingBoxPlan {
  SingBoxPlan({required this.config, required Map<String, String> ruleSets})
    : ruleSets = Map.unmodifiable(ruleSets),
      configHash = Hashing.sha256Hex(config);

  SingBoxPlan._({
    required this.config,
    required Map<String, String> ruleSets,
    required this.configHash,
  }) : ruleSets = Map.unmodifiable(ruleSets);

  factory SingBoxPlan.fromJson(Map<String, Object?> json) => SingBoxPlan._(
    config: _string(json, 'config'),
    configHash: _string(json, 'configHash'),
    ruleSets: _stringMap(json['ruleSets'], 'ruleSets'),
  );

  final String config;
  final Map<String, String> ruleSets;
  final String configHash;

  Map<String, Object?> toJson() => {
    'config': config,
    'configHash': configHash,
    'ruleSets': ruleSets,
  };

  @override
  bool operator ==(Object other) =>
      other is SingBoxPlan &&
      config == other.config &&
      configHash == other.configHash &&
      const MapEquality<String, String>().equals(ruleSets, other.ruleSets);

  @override
  int get hashCode => Object.hash(
    config,
    configHash,
    const MapEquality<String, String>().hash(ruleSets),
  );
}

final class OpenVPNRuntime {
  OpenVPNRuntime({
    required String id,
    required this.interface,
    required this.config,
    this.credentials,
    this.keyPassphrase,
  }) : id = id.toLowerCase(),
       configHash = Hashing.sha256Hex(
         [
           config,
           credentials?.username ?? '',
           credentials?.password ?? '',
           keyPassphrase ?? '',
         ].join('\u0000'),
       );

  OpenVPNRuntime._({
    required this.id,
    required this.interface,
    required this.config,
    required this.credentials,
    required this.keyPassphrase,
    required this.configHash,
  });

  factory OpenVPNRuntime.fromJson(Map<String, Object?> json) =>
      OpenVPNRuntime._(
        id: _string(json, 'id').toLowerCase(),
        interface: _string(json, 'interface'),
        config: _string(json, 'config'),
        credentials: json['credentials'] == null
            ? null
            : Credentials.fromJson(_map(json['credentials'], 'credentials')),
        keyPassphrase: _optionalString(json, 'keyPassphrase'),
        configHash: _string(json, 'configHash'),
      );

  final String id;
  final String interface;
  final String config;
  final Credentials? credentials;
  final String? keyPassphrase;
  final String configHash;

  Map<String, Object?> toJson() => {
    'id': id,
    'interface': interface,
    'config': config,
    if (credentials != null) 'credentials': credentials!.toJson(),
    if (keyPassphrase != null) 'keyPassphrase': keyPassphrase,
    'configHash': configHash,
  };

  @override
  bool operator ==(Object other) =>
      other is OpenVPNRuntime &&
      id == other.id &&
      interface == other.interface &&
      config == other.config &&
      credentials == other.credentials &&
      keyPassphrase == other.keyPassphrase &&
      configHash == other.configHash;

  @override
  int get hashCode => Object.hash(
    id,
    interface,
    config,
    credentials,
    keyPassphrase,
    configHash,
  );
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object');
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is List<Object?>) return value;
  throw FormatException('$key must be an array');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
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

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

Map<String, String> _stringMap(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be an object');
  }
  return value.map((key, item) {
    if (item is! String) throw FormatException('$name.$key must be a string');
    return MapEntry(key, item);
  });
}
