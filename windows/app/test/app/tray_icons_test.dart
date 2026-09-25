import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/services/tray_icons.dart';
import 'package:wayfork/app/services/system_theme.dart';
import 'package:wayfork/core/app/global_state.dart';

void main() {
  test('every global state maps to a glyph', () {
    TrayIcon icon(
      GlobalState state, {
      bool pulse = false,
      bool repair = false,
    }) => TrayIcons.forState(state, pulse: pulse, needsRepair: repair);

    expect(icon(const GlobalState.off()), TrayIcon.off);
    expect(icon(const GlobalState.on()), TrayIcon.on);
    expect(
      icon(const GlobalState.degraded(failingTunnelIDs: ['a'])),
      TrayIcon.degraded,
    );
    expect(icon(const GlobalState.error(reason: 'x')), TrayIcon.error);
    // Starting and stopping alternate with the dimmed twin.
    expect(icon(const GlobalState.starting()), TrayIcon.on);
    expect(icon(const GlobalState.starting(), pulse: true), TrayIcon.pulse);
    expect(icon(const GlobalState.stopping(), pulse: true), TrayIcon.pulse);
    // A service that has to be repaired outranks the routing state.
    expect(icon(const GlobalState.on(), repair: true), TrayIcon.error);
  });

  test('asset paths name the taskbar theme', () {
    expect(
      TrayIcons.asset(TrayIcon.degraded, TrayTheme.light),
      'assets/tray/light/degraded.ico',
    );
    expect(
      TrayIcons.asset(TrayIcon.pulse, TrayTheme.dark),
      'assets/tray/dark/pulse.ico',
    );
  });

  test('the taskbar theme falls back to dark off Windows', () {
    // On Windows the value is whatever the shell says; that case lives in
    // test/app/system_backends_test.dart.
    if (Platform.isWindows) return;
    expect(SystemTheme.trayTheme(), TrayTheme.dark);
  });
}
