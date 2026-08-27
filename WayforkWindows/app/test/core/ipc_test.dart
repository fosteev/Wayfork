import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/model/export_document.dart';

import 'fixtures.dart';

void main() {
  test('IPC payloads round-trip', () {
    final status = RuntimeStatus(
      engine: EngineState.running(since: Fixtures.date),
      tunnels: {
        'a': TunnelState.connected(
          since: Fixtures.date,
          ip: '10.8.0.2',
          interface: 'Wayfork-1',
        ),
        'b': const TunnelState.reconnecting(
          attempt: 3,
          nextIn: 4,
          reason: 'ping-restart',
        ),
        'c': const TunnelState.failed(reason: 'auth', permanent: true),
      },
      planHash: 'h',
      discoveredDNS: const {
        'a': ['10.8.0.1'],
      },
    );
    final statusJson = IpcCodec.encode(status);
    expect(
      RuntimeStatus.fromJson(
        IpcCodec.decode(statusJson)! as Map<String, Object?>,
      ),
      status,
    );

    final result = ApplyResult.failure(
      const DaemonError.configInvalid(output: 'bad json'),
    );
    expect(
      ApplyResult.fromJson(
        IpcCodec.decode(IpcCodec.encode(result))! as Map<String, Object?>,
      ),
      result,
    );
  });

  test('plan hashes include rule sets but config hash does not', () {
    final a = SingBoxPlan(config: '{}', ruleSets: const {'r.json': '1'});
    final b = SingBoxPlan(config: '{}', ruleSets: const {'r.json': '2'});
    expect(a.configHash, b.configHash);
    expect(
      RuntimePlan(singBox: a, openVPN: const []).planHash,
      isNot(RuntimePlan(singBox: b, openVPN: const []).planHash),
    );
    final plain = OpenVPNRuntime(
      id: 'x',
      interface: 'Wayfork-1',
      config: 'client',
    );
    final authenticated = OpenVPNRuntime(
      id: 'x',
      interface: 'Wayfork-1',
      config: 'client',
      credentials: const Credentials(username: 'u', password: 'p'),
    );
    expect(plain.configHash, isNot(authenticated.configHash));

    final encoded = IpcCodec.encode(
      RuntimePlan(singBox: a, openVPN: [authenticated]),
    );
    final decoded = RuntimePlan.fromJson(
      IpcCodec.decode(encoded)! as Map<String, Object?>,
    );
    expect(decoded.singBox.configHash, a.configHash);
    expect(decoded.openVPN.single.configHash, authenticated.configHash);
  });

  test('every sealed wire case is pinned', () {
    final engineCases = <EngineState, String>{
      const EngineState.stopped(): '{"stopped":{}}',
      const EngineState.starting(): '{"starting":{}}',
      EngineState.running(since: Fixtures.date):
          '{"running":{"since":"2026-08-25T12:00:00Z"}}',
      const EngineState.failed(reason: 'boom'): '{"failed":{"reason":"boom"}}',
    };
    for (final entry in engineCases.entries) {
      expect(IpcCodec.encode(entry.key), entry.value);
      expect(
        EngineState.fromJson(
          IpcCodec.decode(entry.value)! as Map<String, Object?>,
        ),
        entry.key,
      );
    }

    final tunnelCases = <TunnelState, String>{
      const TunnelState.disabled(): '{"disabled":{}}',
      const TunnelState.connecting(attempt: 2): '{"connecting":{"attempt":2}}',
      TunnelState.connected(
        since: Fixtures.date,
        ip: '10.8.0.2',
        interface: 'Wayfork-1',
      ): '{"connected":{"interface":"Wayfork-1","ip":"10.8.0.2","since":"2026-08-25T12:00:00Z"}}',
      const TunnelState.reconnecting(attempt: 3, nextIn: 4.5, reason: 'ping'):
          '{"reconnecting":{"attempt":3,"nextIn":4.5,"reason":"ping"}}',
      const TunnelState.failed(reason: 'auth', permanent: true):
          '{"failed":{"permanent":true,"reason":"auth"}}',
    };
    for (final entry in tunnelCases.entries) {
      expect(IpcCodec.encode(entry.key), entry.value);
      expect(
        TunnelState.fromJson(
          IpcCodec.decode(entry.value)! as Map<String, Object?>,
        ),
        entry.key,
      );
    }

    final resolverCases = <ResolverOverrideState, String>{
      const ResolverOverrideState.off(): '{"off":{}}',
      const ResolverOverrideState.active(service: 'Ethernet'):
          '{"active":{"service":"Ethernet"}}',
      ResolverOverrideState.shadowed(manual: const ['1.1.1.1']):
          '{"shadowed":{"manual":["1.1.1.1"]}}',
      const ResolverOverrideState.failed(reason: 'denied'):
          '{"failed":{"reason":"denied"}}',
    };
    for (final entry in resolverCases.entries) {
      expect(IpcCodec.encode(entry.key), entry.value);
      expect(
        ResolverOverrideState.fromJson(
          IpcCodec.decode(entry.value)! as Map<String, Object?>,
        ),
        entry.key,
      );
    }

    final errorCases = <DaemonError, String>{
      const DaemonError.binaryUntrusted(path: r'C:\bad.exe'):
          r'{"binaryUntrusted":{"path":"C:\\bad.exe"}}',
      const DaemonError.planInvalid(reason: 'too many'):
          '{"planInvalid":{"reason":"too many"}}',
      const DaemonError.configInvalid(output: 'bad'):
          '{"configInvalid":{"output":"bad"}}',
      DaemonError.startFailed(logTail: const ['one', 'two']):
          '{"startFailed":{"logTail":["one","two"]}}',
      const DaemonError.tunnelNotFound(id: 'x'):
          '{"tunnelNotFound":{"id":"x"}}',
      const DaemonError.notRunning(): '{"notRunning":{}}',
      const DaemonError.internalError(message: 'oops'):
          '{"internalError":{"message":"oops"}}',
    };
    for (final entry in errorCases.entries) {
      expect(IpcCodec.encode(entry.key), entry.value);
      expect(
        DaemonError.fromJson(
          IpcCodec.decode(entry.value)! as Map<String, Object?>,
        ),
        entry.key,
      );
    }
  });

  test('remaining payload models preserve their wire values', () {
    const counters = TrafficCounters(
      downBytesPerSecond: 12.5,
      upBytesPerSecond: 2,
      downTotal: 100,
      upTotal: 20,
      connections: 3,
    );
    expect(counters.isIdle, isFalse);
    final snapshot = TrafficSnapshot(
      sampledAt: Fixtures.date,
      interval: 1.25,
      tunnels: const {'a': counters},
      direct: TrafficCounters.zero,
    );
    final decoded = TrafficSnapshot.fromJson(
      IpcCodec.decode(IpcCodec.encode(snapshot))! as Map<String, Object?>,
    );
    expect(decoded, snapshot);
    expect(decoded.countersForTunnel('missing'), TrafficCounters.zero);
    expect(RuntimeStatus.stopped.resolverOverride, const ResolverOverrideOff());
  });
}
