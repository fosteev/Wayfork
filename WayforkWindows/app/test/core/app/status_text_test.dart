import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/global_state.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';

import 'sample_store.dart';

void main() {
  final since = DateTime.utc(2026, 8, 28, 12);

  test('summary lines', () {
    final sample = SampleStore();
    final store = sample.store;
    expect(
      StatusText.summary(state: const GlobalState.off(), store: store),
      'Off — all traffic goes direct',
    );
    expect(
      StatusText.summary(state: const GlobalState.starting(), store: store),
      'Starting…',
    );
    // 6 rules, one disabled → 5 domains; 3 enabled tunnels.
    expect(
      StatusText.summary(state: const GlobalState.on(), store: store),
      'On — routing 5 domains through 3 tunnels',
    );
    expect(
      StatusText.summary(
        state: GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
        store: store,
      ),
      'Degraded — Lab is failing · 5 domains, 2 tunnels up',
    );
    expect(
      StatusText.summary(
        state: GlobalState.degraded(
          failingTunnelIDs: [sample.work.id, sample.lab.id],
        ),
        store: store,
      ),
      'Degraded — Work, Lab are failing · 5 domains, 1 tunnel up',
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
      'failed: server rejected username/password',
    );
    expect(
      StatusText.failureMessage('ovpn.keyPassphrase'),
      'failed: wrong key passphrase',
    );
    expect(
      StatusText.failureMessage('ovpn.configError'),
      'failed: OpenVPN rejected the config',
    );
    expect(
      StatusText.failureMessage('singbox.startFailed'),
      'Routing engine failed to start. Another VPN may be active.',
    );
    expect(StatusText.failureMessage('something.new'), 'failed: something.new');
    expect(
      StatusText.failureAction('ovpn.authFailed'),
      FailureAction.editCredentials,
    );
    expect(
      StatusText.failureAction('ovpn.needsKeyPassphrase'),
      FailureAction.editKeyPassphrase,
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
    final connected = StatusText.card(
      tunnel: sample.work,
      state: TunnelState.connected(
        since: since,
        ip: '10.8.0.6',
        interface: 'Wayfork-1',
      ),
      global: const GlobalState.on(),
      ruleCount: 3,
    );
    expect(connected.detail, 'connected · 10.8.0.6 on Wayfork-1 · 3 rules');
    expect(connected.glyph, StatusGlyph.up);
    expect(connected.action, const TunnelCardAction.reconnect());

    final ready = StatusText.card(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
      ruleCount: 2,
    );
    expect(ready.detail, 'ready · host.example.com · 2 rules');
    expect(ready.action, isNull);

    final reconnecting = StatusText.card(
      tunnel: sample.lab,
      state: const TunnelState.reconnecting(
        attempt: 2,
        nextIn: 4,
        reason: 'tls-error',
      ),
      global: GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
      ruleCount: 1,
    );
    expect(reconnecting.detail, 'reconnecting… attempt 2 · tls-error');
    expect(reconnecting.glyph, StatusGlyph.transitioning);

    final failed = StatusText.card(
      tunnel: sample.lab,
      state: const TunnelState.failed(
        reason: 'ovpn.authFailed',
        permanent: true,
      ),
      global: GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
      ruleCount: 1,
    );
    expect(failed.detail, 'failed: server rejected username/password');
    expect(failed.isError, isTrue);
    expect(
      failed.action,
      const TunnelCardAction.edit(FailureAction.editCredentials),
    );

    final disabled = StatusText.card(
      tunnel: sample.lab.copyWith(isEnabled: false),
      state: null,
      global: const GlobalState.on(),
      ruleCount: 1,
    );
    expect(disabled.detail, 'disabled · 1 rule');
    expect(disabled.isDimmed, isTrue);
    expect(disabled.action, const TunnelCardAction.enable());

    final off = StatusText.card(
      tunnel: sample.work,
      state: null,
      global: const GlobalState.off(),
      ruleCount: 3,
    );
    expect(off.detail, 'not running · 3 rules');
    expect(off.isDimmed, isTrue);
    expect(off.action, isNull);

    final missing = StatusText.card(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.off(),
      ruleCount: 2,
      missingSecret: true,
    );
    expect(missing.detail, 'UUID missing · 2 rules');
    expect(missing.isError, isTrue);

    final connecting = StatusText.card(
      tunnel: sample.work,
      state: null,
      global: const GlobalState.starting(),
      ruleCount: 3,
    );
    expect(connecting.detail, 'connecting…');
    expect(connecting.glyph, StatusGlyph.transitioning);
  });

  test('tunnel row summaries', () {
    final sample = SampleStore();
    final row = StatusText.rowSummary(
      tunnel: sample.work,
      state: TunnelState.connected(
        since: since,
        ip: '10.8.0.6',
        interface: 'Wayfork-1',
      ),
      global: const GlobalState.on(),
    );
    expect(
      row.text,
      'connected · vpn.example.com:1194 udp · 10.8.0.6 on Wayfork-1',
    );
    expect(row.glyph, StatusGlyph.up);
    final vless = StatusText.rowSummary(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
    );
    expect(vless.text, 'ready · host.example.com:443 · REALITY · vision');
    final off = StatusText.rowSummary(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.off(),
    );
    expect(off.text, 'not running · host.example.com:443 · REALITY · vision');
    expect(off.glyph, StatusGlyph.idle);
    final failed = StatusText.rowSummary(
      tunnel: sample.work,
      state: const TunnelState.failed(
        reason: 'ovpn.needsCredentials',
        permanent: true,
      ),
      global: const GlobalState.on(),
    );
    expect(failed.text, 'failed: username and password required');
    expect(failed.isError, isTrue);
    expect(StatusText.typeBadge(sample.work.kind), 'OpenVPN');
    expect(StatusText.typeBadge(sample.home.kind), 'VLESS');
  });

  test('summary and cards with a default tunnel (F8)', () {
    final sample = SampleStore();
    var store = sample.store.copyWith(
      defaultTunnelID: sample.home.id,
      rules: [
        ...sample.store.rules,
        Rule(pattern: 'bank.example.org', target: const RuleTargetDirect()),
        Rule(
          pattern: 'paused.example.org',
          target: const RuleTargetDirect(),
          isEnabled: false,
        ),
      ],
    );
    expect(
      StatusText.summary(state: const GlobalState.on(), store: store),
      'On — everything via Home · 5 rules, 1 exception',
    );
    // A default without its secret is no default.
    expect(
      StatusText.summary(
        state: const GlobalState.on(),
        store: store,
        missingSecrets: {sample.home.id},
      ),
      'On — routing 5 domains through 3 tunnels',
    );
    store = store.copyWith(defaultTunnelID: sample.work.id);
    expect(
      StatusText.summary(
        state: GlobalState.degraded(failingTunnelIDs: [sample.work.id]),
        store: store,
      ),
      'Degraded — Work (default) is down · unmatched traffic is blocked',
    );
    expect(
      StatusText.summary(
        state: GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
        store: store,
      ),
      'Degraded — Lab is failing · 5 domains, 2 tunnels up',
    );
    expect(StatusText.activeExceptionCount(store), 1);

    final card = StatusText.card(
      tunnel: sample.work,
      state: TunnelState.connected(
        since: since,
        ip: '10.8.0.6',
        interface: 'Wayfork-1',
      ),
      global: const GlobalState.on(),
      ruleCount: 3,
      isDefault: true,
    );
    expect(
      card.detail,
      'connected · 10.8.0.6 on Wayfork-1 · 3 rules · everything else',
    );
    final ready = StatusText.card(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
      ruleCount: 2,
      isDefault: true,
    );
    expect(
      ready.detail,
      'ready · host.example.com · 2 rules · everything else',
    );
    final row = StatusText.rowSummary(
      tunnel: sample.home,
      state: null,
      global: const GlobalState.on(),
      isDefault: true,
    );
    expect(
      row.text,
      'ready · host.example.com:443 · REALITY · vision · everything else',
    );
  });
}
