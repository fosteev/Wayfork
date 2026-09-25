import 'dart:async';

import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/runtime_plan.dart';
import 'package:wayfork/core/ipc/service_connection.dart';
import 'package:wayfork/core/ipc/service_transport.dart';

enum ServiceClientPhase {
  /// Dialing the pipe (also between reconnect attempts).
  connecting,

  /// Hello verified and subscribed; calls go through.
  connected,

  /// The pipe does not exist: the service is not installed or not running
  /// ("repair installation").
  serviceMissing,

  /// The service speaks another protocol or plan version.
  versionMismatch,

  /// A connection was lost; a reconnect is scheduled.
  disconnected,
}

final class ServiceClientState {
  const ServiceClientState(this.phase, {this.hello, this.message});

  final ServiceClientPhase phase;

  /// The service's hello, on [ServiceClientPhase.connected] and
  /// [ServiceClientPhase.versionMismatch].
  final ServiceHello? hello;

  /// Why the client is not connected, for the UI.
  final String? message;

  bool get isConnected => phase == ServiceClientPhase.connected;

  @override
  bool operator ==(Object other) =>
      other is ServiceClientState &&
      phase == other.phase &&
      hello == other.hello &&
      message == other.message;

  @override
  int get hashCode => Object.hash(phase, hello, message);

  @override
  String toString() =>
      'ServiceClientState($phase'
      '${hello == null ? '' : ', $hello'}'
      '${message == null ? '' : ', $message'})';
}

/// Reconnect delays: a short first retry, then doubling up to [max].
final class ServiceBackoff {
  const ServiceBackoff({
    this.initial = const Duration(milliseconds: 500),
    this.max = const Duration(seconds: 5),
  });

  final Duration initial;
  final Duration max;

  Duration delay(int failures) {
    if (failures <= 0) return initial;
    var delay = initial;
    for (var i = 1; i < failures && delay < max; i++) {
      delay *= 2;
    }
    return delay > max ? max : delay;
  }
}

/// The app's client to the service (docs/design/08-windows.md, "IPC"): dials
/// with a short backoff, verifies the hello, subscribes, forwards pushes and
/// re-dials whenever the connection drops. The service keeps running the
/// current plan across app restarts, so a reconnect only re-subscribes.
final class ServiceClient {
  ServiceClient({
    required this._connect,
    this.backoff = const ServiceBackoff(),
    this.helloTimeout = const Duration(seconds: 5),
  });

  final ServiceTransportConnector _connect;
  final ServiceBackoff backoff;
  final Duration helloTimeout;

  final _states = StreamController<ServiceClientState>.broadcast();
  final _status = StreamController<RuntimeStatus>.broadcast();
  final _logLines = StreamController<List<LogLine>>.broadcast();
  final _traffic = StreamController<TrafficSnapshot>.broadcast();

  var _state = const ServiceClientState(ServiceClientPhase.disconnected);
  ServiceConnection? _connection;
  Completer<void>? _wakeup;
  Future<void>? _loop;
  bool _running = false;

  ServiceClientState get state => _state;
  bool get isConnected => _state.isConnected;

  /// Every state change, after [state] was updated.
  Stream<ServiceClientState> get states => _states.stream;
  Stream<RuntimeStatus> get statusChanged => _status.stream;
  Stream<List<LogLine>> get logLines => _logLines.stream;
  Stream<TrafficSnapshot> get trafficChanged => _traffic.stream;

  /// Starts dialing; idempotent.
  void start() {
    if (_running) return;
    _running = true;
    _loop = _run();
  }

