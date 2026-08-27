import 'package:collection/collection.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/support/uuid.dart';

final class Remote {
  const Remote({required this.host, required this.port, required this.proto});

  factory Remote.fromJson(Map<String, Object?> json) => Remote(
    host: _string(json, 'host'),
    port: _int(json, 'port'),
    proto: _string(json, 'proto'),
  );

  final String host;
  final int port;
  final String proto;

  Map<String, Object?> toJson() => {'host': host, 'port': port, 'proto': proto};

  @override
  bool operator ==(Object other) =>
      other is Remote &&
      host == other.host &&
      port == other.port &&
      proto == other.proto;

  @override
  int get hashCode => Object.hash(host, port, proto);
}

sealed class TunnelDNS {
  const TunnelDNS();

  factory TunnelDNS.fromJson(Map<String, Object?> json) {
    if (json['auto'] is Map<String, Object?>) return const TunnelDNSAuto();
    final custom = json['custom'];
    if (custom case {'servers': final List<Object?> servers}) {
      return TunnelDNSCustom(
        servers.map((value) {
          if (value is String) return value;
          throw const FormatException('DNS server must be a string');
        }).toList(),
      );
    }
    throw const FormatException('Tunnel DNS must be auto or custom');
  }

  Map<String, Object?> toJson();
}

final class TunnelDNSAuto extends TunnelDNS {
  const TunnelDNSAuto();

  @override
  Map<String, Object?> toJson() => {'auto': <String, Object?>{}};

  @override
  bool operator ==(Object other) => other is TunnelDNSAuto;

  @override
  int get hashCode => 0;
}

final class TunnelDNSCustom extends TunnelDNS {
  TunnelDNSCustom(List<String> servers) : servers = List.unmodifiable(servers);

  final List<String> servers;

  @override
  Map<String, Object?> toJson() => {
    'custom': <String, Object?>{'servers': servers},
  };

  @override
  bool operator ==(Object other) =>
      other is TunnelDNSCustom &&
      const ListEquality<String>().equals(servers, other.servers);

  @override
  int get hashCode => const ListEquality<String>().hash(servers);
}

final class OpenVPNMeta {
  OpenVPNMeta({
    required List<Remote> remotes,
    required this.needsCredentials,
    required this.needsKeyPassphrase,
    this.dns = const TunnelDNSAuto(),
    List<String> discoveredDNS = const [],
    required this.configHash,
  }) : remotes = List.unmodifiable(remotes),
       discoveredDNS = List.unmodifiable(discoveredDNS);

  factory OpenVPNMeta.fromJson(Map<String, Object?> json) => OpenVPNMeta(
    remotes: _list(
      json,
      'remotes',
    ).map((value) => Remote.fromJson(_map(value, 'remote'))).toList(),
    needsCredentials: _bool(json, 'needsCredentials'),
    needsKeyPassphrase: _bool(json, 'needsKeyPassphrase'),
    dns: TunnelDNS.fromJson(_map(json['dns'], 'dns')),
    discoveredDNS: _list(
      json,
      'discoveredDNS',
    ).map((value) => _stringValue(value, 'DNS server')).toList(),
    configHash: _string(json, 'configHash'),
  );

  final List<Remote> remotes;
  final bool needsCredentials;
  final bool needsKeyPassphrase;
  final TunnelDNS dns;
  final List<String> discoveredDNS;
  final String configHash;

  Map<String, Object?> toJson() => {
    'remotes': remotes.map((value) => value.toJson()).toList(),
    'needsCredentials': needsCredentials,
    'needsKeyPassphrase': needsKeyPassphrase,
    'dns': dns.toJson(),
    'discoveredDNS': discoveredDNS,
    'configHash': configHash,
  };

  @override
  bool operator ==(Object other) =>
      other is OpenVPNMeta &&
      const ListEquality<Remote>().equals(remotes, other.remotes) &&
      needsCredentials == other.needsCredentials &&
      needsKeyPassphrase == other.needsKeyPassphrase &&
      dns == other.dns &&
      const ListEquality<String>().equals(discoveredDNS, other.discoveredDNS) &&
      configHash == other.configHash;

  @override
  int get hashCode => Object.hash(
    const ListEquality<Remote>().hash(remotes),
    needsCredentials,
    needsKeyPassphrase,
    dns,
    const ListEquality<String>().hash(discoveredDNS),
    configHash,
  );
}

enum VLESSSecurity {
  none('none'),
  tls('tls'),
  reality('reality');

  const VLESSSecurity(this.jsonValue);
  final String jsonValue;

  static VLESSSecurity fromJson(Object? value) {
    if (value is String) {
      for (final security in values) {
        if (security.jsonValue == value) return security;
      }
    }
    throw FormatException('Unknown VLESS security: $value');
  }
}

sealed class VLESSTransport {
  const VLESSTransport();

