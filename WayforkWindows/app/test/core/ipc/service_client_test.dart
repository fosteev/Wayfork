import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/ipc/service_client.dart';
import 'package:wayfork/core/ipc/service_connection.dart';
import 'package:wayfork/core/model/settings.dart';

import 'fake_service.dart';

void main() {
  group('ServiceConnection', () {
    test('handshake, calls and events', () async {
      final service = FakeService();
      final connection = await ServiceConnection.open(await service.connect());
      expect(connection.hello, service.hello);
      expect(connection.hello.isCompatible, isTrue);

      expect(await connection.getInfo(), service.info);
      expect(await connection.getStatus(), service.status);
      expect((await connection.reconnect('a')).ok, isTrue);
      final failed = await connection.reconnect('b');
      expect(failed.ok, isFalse);
      expect(failed.error, const DaemonError.tunnelNotFound(id: 'b'));
      expect((await connection.collectDiagnostics()).routes, 'r');
      final plan = samplePlan();
      expect((await connection.apply(plan)).ok, isTrue);
      expect(service.applied.single.planHash, plan.planHash);

      final statuses = <RuntimeStatus>[];
      final logs = <List<LogLine>>[];
      final traffic = <TrafficSnapshot>[];
      connection.statusChanged.listen(statuses.add);
      connection.logLines.listen(logs.add);
      connection.trafficChanged.listen(traffic.add);
      expect((await connection.subscribe()).ok, isTrue);
      final line = LogLine(
        ts: fakeSince,
        source: 'sing-box',
        level: LogLevel.info,
        message: 'started',
      );
      service.current.push(ServiceEvent.logLines, [line.toJson()]);
      final snapshot = TrafficSnapshot(
        sampledAt: fakeSince,
        interval: 1,
        tunnels: const {},
        direct: const TrafficCounters(connections: 2),
      );
      service.current.push(ServiceEvent.trafficChanged, snapshot.toJson());
      service.current.push('somethingNew', {'x': 1});
      await pumpEventQueue();
      expect(statuses, [service.status]);
      expect(logs, [
        [line],
      ]);
      expect(traffic, [snapshot]);
      await connection.close();
      expect(connection.isOpen, isFalse);
    });

    test('reassembles lines split across chunks', () async {
      final service = FakeService();
      final connection = await ServiceConnection.open(await service.connect());
      final statuses = <RuntimeStatus>[];
      connection.statusChanged.listen(statuses.add);
      final payload = utf8.encode(
        '${jsonEncode({'event': ServiceEvent.statusChanged, 'data': RuntimeStatus.stopped.toJson()})}\n',
      );
      service.current.writeRaw(payload.sublist(0, 10));
      await pumpEventQueue();
      expect(statuses, isEmpty);
      service.current.writeRaw(payload.sublist(10));
      // Two events in one chunk.
      service.current.writeRaw([...payload, ...payload]);
      await pumpEventQueue();
      expect(statuses, hasLength(3));
      await connection.close();
    });

    test('remote and protocol errors', () async {
      final service = FakeService();
      final connection = await ServiceConnection.open(await service.connect());
      await expectLater(
        connection.call('bogus'),
        throwsA(
          isA<ServiceException>().having(
            (e) => e.kind,
            'kind',
            ServiceErrorKind.remote,
          ),
        ),
      );
      // A pending call is rejected when the service drops the connection.
      final pending = connection.getStatus();
      await service.current.drop();
      await expectLater(
        pending,
        throwsA(
          isA<ServiceException>().having(
            (e) => e.kind,
            'kind',
            ServiceErrorKind.transport,
          ),
        ),
      );
      await connection.done;
      expect(connection.isOpen, isFalse);
      await expectLater(
        connection.getInfo(),
        throwsA(
          isA<ServiceException>().having(
            (e) => e.kind,
            'kind',
            ServiceErrorKind.notConnected,
          ),
        ),
      );
    });

    test('rejects undecodable events and a missing hello', () async {
      final service = FakeService();
      final connection = await ServiceConnection.open(await service.connect());
      service.current.writeRaw(utf8.encode('not json\n'));
      await connection.done;
      expect(connection.isOpen, isFalse);

      // A service that never says hello: the client times out instead of
      // hanging.
      final silent = FakeService()..sendHello = false;
      await expectLater(
        ServiceConnection.open(
          await silent.connect(),
          helloTimeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<ServiceException>().having(
            (e) => e.kind,
            'kind',
            ServiceErrorKind.protocol,
          ),
        ),
      );
      expect(silent.current.toClient.isClosed, isTrue);
    });
  });

  group('ServiceClient', () {
    const backoff = ServiceBackoff(
      initial: Duration(milliseconds: 10),
      max: Duration(milliseconds: 40),
    );

    test('connects, subscribes, forwards pushes and reconnects', () async {
      final service = FakeService();
      final client = ServiceClient(connect: service.connect, backoff: backoff);
      final phases = <ServiceClientPhase>[];
      client.states.listen((state) => phases.add(state.phase));
      final statuses = <RuntimeStatus>[];
      client.statusChanged.listen(statuses.add);

      client.start();
      final connected = await nextPhase(client, ServiceClientPhase.connected);
      expect(connected.hello, service.hello);
      expect(client.isConnected, isTrue);
      expect(service.current.subscribed, isTrue);
      await pumpEventQueue();
      expect(statuses, [service.status]);
      expect(await client.getInfo(), service.info);

      // The service restarts: the client notices, re-dials and re-subscribes.
      await service.current.drop();
      await nextPhase(client, ServiceClientPhase.disconnected);
      expect(client.isConnected, isFalse);
      await expectLater(
        client.getStatus(),
        throwsA(
          isA<ServiceException>().having(
            (e) => e.kind,
            'kind',
            ServiceErrorKind.notConnected,
          ),
        ),
      );
      await nextPhase(client, ServiceClientPhase.connected);
      expect(service.connections, hasLength(2));
      expect(service.current.subscribed, isTrue);
      expect(
        service.calls.where((c) => c == ServiceMethod.subscribe),
        hasLength(2),
      );
      await pumpEventQueue();
      expect(statuses, hasLength(2));

      await client.stop();
      await pumpEventQueue();
      expect(client.state.phase, ServiceClientPhase.disconnected);
      expect(service.current.toClient.isClosed, isTrue);
      expect(phases, [
        ServiceClientPhase.connecting,
        ServiceClientPhase.connected,
        ServiceClientPhase.disconnected,
        ServiceClientPhase.connecting,
        ServiceClientPhase.connected,
        ServiceClientPhase.disconnected,
      ]);
      // No further dial after stop.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.connections, hasLength(2));
    });

    test('reports a missing service until it appears', () async {
      final service = FakeService()..available = false;
      final client = ServiceClient(connect: service.connect, backoff: backoff);
      client.start();
      final missing = await nextPhase(
        client,
        ServiceClientPhase.serviceMissing,
      );
      expect(missing.message, contains('missing'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      service.available = true;
      client.retryNow();
      await nextPhase(client, ServiceClientPhase.connected);
      await client.stop();
    });

    test('reports a version mismatch and keeps retrying', () async {
      final service = FakeService()
        ..hello = const ServiceHello(
          protocol: 2,
          planVersion: RuntimePlan.currentVersion,
          version: '9.9.9',
        );
      final client = ServiceClient(connect: service.connect, backoff: backoff);
      client.start();
      final mismatch = await nextPhase(
        client,
        ServiceClientPhase.versionMismatch,
      );
      expect(mismatch.hello?.version, '9.9.9');
      expect(mismatch.message, contains('protocol 2'));
      expect(service.current.toClient.isClosed, isTrue);
      // After an upgrade the next dial succeeds.
      service.hello = const ServiceHello(
        protocol: serviceProtocolVersion,
        planVersion: RuntimePlan.currentVersion,
        version: '0.2.0',
      );
      client.retryNow();
      final connected = await nextPhase(client, ServiceClientPhase.connected);
      expect(connected.hello?.version, '0.2.0');
      await client.stop();
    });

    test('backoff doubles up to the cap', () {
      const policy = ServiceBackoff(
        initial: Duration(milliseconds: 500),
        max: Duration(seconds: 5),
      );
      expect(policy.delay(0), const Duration(milliseconds: 500));
      expect(policy.delay(1), const Duration(milliseconds: 500));
      expect(policy.delay(2), const Duration(seconds: 1));
      expect(policy.delay(4), const Duration(seconds: 4));
      expect(policy.delay(5), const Duration(seconds: 5));
      expect(policy.delay(50), const Duration(seconds: 5));
    });
  });
}
