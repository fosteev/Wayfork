import 'package:collection/collection.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/uuid.dart';

final class Store {
  Store({
    this.schemaVersion = currentSchemaVersion,
    List<Tunnel> tunnels = const [],
    List<Rule> rules = const [],
    this.settings = const Settings(),
    String? defaultTunnelID,
  }) : tunnels = List.unmodifiable(tunnels),
       rules = List.unmodifiable(rules),
       defaultTunnelID = defaultTunnelID == null
           ? null
           : _uuid(defaultTunnelID, 'defaultTunnelID');

  factory Store.fromJson(Map<String, Object?> json) => Store(
    schemaVersion: _int(json, 'schemaVersion'),
    tunnels: _list(
      json,
      'tunnels',
    ).map((value) => Tunnel.fromJson(_map(value, 'tunnel'))).toList(),
    rules: _list(
      json,
      'rules',
    ).map((value) => Rule.fromJson(_map(value, 'rule'))).toList(),
    settings: Settings.fromJson(_map(json['settings'], 'settings')),
    defaultTunnelID: _optionalString(json, 'defaultTunnelID'),
  );

  static const currentSchemaVersion = 2;
  static final empty = Store();

  final int schemaVersion;
  final List<Tunnel> tunnels;
  final List<Rule> rules;
  final Settings settings;
  final String? defaultTunnelID;

  Tunnel? tunnel(String id) {
    final normalized = Uuid.normalize(id);
    if (normalized == null) return null;
    for (final tunnel in tunnels) {
      if (tunnel.id == normalized) return tunnel;
    }
    return null;
  }

  List<Rule> rulesFor(RuleTarget target) =>
      rules.where((rule) => rule.target == target).toList();

  List<Rule> rulesForTunnel(String id) => rulesFor(RuleTargetTunnel(id));

  List<Rule> get exceptions => rulesFor(const RuleTargetDirect());

  List<Rule> get effectiveRules {
    final ordered = <Rule>[...exceptions];
    for (final tunnel in tunnels) {
      ordered.addAll(rulesForTunnel(tunnel.id));
    }
    final known = tunnels.map((tunnel) => tunnel.id).toSet();
    ordered.addAll(
      rules.where(
        (rule) => rule.tunnelID != null && !known.contains(rule.tunnelID),
      ),
    );
    return ordered;
  }

  Tunnel? get effectiveDefaultTunnel {
    final id = defaultTunnelID;
    if (id == null) return null;
    final value = tunnel(id);
    return value != null && value.isEnabled ? value : null;
  }

  int? nextFreeSlot() {
    final used = tunnels.map((tunnel) => tunnel.slot).toSet();
    for (var slot = 0; slot < Tunnel.maxSlots; slot++) {
      if (!used.contains(slot)) return slot;
    }
    return null;
  }

  bool isNameAvailable(String name, {String? excluding}) {
    final candidate = name.trim().toLowerCase();
    final excluded = excluding == null ? null : Uuid.normalize(excluding);
    return !tunnels.any(
      (tunnel) =>
          tunnel.id != excluded && tunnel.name.toLowerCase() == candidate,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'tunnels': tunnels.map((tunnel) => tunnel.toJson()).toList(),
    'rules': rules.map((rule) => rule.toJson()).toList(),
    'settings': settings.toJson(),
    if (defaultTunnelID != null)
      'defaultTunnelID': Uuid.encode(defaultTunnelID!),
  };

  Store copyWith({
    int? schemaVersion,
    List<Tunnel>? tunnels,
    List<Rule>? rules,
    Settings? settings,
    Object? defaultTunnelID = _unset,
  }) => Store(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    tunnels: tunnels ?? this.tunnels,
    rules: rules ?? this.rules,
    settings: settings ?? this.settings,
    defaultTunnelID: identical(defaultTunnelID, _unset)
        ? this.defaultTunnelID
        : defaultTunnelID as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is Store &&
      schemaVersion == other.schemaVersion &&
      const ListEquality<Tunnel>().equals(tunnels, other.tunnels) &&
      const ListEquality<Rule>().equals(rules, other.rules) &&
      settings == other.settings &&
      defaultTunnelID == other.defaultTunnelID;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    const ListEquality<Tunnel>().hash(tunnels),
    const ListEquality<Rule>().hash(rules),
    settings,
    defaultTunnelID,
  );
}

typedef StoreMigrationApply = void Function(Map<String, Object?> document);

final class StoreMigration {
  const StoreMigration({required this.fromVersion, required this.apply});

  final int fromVersion;
  final StoreMigrationApply apply;
}

enum StoreCodecError { newerSchema, invalidDocument }

final class StoreCodecException implements Exception {
  const StoreCodecException._(this.kind, {this.found, this.supported});

  const StoreCodecException.newerSchema({
    required int found,
    required int supported,
  }) : this._(StoreCodecError.newerSchema, found: found, supported: supported);

  const StoreCodecException.invalidDocument()
    : this._(StoreCodecError.invalidDocument);

  final StoreCodecError kind;
  final int? found;
  final int? supported;

  @override
  bool operator ==(Object other) =>
      other is StoreCodecException &&
      kind == other.kind &&
      found == other.found &&
      supported == other.supported;

  @override
  int get hashCode => Object.hash(kind, found, supported);

  @override
  String toString() => switch (kind) {
    StoreCodecError.newerSchema =>
      'Store schema $found is newer than supported schema $supported',
    StoreCodecError.invalidDocument => 'Invalid store document',
  };
}

abstract final class StoreCodec {
  static final List<StoreMigration> migrations = [
    StoreMigration(fromVersion: 1, apply: (_) {}),
  ];

  static String encode(Store store) => JsonCoding.encodePretty(store.toJson());

  static Store decode(String text) {
    try {
      final decoded = JsonCoding.decode(text);
      if (decoded is! Map<String, Object?>) {
        throw const StoreCodecException.invalidDocument();
      }
      final object = Map<String, Object?>.from(decoded);
      final rawVersion = object['schemaVersion'];
      if (rawVersion != null && rawVersion is! int) {
        throw const StoreCodecException.invalidDocument();
      }
      var version = rawVersion as int? ?? 1;
      if (version > Store.currentSchemaVersion) {
        throw StoreCodecException.newerSchema(
          found: version,
          supported: Store.currentSchemaVersion,
        );
      }
      while (version < Store.currentSchemaVersion) {
        StoreMigration? migration;
        for (final candidate in migrations) {
          if (candidate.fromVersion == version) migration = candidate;
        }
        if (migration == null) {
          throw const StoreCodecException.invalidDocument();
        }
        migration.apply(object);
        version++;
        object['schemaVersion'] = version;
      }
      return Store.fromJson(object);
    } on StoreCodecException {
      rethrow;
    } on Object {
      throw const StoreCodecException.invalidDocument();
    }
  }
}

const _unset = Object();

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object');
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is List<Object?>) return value;
  throw FormatException('$key must be an array');
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key must be an integer');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('$key must be a string or null');
}

String _uuid(String value, String name) {
  final normalized = Uuid.normalize(value);
  if (normalized == null) throw FormatException('$name must be a UUID');
  return normalized;
}
