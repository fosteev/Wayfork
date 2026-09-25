import 'dart:async';

import 'package:wayfork/core/plan/system_dns.dart';

/// The `networkChanges` source of `AppModel` — the Windows stand-in for the
/// macOS `SystemDNS.Watcher` on `State:/Network/Global/DNS`.
///
/// Windows does have event APIs here (`NotifyIpInterfaceChange`,
/// `NotifyRouteChange2`), and they are deliberately not used: neither fires
/// when only an adapter's resolver list changes, because those live in the
/// Tcpip registry — and a DHCP lease that hands out new resolvers is exactly
/// the case F12 cares about. Their callbacks also arrive on arbitrary OS
/// threads, which an FFI listener then has to marshal back into the isolate.
/// A snapshot is one `GetAdaptersAddresses` call plus two registry reads, so
/// polling it covers strictly more ground at a cost that does not show up in a
/// profile, and the model ignores a tick whose resolvers and gateway match
/// what it applied.
final class SystemNetworkWatcher {
  SystemNetworkWatcher({
    this.interval = const Duration(seconds: 5),
    this._snapshot = SystemDns.snapshot,
  });

  final Duration interval;
  final SystemDnsSnapshot Function() _snapshot;
  final _changes = StreamController<void>.broadcast();

  Timer? _timer;
  SystemDnsSnapshot? _last;

  /// One event per observed change; nothing is emitted for the first reading.
  Stream<void> get changes => _changes.stream;

  void start() {
    if (_timer != null) return;
    _last = _read();
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  /// Reads now and emits when the picture moved; also the test seam.
  void poll() => _poll();

  void _poll() {
    final snapshot = _read();
    if (snapshot == null) return;
    final previous = _last;
    _last = snapshot;
    if (previous == null || previous == snapshot) return;
    if (!_changes.isClosed) _changes.add(null);
  }

  SystemDnsSnapshot? _read() {
    try {
      return _snapshot();
    } on Object {
      // A transient Win32 failure must not kill the timer.
      return null;
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _changes.close();
  }
}
