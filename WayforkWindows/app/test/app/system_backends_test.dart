import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/services/launch_at_login_registry.dart';
import 'package:wayfork/app/services/network_watcher.dart';
import 'package:wayfork/app/services/single_instance.dart';
import 'package:wayfork/app/services/system_theme.dart';
import 'package:wayfork/app/services/tray_icons.dart';
import 'package:wayfork/app/services/windows_registry.dart';
import 'package:wayfork/core/plan/system_dns.dart';

void main() {
  test('the network watcher only reports real changes', () async {
    var snapshot = SystemDnsSnapshot(const ['192.168.1.1'], '192.168.1.1');
    final watcher = SystemNetworkWatcher(
      interval: const Duration(hours: 1),
      snapshot: () => snapshot,
    );
    addTearDown(watcher.dispose);
    final events = <void>[];
    watcher.changes.listen(events.add);
    watcher.start();

    // The first reading is the baseline, and an identical one is not news.
    watcher.poll();
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);

    // Wi-Fi to Ethernet: other resolvers, other gateway.
    snapshot = SystemDnsSnapshot(const ['10.0.0.1'], '10.0.0.1');
    watcher.poll();
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));

    watcher.poll();
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
  });

  test('a failing lookup does not kill the watcher', () async {
    var fail = true;
    final watcher = SystemNetworkWatcher(
      interval: const Duration(hours: 1),
      snapshot: () {
        if (fail) throw StateError('GetAdaptersAddresses failed');
        return SystemDnsSnapshot(const ['1.1.1.1'], null);
      },
    );
    addTearDown(watcher.dispose);
    final events = <void>[];
    watcher.changes.listen(events.add);
    watcher.start();

    fail = false;
    // The first successful reading becomes the baseline, the next is silent.
    watcher.poll();
    watcher.poll();
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
  });

  test('launch at login writes a quoted command that starts into the tray', () {
    final launch = RegistryLaunchAtLogin(
      executable: r'C:\Program Files\Wayfork\wayfork.exe',
    );
    expect(
      launch.command,
      r'"C:\Program Files\Wayfork\wayfork.exe" --minimized',
    );
    expect(
      RegistryLaunchAtLogin.runKey,
      r'Software\Microsoft\Windows\CurrentVersion\Run',
    );
    // Off Windows there is no value to find, and enabling is refused loudly.
    if (!Platform.isWindows) {
      expect(launch.isEnabled, isFalse);
      expect(() => launch.setEnabled(true), throwsUnsupportedError);
    }
  });

  test('the Run value round-trips through the registry', () {
    if (!Platform.isWindows) return;
    // A name of its own: the real one belongs to the user's settings.
    final launch = RegistryLaunchAtLogin(
      executable: r'C:\Wayfork\wayfork.exe',
      valueName: 'WayforkTest',
    );
    addTearDown(() => launch.setEnabled(false));

    expect(launch.isEnabled, isFalse);
    launch.setEnabled(true);
    expect(launch.isEnabled, isTrue);
    expect(
      WindowsRegistry.readString(RegistryLaunchAtLogin.runKey, 'WayforkTest'),
      launch.command,
    );
    launch.setEnabled(false);
    expect(launch.isEnabled, isFalse);
    // Deleting a value that is already gone is not an error.
    launch.setEnabled(false);
  });

  test('the single-instance guard owns a named event', () {
    if (!Platform.isWindows) {
      expect(SingleInstance.acquire(), isTrue);
      expect(SingleInstance.activateExisting(), isFalse);
      expect(SingleInstance.holdsInstance, isFalse);
      return;
    }
    const name = r'Local\Wayfork.SingleInstanceTest';
    expect(SingleInstance.acquire(name: name), isTrue);
    expect(SingleInstance.holdsInstance, isTrue);
    // The second caller finds the event and steps aside.
    expect(SingleInstance.acquire(name: name), isFalse);
    SingleInstance.release();
    expect(SingleInstance.holdsInstance, isFalse);
    // With the event gone the name is free again.
    expect(SingleInstance.acquire(name: name), isTrue);
    SingleInstance.release();
  });

  test('the taskbar theme is readable on Windows', () {
    if (!Platform.isWindows) return;
    expect(TrayTheme.values, contains(SystemTheme.trayTheme()));
    // A value that cannot exist reads as absent rather than throwing.
    expect(
      WindowsRegistry.readDword(SystemTheme.personalizeKey, 'WayforkNoSuch'),
      isNull,
    );
  });
}
