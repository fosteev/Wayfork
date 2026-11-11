import 'package:wayfork/core/model/rule_list.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/local_networks.dart';

/// Problems the UI shows as chips next to a rule.
sealed class RuleIssue {
  const RuleIssue();

  /// Same pattern and match as an earlier rule in the same group.
  const factory RuleIssue.duplicate(String of) = RuleIssueDuplicate;

  /// Same pattern and match as an active rule in an earlier group. Direct is
  /// first, so the later rule can never match.
  const factory RuleIssue.shadowed(String by) = RuleIssueShadowed;

  /// The rule is inert because its tunnel (or group, F16 — also: a group
  /// with no enabled member) is disabled.
  const factory RuleIssue.tunnelDisabled() = RuleIssueTunnelDisabled;

  /// The rule points at a tunnel or group which no longer exists.
  const factory RuleIssue.tunnelMissing() = RuleIssueTunnelMissing;

  /// The pattern covers tunnel control traffic, which would try to route the
  /// tunnel through a tunnel.
  const factory RuleIssue.coversTunnelServer(String tunnelName) =
      RuleIssueCoversTunnelServer;

  /// An IP rule overlaps one of the machine's own networks, so LAN devices in
  /// that range will go through the tunnel while Wayfork is on.
  const factory RuleIssue.coversLocalNetwork(String interface, String network) =
      RuleIssueCoversLocalNetwork;
}

final class RuleIssueDuplicate extends RuleIssue {
  const RuleIssueDuplicate(this.of);
  final String of;

  @override
  bool operator ==(Object other) =>
      other is RuleIssueDuplicate && of == other.of;
  @override
  int get hashCode => Object.hash(runtimeType, of);
}

final class RuleIssueShadowed extends RuleIssue {
  const RuleIssueShadowed(this.by);
  final String by;

  @override
  bool operator ==(Object other) =>
      other is RuleIssueShadowed && by == other.by;
  @override
  int get hashCode => Object.hash(runtimeType, by);
}

final class RuleIssueTunnelDisabled extends RuleIssue {
  const RuleIssueTunnelDisabled();

