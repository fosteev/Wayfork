import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/ipc/service_transport.dart';

/// The framing version of the pipe protocol; `hello.protocol` must match.
const int serviceProtocolVersion = 1;

/// A message on the pipe is at most this long (a plan carries the sing-box
/// config, the rule-sets and the OpenVPN bodies).
const int serviceMaxLineBytes = 64 << 20;

/// Method and event names shared with `service/internal/ipc/protocol.go`.
abstract final class ServiceMethod {
  static const getInfo = 'getInfo';
  static const getStatus = 'getStatus';
  static const subscribe = 'subscribe';
  static const apply = 'apply';
  static const stop = 'stop';
  static const reconnect = 'reconnect';
  static const collectDiagnostics = 'collectDiagnostics';
}

abstract final class ServiceEvent {
  static const hello = 'hello';
  static const statusChanged = 'statusChanged';
  static const logLines = 'logLines';
  static const trafficChanged = 'trafficChanged';
}

/// The first event on every connection.
final class ServiceHello {
  const ServiceHello({
    required this.protocol,
    required this.planVersion,
    required this.version,
  });

  factory ServiceHello.fromJson(Map<String, Object?> json) => ServiceHello(
    protocol: _int(json, 'protocol'),
    planVersion: _int(json, 'planVersion'),
    version: _string(json, 'version'),
  );

  final int protocol;
  final int planVersion;

  /// The service executable's version string.
  final String version;

  bool get isCompatible =>
      protocol == serviceProtocolVersion &&
      planVersion == RuntimePlan.currentVersion;

  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'planVersion': planVersion,
    'version': version,
  };

  @override
  bool operator ==(Object other) =>
      other is ServiceHello &&
      protocol == other.protocol &&
      planVersion == other.planVersion &&
      version == other.version;

  @override
  int get hashCode => Object.hash(protocol, planVersion, version);

  @override
  String toString() =>
      'ServiceHello(protocol: $protocol, planVersion: $planVersion, '
      'version: $version)';
}

enum ServiceErrorKind {
  /// No connection to the service.
  notConnected,

  /// The transport broke while a call was in flight.
  transport,

  /// The service answered with a protocol-level error (undecodable request,
  /// unknown method, bad params).
  remote,

  /// The service sent something the client cannot parse.
  protocol,

  /// The hello announced a protocol or plan version this app does not speak.
  versionMismatch,
}

final class ServiceException implements Exception {
  const ServiceException(this.kind, this.message);

  final ServiceErrorKind kind;
  final String message;

  @override
  String toString() => 'ServiceException($kind): $message';
}

/// One connection to the service: newline-delimited JSON, one request or event
/// per line (docs/design/08-windows.md, "IPC"). Requests are matched to replies
/// by `id`; events are fanned out on broadcast streams.
final class ServiceConnection {
  ServiceConnection._(this._transport);

  /// Reads the hello line from a freshly opened transport.
  static Future<ServiceConnection> open(
    ServiceTransport transport, {
    Duration helloTimeout = const Duration(seconds: 5),
  }) async {
    final connection = ServiceConnection._(transport);
    connection._subscription = transport.input.listen(
      connection._onBytes,
      onError: connection._onTransportError,
      onDone: connection._onTransportDone,
      cancelOnError: true,
    );
    try {
      return await connection._hello.future
          .timeout(
            helloTimeout,
            onTimeout: () => throw const ServiceException(
              ServiceErrorKind.protocol,
              'no hello from the service',
            ),
          )
          .then((_) => connection);
    } on Object {
      await connection.close();
      rethrow;
    }
  }

  final ServiceTransport _transport;
  final _hello = Completer<ServiceHello>();
  final _done = Completer<void>();
  final _status = StreamController<RuntimeStatus>.broadcast();
  final _logLines = StreamController<List<LogLine>>.broadcast();
  final _traffic = StreamController<TrafficSnapshot>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  final _buffer = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? _subscription;
  int _nextID = 1;
  bool _closed = false;

  ServiceHello get hello => _hello.isCompleted
      ? _helloValue!
      : throw StateError('hello not received');
  ServiceHello? _helloValue;

  /// Completes when the transport ends; never with an error.
  Future<void> get done => _done.future;

  bool get isOpen => !_closed;

  Stream<RuntimeStatus> get statusChanged => _status.stream;
  Stream<List<LogLine>> get logLines => _logLines.stream;
  Stream<TrafficSnapshot> get trafficChanged => _traffic.stream;

  // Calls

  Future<DaemonInfo> getInfo() async =>
      DaemonInfo.fromJson(_object(await call(ServiceMethod.getInfo)));