  factory VLESSTransport.fromJson(Map<String, Object?> json) {
    if (json['tcp'] is Map<String, Object?>) {
      return const VLESSTransportTCP();
    }
    if (json['ws'] case final Map<String, Object?> ws) {
      return VLESSTransportWS(
        path: _string(ws, 'path'),
        host: _optionalString(ws, 'host'),
      );
    }
    if (json['grpc'] case final Map<String, Object?> grpc) {
      return VLESSTransportGRPC(serviceName: _string(grpc, 'serviceName'));
    }
    throw const FormatException('Unknown VLESS transport');
  }

  Map<String, Object?> toJson();
}

final class VLESSTransportTCP extends VLESSTransport {
  const VLESSTransportTCP();

  @override
  Map<String, Object?> toJson() => {'tcp': <String, Object?>{}};

  @override
  bool operator ==(Object other) => other is VLESSTransportTCP;

  @override
  int get hashCode => 0;
}

final class VLESSTransportWS extends VLESSTransport {
  const VLESSTransportWS({required this.path, this.host});

  final String path;
  final String? host;

  @override
  Map<String, Object?> toJson() => {
    'ws': <String, Object?>{'path': path, if (host != null) 'host': host},
  };

  @override
  bool operator ==(Object other) =>
      other is VLESSTransportWS && path == other.path && host == other.host;

  @override
  int get hashCode => Object.hash(path, host);
}

final class VLESSTransportGRPC extends VLESSTransport {
  const VLESSTransportGRPC({required this.serviceName});

  final String serviceName;

  @override
  Map<String, Object?> toJson() => {
    'grpc': <String, Object?>{'serviceName': serviceName},
  };

  @override
  bool operator ==(Object other) =>
      other is VLESSTransportGRPC && serviceName == other.serviceName;

  @override
  int get hashCode => serviceName.hashCode;
}

final class VLESSMeta {
  VLESSMeta({
    required this.server,
    required this.port,
    this.flow,
    required this.security,
    this.sni,
    this.fingerprint,
    List<String> alpn = const [],
    this.realityPublicKey,
    this.realityShortID,
    this.transport = const VLESSTransportTCP(),
    this.allowInsecure = false,
  }) : alpn = List.unmodifiable(alpn);

  factory VLESSMeta.fromJson(Map<String, Object?> json) => VLESSMeta(
    server: _string(json, 'server'),
    port: _int(json, 'port'),
    flow: _optionalString(json, 'flow'),
    security: VLESSSecurity.fromJson(json['security']),
    sni: _optionalString(json, 'sni'),
    fingerprint: _optionalString(json, 'fingerprint'),
    alpn: _list(
      json,
      'alpn',
    ).map((value) => _stringValue(value, 'ALPN')).toList(),
    realityPublicKey: _optionalString(json, 'realityPublicKey'),
    realityShortID: _optionalString(json, 'realityShortID'),
    transport: VLESSTransport.fromJson(_map(json['transport'], 'transport')),
    allowInsecure: _bool(json, 'allowInsecure'),
  );

  final String server;
  final int port;
  final String? flow;
  final VLESSSecurity security;
  final String? sni;
  final String? fingerprint;
  final List<String> alpn;
  final String? realityPublicKey;
  final String? realityShortID;
  final VLESSTransport transport;
  final bool allowInsecure;

  Map<String, Object?> toJson() => {
    'server': server,
    'port': port,
    if (flow != null) 'flow': flow,
    'security': security.jsonValue,
    if (sni != null) 'sni': sni,
    if (fingerprint != null) 'fingerprint': fingerprint,
    'alpn': alpn,
    if (realityPublicKey != null) 'realityPublicKey': realityPublicKey,
    if (realityShortID != null) 'realityShortID': realityShortID,
    'transport': transport.toJson(),
    'allowInsecure': allowInsecure,
  };

  @override
  bool operator ==(Object other) =>
      other is VLESSMeta &&
      server == other.server &&
      port == other.port &&
      flow == other.flow &&
      security == other.security &&
      sni == other.sni &&
      fingerprint == other.fingerprint &&
      const ListEquality<String>().equals(alpn, other.alpn) &&
      realityPublicKey == other.realityPublicKey &&
      realityShortID == other.realityShortID &&
      transport == other.transport &&
      allowInsecure == other.allowInsecure;

  @override
  int get hashCode => Object.hash(
    server,
    port,
    flow,
    security,
    sni,
    fingerprint,
    const ListEquality<String>().hash(alpn),
    realityPublicKey,
    realityShortID,
    transport,
    allowInsecure,
  );
}

sealed class TunnelKind {
  const TunnelKind();

