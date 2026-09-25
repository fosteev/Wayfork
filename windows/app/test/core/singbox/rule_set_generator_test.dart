import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/singbox/rule_set_generator.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

import '../fixtures.dart';

void main() {
  test('app rules are emitted as a separate rule', () {
    final rules = [
      Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID),
      Rule.tunnel(
        pattern: '/Applications/Telegram.app',
        match: RuleMatch.app,
        tunnelID: Fixtures.workID,
      ),
    ];
    final objects = _ruleObjects(
      RuleSetGenerator.render(rules, platform: WayforkPlatform.macOS),
    );
    expect(objects, hasLength(2));
    expect(objects[0].keys.toList()..sort(), ['domain', 'domain_suffix']);
    expect(objects[1].keys.toList(), ['process_path_regex']);
    expect(objects[1]['process_path_regex'], [
      r'^/Applications/Telegram\.app/',
    ]);

    final appOnly = _ruleObjects(
      RuleSetGenerator.render([rules[1]], platform: WayforkPlatform.macOS),
    );
    expect(appOnly, hasLength(1));
    expect(appOnly[0].keys.toList(), ['process_path_regex']);

    final direct = _ruleObjects(
      RuleSetGenerator.renderDirect(
        exceptions: [
          Rule(
            pattern: '/Applications/Bank.app',
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
          ),
        ],
        platform: WayforkPlatform.macOS,
      ),
    );
    expect(direct, hasLength(2));
    expect(direct[0]['domain'], RuleSetGenerator.builtInDirectDomains);
    expect(direct[1]['process_path_regex'], [r'^/Applications/Bank\.app/']);
  });

  test('IP rule sets are separate files', () {
    final rules = [
      Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID),
      Rule.tunnel(
        pattern: '10.8.0.0/24',
        match: RuleMatch.ip,
        tunnelID: Fixtures.workID,
      ),
      Rule.tunnel(
        pattern: '203.0.113.7',
        match: RuleMatch.ip,
        tunnelID: Fixtures.workID,
      ),
      Rule.tunnel(
        pattern: '172.16.0.0/12',
        match: RuleMatch.ip,
        tunnelID: Fixtures.workID,
      ),
    ];
    final domains = _ruleObjects(RuleSetGenerator.render(rules));
    expect(domains, hasLength(1));
    expect(domains[0].containsKey('ip_cidr'), isFalse);

    final ip = _ruleObjects(RuleSetGenerator.renderIP(rules));
    expect(ip, hasLength(1));
    final ranges = (ip[0]['ip_cidr']! as List<Object?>).cast<String>();
    expect(ranges.take(2), ['10.8.0.0/24', '203.0.113.7/32']);
    final tun = IPv4Prefix.parse('172.19.0.0/30')!;
    expect(ranges, isNot(contains('172.16.0.0/12')));
    expect(ranges, contains('172.24.0.0/13'));
    expect(
      ranges
          .map(IPv4Prefix.parse)
          .whereType<IPv4Prefix>()
          .any((range) => range.contains(tun)),
      isFalse,
    );
    expect(_ruleObjects(RuleSetGenerator.renderIP([rules[0]])), isEmpty);

    final files = RuleSetGenerator.generate(
      tunnels: [Fixtures.work],
      activeRules: {Fixtures.workID: rules},
      exceptions: [
        Rule(
          pattern: '192.0.2.0/24',
          match: RuleMatch.ip,
          target: const RuleTargetDirect(),
        ),
      ],
    );
    expect(
      files.keys.toList()..sort(),
      [
        'rules-direct-ip.json',
        'rules-direct.json',
        Fixtures.work.ipRuleSetFileName,
        Fixtures.work.ruleSetFileName,
      ]..sort(),
    );
    expect(_ruleObjects(files['rules-direct-ip.json']!)[0]['ip_cidr'], [
      '192.0.2.0/24',
    ]);
    expect(files.values.every((text) => text.endsWith('\n')), isTrue);
  });
}

List<Map<String, Object?>> _ruleObjects(String text) {
  final object = jsonDecode(text)! as Map<String, Object?>;
  return (object['rules']! as List<Object?>).cast<Map<String, Object?>>();
}
