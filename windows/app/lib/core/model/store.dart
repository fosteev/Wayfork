import 'package:collection/collection.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/local_proxy.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/model/tunnel_group.dart';
import 'package:wayfork/core/support/uuid.dart';

final class Store {
  Store({
    this.schemaVersion = currentSchemaVersion,
    List<Tunnel> tunnels = const [],
    List<Rule> rules = const [],
    this.settings = const Settings(),
    String? defaultTunnelID,
    List<TunnelGroup> groups = const [],
  }) : tunnels = List.unmodifiable(tunnels),
       rules = List.unmodifiable(rules),
       groups = List.unmodifiable(groups),
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
    groups: json['groups'] == null
        ? const []
        : _list(
            json,
            'groups',
          ).map((value) => TunnelGroup.fromJson(_map(value, 'group'))).toList(),
  );

  static const currentSchemaVersion = 2;
  static final empty = Store();

  final int schemaVersion;
  final List<Tunnel> tunnels;
  final List<Rule> rules;
  final Settings settings;
  final String? defaultTunnelID;

  /// F16: groups of tunnels; a rule or `defaultTunnelID` may name one.
  final List<TunnelGroup> groups;

  Tunnel? tunnel(String id) {
    final normalized = Uuid.normalize(id);
    if (normalized == null) return null;
    for (final tunnel in tunnels) {
      if (tunnel.id == normalized) return tunnel;
    }
    return null;
  }

  TunnelGroup? group(String id) {
    final normalized = Uuid.normalize(id);
    if (normalized == null) return null;
    for (final group in groups) {
      if (group.id == normalized) return group;
    }
    return null;
  }

  /// The name of a tunnel or group, whichever `id` is.
  String? exitName(String id) => tunnel(id)?.name ?? group(id)?.name;

  List<Rule> rulesFor(RuleTarget target) =>
      rules.where((rule) => rule.target == target).toList();

  List<Rule> rulesForTunnel(String id) => rulesFor(RuleTargetTunnel(id));

  /// Rules of one group of tunnels (F16) in their list order.
  List<Rule> rulesForGroup(String id) => rulesFor(RuleTargetGroup(id));

  /// The enabled tunnels among a group's members, in the group's order.
  List<Tunnel> enabledMembers(TunnelGroup group) => group.members
      .map(tunnel)
      .whereType<Tunnel>()
      .where((member) => member.isEnabled)
      .toList();

  List<Rule> get exceptions => rulesFor(const RuleTargetDirect());

  /// Rules in matching order: the Direct group first (exceptions always win),
  /// then tunnels in store order, then groups in store order (F16), each
  /// section's rules in list order. Rules pointing at a tunnel or group that
  /// no longer exists come last.
  List<Rule> get effectiveRules {
    final ordered = <Rule>[...exceptions];
    for (final tunnel in tunnels) {
      ordered.addAll(rulesForTunnel(tunnel.id));
    }
    for (final group in groups) {
      ordered.addAll(rulesForGroup(group.id));
    }
    final known = {
      ...tunnels.map((tunnel) => tunnel.id),
      ...groups.map((group) => group.id),
    };
    ordered.addAll(
      rules.where(
        (rule) => rule.exitID != null && !known.contains(rule.exitID),
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

  /// Where "everything else" goes (F8, F16): a tunnel or a group, when it
  /// exists and is enabled (a group also needs an enabled member). Null means
  /// direct.
  DefaultExit? get effectiveDefaultExit {
    final id = defaultTunnelID;
    if (id == null) return null;
    final asTunnel = tunnel(id);
    if (asTunnel != null) {
      return asTunnel.isEnabled ? DefaultExitTunnel(asTunnel) : null;
    }
    final asGroup = group(id);
    if (asGroup != null &&
        asGroup.isEnabled &&
        enabledMembers(asGroup).isNotEmpty) {
      return DefaultExitGroup(asGroup);
    }
    return null;
  }

  /// Ports held by every tunnel and group (on or off), by owner id (F17).
  Map<String, int> get localProxyPorts => {
    for (final tunnel in tunnels)
      if (tunnel.localProxy != null) tunnel.id: tunnel.localProxy!.port,
    for (final group in groups)
      if (group.localProxy != null) group.id: group.localProxy!.port,
  };

  /// The lowest port from `LocalProxy.firstPort` up that no tunnel or group
  /// holds.
  int nextFreeLocalProxyPort() {
    final used = localProxyPorts.values.toSet();
    var port = LocalProxy.firstPort;
    while (used.contains(port)) {
      port++;
    }
    return port;
  }

  /// The name of the other tunnel or group holding `port`, when one does.
  String? localProxyPortOwner(int port, {required String excluding}) {
    final excluded = Uuid.normalize(excluding);
    for (final entry in localProxyPorts.entries) {
      if (entry.key != excluded && entry.value == port) {
        return exitName(entry.key);
      }
    }
    return null;
  }

  /// The local proxy of a tunnel or group, whichever `id` is.
  LocalProxy? localProxyOfExit(String id) =>
      tunnel(id)?.localProxy ?? group(id)?.localProxy;

  /// Lowest free slot, or null when all `Tunnel.maxSlots` are taken.
  /// `excluding` lists slots claimed by tunnels not yet appended (a batch
  /// import).
  int? nextFreeSlot({Iterable<int> excluding = const []}) {
    final used = {...tunnels.map((tunnel) => tunnel.slot), ...excluding};
    for (var slot = 0; slot < Tunnel.maxSlots; slot++) {
      if (!used.contains(slot)) return slot;
    }
    return null;
  }

  /// Slots still free for new tunnels.
  int get freeSlotCount => Tunnel.maxSlots - tunnels.length < 0
      ? 0
      : Tunnel.maxSlots - tunnels.length;

  /// Tunnel and group names share one namespace, compared case-insensitively.
  bool isNameAvailable(String name, {String? excluding}) {
    final candidate = name.trim().toLowerCase();
    final excluded = excluding == null ? null : Uuid.normalize(excluding);
    return !tunnels.any(
          (tunnel) =>
              tunnel.id != excluded && tunnel.name.toLowerCase() == candidate,
        ) &&
        !groups.any(
          (group) =>
              group.id != excluded && group.name.toLowerCase() == candidate,
        );
  }

  /// `groups` is written only when there are any, so a store without groups is
  /// byte-identical to one written before F16.
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'tunnels': tunnels.map((tunnel) => tunnel.toJson()).toList(),
    'rules': rules.map((rule) => rule.toJson()).toList(),
    'settings': settings.toJson(),
    if (defaultTunnelID != null)
      'defaultTunnelID': Uuid.encode(defaultTunnelID!),
    if (groups.isNotEmpty)
      'groups': groups.map((group) => group.toJson()).toList(),
  };

  Store copyWith({
    int? schemaVersion,
    List<Tunnel>? tunnels,
    List<Rule>? rules,
    Settings? settings,
    Object? defaultTunnelID = _unset,
    List<TunnelGroup>? groups,
  }) => Store(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    tunnels: tunnels ?? this.tunnels,
    rules: rules ?? this.rules,
    settings: settings ?? this.settings,
    defaultTunnelID: identical(defaultTunnelID, _unset)
        ? this.defaultTunnelID
        : defaultTunnelID as String?,
    groups: groups ?? this.groups,
  );

  @override
  bool operator ==(Object other) =>
      other is Store &&
      schemaVersion == other.schemaVersion &&
      const ListEquality<Tunnel>().equals(tunnels, other.tunnels) &&
      const ListEquality<Rule>().equals(rules, other.rules) &&
      settings == other.settings &&
      defaultTunnelID == other.defaultTunnelID &&
      const ListEquality<TunnelGroup>().equals(groups, other.groups);

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    const ListEquality<Tunnel>().hash(tunnels),
    const ListEquality<Rule>().hash(rules),
    settings,
    defaultTunnelID,
    const ListEquality<TunnelGroup>().hash(groups),
  );
}

/// The default exit (F8, F16) once resolved against the store.
sealed class DefaultExit {
  const DefaultExit();

  String get id;
  String get name;
  String get outboundTag;
}

final class DefaultExitTunnel extends DefaultExit {
  const DefaultExitTunnel(this.tunnel);

  final Tunnel tunnel;

  @override
  String get id => tunnel.id;

  @override
  String get name => tunnel.name;

  @override
  String get outboundTag => tunnel.outboundTag;
}

final class DefaultExitGroup extends DefaultExit {
  const DefaultExitGroup(this.group);

  final TunnelGroup group;

  @override
  String get id => group.id;

  @override
  String get name => group.name;

  @override
  String get outboundTag => group.outboundTag;
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