  /// Closes the connection and stops reconnecting.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _wake();
    final connection = _connection;
    _connection = null;
    await connection?.close();
    await _loop;
    _loop = null;
    _setState(const ServiceClientState(ServiceClientPhase.disconnected));
  }

  /// Skips the current backoff wait and dials right away.
  void retryNow() => _wake();

  /// The wait's timer can have completed the wakeup already — `_wait` only
  /// clears it a microtask later — and completing it twice throws.
  void _wake() {
    final wakeup = _wakeup;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
  }

  // Calls

  // `async` so that "not connected" surfaces as a Future error, never as a
  // synchronous throw from the call site.
  Future<DaemonInfo> getInfo() async => _current.getInfo();
  Future<RuntimeStatus> getStatus() async => _current.getStatus();
  Future<ApplyResult> apply(RuntimePlan plan) async => _current.apply(plan);
  Future<ApplyResult> stopEngine() async => _current.stop();
  Future<ApplyResult> reconnect(String tunnelID) async =>
      _current.reconnect(tunnelID);
  Future<DaemonDiagnostics> collectDiagnostics() async =>
      _current.collectDiagnostics();

  ServiceConnection get _current {
    final connection = _connection;
    if (connection == null || !_state.isConnected) {
      throw ServiceException(
        ServiceErrorKind.notConnected,
        _state.message ?? 'not connected to the Wayfork service',
      );
    }
    return connection;
  }

  // Loop

  Future<void> _run() async {
    var failures = 0;
    while (_running) {
      _setState(const ServiceClientState(ServiceClientPhase.connecting));
      final ServiceConnection connection;
      try {
        connection = await ServiceConnection.open(
          await _connect(),
          helloTimeout: helloTimeout,
        );
      } on ServiceUnavailableException catch (error) {
        failures += 1;
        _setState(
          ServiceClientState(
            ServiceClientPhase.serviceMissing,
            message: error.message,
          ),
        );
        await _wait(backoff.delay(failures));
        continue;
      } on Object catch (error) {
        failures += 1;
        _setState(
          ServiceClientState(
            ServiceClientPhase.disconnected,
            message: _describe(error),
          ),
        );
        await _wait(backoff.delay(failures));
        continue;
      }
      if (!_running) {
        await connection.close();
        break;
      }
      final hello = connection.hello;
      if (!hello.isCompatible) {
        await connection.close();
        failures += 1;
        _setState(
          ServiceClientState(
            ServiceClientPhase.versionMismatch,
            hello: hello,
            message:
                'service speaks protocol ${hello.protocol} / plan '
                '${hello.planVersion}, this app expects '
                '$serviceProtocolVersion / ${RuntimePlan.currentVersion}',
          ),
        );
        await _wait(backoff.max);
        continue;
      }
      _connection = connection;
      final forward = [
        connection.statusChanged.listen(_status.add),
        connection.logLines.listen(_logLines.add),
        connection.trafficChanged.listen(_traffic.add),
      ];
      try {
        await connection.subscribe();
      } on ServiceException catch (error) {
        for (final subscription in forward) {
          await subscription.cancel();
        }
        _connection = null;
        await connection.close();
        failures += 1;
        _setState(
          ServiceClientState(
            ServiceClientPhase.disconnected,
            message: error.message,
          ),
        );
        await _wait(backoff.delay(failures));
        continue;
      }
      failures = 0;
      _setState(ServiceClientState(ServiceClientPhase.connected, hello: hello));
      await connection.done;
      for (final subscription in forward) {
        await subscription.cancel();
      }
      if (identical(_connection, connection)) _connection = null;
      if (!_running) break;
      _setState(
        const ServiceClientState(
          ServiceClientPhase.disconnected,
          message: 'connection to the Wayfork service was lost',
        ),
      );
      await _wait(backoff.delay(failures));
    }
  }

  Future<void> _wait(Duration delay) async {
    if (!_running) return;
    final wakeup = Completer<void>();
    _wakeup = wakeup;
    final timer = Timer(delay, () {
      if (!wakeup.isCompleted) wakeup.complete();
    });
    await wakeup.future;
    timer.cancel();
    if (identical(_wakeup, wakeup)) _wakeup = null;
  }

  void _setState(ServiceClientState state) {
    if (state == _state) return;
    _state = state;
    _states.add(state);
  }

  static String _describe(Object error) => switch (error) {
    ServiceException(:final message) => message,
    ServiceTransportException(:final message) => message,
    _ => '$error',
  };
}
