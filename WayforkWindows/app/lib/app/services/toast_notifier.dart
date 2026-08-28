import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:wayfork/app/services/notifier.dart';

/// Windows toasts for the permanent failures of docs/design/02-ux.md
/// ("Notifications"). Posting is best effort: a notification that the shell
/// refuses must never take a routing decision down with it.
final class ToastNotifier implements Notifier {
  ToastNotifier._(this._notifier);

  static const appName = 'Wayfork';

  /// Initialises the platform side. Returns a [SilentNotifier] when the shell
  /// will not have us (no Start Menu shortcut, an unsupported host).
  static Future<Notifier> start({
    String name = appName,
    LocalNotifier? notifier,
  }) async {
    final local = notifier ?? localNotifier;
    try {
      await local.setup(appName: name);
      return ToastNotifier._(local);
    } on Object catch (error) {
      debugPrint('toast notifications unavailable: $error');
      return const SilentNotifier();
    }
  }

  final LocalNotifier _notifier;
  final _shown = <String, LocalNotification>{};

  @override
  Future<void> post({
    required String id,
    required String title,
    required String body,
  }) async {
    try {
      final previous = _shown.remove(id);
      if (previous != null) await _notifier.destroy(previous);
      final notification = LocalNotification(
        identifier: id,
        title: title,
        body: body,
      );
      _shown[id] = notification;
      await _notifier.notify(notification);
    } on Object catch (error) {
      debugPrint('cannot post notification $id: $error');
    }
  }

  /// Drops every toast this session posted; call before quitting so nothing
  /// outlives the app.
  Future<void> dispose() async {
    for (final notification in _shown.values.toList()) {
      try {
        await _notifier.destroy(notification);
      } on Object {
        // Best effort.
      }
    }
    _shown.clear();
  }
}
