import 'package:collection/collection.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/uuid.dart';

final class Credentials {
  const Credentials({required this.username, required this.password});

  factory Credentials.fromJson(Map<String, Object?> json) => Credentials(
    username: _string(json, 'username'),
    password: _string(json, 'password'),
  );

  final String username;
  final String password;

  Map<String, Object?> toJson() => {'username': username, 'password': password};

  @override
  bool operator ==(Object other) =>
      other is Credentials &&
      username == other.username &&
      password == other.password;

  @override
  int get hashCode => Object.hash(username, password);
}

final class TunnelSecrets {
  const TunnelSecrets({
    this.ovpn,
    this.credentials,
    this.keyPassphrase,
    this.uuid,
  });

  factory TunnelSecrets.fromJson(Map<String, Object?> json) => TunnelSecrets(
    ovpn: _optionalString(json, 'ovpn'),
    credentials: json['credentials'] == null
        ? null
        : Credentials.fromJson(_map(json['credentials'], 'credentials')),
    keyPassphrase: _optionalString(json, 'keyPassphrase'),
    uuid: _optionalString(json, 'uuid'),
  );

  static const none = TunnelSecrets();

  final String? ovpn;
  final Credentials? credentials;
  final String? keyPassphrase;
  final String? uuid;

  bool get isEmpty =>
      ovpn == null &&
      credentials == null &&
      keyPassphrase == null &&
      uuid == null;

  Map<String, Object?> toJson() => {
    if (ovpn != null) 'ovpn': ovpn,
    if (credentials != null) 'credentials': credentials!.toJson(),
    if (keyPassphrase != null) 'keyPassphrase': keyPassphrase,
    if (uuid != null) 'uuid': uuid,
  };

  @override
  bool operator ==(Object other) =>
      other is TunnelSecrets &&
      ovpn == other.ovpn &&
      credentials == other.credentials &&
      keyPassphrase == other.keyPassphrase &&
      uuid == other.uuid;

  @override
  int get hashCode => Object.hash(ovpn, credentials, keyPassphrase, uuid);
}

final class ExportedTunnel {
  factory ExportedTunnel({
    required String id,
    required String name,
    required bool isEnabled,
    required DateTime createdAt,
    required TunnelKind kind,
    TunnelSecrets secrets = TunnelSecrets.none,
  }) => ExportedTunnel._(
    id: _uuid(id, 'id'),
    name: name,
    isEnabled: isEnabled,
    createdAt: createdAt.toUtc(),
    kind: kind,
    secrets: secrets,
  );

  factory ExportedTunnel.fromTunnel(
    Tunnel tunnel, {
    TunnelSecrets secrets = TunnelSecrets.none,
  }) => ExportedTunnel(
    id: tunnel.id,
    name: tunnel.name,
    isEnabled: tunnel.isEnabled,
    createdAt: tunnel.createdAt,
    kind: tunnel.kind,
    secrets: secrets,
  );

  const ExportedTunnel._({
    required this.id,
    required this.name,
    required this.isEnabled,
    required this.createdAt,
    required this.kind,
    required this.secrets,
  });

  factory ExportedTunnel.fromJson(Map<String, Object?> json) => ExportedTunnel(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    isEnabled: _bool(json, 'isEnabled'),
    createdAt: JsonCoding.decodeDate(_string(json, 'createdAt')),
    kind: TunnelKind.fromJson(_map(json['kind'], 'kind')),
    secrets: TunnelSecrets.fromJson(_map(json['secrets'], 'secrets')),
  );

  final String id;
  final String name;
  final bool isEnabled;
  final DateTime createdAt;
  final TunnelKind kind;
  final TunnelSecrets secrets;

  Map<String, Object?> toJson() => {
    'id': Uuid.encode(id),
    'name': name,
    'isEnabled': isEnabled,
    'createdAt': JsonCoding.encodeDate(createdAt),
    'kind': kind.toJson(),
    'secrets': secrets.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ExportedTunnel &&
      id == other.id &&
      name == other.name &&
      isEnabled == other.isEnabled &&
      createdAt == other.createdAt &&
      kind == other.kind &&
      secrets == other.secrets;

  @override
  int get hashCode =>
      Object.hash(id, name, isEnabled, createdAt, kind, secrets);
}

enum ExportDocumentError { unknownFormat, newerVersion }

final class ExportDocumentException implements Exception {
  const ExportDocumentException._(this.kind, {this.format, this.version});