  factory TunnelKind.fromJson(Map<String, Object?> json) {
    if (json['openVPN'] case final Map<String, Object?> meta) {
      return TunnelKindOpenVPN(OpenVPNMeta.fromJson(meta));
    }
    if (json['vless'] case final Map<String, Object?> meta) {
      return TunnelKindVLESS(VLESSMeta.fromJson(meta));
    }
    throw const FormatException('Tunnel kind must be one of: openVPN, vless');
  }

  bool get isOpenVPN => this is TunnelKindOpenVPN;
  OpenVPNMeta? get openVPN => switch (this) {
    TunnelKindOpenVPN(:final meta) => meta,
    _ => null,
  };
  VLESSMeta? get vless => switch (this) {
    TunnelKindVLESS(:final meta) => meta,
    _ => null,
  };
  List<String> get serverHosts => switch (this) {
    TunnelKindOpenVPN(:final meta) =>
      meta.remotes.map((remote) => remote.host).toList(),
    TunnelKindVLESS(:final meta) => [meta.server],
  };

  Map<String, Object?> toJson();
}

final class TunnelKindOpenVPN extends TunnelKind {
  const TunnelKindOpenVPN(this.meta);
  final OpenVPNMeta meta;

  @override
  Map<String, Object?> toJson() => {'openVPN': meta.toJson()};

  @override
  bool operator ==(Object other) =>
      other is TunnelKindOpenVPN && meta == other.meta;

  @override
  int get hashCode => meta.hashCode;
}

final class TunnelKindVLESS extends TunnelKind {
  const TunnelKindVLESS(this.meta);
  final VLESSMeta meta;

  @override
  Map<String, Object?> toJson() => {'vless': meta.toJson()};

  @override
  bool operator ==(Object other) =>
      other is TunnelKindVLESS && meta == other.meta;

  @override
  int get hashCode => meta.hashCode;
}

final class Tunnel {
  factory Tunnel({
    String? id,
    required String name,
    bool isEnabled = true,
    required int slot,
    required TunnelKind kind,
    DateTime? createdAt,
  }) => Tunnel._(
    id: _uuid(id ?? Uuid.generate(), 'id'),
    name: name,
    isEnabled: isEnabled,
    slot: slot,
    kind: kind,
    createdAt: createdAt == null
        ? _wholeSeconds(DateTime.now())
        : createdAt.toUtc(),
  );

  const Tunnel._({
    required this.id,
    required this.name,
    required this.isEnabled,
    required this.slot,
    required this.kind,
    required this.createdAt,
  });

  factory Tunnel.fromJson(Map<String, Object?> json) => Tunnel(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    isEnabled: _bool(json, 'isEnabled'),
    slot: _int(json, 'slot'),
    kind: TunnelKind.fromJson(_map(json['kind'], 'kind')),
    createdAt: JsonCoding.decodeDate(_string(json, 'createdAt')),
  );

  static const maxSlots = 32;
  static const nameMaxLength = 40;
  static const outboundTagPrefix = 't-';

  final String id;
  final String name;
  final bool isEnabled;
  final int slot;
  final TunnelKind kind;
  final DateTime createdAt;

  String get outboundTag => '$outboundTagPrefix$id';

  static String? tunnelID(String outboundTag) =>
      outboundTag.startsWith(outboundTagPrefix) &&
          outboundTag.length > outboundTagPrefix.length
      ? outboundTag.substring(outboundTagPrefix.length)
      : null;

  String get ruleSetTag => 'rules-$outboundTag';
  String get ruleSetFileName => '$ruleSetTag.json';
  String get ipRuleSetTag => '$ruleSetTag-ip';
  String get ipRuleSetFileName => '$ipRuleSetTag.json';
  String? get interfaceName => kind.isOpenVPN ? 'Wayfork-${slot + 1}' : null;

  Map<String, Object?> toJson() => {
    'id': Uuid.encode(id),
    'name': name,
    'isEnabled': isEnabled,
    'slot': slot,
    'kind': kind.toJson(),
    'createdAt': JsonCoding.encodeDate(createdAt),
  };

  Tunnel copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    int? slot,
    TunnelKind? kind,
    DateTime? createdAt,
  }) => Tunnel(
    id: id ?? this.id,
    name: name ?? this.name,
    isEnabled: isEnabled ?? this.isEnabled,
    slot: slot ?? this.slot,
    kind: kind ?? this.kind,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Tunnel &&
      id == other.id &&
      name == other.name &&
      isEnabled == other.isEnabled &&
      slot == other.slot &&
      kind == other.kind &&
      createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(id, name, isEnabled, slot, kind, createdAt);
}

DateTime _wholeSeconds(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.toUtc().millisecondsSinceEpoch ~/ 1000 * 1000,
  isUtc: true,
);

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object');
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is List<Object?>) return value;
  throw FormatException('$key must be an array');
}

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

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

String _uuid(String value, String name) {
  final normalized = Uuid.normalize(value);
  if (normalized == null) throw FormatException('$name must be a UUID');
  return normalized;
}
