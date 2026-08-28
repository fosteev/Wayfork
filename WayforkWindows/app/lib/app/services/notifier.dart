import 'package:flutter/foundation.dart';

/// User notifications for permanent failures (docs/design/02-ux.md,
/// "Notifications"): a tunnel entered `failed` for good, the routing engine
/// crashed or could not start, the service went away. Never for transient
/// reconnects. Windows toasts arrive with WM3c; until then the console backend
/// is the only one.
abstract interface class Notifier {
  /// Posts (or replaces, by [id]) one notification.
  Future<void> post({
    required String id,
    required String title,
    required String body,
  });
}

/// Prints notifications to the debug console.
final class ConsoleNotifier implements Notifier {
  const ConsoleNotifier();

  @override
  Future<void> post({
    required String id,
    required String title,
    required String body,
  }) async {
    debugPrint('[notification $id] $title: $body');
  }
}

/// Drops notifications; for hosts without a notification surface.
final class SilentNotifier implements Notifier {
  const SilentNotifier();

  @override
  Future<void> post({
    required String id,
    required String title,
    required String body,
  }) async {}
}
