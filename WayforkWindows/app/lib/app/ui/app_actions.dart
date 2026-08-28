import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/window_controller.dart';
import 'package:wayfork/app/ui/app_navigation.dart';

typedef FileRevealer = Future<void> Function(String path);

/// Turns the model's `actions` stream — the macOS "open this window" calls —
/// into navigation, and is the single place the tray and the alert buttons go
/// through as well.
final class AppActionHandler {
  AppActionHandler({
    required this.model,
    required this.navigator,
    required this.window,
    this.reveal = revealInExplorer,
  });

  final AppModel model;
  final AppNavigator navigator;
  final WindowController window;
  final FileRevealer reveal;

  StreamSubscription<AppAction>? _subscription;

  void start() {
    _subscription ??= model.actions.listen(
      (action) => unawaited(handle(action)),
    );
  }

  Future<void> handle(AppAction action) async {
    switch (action) {
      case AppActionOpenTunnel():
        // The model already put the tunnel and the field in `expandedTunnelID`
        // / `pendingFocus`; the page reads them when it builds.
        navigator.go(AppPage.tunnels);
        await window.showAndFocus();
      case AppActionShowLogs(:final source):
        navigator.showLogs(source: source);
        await window.showAndFocus();
      case AppActionExportDiagnostics():
        // The export itself arrives with the General page (WM3f).
        navigator.go(AppPage.general);
        await window.showAndFocus();
      case AppActionRepairInstallation():
        // The service block of General carries the instructions; running the
        // MSI repair is the installer's job (WM4).
        navigator.go(AppPage.general);
        await window.showAndFocus();
      case AppActionRevealFile(:final path):
        await reveal(path);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// Opens Explorer with the file selected. Explorer exits non-zero even when it
/// worked, so the result is ignored.
Future<void> revealInExplorer(String path) async {
  if (!Platform.isWindows) return;
  try {
    await Process.start('explorer.exe', ['/select,$path']);
  } on Object catch (error) {
    debugPrint('cannot reveal $path: $error');
  }
}

/// Opens a folder in Explorer (the Logs folder of General).
Future<void> openFolderInExplorer(String path) async {
  if (!Platform.isWindows) return;
  try {
    await Process.start('explorer.exe', [path]);
  } on Object catch (error) {
    debugPrint('cannot open $path: $error');
  }
}

/// Settings › Apps › Installed apps, where Wayfork's own installer offers the
/// repair that reinstalls the service (the MSI itself lands in WM4).
Future<void> openInstalledApps() async {
  if (!Platform.isWindows) return;
  try {
    await Process.start('explorer.exe', ['ms-settings:appsfeatures']);
  } on Object catch (error) {
    debugPrint('cannot open Windows Settings: $error');
  }
}
