import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/local_networks.dart';
import 'package:wayfork/core/rules/rule_validator.dart';

abstract final class LegacyRuleValidator {
  /// Issues per rule id. Rules without problems are absent.
  static Map<String, List<RuleIssue>> validate(
    Store store, {
    List<LocalNetwork> localNetworks = const [],
  }) {
    final issues = <String, List<RuleIssue>>{};
    final tunnelsByID = {for (final tunnel in store.tunnels) tunnel.id: tunnel};
    final groupsByID = {for (final group in store.groups) group.id: group};
    // Section order for shadowing: Direct first, then tunnels, then groups
    // (F16), each in store order.
    final groupOrder = <RuleTarget, int>{const RuleTargetDirect(): 0};
    for (var index = 0; index < store.tunnels.length; index++) {
      groupOrder[RuleTargetTunnel(store.tunnels[index].id)] = index + 1;
    }
    for (var index = 0; index < store.groups.length; index++) {
      groupOrder[RuleTargetGroup(store.groups[index].id)] =
          store.tunnels.length + index + 1;
    }
    bool isSectionActive(RuleTarget target) => switch (target) {
      RuleTargetDirect() => true,
      RuleTargetTunnel(:final tunnelID) =>
        tunnelsByID[tunnelID]?.isEnabled == true,
      RuleTargetGroup(:final groupID) => switch (groupsByID[groupID]) {
        null => false,
        final group =>
          group.isEnabled && store.enabledMembers(group).isNotEmpty,
      },
    };

    final seen = <_RuleKey, String>{};
    final duplicates = <String>{};
    for (final rule in store.rules) {
      final key = _RuleKey(rule, rule.target!);
      final first = seen[key];
      if (first != null) {
        (issues[rule.id] ??= []).add(RuleIssue.duplicate(first));
        duplicates.add(rule.id);
      } else {
        seen[key] = rule.id;
      }
    }

    // Shadowing: an active rule is shadowed by an earlier one in the
    // effective order with the same pattern and match whose network covers
    // its own (F23). The order is a rank (Direct both 0, Direct narrowed 1,
    // exit narrowed 2, exit both 3), then the section order; without narrowed
    // rules that is the plain section order.
    final active = <_PatternKey, List<_Candidate>>{};
    for (final rule in store.legacyEffectiveRules) {
      final activeGroup = isSectionActive(rule.target!);
      final group = groupOrder[rule.target];
      if (!rule.isEnabled ||
          duplicates.contains(rule.id) ||
          !activeGroup ||
          group == null) {
        continue;
      }
      final narrowed = rule.network != null;
      final rank = rule.isException ? (narrowed ? 1 : 0) : (narrowed ? 2 : 3);
      (active[_PatternKey(rule)] ??= []).add(
        _Candidate(rule.id, rule.network, rank, group),
      );
    }
    for (final candidates in active.values) {
      for (final candidate in candidates) {
        _Candidate? earlier;
        for (final other in candidates) {
          if (other.ruleID != candidate.ruleID &&
              other.precedes(candidate) &&
              (other.network == null || other.network == candidate.network)) {
            earlier = other;
            break;
          }
        }
        if (earlier != null) {
          (issues[candidate.ruleID] ??= []).add(
            RuleIssue.shadowed(earlier.ruleID),
          );
        }
      }
    }

    final serverNames = <({String host, String tunnel})>[];
    final serverAddresses = <({IPv4Prefix address, String tunnel})>[];
    for (final tunnel in store.tunnels) {
      for (final host in tunnel.kind.serverHosts) {
        final address = IPv4Prefix.parse(host);
        if (address != null) {
          serverAddresses.add((address: address, tunnel: tunnel.name));
        } else {
          try {
            serverNames.add((
              host: RulePattern.normalize(host, match: RuleMatch.exact),
              tunnel: tunnel.name,
            ));
          } on RulePatternException {
            // Invalid server names are diagnosed by their importer, not by rules.
          }
        }
      }
    }

    for (final rule in store.rules) {
      final exitID = rule.exitID;
      if (exitID == null) continue;
      final tunnel = tunnelsByID[exitID];
      final group = groupsByID[exitID];
      if (tunnel != null) {
        if (!tunnel.isEnabled) {
          (issues[rule.id] ??= []).add(const RuleIssue.tunnelDisabled());
        }
      } else if (group != null) {
        if (!group.isEnabled || store.enabledMembers(group).isEmpty) {
          (issues[rule.id] ??= []).add(const RuleIssue.tunnelDisabled());
        }
      } else {
        (issues[rule.id] ??= []).add(const RuleIssue.tunnelMissing());
      }
      if (rule.isIP) {
        final range = IPv4Prefix.parse(rule.pattern);
        if (range == null) continue;
        for (final server in serverAddresses) {
          if (range.contains(server.address)) {
            (issues[rule.id] ??= []).add(
              RuleIssue.coversTunnelServer(server.tunnel),
            );
          }
        }
        for (final network in localNetworks) {
          if (range.overlaps(network.prefix)) {
            (issues[rule.id] ??= []).add(
              RuleIssue.coversLocalNetwork(
                network.interface,
                network.prefix.toString(),
              ),
            );
          }
        }
      } else {
        for (final server in serverNames) {
          if (RulePattern.matches(
            host: server.host,
            pattern: rule.pattern,
            match: rule.match,
          )) {
            (issues[rule.id] ??= []).add(
              RuleIssue.coversTunnelServer(server.tunnel),
            );
          }
        }
      }
    }
    return issues;
  }

