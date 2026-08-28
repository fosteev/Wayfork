import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/services/tray_menu.dart';
import 'package:wayfork/core/ipc/payloads.dart';

import 'fakes.dart';

List<String> keys(List<TrayMenuEntry> entries) => [
  for (final entry in entries)
    if (entry is TrayMenuItem) entry.key else '---',
];

TrayMenuItem item(List<TrayMenuEntry> entries, String key) =>
    entries.whereType<TrayMenuItem>().firstWhere((item) => item.key == key);

void main() {
  test('the menu follows the prototype while off', () async {
    final harness = Harness();
    harness.service.status = RuntimeStatus.stopped;
    await harness.start();
    addTearDown(harness.dispose);

    final entries = TrayMenu.build(harness.model);
    expect(keys(entries), [
      'toggle',
      'summary',
      '---',
      'open',
      'quickAdd',
      '---',
      'reconnect',
      'logs',
      'settings',
      '---',
      'quit',
    ]);
    expect(item(entries, 'toggle').label, 'Wayfork is Off');
    expect(item(entries, 'toggle').checked, isFalse);
    expect(item(entries, 'summary').enabled, isFalse);
    expect(item(entries, 'summary').label, harness.model.summary);
    // Nothing is running, so there is nothing to reconnect.
    expect(item(entries, 'reconnect').enabled, isFalse);
    expect(item(entries, 'reconnect').submenu, isNull);
  });

  test('running lists the OpenVPN tunnels under Reconnect', () async {
    final harness = Harness();
    await harness.startOn();
    harness.service.current.pushStatus(
      running(planHash: harness.model.lastPlan!.planHash),
    );
    await harness.settle();
    addTearDown(harness.dispose);

    final entries = TrayMenu.build(harness.model);
    expect(item(entries, 'toggle').label, 'Wayfork is On');
    expect(item(entries, 'toggle').checked, isTrue);
    final reconnect = item(entries, 'reconnect');
    expect(reconnect.enabled, isTrue);
    final submenu = reconnect.submenu!;
    expect(keys(submenu), [
      'reconnect.all',
      '---',
      'reconnect.${harness.sample.work.id}',
      'reconnect.${harness.sample.lab.id}',
    ]);
    // Home is VLESS: it lives inside sing-box and has no process to restart.
    expect(submenu.whereType<TrayMenuItem>().map((entry) => entry.label), [
      'All Tunnels',
      'Work',
      'Lab',
    ]);
    expect(
      item(submenu, 'reconnect.${harness.sample.work.id}').command,
      TrayCommand.reconnect(harness.sample.work.id),
    );
    expect(
      item(submenu, 'reconnect.all').command,
      const TrayCommand.reconnect(),
    );
  });

  test('the toggle is dead while a transition is in flight', () async {
    final harness = Harness();
    harness.service.status = RuntimeStatus.stopped;
    await harness.start();
    addTearDown(harness.dispose);

    final turningOn = harness.model.turnOn();
    expect(item(TrayMenu.build(harness.model), 'toggle').enabled, isFalse);
    await turningOn;
  });

  test('a service that needs repairing gets its own entry', () async {
    final harness = Harness();
    harness.service.available = false;
    await harness.start();
    await harness.settle();
    addTearDown(harness.dispose);

    final entries = TrayMenu.build(harness.model);
    expect(keys(entries).take(4), ['toggle', 'summary', 'repair', '---']);
    expect(item(entries, 'repair').command, const TrayCommand.repair());
    expect(item(entries, 'summary').label, contains('Repair the installation'));
  });
}
