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

  /// The rule is inert because its tunnel is disabled.
  const factory RuleIssue.tunnelDisabled() = RuleIssueTunnelDisabled;

  /// The rule points at a tunnel which no longer exists.
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
  }) {
    final issues = <String, List<RuleIssue>>{};
    final tunnelsByID = {for (final tunnel in store.tunnels) tunnel.id: tunnel};
    final groupOrder = <RuleTarget, int>{const RuleTargetDirect(): 0};
    for (var index = 0; index < store.tunnels.length; index++) {
      groupOrder[RuleTargetTunnel(store.tunnels[index].id)] = index + 1;
    }

    final seen = <_RuleKey, String>{};
    final duplicates = <String>{};
    for (final rule in store.rules) {
      final key = _RuleKey(rule, rule.target);
      final first = seen[key];
      if (first != null) {
        (issues[rule.id] ??= []).add(RuleIssue.duplicate(first));
        duplicates.add(rule.id);
      } else {
        seen[key] = rule.id;
      }
    }

    final firstActive = <_RuleKey, ({String ruleID, int group})>{};
    for (final rule in store.effectiveRules) {
      final activeGroup =
          rule.target.isDirect ||
          (rule.tunnelID != null &&
              tunnelsByID[rule.tunnelID]?.isEnabled == true);
      final group = groupOrder[rule.target];
      if (!rule.isEnabled ||
          duplicates.contains(rule.id) ||
          !activeGroup ||
          group == null) {
        continue;
      }
      final key = _RuleKey(rule, null);
      final earlier = firstActive[key];
      if (earlier != null) {
        if (earlier.group < group) {
          (issues[rule.id] ??= []).add(RuleIssue.shadowed(earlier.ruleID));
        }
      } else {
        firstActive[key] = (ruleID: rule.id, group: group);
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
      final tunnelID = rule.tunnelID;
      if (tunnelID == null) continue;
      final tunnel = tunnelsByID[tunnelID];
      if (tunnel == null) {
        (issues[rule.id] ??= []).add(const RuleIssue.tunnelMissing());
      } else if (!tunnel.isEnabled) {
        (issues[rule.id] ??= []).add(const RuleIssue.tunnelDisabled());
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

  /// Active tunnel rules grouped by tunnel id, in effective order.
  static Map<String, List<Rule>> activeRules(Store store) {
    final result = <String, List<Rule>>{};
    for (final rule in _activeRulesInOrder(store)) {
      final tunnelID = rule.tunnelID;
      if (tunnelID != null) (result[tunnelID] ??= []).add(rule);
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
    return store.effectiveRules.where((rule) {
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
  const _RuleKey._(this.pattern, this.match, this.target);
  factory _RuleKey(Rule rule, RuleTarget? target) =>
      _RuleKey._(rule.pattern, rule.match, target);

  final String pattern;
  final RuleMatch match;
  final RuleTarget? target;

  @override
  bool operator ==(Object other) =>
      other is _RuleKey &&
      pattern == other.pattern &&
      match == other.match &&
      target == other.target;
  @override
  int get hashCode => Object.hash(pattern, match, target);
}