  @override
  bool operator ==(Object other) => other is RuleIssueTunnelDisabled;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class RuleIssueTunnelMissing extends RuleIssue {
  const RuleIssueTunnelMissing();

  @override
  bool operator ==(Object other) => other is RuleIssueTunnelMissing;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class RuleIssueCoversTunnelServer extends RuleIssue {
  const RuleIssueCoversTunnelServer(this.tunnelName);
  final String tunnelName;

  @override
  bool operator ==(Object other) =>
      other is RuleIssueCoversTunnelServer && tunnelName == other.tunnelName;
  @override
  int get hashCode => Object.hash(runtimeType, tunnelName);
}

final class RuleIssueCoversLocalNetwork extends RuleIssue {
  const RuleIssueCoversLocalNetwork(this.interface, this.network);
  final String interface;
  final String network;

  @override
  bool operator ==(Object other) =>
      other is RuleIssueCoversLocalNetwork &&
      interface == other.interface &&
      network == other.network;
  @override
  int get hashCode => Object.hash(runtimeType, interface, network);
}

/// Why the default tunnel is not taking everything else right now.
enum DefaultTunnelIssue { missing, disabled, missingSecret }

abstract final class RuleValidator {
  /// Issues per rule id. Rules without problems are absent.
  static Map<String, List<RuleIssue>> validate(
    Store store, {
    List<LocalNetwork> localNetworks = const [],
    Set<String>? routedExitIDs,
  }) {
    final issues = <String, List<RuleIssue>>{};
    final tunnelsByID = {for (final tunnel in store.tunnels) tunnel.id: tunnel};
    final groupsByID = {for (final group in store.groups) group.id: group};
    final candidates = _resolvedCandidates(store, routedExitIDs: routedExitIDs);
    final seen = <String, String>{};
    final earlier = <ResolvedRule>[];
    for (final row in candidates) {
      final rule = row.rule;
      final key = _key(row);
      final first = seen[key];
      if (first != null) {
        (issues[rule.id] ??= []).add(RuleIssue.duplicate(first));
        continue;
      }
      seen[key] = rule.id;
      ResolvedRule? winner;
      for (final other in earlier) {
        if (_covers(other.rule, rule)) {
          winner = other;
          break;
        }
      }
      if (winner != null) {
        (issues[rule.id] ??= []).add(RuleIssue.shadowed(winner.rule.id));
      } else {
        earlier.add(row);
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
      final exitID = store.targetFor(rule)?.exitID;
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
      if (routedExitIDs != null &&
          !routedExitIDs.contains(exitID) &&
          !(issues[rule.id]?.any(
                (issue) =>
                    issue is RuleIssueTunnelMissing ||
                    issue is RuleIssueTunnelDisabled,
              ) ??
              false)) {
        (issues[rule.id] ??= []).add(const RuleIssueMissingSecret());
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
    if (tunnel != null) {
      if (!tunnel.isEnabled) return DefaultTunnelIssue.disabled;
      return missingSecrets.contains(id)
          ? DefaultTunnelIssue.missingSecret
          : null;
    }
    final group = store.group(id);
    if (group == null) return DefaultTunnelIssue.missing;
    final members = store.enabledMembers(group);
    if (!group.isEnabled || members.isEmpty) return DefaultTunnelIssue.disabled;
    return members.every((member) => missingSecrets.contains(member.id))
        ? DefaultTunnelIssue.missingSecret
        : null;
  }

  static List<Rule> _activeRulesInOrder(Store store) => resolvedRules(
    store,
  ).map((row) => row.rule.copyWith(target: row.target)).toList();

  static String _key(ResolvedRule row) =>
      '${row.listID}|${row.rule.match.jsonValue}|${row.rule.pattern}|${row.rule.network?.jsonValue ?? 'both'}';
  static bool _covers(Rule earlier, Rule later) =>
      earlier.pattern == later.pattern &&
      earlier.match == later.match &&
      (earlier.network == null || earlier.network == later.network);

  static List<ResolvedRule> resolvedRules(
    Store store, {
    Set<String>? routedExitIDs,
  }) {
    final seen = <String>{};
    final active = <ResolvedRule>[];
    for (final row in _resolvedCandidates(
      store,
      routedExitIDs: routedExitIDs,
    )) {
      if (!seen.add(_key(row)) ||
          active.any((other) => _covers(other.rule, row.rule))) {
        continue;
      }
      active.add(row);
    }
    return active;
  }

  static Set<String> availableExitIDs(
    Store store, {
    Set<String> missingSecrets = const {},
  }) {
    final enabled = store.tunnels
        .where(
          (tunnel) => tunnel.isEnabled && !missingSecrets.contains(tunnel.id),
        )
        .map((tunnel) => tunnel.id)
        .toSet();
    return {
      ...enabled,
      ...store.groups
          .where(
            (group) => group.isEnabled && group.members.any(enabled.contains),
          )
          .map((group) => group.id),
    };
  }

  static List<ResolvedRule> _resolvedCandidates(
    Store store, {
    Set<String>? routedExitIDs,
  }) {
    final available = routedExitIDs ?? availableExitIDs(store);
    final rows = <ResolvedRule>[];
    for (final list in store.lists.where((list) => list.isEnabled)) {
      for (final rule
          in store.rulesIn(list.id).where((rule) => rule.isEnabled)) {
        final binding = rule.target == null
            ? list.target
            : RuleListExit(rule.target!);
        final RuleTarget target;
        if (binding case RuleListExit(:final exit)) {
          target = exit;
        } else {
          final id = store.defaultTunnelID;
          target = id != null && available.contains(id)
              ? (store.tunnel(id) != null
                    ? RuleTargetTunnel(id)
                    : RuleTargetGroup(id))
              : const RuleTargetDirect();
        }
        if (target.exitID != null && !available.contains(target.exitID)) {
          continue;
        }
        rows.add(
          ResolvedRule(
            rule: rule,
            listID: list.id,
            target: target,
            isException: binding == const RuleListExit(RuleTargetDirect()),
          ),
        );
      }
    }
    return [
      ...rows.where((row) => row.isException),
      ...rows.where((row) => !row.isException),
    ];
  }
}

final class RuleIssueMissingSecret extends RuleIssue {
  const RuleIssueMissingSecret();
  @override
  bool operator ==(Object other) => other is RuleIssueMissingSecret;
  @override
  int get hashCode => runtimeType.hashCode;
}

final class ResolvedRule {
  const ResolvedRule({
    required this.rule,
    required this.listID,
    required this.target,
    required this.isException,
  });
  final Rule rule;
  final String listID;
  final RuleTarget target;
  final bool isException;
  String get outboundTag => switch (target) {
    RuleTargetDirect() => 'direct',
    RuleTargetTunnel(:final tunnelID) => 't-$tunnelID',
    RuleTargetGroup(:final groupID) => 'g-$groupID',
  };
  String get tag => 'rules-r-${rule.id}';
  String get fileName => '$tag.json';
}
