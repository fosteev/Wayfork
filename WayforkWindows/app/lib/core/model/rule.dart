import 'package:wayfork/core/support/uuid.dart';

enum RuleMatch {
  suffix('suffix'),
  exact('exact'),
  wildcard('wildcard'),
  app('app'),
  ip('ip');

  const RuleMatch(this.jsonValue);

  final String jsonValue;

  static const typedCases = [suffix, exact, wildcard, ip];

  bool get isApp => this == app;
  bool get isIP => this == ip;

  static RuleMatch fromJson(Object? value) {
    if (value is String) {
      for (final match in values) {
        if (match.jsonValue == value) return match;
      }
    }
    throw FormatException('Unknown rule match: $value');
  }
}

sealed class RuleTarget {
  const RuleTarget();

  String? get tunnelID;
  bool get isDirect;
}

final class RuleTargetTunnel extends RuleTarget {
  RuleTargetTunnel(String tunnelID) : tunnelID = _uuid(tunnelID, 'tunnelID');

  @override
  final String tunnelID;

  @override
  bool get isDirect => false;

  @override
  bool operator ==(Object other) =>
      other is RuleTargetTunnel && tunnelID == other.tunnelID;

  @override
  int get hashCode => tunnelID.hashCode;
}

final class RuleTargetDirect extends RuleTarget {
  const RuleTargetDirect();

  @override
  String? get tunnelID => null;

  @override
  bool get isDirect => true;

  @override
  bool operator ==(Object other) => other is RuleTargetDirect;

  @override
  int get hashCode => 0;
}

final class Rule {
  factory Rule({
    String? id,
    required String pattern,
    RuleMatch match = RuleMatch.suffix,
    required RuleTarget target,
    bool isEnabled = true,
    String? note,
  }) => Rule._(
    id: _uuid(id ?? Uuid.generate(), 'id'),
    pattern: pattern,
    match: match,
    target: target,
    isEnabled: isEnabled,
    note: note,
  );

  factory Rule.tunnel({
    String? id,
    required String pattern,
    RuleMatch match = RuleMatch.suffix,
    required String tunnelID,
    bool isEnabled = true,
    String? note,
  }) => Rule(
    id: id,
    pattern: pattern,
    match: match,
    target: RuleTargetTunnel(tunnelID),
    isEnabled: isEnabled,
    note: note,
  );

  const Rule._({
    required this.id,
    required this.pattern,
    required this.match,
    required this.target,
    required this.isEnabled,
    required this.note,
  });

  factory Rule.fromJson(Map<String, Object?> json) {
    final targetName = json['target'];
    final RuleTarget target;
    if (targetName != null) {
      if (targetName != 'direct') {
        throw FormatException('Unknown rule target "$targetName"');
      }
      target = const RuleTargetDirect();
    } else if (json['tunnelID'] case final String tunnelID) {
      target = RuleTargetTunnel(tunnelID);
    } else {
      throw const FormatException('Rule needs a tunnelID or target: direct');
    }
    return Rule(
      id: _requiredString(json, 'id'),
      pattern: _requiredString(json, 'pattern'),
      match: RuleMatch.fromJson(json['match']),
      target: target,
      isEnabled: _requiredBool(json, 'isEnabled'),
      note: _optionalString(json, 'note'),
    );
  }

  final String id;
  final String pattern;
  final RuleMatch match;
  final RuleTarget target;
  final bool isEnabled;
  final String? note;

  String? get tunnelID => target.tunnelID;
  bool get isException => target.isDirect;
  bool get isApp => match.isApp;
  bool get isIP => match.isIP;

  Map<String, Object?> toJson() => {
    'id': Uuid.encode(id),
    'pattern': pattern,
    'match': match.jsonValue,
    if (target case RuleTargetTunnel(:final tunnelID))
      'tunnelID': Uuid.encode(tunnelID)
    else
      'target': 'direct',
    'isEnabled': isEnabled,
    if (note != null) 'note': note,
  };

  Rule copyWith({
    String? id,
    String? pattern,
    RuleMatch? match,
    RuleTarget? target,
    bool? isEnabled,
    Object? note = _unset,
  }) => Rule(
    id: id ?? this.id,
    pattern: pattern ?? this.pattern,
    match: match ?? this.match,
    target: target ?? this.target,
    isEnabled: isEnabled ?? this.isEnabled,
    note: identical(note, _unset) ? this.note : note as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is Rule &&
      id == other.id &&
      pattern == other.pattern &&
      match == other.match &&
      target == other.target &&
      isEnabled == other.isEnabled &&
      note == other.note;

  @override
  int get hashCode => Object.hash(id, pattern, match, target, isEnabled, note);
}

const _unset = Object();

String _uuid(String value, String name) {
  final normalized = Uuid.normalize(value);
  if (normalized == null) throw FormatException('$name must be a UUID');
  return normalized;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('$key must be a string or null');
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}
