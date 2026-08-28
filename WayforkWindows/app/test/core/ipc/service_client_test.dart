import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/ipc/service_client.dart';
import 'package:wayfork/core/ipc/service_connection.dart';
import 'package:wayfork/core/ipc/service_transport.dart';
import 'package:wayfork/core/model/settings.dart';

/// The client end of an in-memory pipe.
final class MemoryTransport implements ServiceTransport {
  MemoryTransport(this._service);

  final FakeServiceConnection _service;

  @override
  Stream<List<int>> get input => _service.toClient.stream;

  @override
  Future<void> write(List<int> bytes) async {
    if (_service.toService.isClosed) {
      throw const ServiceTransportException('pipe closed');
    }
    _service.toService.add(bytes);
  }

  @override
  Future<void> close() async {
    await _service.toService.close();
    if (!_service.toClient.isClosed) await _service.toClient.close();
  }
}

/// One accepted connection of the fake service: speaks the Go protocol.
final class FakeServiceConnection {
  FakeServiceConnection(this.service) {
    toService.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onDone: () {
            if (!toClient.isClosed) toClient.close();
          },
        );
    if (service.sendHello) _push(ServiceEvent.hello, service.hello.toJson());
  }

  final FakeService service;
  final toService = StreamController<List<int>>();
  final toClient = StreamController<List<int>>();
  bool subscribed = false;

  void _onLine(String line) {
    final message = jsonDecode(line) as Map<String, Object?>;
    final id = message['id'];
    final method = message['method'];
    if (id is! int || method is! String) {
      _write({'error': 'a request needs id and method'});
      return;
    }
    service.calls.add(method);
    final Object? result;
    switch (method) {
      case ServiceMethod.getInfo:
        result = service.info.toJson();
      case ServiceMethod.getStatus:
        result = service.status.toJson();
      case ServiceMethod.subscribe:
        subscribed = true;
        result = ApplyResult.success.toJson();
        _write({'id': id, 'result': result});
        _push(ServiceEvent.statusChanged, service.status.toJson());
        return;
      case ServiceMethod.apply:
        service.applied.add(
          RuntimePlan.fromJson(message['params']! as Map<String, Object?>),
        );
        result = ApplyResult.success.toJson();
      case ServiceMethod.stop:
        result = ApplyResult.success.toJson();
      case ServiceMethod.reconnect:
        final params = message['params'] as Map<String, Object?>?;
        final tunnelID = params?['id'];
        if (tunnelID is! String || tunnelID.isEmpty) {
          _write({'id': id, 'error': 'reconnect needs {"id": "<tunnel id>"}'});
          return;
        }
        result = tunnelID == 'a'
            ? ApplyResult.success.toJson()
            : ApplyResult.failure(
                DaemonError.tunnelNotFound(id: tunnelID),
              ).toJson();
      case ServiceMethod.collectDiagnostics:
        result = DaemonDiagnostics(
          daemonLogTail: const ['line'],
          childLogTails: const {},
          runDirectoryListing: const [],
          routes: 'r',
        ).toJson();
      default:
        _write({'id': id, 'error': 'unknown method $method'});
        return;
    }
    _write({'id': id, 'result': result});
  }

  void push(String event, Object? data) => _push(event, data);

  void _push(String event, Object? data) =>
      _write({'event': event, 'data': data});

  void _write(Map<String, Object?> message) {
    if (toClient.isClosed) return;
    toClient.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  /// Writes raw bytes, bypassing the framing (for chunking tests).
  void writeRaw(List<int> bytes) => toClient.add(bytes);

  /// The service side drops the connection.
  Future<void> drop() async {
    if (!toClient.isClosed) await toClient.close();
  }
}

final class FakeService {
  ServiceHello hello = const ServiceHello(
    protocol: serviceProtocolVersion,
    planVersion: RuntimePlan.currentVersion,
    version: '0.1.0',
  );
  bool available = true;
  bool sendHello = true;
  final info = const DaemonInfo(
    version: '0.1.0',
    installPath: r'C:\Program Files\Wayfork',
    singBoxVersion: '1.12',
    openVPNVersion: '2.7.6',
  );
  var status = RuntimeStatus(engine: EngineState.running(since: _since));
  final calls = <String>[];
  final applied = <RuntimePlan>[];
  final connections = <FakeServiceConnection>[];

  FakeServiceConnection get current => connections.last;

  Future<ServiceTransport> connect() async {
    if (!available) {
      throw const ServiceUnavailableException(r'\\.\pipe\wayfork missing');
    }
    final connection = FakeServiceConnection(this);
    connections.add(connection);
    return MemoryTransport(connection);
  }
}

final _since = DateTime.utc(2026, 8, 28, 12);

RuntimePlan samplePlan() => RuntimePlan(
  singBox: SingBoxPlan(config: '{}', ruleSets: const {}),
  openVPN: const [],
);

Future<ServiceClientState> nextPhase(
  ServiceClient client,
  ServiceClientPhase phase,
) => client.state.phase == phase
    ? Future.value(client.state)
    : client.states.firstWhere((state) => state.phase == phase);

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
        ts: _since,
        source: 'sing-box',
        level: LogLevel.info,
        message: 'started',
      );
      service.current.push(ServiceEvent.logLines, [line.toJson()]);
      final snapshot = TrafficSnapshot(
        sampledAt: _since,
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
