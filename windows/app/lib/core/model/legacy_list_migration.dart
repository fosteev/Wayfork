import 'package:characters/characters.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/rule_list.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/rules/legacy_rule_validator.dart';
import 'package:wayfork/core/rules/rule_validator.dart';

/// Pure G1 migration. Only legacy duplicates are archived; shadowed rows remain fallback.
abstract final class LegacyListMigration {
  static Store migrate(Store source) {
    if (source.rules.any((rule) => rule.target == null) ||
        source.rules.map((rule) => rule.id).toSet().length !=
            source.rules.length) {
      return source;
    }
    final suppressed = LegacyRuleValidator.validate(source).entries
        .where(
          (entry) => entry.value.any((issue) => issue is RuleIssueDuplicate),
        )
        .map((entry) => entry.key)
        .toSet();
    final exits = <RuleTarget>[
      ...source.tunnels.map((tunnel) => RuleTargetTunnel(tunnel.id)),
      ...source.groups.map((group) => RuleTargetGroup(group.id)),
    ];
    final known = {...exits, const RuleTargetDirect()};
    final unknown = source.rules
        .map((rule) => rule.target!)
        .where((target) => !known.contains(target))
        .toSet()
        .toList();
    final normal = source.rules
        .where((rule) => !suppressed.contains(rule.id))
        .toList();
    var result = source.copyWith(schemaVersion: 4, lists: [], rules: []);
    void add(
      List<Rule> rows,
      RuleTarget target, {
      String suffix = '',
      bool paused = false,
    }) {
      if (rows.isEmpty) return;
      final base = target.exitID == null
          ? 'Direct'
          : source.exitName(target.exitID!) ?? 'Unknown exit';
      final keep = 40 - suffix.length;
      final name = result.availableListName(
        '${base.characters.take(keep).toString()}$suffix',
      );
      result = result.copyWith(
        lists: [
          ...result.lists,
          RuleList(
            id: rows.first.id,
            name: name,
            target: RuleListExit(target),
            isEnabled: !paused,
            showInMenu: !paused,
          ),
        ],
        rules: [
          ...result.rules,
          ...rows.map(
            (row) => row.copyWith(listID: rows.first.id, target: null),
          ),
        ],
      );
    }

    add(
      normal.where((row) => row.target is RuleTargetDirect).toList(),
      const RuleTargetDirect(),
    );
    for (final target in exits) {
      final rows = normal.where((row) => row.target == target).toList();
      add(
        [
          for (final network in RuleNetwork.values)
            ...rows.where((row) => row.network == network),
        ],
        target,
        suffix: rows.any((row) => row.network == null) ? ' — TCP/UDP' : '',
      );
    }
    for (final target in exits) {
      add(
        normal
            .where((row) => row.target == target && row.network == null)
            .toList(),
        target,
      );
    }
    for (final target in unknown) {
      add(normal.where((row) => row.target == target).toList(), target);
    }
    for (final target in [const RuleTargetDirect(), ...exits, ...unknown]) {
      add(
        source.rules
            .where((row) => row.target == target && suppressed.contains(row.id))
            .toList(),
        target,
        suffix: ' — Previously inactive',
        paused: true,
      );
    }
    return result;
  }
}
