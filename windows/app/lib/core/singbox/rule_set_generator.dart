import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/model/tunnel_group.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

/// Produces domain/application and route-only IP rule-set files.
abstract final class RuleSetGenerator {
  static const version = 3;

  /// Tag and file of the Direct rule-set: user exceptions plus local names.
  static const directTag = 'rules-direct';
  static const directFileName = 'rules-direct.json';

  /// Tag and file of the Direct IP rule-set.
  static const directIPTag = 'rules-direct-ip';
  static const directIPFileName = 'rules-direct-ip.json';

  /// Tag and file of the Direct rule-set narrowed to one transport (F23).
  static String directNarrowedTag(RuleNetwork network) =>
      'rules-direct-${network.jsonValue}';
  static String directNarrowedFileName(RuleNetwork network) =>
      '${directNarrowedTag(network)}.json';

  /// Built-in exceptions: names that must never leave the local network.
  static const builtInDirectSuffixes = [
    '.local',
    '.lan',
    '.internal',
    '.home.arpa',
    '.localhost',
  ];
  static const builtInDirectDomains = ['localhost'];

  /// Emits two files per tunnel plus the two Direct files, even when empty.
  static Map<String, String> generate({
    required List<Tunnel> tunnels,
    required Map<String, List<Rule>> activeRules,
    List<Rule> exceptions = const [],
    WayforkPlatform platform = WayforkPlatform.windows,
  }) => generateForExits(
    exits: tunnels.map(RoutedExit.tunnel).toList(),
    activeRules: activeRules,
    exceptions: exceptions,
    platform: platform,
  );

  /// The same for tunnels and groups alike (F16): `rules-t-<id>` /
  /// `rules-g-<id>`.
  static Map<String, String> generateForExits({
    required List<RoutedExit> exits,
    required Map<String, List<Rule>> activeRules,
    List<Rule> exceptions = const [],
    WayforkPlatform platform = WayforkPlatform.windows,
  }) {
    final files = <String, String>{
      directFileName: renderDirect(exceptions: exceptions, platform: platform),
      directIPFileName: renderIP(exceptions),
    };
    for (final exit in exits) {
      final rules = activeRules[exit.id] ?? const [];
      files[exit.ruleSetFileName] = render(rules, platform: platform);
      files[exit.ipRuleSetFileName] = renderIP(rules);
      for (final network in RuleNetwork.values) {
        final text = renderNarrowed(rules, network, platform: platform);
        if (text != null) files[exit.narrowedRuleSetFileName(network)] = text;
      }
    }
    for (final network in RuleNetwork.values) {
      final text = renderNarrowed(exceptions, network, platform: platform);
      if (text != null) files[directNarrowedFileName(network)] = text;
    }
    return files;
  }

  /// F23: the app and IP rules narrowed to `network`, route-only like the
  /// `-ip` files: a `process_path_regex` rule and an `ip_cidr` rule (same
  /// reserved-range subtraction as [renderIP]), each only when non-empty.
  /// Null when there is no such rule, so the caller emits neither the file nor
  /// its route rule.
  static String? renderNarrowed(
    List<Rule> rules,
    RuleNetwork network, {
    WayforkPlatform platform = WayforkPlatform.windows,
  }) {
    final narrowed = rules.where((rule) => rule.network == network).toList();
    final paths = [
      for (final rule in narrowed.where((rule) => rule.isApp))
        platform.appPathRegex(rule.pattern),
    ];
    final ranges = <String>[];
    for (final rule in narrowed.where((rule) => rule.isIP)) {
      final prefix = IPv4Prefix.parse(rule.pattern);
      if (prefix == null) continue;
      ranges.addAll(
        prefix
            .subtractingAll(RulePattern.reservedRanges)
            .map((value) => value.toString()),
      );
    }
    final ruleObjects = <Object?>[
      if (paths.isNotEmpty) <String, Object?>{'process_path_regex': paths},
      if (ranges.isNotEmpty) <String, Object?>{'ip_cidr': ranges},
    ];
    if (ruleObjects.isEmpty) return null;
    return '${JsonText.render(<String, Object?>{'version': version, 'rules': ruleObjects})}\n';
  }

  /// IP rules live in route-only twins. Reserved ranges are carved from wide
  /// patterns so they cannot capture Wayfork or unroutable addresses.
  static String renderIP(List<Rule> rules) {
    final ranges = <String>[];
    for (final rule in rules.where(
      (rule) => rule.isIP && rule.network == null,
    )) {
      final prefix = IPv4Prefix.parse(rule.pattern);
      if (prefix == null) continue;
      ranges.addAll(
        prefix
            .subtractingAll(RulePattern.reservedRanges)
            .map((value) => value.toString()),
      );
    }
    return '${JsonText.render(<String, Object?>{
      'version': version,
      'rules': ranges.isEmpty ? <Object?>[] : <Object?>[
              <String, Object?>{'ip_cidr': ranges},
            ],
    })}\n';
  }

  /// Domain and application rules are separate objects because sing-box ANDs
  /// different matcher kinds within one object and ORs objects in a set.
  static String render(
    List<Rule> rules, {
    WayforkPlatform platform = WayforkPlatform.windows,
  }) =>
      _render(rules, domains: const [], suffixes: const [], platform: platform);

  /// Built-in local names precede the user's Direct exceptions.
  static String renderDirect({
    List<Rule> exceptions = const [],
    WayforkPlatform platform = WayforkPlatform.windows,
  }) => _render(
    exceptions,
    domains: builtInDirectDomains,
    suffixes: builtInDirectSuffixes,
    platform: platform,
  );

  static String _render(
    List<Rule> rules, {
    required List<String> domains,
    required List<String> suffixes,
    required WayforkPlatform platform,
  }) {
    final domain = [...domains];
    final domainSuffix = [...suffixes];
    final domainRegex = <String>[];
    final processPathRegex = <String>[];
    for (final rule in rules.where((rule) => rule.network == null)) {
      switch (rule.match) {
        case RuleMatch.exact:
          domain.add(rule.pattern);
        case RuleMatch.suffix:
          domain.add(rule.pattern);
          domainSuffix.add('.${rule.pattern}');
        case RuleMatch.wildcard:
          domainRegex.add(RulePattern.wildcardRegex(rule.pattern));
        case RuleMatch.app:
          processPathRegex.add(platform.appPathRegex(rule.pattern));
        case RuleMatch.ip:
          break;
      }
    }

    final domainRule = <String, Object?>{
      if (domain.isNotEmpty) 'domain': domain,
      if (domainSuffix.isNotEmpty) 'domain_suffix': domainSuffix,
      if (domainRegex.isNotEmpty) 'domain_regex': domainRegex,
    };
    final ruleObjects = <Object?>[
      if (domainRule.isNotEmpty) domainRule,
      if (processPathRegex.isNotEmpty)
        <String, Object?>{'process_path_regex': processPathRegex},
    ];
    return '${JsonText.render(<String, Object?>{'version': version, 'rules': ruleObjects})}\n';
  }
}
