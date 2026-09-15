import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/local_proxy.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel_group.dart';
import 'package:wayfork/core/rules/rule_validator.dart';

import 'fixtures.dart';

// F16–F18 model additions; the JSON shapes are pinned by the shared goldens
// (fixtures/singbox/group-*, proxy-*, block-*), these cover the helpers.
void main() {
  const groupID = '00000000-0000-4000-8000-0000000000a1';

  Store grouped({
    bool homeEnabled = true,
    GroupPolicy policy = GroupPolicy.fastest,
  }) {
    final home = homeEnabled
        ? Fixtures.home
        : Fixtures.home.copyWith(isEnabled: false);
    return Store(
      tunnels: [Fixtures.work, home],
      groups: [
        TunnelGroup(
          id: groupID,
          name: 'Streaming',
          members: [Fixtures.homeID, Fixtures.workID],
          policy: policy,
          createdAt: Fixtures.date,
        ),
      ],
      rules: [
        Rule.tunnel(pattern: 'example.com', tunnelID: Fixtures.workID),
        Rule(pattern: 'video.example.com', target: RuleTargetGroup(groupID)),
        Rule(pattern: 'example.com', target: RuleTargetGroup(groupID)),
      ],
    );
  }

  test('groups round-trip and are omitted when empty', () {
    final store = grouped();
    final text = StoreCodec.encode(store);
    expect(StoreCodec.decode(text), store);
    expect(text, contains('"groupID"'));
    expect(text, contains('"policy" : "fastest"'));
    expect(StoreCodec.encode(Fixtures.store()), isNot(contains('groups')));
    expect(store.group(groupID)?.outboundTag, 'g-$groupID');
    expect(TunnelGroup.groupID('g-abc'), 'abc');
    expect(TunnelGroup.groupID('t-abc'), isNull);
    expect(store.exitName(groupID), 'Streaming');
    expect(store.rulesForGroup(groupID).length, 2);
    expect(store.isNameAvailable('streaming'), isFalse);
    expect(store.isNameAvailable('streaming', excluding: groupID), isTrue);
  });

  test('effective rules and the default exit know groups', () {
    final store = grouped();
    expect(store.effectiveRules.map((rule) => rule.pattern).toList(), [
      'example.com',
      'video.example.com',
      'example.com',
    ]);
    // The group's duplicate of a tunnel rule is shadowed by the tunnel section.
    final issues = RuleValidator.validate(store);
    final shadowed = store.rules.last;
    expect(issues[shadowed.id], [RuleIssue.shadowed(store.rules.first.id)]);
    expect(RuleValidator.activeRules(store)[groupID]?.length, 1);

    final asDefault = store.copyWith(defaultTunnelID: groupID);
    expect(asDefault.effectiveDefaultExit, isA<DefaultExitGroup>());
    expect(asDefault.effectiveDefaultExit?.outboundTag, 'g-$groupID');
    expect(asDefault.effectiveDefaultTunnel, isNull);
    expect(store.enabledMembers(store.groups.single).length, 2);

    // No enabled member: the group is off for routing and its rules are inert.
    final dead = grouped(homeEnabled: false).copyWith(
      tunnels: [
        Fixtures.work.copyWith(isEnabled: false),
        Fixtures.home.copyWith(isEnabled: false),
      ],
    );
    expect(dead.effectiveDefaultExit, isNull);
    final deadIssues = RuleValidator.validate(dead);
    expect(
      deadIssues[dead.rules[1].id],
      contains(const RuleIssue.tunnelDisabled()),
    );
    final missing = store.copyWith(groups: const []);
    expect(
      RuleValidator.validate(missing)[missing.rules[1].id],
      contains(const RuleIssue.tunnelMissing()),
    );
  });

  test('local proxy ports are handed out and checked', () {
    var store = Fixtures.store();
    expect(store.nextFreeLocalProxyPort(), LocalProxy.firstPort);
    store = store.copyWith(
      tunnels: [
        Fixtures.work.copyWith(
          localProxy: const LocalProxy(isEnabled: true, port: 1081),
        ),
        Fixtures.home.copyWith(
          localProxy: const LocalProxy(isEnabled: false, port: 1082),
        ),
      ],
    );
    expect(store.nextFreeLocalProxyPort(), 1083);
    expect(store.localProxyPortOwner(1082, excluding: Fixtures.workID), 'Home');
    expect(store.localProxyPortOwner(1082, excluding: Fixtures.homeID), isNull);
    expect(store.localProxyOfExit(Fixtures.homeID)?.port, 1082);
    const proxy = LocalProxy(isEnabled: true, port: 1081);
    expect(proxy.address, '127.0.0.1:1081');
    expect(proxy.copyText, 'socks5h://127.0.0.1:1081');
    expect(LocalProxy.inboundTag('t-abc'), 'proxy-t-abc');
    expect(LocalProxy.outboundTag('proxy-g-abc'), 'g-abc');
    expect(LocalProxy.outboundTag('tun-in'), isNull);
    final text = StoreCodec.encode(store);
    expect(StoreCodec.decode(text), store);
    expect(text, contains('"localProxy"'));
    expect(StoreCodec.encode(Fixtures.store()), isNot(contains('localProxy')));
  });

  test('block list settings are omitted while default', () {
    const settings = Settings();
    expect(settings.toJson().containsKey('blockList'), isFalse);
    final on = settings.copyWith(
      blockList: const BlockListSettings(
        isEnabled: true,
        exceptions: ['example.com'],
      ),
    );
    expect(Settings.fromJson(on.toJson()), on);
    expect(
      Settings.fromJson(settings.toJson()).blockList,
      const BlockListSettings(),
    );
  });
}