  Future<RuntimeStatus> getStatus() async =>
      RuntimeStatus.fromJson(_object(await call(ServiceMethod.getStatus)));

  Future<ApplyResult> subscribe() async =>
      ApplyResult.fromJson(_object(await call(ServiceMethod.subscribe)));

  Future<ApplyResult> apply(RuntimePlan plan) async => ApplyResult.fromJson(
    _object(await call(ServiceMethod.apply, params: plan.toJson())),
  );

  Future<ApplyResult> stop() async =>
      ApplyResult.fromJson(_object(await call(ServiceMethod.stop)));

  Future<ApplyResult> reconnect(String tunnelID) async => ApplyResult.fromJson(
    _object(await call(ServiceMethod.reconnect, params: {'id': tunnelID})),
  );

  Future<DaemonDiagnostics> collectDiagnostics() async =>
      DaemonDiagnostics.fromJson(
        _object(await call(ServiceMethod.collectDiagnostics)),
      );

  /// Sends one request and returns its raw `result`.
  Future<Object?> call(String method, {Object? params}) async {
    if (_closed) {
      throw const ServiceException(
        ServiceErrorKind.notConnected,
        'connection closed',
      );
    }
    final id = _nextID++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final line = IpcCodec.encode({
      'id': id,
      'method': method,
      'params': ?params,
    });
    try {
      await _transport.write(utf8.encode('$line\n'));
    } on Object catch (error) {
      _pending.remove(id);
      throw ServiceException(ServiceErrorKind.transport, '$error');
    }
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _transport.close();
    _finish('connection closed');
  }

  // Plumbing

  void _onBytes(List<int> chunk) {
    _buffer.add(chunk);
    if (_buffer.length > serviceMaxLineBytes) {
      _fail('message exceeds $serviceMaxLineBytes bytes');
      return;
    }
    // Scan for complete lines; keep the tail for the next chunk.
    final bytes = _buffer.takeBytes();
    var start = 0;
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != 0x0A) continue;
      if (index > start) {
        _onLine(Uint8List.sublistView(bytes, start, index));
        if (_closed) return;
      }
      start = index + 1;
    }
    if (start < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, start));
    }
  }

  void _onLine(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = IpcCodec.decode(utf8.decode(bytes));
    } on FormatException catch (error) {
      _fail('undecodable message: ${error.message}');
      return;
    }
    if (decoded is! Map<String, Object?>) {
      _fail('message is not an object');
      return;
    }
    final event = decoded['event'];
    if (event is String) {
      _onEvent(event, decoded['data']);
      return;
    }
    final id = decoded['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = decoded['error'];
      if (error is String && error.isNotEmpty) {
        completer.completeError(
          ServiceException(ServiceErrorKind.remote, error),
        );
      } else {
        completer.complete(decoded['result']);
      }
    }
    // A reply without an id is the service complaining about an undecodable
    // request; nothing to match it to.
  }

  void _onEvent(String event, Object? data) {
    try {
      switch (event) {
        case ServiceEvent.hello:
          final hello = ServiceHello.fromJson(_object(data));
          _helloValue = hello;
          if (!_hello.isCompleted) _hello.complete(hello);
        case ServiceEvent.statusChanged:
          _status.add(RuntimeStatus.fromJson(_object(data)));
        case ServiceEvent.logLines:
          final list = data is List ? data : const <Object?>[];
          _logLines.add([
            for (final item in list) LogLine.fromJson(_object(item)),
          ]);
        case ServiceEvent.trafficChanged:
          _traffic.add(TrafficSnapshot.fromJson(_object(data)));
        default:
          // Unknown events are ignored for forward compatibility.
          break;
      }
    } on FormatException catch (error) {
      _fail('undecodable $event event: ${error.message}');
    }
  }

  void _onTransportError(Object error) => _fail('$error');

  void _onTransportDone() {
    if (_closed) return;
    _closed = true;
    _transport.close().ignore();
    _finish('service closed the connection');
  }

  void _fail(String message) {
    if (_closed) return;
    _closed = true;
    _subscription?.cancel().ignore();
    _subscription = null;
    _transport.close().ignore();
    _finish(message);
  }

  void _finish(String message) {
    final failure = ServiceException(ServiceErrorKind.transport, message);
    for (final completer in _pending.values) {
      completer.completeError(failure);
    }
    _pending.clear();
    if (!_hello.isCompleted) {
      _hello.completeError(
        ServiceException(ServiceErrorKind.protocol, message),
      );
    }
    _status.close();
    _logLines.close();
    _traffic.close();
    if (!_done.isCompleted) _done.complete();
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is Map<String, Object?>) return value;
    throw const FormatException('expected an object');
  }
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key must be an integer');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}
