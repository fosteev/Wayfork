import 'dart:async';
import 'dart:convert';

import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/ipc/service_client.dart';
import 'package:wayfork/core/ipc/service_connection.dart';
import 'package:wayfork/core/ipc/service_transport.dart';

// An in-memory stand-in for the Go service: the client end of the pipe, one
// accepted connection per dial and the handler contract of
// `service/internal/ipc` (hello first, request/reply by id, pushes after
// `subscribe`). Shared by the client and the app-model tests.

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
        final plan = RuntimePlan.fromJson(
          message['params']! as Map<String, Object?>,
        );
        service.applied.add(plan);
        service.onApply?.call(plan, this);
        result = service.applyResult.toJson();
      case ServiceMethod.stop:
        service.onStop?.call(this);
        result = service.stopResult.toJson();
      case ServiceMethod.reconnect:
        final params = message['params'] as Map<String, Object?>?;
        final tunnelID = params?['id'];
        if (tunnelID is! String || tunnelID.isEmpty) {
          _write({'id': id, 'error': 'reconnect needs {"id": "<tunnel id>"}'});
          return;
        }
        result = service.knownTunnelIDs.contains(tunnelID)
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

  /// Pushes a status and makes it the answer of later `getStatus` calls.
  void pushStatus(RuntimeStatus status) {
    service.status = status;
    _push(ServiceEvent.statusChanged, status.toJson());
  }

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
  var status = RuntimeStatus(engine: EngineState.running(since: fakeSince));

  /// What `apply` / `stop` answer.
  ApplyResult applyResult = ApplyResult.success;
  ApplyResult stopResult = ApplyResult.success;

  /// Hooks to react like the real service (push a status, flip [status]).
  void Function(RuntimePlan plan, FakeServiceConnection connection)? onApply;
  void Function(FakeServiceConnection connection)? onStop;

  /// Tunnel ids `reconnect` accepts.
  final knownTunnelIDs = <String>{'a'};
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

final fakeSince = DateTime.utc(2026, 8, 28, 12);

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
