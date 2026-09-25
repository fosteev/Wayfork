import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/services/tray_controller.dart';
import 'package:wayfork/app/services/tray_icons.dart';
import 'package:wayfork/app/services/window_controller.dart';
import 'package:wayfork/app/ui/app_actions.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/core/ipc/payloads.dart';

import 'fakes.dart';
import 'lifecycle_fakes.dart';

/// A tray controller over the fakes, with the pieces the tests poke at.
final class TrayHarness {
  TrayHarness(this.app, {this.theme = TrayTheme.dark}) {
    window = WindowController(windowBackend);
    actions = AppActionHandler(
      model: app.model,
      navigator: navigator,
      window: window,
      reveal: (path) async => revealed.add(path),
    );
    controller = TrayController(
      model: app.model,
      backend: backend,
      window: window,
      navigator: navigator,
      actions: actions,
      onQuit: () async => quits += 1,
      theme: () => theme,
      refreshInterval: const Duration(hours: 1),
    );
  }

  final Harness app;
  final backend = FakeTrayBackend();
  final windowBackend = FakeWindowBackend();
  final navigator = AppNavigator();
  final revealed = <String>[];
  final TrayTheme theme;
  late final WindowController window;
  late final AppActionHandler actions;
  late final TrayController controller;
  int quits = 0;

  Future<void> start() async {
    await window.start();
    await controller.start();
  }

  Future<void> dispose() async {
    await controller.dispose();
    await actions.dispose();
    await app.dispose();
  }
}

void main() {
  test('start publishes the icon, the tooltip and the menu once', () async {
    final app = Harness();
    app.service.status = RuntimeStatus.stopped;
    await app.start();
    final harness = TrayHarness(app);
    addTearDown(harness.dispose);
    await harness.start();

    expect(harness.backend.icon, 'assets/tray/dark/off.ico');
    expect(harness.backend.toolTip, startsWith('Wayfork — Off'));
    expect(harness.backend.menus, hasLength(1));

    // Nothing changed: nothing is pushed again.
    await harness.controller.refresh();
    expect(harness.backend.icons, hasLength(1));
    expect(harness.backend.toolTips, hasLength(1));
    expect(harness.backend.menus, hasLength(1));
  });

  test('the icon follows the model and the taskbar theme', () async {
    final app = Harness();
    app.service.status = RuntimeStatus.stopped;
    await app.start();
    final harness = TrayHarness(app, theme: TrayTheme.light);
    addTearDown(harness.dispose);
    await harness.start();
    expect(harness.backend.icon, 'assets/tray/light/off.ico');

    await app.model.turnOn();
    await waitFor(
      () => harness.backend.icon == 'assets/tray/light/on.ico',
      what: 'the on icon',
    );
  });

  test('a long summary is trimmed to what szTip holds', () async {
    final app = Harness();
    await app.start();
    await app.model.update(
      (store) => store.copyWith(
        tunnels: [
          for (final tunnel in store.tunnels)
            tunnel.id == app.sample.work.id
                ? tunnel.copyWith(name: 'W' * 200)
                : tunnel,
        ],
        defaultTunnelID: app.sample.work.id,
      ),
    );
    final harness = TrayHarness(app);
    addTearDown(harness.dispose);
    await harness.start();

    final tip = harness.backend.toolTip!;
    expect(app.model.summary.length, greaterThan(TrayController.toolTipLimit));
    expect(tip, hasLength(TrayController.toolTipLimit));
    expect(tip, endsWith('…'));
  });

  test('clicks and the context menu reach the window', () async {
    final app = Harness();
    await app.start();
    final harness = TrayHarness(app);
    addTearDown(harness.dispose);
    await harness.start();

    // Left click hides the window that is in front, then brings it back.
    harness.backend.activate();
    await waitFor(
      () => !harness.windowBackend.visible,
      what: 'the window to hide',
    );
    harness.backend.activate();
    await waitFor(
      () => harness.windowBackend.visible,
      what: 'the window to return',
    );

    harness.backend.requestMenu();
    await waitFor(() => harness.backend.popUps == 1, what: 'the context menu');
  });

  test('every menu command is wired', () async {
    final app = Harness();
    await app.startOn();
    app.service.current.pushStatus(
      running(planHash: app.model.lastPlan!.planHash),
    );
    await app.settle();
    final harness = TrayHarness(app);
    addTearDown(harness.dispose);
    await harness.start();
    await harness.window.hide();

    harness.backend.click('open');
    await waitFor(() => harness.windowBackend.visible, what: 'Open Wayfork');

    harness.backend.click('quickAdd');
    await waitFor(
      () => harness.navigator.quickAddToken == 1,
      what: 'the quick-add jump',
    );
    expect(harness.navigator.page, AppPage.dashboard);

    harness.backend.click('logs');
    await waitFor(() => harness.navigator.page == AppPage.logs, what: 'Logs');

    harness.backend.click('settings');
    await waitFor(
      () => harness.navigator.page == AppPage.general,
      what: 'Settings',
    );

    app.service.knownTunnelIDs.addAll([app.sample.work.id, app.sample.lab.id]);
    harness.backend.click('reconnect.${app.sample.work.id}');
    await waitFor(
      () => app.appLog.contains('reconnect requested for Work'),
      what: 'the single reconnect',
    );

    harness.backend.click('reconnect.all');
    await waitFor(
      () =>
          app.appLog
              .where((line) => line.startsWith('reconnect requested'))
              .length ==
          3,
      what: 'reconnect all',
    );

    harness.backend.click('toggle');
    await waitFor(() => !app.model.desiredOn, what: 'Turn Off');

    harness.backend.click('quit');
    await waitFor(() => harness.quits == 1, what: 'Quit');
  });

  test('Repair Installation opens the General page', () async {
    final app = Harness();
    app.service.available = false;
    await app.start();
    await waitFor(
      () => app.model.serviceIssue?.needsRepair ?? false,
      what: 'the missing service',
    );
    final harness = TrayHarness(app);
    addTearDown(harness.dispose);
    await harness.start();
    await harness.window.hide();

    harness.backend.click('repair');
    await waitFor(
      () => harness.navigator.page == AppPage.general,
      what: 'Repair Installation',
    );
    expect(harness.windowBackend.visible, isTrue);
  });

  test('the action stream reveals a file instead of navigating', () async {
    final app = Harness();
    await app.start();
    final harness = TrayHarness(app);
    addTearDown(harness.dispose);
    await harness.start();

    await harness.actions.handle(
      const AppAction.revealFile(r'C:\x\store.json'),
    );
    expect(harness.revealed, [r'C:\x\store.json']);
  });

  test('a shell that refuses the icon is logged, not fatal', () async {
    final app = Harness();
    app.service.status = RuntimeStatus.stopped;
    await app.start();
    final harness = TrayHarness(app);
    addTearDown(harness.dispose);
    harness.backend.iconFailure = StateError('Shell_NotifyIcon failed');

    await harness.start();
    expect(harness.backend.icons, isEmpty);
    expect(app.appLog, contains(contains('tray icon:')));

    // The next refresh retries everything, de-duplication included.
    harness.backend.iconFailure = null;
    await harness.controller.refresh();
    expect(harness.backend.icon, 'assets/tray/dark/off.ico');
    expect(harness.backend.menus, hasLength(1));
  });

  test('dispose takes the icon down', () async {
    final app = Harness();
    await app.start();
    final harness = TrayHarness(app);
    await harness.start();
    await harness.dispose();
    expect(harness.backend.disposals, 1);
  });
}
