import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/support/uuid.dart';

sealed class RuleListTarget {
  const RuleListTarget();
}

final class RuleListExit extends RuleListTarget {
  const RuleListExit(this.exit);
  final RuleTarget exit;
  @override
  bool operator ==(Object other) => other is RuleListExit && exit == other.exit;
  @override
  int get hashCode => exit.hashCode;
}

final class RuleListEverythingElse extends RuleListTarget {
  const RuleListEverythingElse();
  @override
  bool operator ==(Object other) => other is RuleListEverythingElse;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class RuleList {
  RuleList({
    String? id,
    required this.name,
    this.color,
    required this.target,
    this.isEnabled = true,
    this.showInMenu = true,
  }) : id = _uuid(id ?? Uuid.generate());

  factory RuleList.fromJson(Map<String, Object?> json) {
    final bindings = [
      'target',
      'tunnelID',
      'groupID',
    ].where(json.containsKey).toList();
    if (bindings.length != 1 || json[bindings.single] == null) {
      throw const FormatException('List needs exactly one binding');
    }
    final RuleListTarget target;
    if (json['target'] == 'everythingElse') {
      target = const RuleListEverythingElse();
    } else if (json['target'] == 'direct') {
      target = const RuleListExit(RuleTargetDirect());
    } else if (json['tunnelID'] case final String id) {
      target = RuleListExit(RuleTargetTunnel(id));
    } else if (json['groupID'] case final String id) {
      target = RuleListExit(RuleTargetGroup(id));
    } else {
      throw const FormatException('Unknown list binding');
    }
    return RuleList(
      id: json['id'] as String,
      name: json['name'] as String,
      color: json['color'] as int?,
      target: target,
      isEnabled: json['isEnabled'] as bool,
      showInMenu: json['showInMenu'] as bool,
    );
  }
  final String id;
  final String name;
  final int? color;
  final RuleListTarget target;
  final bool isEnabled;
  final bool showInMenu;
  Map<String, Object?> toJson() => {
    'id': Uuid.encode(id),
    'name': name,
    if (color != null) 'color': color,
    'isEnabled': isEnabled,
    'showInMenu': showInMenu,
    ...switch (target) {
      RuleListEverythingElse() => {'target': 'everythingElse'},
      RuleListExit(exit: RuleTargetDirect()) => {'target': 'direct'},
      RuleListExit(exit: RuleTargetTunnel(:final tunnelID)) => {
        'tunnelID': Uuid.encode(tunnelID),
      },
      RuleListExit(exit: RuleTargetGroup(:final groupID)) => {
        'groupID': Uuid.encode(groupID),
      },
    },
  };
  RuleList copyWith({
    String? id,
    String? name,
    Object? color = _unset,
    RuleListTarget? target,
    bool? isEnabled,
    bool? showInMenu,
  }) => RuleList(
    id: id ?? this.id,
    name: name ?? this.name,
    color: identical(color, _unset) ? this.color : color as int?,
    target: target ?? this.target,
    isEnabled: isEnabled ?? this.isEnabled,
    showInMenu: showInMenu ?? this.showInMenu,
  );
  @override
  bool operator ==(Object other) =>
      other is RuleList &&
      id == other.id &&
      name == other.name &&
      color == other.color &&
      target == other.target &&
      isEnabled == other.isEnabled &&
      showInMenu == other.showInMenu;
  @override
  int get hashCode =>
      Object.hash(id, name, color, target, isEnabled, showInMenu);
}

const _unset = Object();
String _uuid(String id) =>
    Uuid.normalize(id) ?? (throw const FormatException('Invalid list UUID'));
