import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/feature_text.dart';
import 'package:wayfork/core/app/global_state.dart';
import 'package:wayfork/core/app/latency_format.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/local_proxy.dart';
import 'package:wayfork/core/model/tunnel_group.dart';

import 'sample_store.dart';

// The variant C wording (docs/design/02-ux.md), mirroring the macOS
// AppLogicTests so the two clients say the same things.
void main() {
  final since = DateTime.utc(2026, 8, 28, 12);
  TunnelState connected() => TunnelState.connected(
    since: since,
    ip: '10.8.0.6',
    interface: 'Wayfork-1',
  );

  test('summary lines', () {
    final sample = SampleStore();
    final store = sample.store;
    expect(
      StatusText.summary(state: const GlobalState.off(), store: store),
      'Off — nothing goes through a tunnel. Turn on to send your 5 sites '
      'through their tunnels; everything else stays as it is.',
    );
    expect(
      StatusText.summary(
        state: const GlobalState.off(),
        store: store.copyWith(rules: []),
      ),
      'Off — nothing goes through a tunnel.',
    );
    expect(
      StatusText.summary(state: const GlobalState.starting(), store: store),
      'Starting…',
    );
    // 6 rules, one disabled → 5 sites; 3 enabled tunnels.
    expect(
      StatusText.summary(state: const GlobalState.on(), store: store),
      'On — 5 sites via 3 tunnels, the rest as usual',
    );
    expect(
      StatusText.summary(
        state: GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
        store: store,
      ),
      "Lab can't connect — 2 tunnels up",
    );
    expect(
      StatusText.summary(
        state: GlobalState.degraded(
          failingTunnelIDs: [sample.work.id, sample.lab.id],
        ),
        store: store,
      ),
      "Work and Lab can't connect — 1 tunnel up",
    );
    expect(
      StatusText.summary(
        state: const GlobalState.error(reason: 'singbox.startFailed'),
        store: store,
      ),
      'Routing engine failed — see Logs',
    );
    expect(
      StatusText.summary(
        state: const GlobalState.on(),
        store: store.copyWith(tunnels: [], rules: []),
      ),
      'On — no tunnels',
    );
  });

  test('failure messages follow the catalogue', () {
    expect(
      StatusText.failureMessage('ovpn.authFailed'),
      'Server refused the login',
    );
    expect(
      StatusText.failureMessage('ovpn.keyPassphrase'),
      'Wrong key passphrase',
    );
    expect(
      StatusText.failureMessage('ovpn.configError'),
      'OpenVPN rejected the file',
    );
    expect(
      StatusText.failureMessage('singbox.startFailed'),
      'Routing engine failed to start. Another VPN may be active.',
    );
    expect(
      StatusText.failureMessage('something.new'),
      "Can't connect (something.new)",
    );
    expect(
      StatusText.failureAction('ovpn.authFailed'),
      FailureAction.editCredentials,
    );
    expect(
      StatusText.failureAction('ovpn.configError'),
      FailureAction.replaceConfig,
    );
    expect(
      StatusText.failureAction('helper.unreachable'),
      FailureAction.repairInstallation,
    );
    expect(StatusText.failureAction('something.new'), FailureAction.showLog);
  });

  test('tunnel cards', () {
    final sample = SampleStore();
    final card = StatusText.card(
      tunnel: sample.work,
      state: connected(),
      global: const GlobalState.on(),
      ruleCount: 3,
    );
    expect(card.status, 'Connected');
    expect(card.detail, '3 sites');
    expect(card.glyph, StatusGlyph.up);
    expect(card.actions, isEmpty);

    final ready = StatusText.card(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
      ruleCount: 1,
    );
    expect(ready.status, 'Connected');
    expect(ready.detail, '1 site');

    final connecting = StatusText.card(
      tunnel: sample.work,
      state: const TunnelState.connecting(attempt: 2),
      global: const GlobalState.on(),
      ruleCount: 3,
    );
    expect(connecting.status, 'Connecting…');
    expect(connecting.detail, '2nd try');
    expect(connecting.glyph, StatusGlyph.transitioning);

    final failed = StatusText.card(
      tunnel: sample.work,
      state: const TunnelState.failed(
        reason: 'ovpn.authFailed',
        permanent: true,
      ),
      global: const GlobalState.on(),
      ruleCount: 3,
    );
    expect(failed.status, "Can't connect");
    expect(failed.detail, 'Server refused the login');
    expect(failed.isError, isTrue);
    expect(failed.actions, [
      const TunnelCardAction.reconnect(),
      const TunnelCardAction.edit(FailureAction.editCredentials),
    ]);

    final off = StatusText.card(
      tunnel: sample.work,
      state: null,
      global: const GlobalState.off(),
      ruleCount: 3,
    );
    expect(off.status, 'Not running');
    expect(off.isDimmed, isTrue);

    final disabled = StatusText.card(
      tunnel: sample.work.copyWith(isEnabled: false),
      state: null,
      global: const GlobalState.on(),
      ruleCount: 3,
    );
    expect(disabled.status, 'Off');
    expect(disabled.actions, [const TunnelCardAction.enable()]);

    final missing = StatusText.card(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
      ruleCount: 0,
      missingSecret: true,
    );
    expect(missing.status, 'Not ready');
    expect(missing.detail, 'UUID missing');

    // F14: probes failed three times in a row.
    final unreachable = StatusText.card(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
      ruleCount: 2,
      latency: LatencySample(
        failedInARow: 3,
        unreachable: true,
        lastSuccess: since,
      ),
      now: since.add(const Duration(minutes: 2)),
    );
    expect(unreachable.status, 'Not reachable');
    expect(
      unreachable.detail,
      'No answer through the tunnel for 2 min · 2 sites wait',
    );
    expect(unreachable.actions, [const TunnelCardAction.reconnect()]);
    expect(StatusText.ordinal(1), '1st try');
    expect(StatusText.ordinal(11), '11th try');
    expect(StatusText.ordinal(22), '22nd try');
    expect(StatusText.matchWord(RuleMatch.suffix), 'and subdomains');
    expect(StatusText.logDetailName(LogLevel.warning), 'Problems');
  });

  test('tunnel row summaries', () {
    final sample = SampleStore();
    final row = StatusText.rowSummary(
      tunnel: sample.work,
      state: connected(),
      global: const GlobalState.on(),
      ruleCount: 3,
    );
    expect(row.text, 'Connected · OpenVPN · 3 sites');
    expect(row.glyph, StatusGlyph.up);
    final vless = StatusText.rowSummary(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
      isDefault: true,
      ruleCount: 2,
    );
    expect(
      vless.text,
      'Connected · VLESS · routes everything else and 2 sites',
    );
    final off = StatusText.rowSummary(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.off(),
      ruleCount: 1,
    );
    expect(off.text, 'Not running · VLESS · 1 site');
    expect(off.glyph, StatusGlyph.idle);
    final failed = StatusText.rowSummary(
      tunnel: sample.work,
      state: const TunnelState.failed(
        reason: 'ovpn.needsCredentials',
        permanent: true,
      ),
      global: const GlobalState.on(),
      ruleCount: 3,
    );
    expect(
      failed.text,
      "Can't connect · Login and password needed · OpenVPN · 3 sites",
    );
    expect(failed.isError, isTrue);
    expect(
      StatusText.endpointDescription(sample.home.kind),
      'host.example.com:443 · REALITY · vision',
    );
  });

  test('summary and cards with a default tunnel (F8)', () {
    final sample = SampleStore();
    var store = sample.store.copyWith(
      defaultTunnelID: sample.home.id,
      rules: [
        ...sample.store.rules,
        Rule(pattern: 'bank.example.org', target: const RuleTargetDirect()),
      ],
    );
    // 5 active tunnel rules, 3 of them outside Home.
    expect(
      StatusText.summary(state: const GlobalState.on(), store: store),
      'On — everything goes via Home, 3 sites via other tunnels',
    );
    expect(
      StatusText.summary(
        state: const GlobalState.on(),
        store: store,
        missingSecrets: {sample.home.id},
      ),
      'On — 5 sites via 3 tunnels, the rest as usual',
    );
    store = store.copyWith(defaultTunnelID: sample.work.id);
    expect(
      StatusText.summary(
        state: GlobalState.degraded(failingTunnelIDs: [sample.work.id]),
        store: store,
      ),
      "Work can't connect — sites without a rule are blocked until it is back",
    );
    expect(
      StatusText.summary(
        state: GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
        store: store,
      ),
      "Lab can't connect — 2 tunnels up, everything else via Work",
    );
    expect(StatusText.activeExceptionCount(store), 1);
  });

  test('group cards, rows and hints (F16)', () {
    final sample = SampleStore();
    final group = TunnelGroup(
      name: 'Streaming',
      members: [sample.home.id, sample.lab.id],
      policy: GroupPolicy.fastest,
    );
    var store = sample.store.copyWith(
      groups: [group],
      rules: [
        ...sample.store.rules,
        Rule(pattern: 'video.example.com', target: RuleTargetGroup(group.id)),
        Rule(pattern: 'cdn.example.net', target: RuleTargetGroup(group.id)),
      ],
    );
    final groups = {group.id: GroupState(activeMember: sample.home.id)};
    final latency = {
      sample.home.id: LatencySample(milliseconds: 180),
      sample.lab.id: LatencySample(milliseconds: 90),
    };
    final states = {sample.lab.id: connected()};

    final running = StatusText.groupCard(
      group: group,
      store: store,
      global: const GlobalState.on(),
      latency: latency,
      groups: groups,
      states: states,
    );
    expect(running.glyph, StatusGlyph.group);
    expect(running.status, 'Fastest');
    expect(running.detail, 'using Home · 2 sites');

    final members = StatusText.groupMembers(
      group: group,
      store: store,
      global: const GlobalState.on(),
      latency: latency,
      groups: groups,
      states: states,
    );
    expect(members.map((row) => row.tunnel.name).toList(), ['Home', 'Lab']);
    expect(members[0].note, '✓ in use');
    expect(members[0].isActive, isTrue);
    expect(members[1].note, '');
    expect(members[1].latency?.milliseconds, 90);

    expect(
      StatusText.groupCard(
        group: group,
        store: store,
        global: const GlobalState.off(),
      ).status,
      'Not running',
    );
    expect(
      StatusText.groupCard(
        group: group.copyWith(isEnabled: false),
        store: store,
        global: const GlobalState.on(),
      ).actions,
      [const TunnelCardAction.enable()],
    );

    final unreachable = {
      sample.home.id: LatencySample(failedInARow: 3, unreachable: true),
      sample.lab.id: LatencySample(failedInARow: 3, unreachable: true),
    };
    final dead = StatusText.groupCard(
      group: group,
      store: store,
      global: const GlobalState.on(),
      latency: unreachable,
      groups: groups,
      states: states,
    );
    expect(dead.status, 'No member reachable');
    expect(dead.detail, 'its 2 sites stay outside a tunnel for now');
    expect(dead.isError, isTrue);
    store = store.copyWith(defaultTunnelID: sample.work.id);
    expect(
      StatusText.groupCard(
        group: group,
        store: store,
        global: const GlobalState.on(),
        latency: unreachable,
        groups: groups,
        states: states,
      ).detail,
      'its 2 sites go via Work for now',
    );
    expect(
      StatusText.groupMembers(
        group: group,
        store: store,
        global: const GlobalState.on(),
        latency: unreachable,
        groups: groups,
        states: states,
      ).map((row) => row.note).toList(),
      ['skipped — not reachable', 'skipped — not reachable'],
    );

    expect(
      StatusText.groupRowSummary(
        group: group,
        store: store,
        global: const GlobalState.on(),
        groups: groups,
      ).text,
      'Group · fastest of Home, Lab · using Home · 2 sites',
    );
    expect(
      StatusText.groupRowSummary(
        group: group,
        store: store,
        global: const GlobalState.off(),
      ).text,
      'Not running · Group · fastest of Home, Lab · 2 sites',
    );
    expect(
      StatusText.groupHint(
        group: group,
        store: store,
        global: const GlobalState.on(),
        groups: groups,
      ).text,
      'fastest of Home, Lab · using Home right now',
    );
    expect(
      StatusText.groupHint(
        group: group.copyWith(isEnabled: false),
        store: store,
        global: const GlobalState.on(),
      ).text,
      'off — its sites go via Work for now',
    );
    expect(StatusText.policyWord(GroupPolicy.firstLive), 'First live');

    // The group as the default exit: the summary names it.
    store = store.copyWith(defaultTunnelID: group.id);
    expect(
      StatusText.summary(state: const GlobalState.on(), store: store),
      'On — everything goes via Streaming, 5 sites via other tunnels',
    );
    expect(StatusText.effectiveDefaultExitName(store), 'Streaming');
    expect(
      StatusText.effectiveDefaultExitName(
        store.copyWith(
          tunnels: [
            sample.work,
            sample.home.copyWith(isEnabled: false),
            sample.lab,
          ],
        ),
        missingSecrets: {sample.lab.id},
      ),
      isNull,
    );
  });

  test('latency, local proxy, block list and failed-connection words', () {
    expect(LatencyBand.of(62), LatencyBand.good);
    expect(LatencyBand.of(180), LatencyBand.fair);
    expect(LatencyBand.of(500), LatencyBand.poor);
    expect(LatencyFormat.duration(30), '30 s');
    expect(LatencyFormat.duration(125), '2 min');
    expect(LatencyFormat.duration(3900), '1 h 05 min');
    expect(
      LatencyFormat.tooltip(
        LatencySample(milliseconds: 60, history: [58, 71, 60]),
      ),
      'Measured through the tunnel every 10 s · last 2 min: min 58, max 71 ms',
    );

    final sample = SampleStore();
    final store = sample.store.copyWith(
      tunnels: [
        sample.work.copyWith(
          localProxy: const LocalProxy(isEnabled: true, port: 1081),
        ),
        sample.home,
        sample.lab,
      ],
    );
    expect(
      LocalProxyText.portProblem(
        '1081',
        store: store,
        excluding: sample.home.id,
      ),
      'Port already used by Work',
    );
    expect(
      LocalProxyText.portProblem('80', store: store, excluding: sample.home.id),
      'Ports 1024–65535',
    );
    expect(
      LocalProxyText.portProblem(
        '1082',
        store: store,
        excluding: sample.home.id,
      ),
      isNull,
    );
    expect(
      LocalProxyText.portTaken(1081),
      'Port 1081 is taken by another program — pick another',
    );

    const info = BlockListInfo(
      isAvailable: true,
      name: 'oisd small',
      entries: 56069,
    );
    expect(
      BlockListText.hint(
        info: info,
        isEnabled: true,
        blockedToday: 12,
        isRunning: true,
        countingPossible: true,
        appVersion: '0.7.0',
      ),
      'Blocked 12 today · list of 56,069 sites · from Wayfork 0.7.0',
    );
    expect(
      BlockListText.hint(
        info: BlockListInfo.missing,
        isEnabled: true,
        blockedToday: null,
        isRunning: false,
        countingPossible: true,
        appVersion: '0.7.0',
      ),
      'The block list is missing from this build — reinstall Wayfork',
    );
    expect(BlockListText.normalizeException(' Example.COM. '), 'example.com');

    expect(
      FailedText.reason(const FailureReason(FailureKind.noAnswer)),
      'no answer',
    );
    expect(
      FailedText.reason(
        const FailureReason(FailureKind.tunnelDown),
        exitName: 'Lab',
      ),
      'Lab is down',
    );
    expect(FailedText.tries(14), '×14');
    expect(
      FailedText.lastSeen(since, now: since.add(const Duration(seconds: 12))),
      '12 s ago',
    );
    expect(
      FailedText.lastSeen(since, now: since.add(const Duration(minutes: 3))),
      '3 min ago',
    );
    expect(
      FailedText.header(count: 4, since: null, appsUnknown: false),
      '4 sites — click a row to see its log lines',
    );
    expect(
      FailedText.showing(
        host: 'a.example',
        tries: 3,
        reason: 'refused',
        via: 'Work',
      ),
      'Showing lines for a.example · 3 tries, all refused · went Work',
    );
    expect(FailedText.flyoutLine(3), "3 sites can't be reached");
  });
}
