import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/global_state.dart';
import 'package:wayfork/core/ipc/payloads.dart';

import 'sample_store.dart';

void main() {
  final since = DateTime.utc(2026, 8, 28, 12);

  test('off without status or transition', () {
    final sample = SampleStore();
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: null,
        transition: null,
      ),
      const GlobalState.off(),
    );
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: RuntimeStatus.stopped,
        transition: null,
      ),
      const GlobalState.off(),
    );
  });

  test('starting until the tunnels connect', () {
    final sample = SampleStore();
    final transition = AppTransition.starting(since: since);
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: null,
        transition: transition,
      ),
      const GlobalState.starting(),
    );
    var status = RuntimeStatus(
      engine: EngineState.running(since: since),
      tunnels: {
        sample.work.id: const TunnelState.connecting(attempt: 1),
        sample.lab.id: const TunnelState.connecting(attempt: 1),
      },
    );
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: status,
        transition: transition,
        now: since.add(const Duration(seconds: 5)),
      ),
      const GlobalState.starting(),
    );
    // Timeout → degraded with the tunnels still waiting.
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: status,
        transition: transition,
        now: since.add(const Duration(seconds: 31)),
      ),
      GlobalState.degraded(failingTunnelIDs: [sample.work.id, sample.lab.id]),
    );
    status = RuntimeStatus(
      engine: EngineState.running(since: since),
      tunnels: {
        sample.work.id: TunnelState.connected(
          since: since,
          ip: '10.8.0.6',
          interface: 'Wayfork-1',
        ),
        sample.lab.id: TunnelState.connected(
          since: since,
          interface: 'Wayfork-3',
        ),
      },
    );
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: status,
        transition: transition,
      ),
      const GlobalState.on(),
    );
  });

  test('degraded when a tunnel fails', () {
    final sample = SampleStore();
    var status = RuntimeStatus(
      engine: EngineState.running(since: since),
      tunnels: {
        sample.work.id: TunnelState.connected(
          since: since,
          ip: '10.8.0.6',
          interface: 'Wayfork-1',
        ),
        sample.lab.id: const TunnelState.failed(
          reason: 'ovpn.authFailed',
          permanent: true,
        ),
      },
    );
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: status,
        transition: null,
      ),
      GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
    );
    // A reconnecting tunnel ends `starting` immediately.
    status = RuntimeStatus(
      engine: EngineState.running(since: since),
      tunnels: {
        ...status.tunnels,
        sample.lab.id: const TunnelState.reconnecting(
          attempt: 2,
          nextIn: 4,
          reason: 'tls-error',
        ),
      },
    );
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: status,
        transition: AppTransition.starting(since: since),
        now: since,
      ),
      GlobalState.degraded(failingTunnelIDs: [sample.lab.id]),
    );
  });

  test('ignores disabled tunnels and stale entries', () {
    final sample = SampleStore();
    final store = sample.store.copyWith(
      tunnels: [
        sample.work,
        sample.home,
        sample.lab.copyWith(isEnabled: false),
      ],
    );
    final status = RuntimeStatus(
      engine: EngineState.running(since: since),
      tunnels: {
        sample.work.id: TunnelState.connected(
          since: since,
          ip: '10.8.0.6',
          interface: 'Wayfork-1',
        ),
        sample.lab.id: const TunnelState.failed(
          reason: 'ovpn.authFailed',
          permanent: true,
        ),
        'not-a-known-id': const TunnelState.failed(
          reason: 'ovpn.exited',
          permanent: false,
        ),
      },
    );
    expect(
      GlobalStateDerivation.derive(
        store: store,
        status: status,
        transition: null,
      ),
      const GlobalState.on(),
    );
  });

  test('error and stopping', () {
    final sample = SampleStore();
    final failed = RuntimeStatus(
      engine: const EngineState.failed(reason: 'singbox.startFailed'),
    );
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: failed,
        transition: null,
      ),
      const GlobalState.error(reason: 'singbox.startFailed'),
    );
    expect(
      GlobalStateDerivation.derive(
        store: sample.store,
        status: failed,
        transition: const AppTransition.stopping(),
      ),
      const GlobalState.stopping(),
    );
    expect(const GlobalState.stopping().isTransitioning, isTrue);
    expect(const GlobalState.degraded(failingTunnelIDs: []).isRunning, isTrue);
    expect(const GlobalState.off().isOff, isTrue);
  });
}