  /// Active tunnel and group rules keyed by the tunnel or group id, in
  /// effective order.
  static Map<String, List<Rule>> activeRules(Store store) {
    final result = <String, List<Rule>>{};
    for (final rule in _activeRulesInOrder(store)) {
      final exitID = rule.exitID;
      if (exitID != null) (result[exitID] ??= []).add(rule);
    }
    return result;
  }

  /// Active Direct rules, in list order.
  static List<Rule> activeExceptions(Store store) =>
      _activeRulesInOrder(store).where((rule) => rule.isException).toList();

  static DefaultTunnelIssue? defaultTunnelIssue(
    Store store, {
    Set<String> missingSecrets = const {},
  }) {
    final id = store.defaultTunnelID;
    if (id == null) return null;
    final tunnel = store.tunnel(id);
    if (tunnel == null) return DefaultTunnelIssue.missing;
    if (!tunnel.isEnabled) return DefaultTunnelIssue.disabled;
    return missingSecrets.contains(id)
        ? DefaultTunnelIssue.missingSecret
        : null;
  }

  static List<Rule> _activeRulesInOrder(Store store) {
    final issues = validate(store);
    return store.legacyEffectiveRules.where((rule) {
      if (!rule.isEnabled) return false;
      final blocking = issues[rule.id]?.any(
        (issue) =>
            issue is RuleIssueDuplicate ||
            issue is RuleIssueShadowed ||
            issue is RuleIssueTunnelDisabled ||
            issue is RuleIssueTunnelMissing,
      );
      return blocking != true;
    }).toList();
  }
}

final class _RuleKey {
  const _RuleKey._(this.pattern, this.match, this.network, this.target);
  factory _RuleKey(Rule rule, RuleTarget target) =>
      _RuleKey._(rule.pattern, rule.match, rule.network, target);

  final String pattern;
  final RuleMatch match;
  final RuleNetwork? network;
  final RuleTarget target;

  @override
  bool operator ==(Object other) =>
      other is _RuleKey &&
      pattern == other.pattern &&
      match == other.match &&
      network == other.network &&
      target == other.target;
  @override
  int get hashCode => Object.hash(pattern, match, network, target);
}

final class _PatternKey {
  _PatternKey(Rule rule) : pattern = rule.pattern, match = rule.match;

  final String pattern;
  final RuleMatch match;

  @override
  bool operator ==(Object other) =>
      other is _PatternKey && pattern == other.pattern && match == other.match;
  @override
  int get hashCode => Object.hash(pattern, match);
}

final class _Candidate {
  const _Candidate(this.ruleID, this.network, this.rank, this.group);

  final String ruleID;
  final RuleNetwork? network;
  final int rank;
  final int group;

  bool precedes(_Candidate other) =>
      rank < other.rank || (rank == other.rank && group < other.group);
}
