import 'dart:math';

/// How long the app waits before re-applying after the routing engine failed
/// (H2, docs/design/05-daemon.md, "Engine failure recovery"). `failed` is
/// terminal for the service, so recovery is the app's job: it keeps trying for
/// as long as the user wants routing on, slowing down but never giving up — the
/// cause is usually another VPN or an adapter that comes back on its own. The
/// port of the Swift `RecoveryBackoff`.
final class RecoveryBackoff {
  RecoveryBackoff({List<Duration>? delays}) : delays = delays ?? defaultDelays;

  /// Delay before attempt 1, 2, 3 …; the last one repeats.
  static const defaultDelays = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
    Duration(seconds: 300),
  ];

  final List<Duration> delays;

  int _failures = 0;

  /// Failures in the current streak (0 = the engine is up, or was never seen
  /// failing).
  int get failures => _failures;

  /// A streak is running: the failure has been reported and retries are under
  /// way.
  bool get isRecovering => _failures > 0;

  /// Registers one more failure and returns how long to wait before re-applying.
  Duration nextDelay() {
    _failures += 1;
    return delays[min(_failures, delays.length) - 1];
  }

  void reset() => _failures = 0;
}
