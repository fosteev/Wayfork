import 'package:collection/collection.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/local_proxy.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/uuid.dart';

/// How a group picks the member that carries its traffic (F16).
enum GroupPolicy {
  /// sing-box `urltest`: the member with the lowest probe latency, with
  /// hysteresis.
  fastest('fastest'),

  /// A `selector` the service points at the first member whose probe passes.
  firstLive('firstLive');

  const GroupPolicy(this.jsonValue);

  final String jsonValue;

  static GroupPolicy fromJson(Object? value) {
    if (value is String) {
      for (final policy in values) {
        if (policy.jsonValue == value) return policy;
      }
    }
    throw FormatException('Unknown group policy: $value');
  }
}

/// Several tunnels behind one name (F16, docs/design/01-data-model.md, "Tunnel
/// groups"). Shares the UUID space with tunnels: a rule target or
/// `Store.defaultTunnelID` names either.
final class TunnelGroup {
  factory TunnelGroup({
    String? id,
    required String name,
    bool isEnabled = true,
    required List<String> members,
    GroupPolicy policy = GroupPolicy.fastest,
    DateTime? createdAt,
    LocalProxy? localProxy,
  }) => TunnelGroup._(
    id: _uuid(id ?? Uuid.generate(), 'id'),
    name: name,
    isEnabled: isEnabled,
    members: List.unmodifiable(
      members.map((member) => _uuid(member, 'member')),
    ),
    policy: policy,
    createdAt: createdAt == null
        ? _wholeSeconds(DateTime.now())
        : createdAt.toUtc(),
    localProxy: localProxy,
  );

  const TunnelGroup._({
    required this.id,
    required this.name,
    required this.isEnabled,
    required this.members,
    required this.policy,
    required this.createdAt,
    required this.localProxy,
  });

  factory TunnelGroup.fromJson(Map<String, Object?> json) {
    final members = json['members'];
    if (members is! List<Object?>) {
      throw const FormatException('members must be an array');
    }
    final localProxy = json['localProxy'];
    return TunnelGroup(
      id: _string(json, 'id'),
      name: _string(json, 'name'),
      isEnabled: _bool(json, 'isEnabled'),
      members: members.map((value) => _stringValue(value, 'member')).toList(),
      policy: GroupPolicy.fromJson(json['policy']),
      createdAt: JsonCoding.decodeDate(_string(json, 'createdAt')),
      localProxy: localProxy == null
          ? null
          : LocalProxy.fromJson(_map(localProxy, 'localProxy')),
    );
  }

  static const minimumMembers = 2;
  static const outboundTagPrefix = 'g-';

  final String id;

  /// Unique among tunnels and groups, 1…40 chars.
  final String name;
  final bool isEnabled;

  /// Tunnel ids in the user's order — never a group, no duplicates, at least
  /// two.
  final List<String> members;
  final GroupPolicy policy;
  final DateTime createdAt;

  /// F17: a loopback port that sends an app through this group; null = never
  /// turned on.
  final LocalProxy? localProxy;

  /// sing-box outbound tag: `g-<id>`.
  String get outboundTag => '$outboundTagPrefix$id';

  /// The group id behind an outbound tag; null for anything else.
  static String? groupID(String outboundTag) =>
      outboundTag.startsWith(outboundTagPrefix) &&
          outboundTag.length > outboundTagPrefix.length
      ? outboundTag.substring(outboundTagPrefix.length)
      : null;

  String get ruleSetTag => 'rules-$outboundTag';
  String get ruleSetFileName => '$ruleSetTag.json';
  String get ipRuleSetTag => '$ruleSetTag-ip';
  String get ipRuleSetFileName => '$ipRuleSetTag.json';

  Map<String, Object?> toJson() => {
    'id': Uuid.encode(id),
    'name': name,
    'isEnabled': isEnabled,
    'members': members.map(Uuid.encode).toList(),
    'policy': policy.jsonValue,
    'createdAt': JsonCoding.encodeDate(createdAt),
    if (localProxy != null) 'localProxy': localProxy!.toJson(),
  };

  TunnelGroup copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? members,
    GroupPolicy? policy,
    DateTime? createdAt,
    Object? localProxy = _unset,
  }) => TunnelGroup(
    id: id ?? this.id,
    name: name ?? this.name,
    isEnabled: isEnabled ?? this.isEnabled,
    members: members ?? this.members,
    policy: policy ?? this.policy,
    createdAt: createdAt ?? this.createdAt,
    localProxy: identical(localProxy, _unset)
        ? this.localProxy
        : localProxy as LocalProxy?,
  );

  @override
  bool operator ==(Object other) =>
      other is TunnelGroup &&
      id == other.id &&
      name == other.name &&
      isEnabled == other.isEnabled &&
      const ListEquality<String>().equals(members, other.members) &&
      policy == other.policy &&
      createdAt == other.createdAt &&
      localProxy == other.localProxy;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    isEnabled,
    const ListEquality<String>().hash(members),
    policy,
    createdAt,
    localProxy,
  );
}

/// What a rule can be sent through once the generator has decided what is
/// usable: a tunnel or a group, reduced to what the config and the rule-set
/// files need.
final class RoutedExit {
  RoutedExit.tunnel(Tunnel tunnel)
    : id = tunnel.id,
      name = tunnel.name,
      outboundTag = tunnel.outboundTag;

  RoutedExit.group(TunnelGroup group)
    : id = group.id,
      name = group.name,
      outboundTag = group.outboundTag;

  final String id;
  final String name;
  final String outboundTag;

  String get ruleSetTag => 'rules-$outboundTag';
  String get ruleSetFileName => '$ruleSetTag.json';
  String get ipRuleSetTag => '$ruleSetTag-ip';
  String get ipRuleSetFileName => '$ipRuleSetTag.json';
  bool get isGroup => outboundTag.startsWith(TunnelGroup.outboundTagPrefix);

  @override
  bool operator ==(Object other) =>
      other is RoutedExit &&
      id == other.id &&
      name == other.name &&
      outboundTag == other.outboundTag;

  @override
  int get hashCode => Object.hash(id, name, outboundTag);
}

const _unset = Object();

DateTime _wholeSeconds(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.toUtc().millisecondsSinceEpoch ~/ 1000 * 1000,
  isUtc: true,
);

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object');
}

String _string(Map<String, Object?> json, String key) =>
    _stringValue(json[key], key);

String _stringValue(Object? value, String name) {
  if (value is String) return value;
  throw FormatException('$name must be a string');
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
