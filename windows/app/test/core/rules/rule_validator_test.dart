import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/rules/rule_validator.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/local_networks.dart';

import '../fixtures.dart';

void main() {
  test('validator flags duplicates, shadows, and tunnel problems', () {
    final workRule = Rule.tunnel(
      pattern: 'example.com',
      tunnelID: Fixtures.workID,
    );
    final shadowed = Rule.tunnel(
      pattern: 'example.com',
      tunnelID: Fixtures.homeID,
    );
    final duplicate = Rule.tunnel(
      pattern: 'example.com',
      tunnelID: Fixtures.workID,
    );
    final orphan = Rule.tunnel(
      pattern: 'x.com',
      tunnelID: '00000000-0000-4000-8000-000000000099',
    );
    final coversServer = Rule.tunnel(
      pattern: 'example.org',
      tunnelID: Fixtures.homeID,
    );
    final differentMatch = Rule.tunnel(
      pattern: 'example.com',
      match: RuleMatch.exact,
      tunnelID: Fixtures.homeID,
    );
    final store = Fixtures.store(
      rules: [
        shadowed,
        workRule,
        duplicate,
        orphan,
        coversServer,
        differentMatch,
      ],
    );
    final issues = RuleValidator.validate(store);
    expect(issues[workRule.id], isNull);
    expect(issues[shadowed.id], [RuleIssue.shadowed(workRule.id)]);
    expect(issues[duplicate.id], [RuleIssue.duplicate(workRule.id)]);
    expect(issues[orphan.id], const [RuleIssue.tunnelMissing()]);
    expect(issues[coversServer.id], const [
      RuleIssue.coversTunnelServer('Work'),
    ]);
    expect(issues[differentMatch.id], isNull);
    final active = RuleValidator.activeRules(store);
    expect(active[Fixtures.workID]?.map((rule) => rule.id), [workRule.id]);
    expect(active[Fixtures.homeID]?.map((rule) => rule.id), [
      coversServer.id,
      differentMatch.id,
    ]);
  });

  test('disabled tunnel rules are inert', () {
    var store = Fixtures.store(
      rules: [
        Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID),
        Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.homeID),
      ],
    );
    store = store.copyWith(
      tunnels: [store.tunnels[0].copyWith(isEnabled: false), store.tunnels[1]],
    );
    final issues = RuleValidator.validate(store);
    expect(issues[store.rules[0].id], const [RuleIssue.tunnelDisabled()]);
    expect(issues[store.rules[1].id], isNull);
    expect(RuleValidator.activeRules(store)[Fixtures.homeID], hasLength(1));
    expect(RuleValidator.activeRules(store)[Fixtures.workID], isNull);
  });

  test('Direct is the first group', () {
    final exception = Rule(
      pattern: 'example.com',
      target: const RuleTargetDirect(),
    );
    final duplicateException = Rule(
      pattern: 'example.com',
      target: const RuleTargetDirect(),
    );
    final workRule = Rule.tunnel(
      pattern: 'example.com',
      tunnelID: Fixtures.workID,
    );
    final other = Rule.tunnel(pattern: 'other.com', tunnelID: Fixtures.workID);
    final coversServer = Rule(
      pattern: 'example.org',
      target: const RuleTargetDirect(),
    );
    final store = Fixtures.store(
      rules: [workRule, exception, duplicateException, other, coversServer],
    );
    final issues = RuleValidator.validate(store);
    expect(issues[exception.id], isNull);
    expect(issues[duplicateException.id], [RuleIssue.duplicate(exception.id)]);
    expect(issues[workRule.id], [RuleIssue.shadowed(exception.id)]);
    expect(issues[other.id], isNull);
    expect(issues[coversServer.id], isNull);
    expect(RuleValidator.activeExceptions(store).map((rule) => rule.id), [
      exception.id,
      coversServer.id,
    ]);
    expect(
      RuleValidator.activeRules(store)[Fixtures.workID]?.map((rule) => rule.id),
      [other.id],
    );

    final paused = store.copyWith(
      rules: [
        workRule,
        exception.copyWith(isEnabled: false),
        duplicateException.copyWith(isEnabled: false),
        other,
        coversServer,
      ],
    );
    expect(RuleValidator.validate(paused)[workRule.id], isNull);
    expect(RuleValidator.activeExceptions(paused).map((rule) => rule.id), [
      coversServer.id,
    ]);
  });

  test('default tunnel issues', () {
    var store = Fixtures.store();
    expect(RuleValidator.defaultTunnelIssue(store), isNull);
    store = store.copyWith(defaultTunnelID: Fixtures.workID);
    expect(RuleValidator.defaultTunnelIssue(store), isNull);
    expect(
      RuleValidator.defaultTunnelIssue(
        store,
        missingSecrets: {Fixtures.workID},
      ),
      DefaultTunnelIssue.missingSecret,
    );
    store = store.copyWith(
      tunnels: [store.tunnels[0].copyWith(isEnabled: false), store.tunnels[1]],
    );
    expect(
      RuleValidator.defaultTunnelIssue(store),
      DefaultTunnelIssue.disabled,
    );
    store = store.copyWith(
      defaultTunnelID: '00000000-0000-4000-8000-000000000099',
    );
    expect(RuleValidator.defaultTunnelIssue(store), DefaultTunnelIssue.missing);
  });

  test('application rules are validated like domains', () {
    const telegram = r'C:\Apps\Telegram.exe';
    final first = Rule.tunnel(
      pattern: telegram,
      match: RuleMatch.app,
      tunnelID: Fixtures.workID,
    );
    final duplicate = Rule.tunnel(
      pattern: telegram,
      match: RuleMatch.app,
      tunnelID: Fixtures.workID,
    );
    final shadowed = Rule.tunnel(
      pattern: telegram,
      match: RuleMatch.app,
      tunnelID: Fixtures.homeID,
    );
    final lookalike = Rule.tunnel(
      pattern: r'C:\Apps\vpn.example.org.exe',
      match: RuleMatch.app,
      tunnelID: Fixtures.homeID,
    );
    final store = Fixtures.store(
      rules: [first, duplicate, shadowed, lookalike],
    );
    final issues = RuleValidator.validate(store);
    expect(issues[first.id], isNull);
    expect(issues[duplicate.id], [RuleIssue.duplicate(first.id)]);
    expect(issues[shadowed.id], [RuleIssue.shadowed(first.id)]);
    expect(issues[lookalike.id], isNull);
    expect(
      RuleValidator.activeRules(store)[Fixtures.workID]?.map((rule) => rule.id),
      [first.id],
    );
    expect(
      RuleValidator.activeRules(store)[Fixtures.homeID]?.map((rule) => rule.id),
      [lookalike.id],
    );
  });

  test('IP rules are checked against servers and LAN', () {
    final office = Fixtures.work.copyWith(
      kind: TunnelKindOpenVPN(
        OpenVPNMeta(
          remotes: const [
            Remote(host: '203.0.113.7', port: 1194, proto: 'udp'),
          ],
          needsCredentials: false,
          needsKeyPassphrase: false,
          configHash: 'x',
        ),
      ),
    );
    final first = _ipRule('10.8.0.0/24', Fixtures.workID);
    final duplicate = _ipRule('10.8.0.0/24', Fixtures.workID);
    final shadowed = _ipRule('10.8.0.0/24', Fixtures.homeID);
    final coversServer = _ipRule('203.0.113.0/24', Fixtures.homeID);
    final coversLAN = _ipRule('192.168.0.0/16', Fixtures.workID);
    final directLAN = Rule(
      pattern: '192.168.1.0/24',
      match: RuleMatch.ip,
      target: const RuleTargetDirect(),
    );
    final store = Store(
      tunnels: [office, Fixtures.home],
      rules: [first, duplicate, shadowed, coversServer, coversLAN, directLAN],
    );
    final lan = LocalNetwork('en0', IPv4Prefix.parse('192.168.1.0/24')!);
    final issues = RuleValidator.validate(store, localNetworks: [lan]);
    expect(issues[first.id], isNull);
    expect(issues[duplicate.id], [RuleIssue.duplicate(first.id)]);
    expect(issues[shadowed.id], [RuleIssue.shadowed(first.id)]);
    expect(issues[coversServer.id], const [
      RuleIssue.coversTunnelServer('Work'),
    ]);
    expect(issues[coversLAN.id], const [
      RuleIssue.coversLocalNetwork('en0', '192.168.1.0/24'),
    ]);
    expect(issues[directLAN.id], isNull);
    expect(
      RuleValidator.activeRules(store)[Fixtures.workID]?.map((rule) => rule.id),
      [first.id, coversLAN.id],
    );
    expect(
      RuleValidator.activeRules(store)[Fixtures.homeID]?.map((rule) => rule.id),
      [coversServer.id],
    );
    expect(RuleValidator.activeExceptions(store).map((rule) => rule.id), [
      directLAN.id,
    ]);
  });
}

Rule _ipRule(String pattern, String tunnelID) =>
    Rule.tunnel(pattern: pattern, match: RuleMatch.ip, tunnelID: tunnelID);