  const ExportDocumentException.unknownFormat(String format)
    : this._(ExportDocumentError.unknownFormat, format: format);

  const ExportDocumentException.newerVersion(int version)
    : this._(ExportDocumentError.newerVersion, version: version);

  final ExportDocumentError kind;
  final String? format;
  final int? version;

  @override
  bool operator ==(Object other) =>
      other is ExportDocumentException &&
      kind == other.kind &&
      format == other.format &&
      version == other.version;

  @override
  int get hashCode => Object.hash(kind, format, version);
}

final class ExportDocument {
  factory ExportDocument({
    DateTime? exportedAt,
    required bool includesSecrets,
    required List<ExportedTunnel> tunnels,
    required List<Rule> rules,
    required Settings settings,
    String? defaultTunnelID,
  }) => ExportDocument._(
    format: formatName,
    version: currentVersion,
    exportedAt: (exportedAt ?? DateTime.now()).toUtc(),
    includesSecrets: includesSecrets,
    tunnels: List.unmodifiable(tunnels),
    rules: List.unmodifiable(rules),
    settings: settings,
    defaultTunnelID: defaultTunnelID == null
        ? null
        : _uuid(defaultTunnelID, 'defaultTunnelID'),
  );

  const ExportDocument._({
    required this.format,
    required this.version,
    required this.exportedAt,
    required this.includesSecrets,
    required this.tunnels,
    required this.rules,
    required this.settings,
    required this.defaultTunnelID,
  });

  factory ExportDocument.fromJson(Map<String, Object?> json) =>
      ExportDocument._(
        format: _string(json, 'format'),
        version: _int(json, 'version'),
        exportedAt: JsonCoding.decodeDate(_string(json, 'exportedAt')),
        includesSecrets: _bool(json, 'includesSecrets'),
        tunnels: List.unmodifiable(
          _list(
            json,
            'tunnels',
          ).map((value) => ExportedTunnel.fromJson(_map(value, 'tunnel'))),
        ),
        rules: List.unmodifiable(
          _list(
            json,
            'rules',
          ).map((value) => Rule.fromJson(_map(value, 'rule'))),
        ),
        settings: Settings.fromJson(_map(json['settings'], 'settings')),
        defaultTunnelID: json['defaultTunnelID'] == null
            ? null
            : _uuid(_string(json, 'defaultTunnelID'), 'defaultTunnelID'),
      );

  static const formatName = 'wayfork-export';
  static const currentVersion = 2;

  final String format;
  final int version;
  final DateTime exportedAt;
  final bool includesSecrets;
  final List<ExportedTunnel> tunnels;
  final List<Rule> rules;
  final Settings settings;
  final String? defaultTunnelID;

  static ExportDocument decode(String text) {
    final value = JsonCoding.decode(text);
    if (value is! Map<String, Object?>) {
      throw const FormatException('Export document must be an object');
    }
    final document = ExportDocument.fromJson(value);
    if (document.format != formatName) {
      throw ExportDocumentException.unknownFormat(document.format);
    }
    if (document.version > currentVersion) {
      throw ExportDocumentException.newerVersion(document.version);
    }
    return document;
  }

  String encode() => JsonCoding.encodePretty(toJson());

  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'exportedAt': JsonCoding.encodeDate(exportedAt),
    'includesSecrets': includesSecrets,
    'tunnels': tunnels.map((tunnel) => tunnel.toJson()).toList(),
    'rules': rules.map((rule) => rule.toJson()).toList(),
    'settings': settings.toJson(),
    if (defaultTunnelID != null)
      'defaultTunnelID': Uuid.encode(defaultTunnelID!),
  };

  @override
  bool operator ==(Object other) =>
      other is ExportDocument &&
      format == other.format &&
      version == other.version &&
      exportedAt == other.exportedAt &&
      includesSecrets == other.includesSecrets &&
      const ListEquality<ExportedTunnel>().equals(tunnels, other.tunnels) &&
      const ListEquality<Rule>().equals(rules, other.rules) &&
      settings == other.settings &&
      defaultTunnelID == other.defaultTunnelID;

  @override
  int get hashCode => Object.hash(
    format,
    version,
    exportedAt,
    includesSecrets,
    const ListEquality<ExportedTunnel>().hash(tunnels),
    const ListEquality<Rule>().hash(rules),
    settings,
    defaultTunnelID,
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

String _uuid(String value, String name) {
  final normalized = Uuid.normalize(value);
  if (normalized == null) throw FormatException('$name must be a UUID');
  return normalized;
}
