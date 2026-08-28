import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/app_shell.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/ipc/service_connection.dart';
import 'package:wayfork/core/model/store.dart';

import '../fakes.dart';
import '../lifecycle_fakes.dart';

/// The whole window, as `main.dart` assembles it.
Widget shell(
  AppModel model,
  AppNavigator navigator,
  List<AppAction> performed, {
  FilePicker? picker,
}) => scoped(
  model,
  navigator,
  AppShell(onAction: performed.add, picker: picker ?? FakeFilePicker()),
);

/// One page under the two scopes it reads, without the navigation view around
/// it — enough for a page test and a lot less to pump.
Widget scoped(AppModel model, AppNavigator navigator, Widget child) =>
    FluentApp(
      debugShowCheckedModeBanner: false,
      home: AppScope(
        model: model,
        child: NavigationScope(navigator: navigator, child: child),
      ),
    );

/// Alternates real time with the tester's fake clock until [done] holds. The
/// model's work crosses both: the fake pipe and its timers run in real async
/// (`runAsync`), while everything the widgets do only moves on a pump.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String what = 'condition',
  int attempts = 400,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
  if (!done()) throw StateError('$what did not hold');
}

/// The model runs on real timers (service client, debounces), so its setup has
/// to happen outside the widget tester's fake clock.
Future<Harness> boot(
  WidgetTester tester, {
  bool serviceAvailable = true,
  RuntimeStatus? status,
  File? corruptBackup,
  Store? store,
  bool on = false,
  bool Function(Harness app)? until,
}) async {
  // A UI test spends far more than the model tests' 60 ms between pushing a
  // sample and reading the rate off the screen.
  final app = Harness(
    store: store,
    trafficStaleAfter: const Duration(seconds: 30),
  );
  addTearDown(() => tester.runAsync(app.dispose));
  await tester.runAsync(() async {
    app.service.available = serviceAvailable;
    if (status != null) app.service.status = status;
    if (on && status == null) app.service.status = RuntimeStatus.stopped;
    app.storage.corruptBackup = corruptBackup;
    await app.start();
  });
  if (on) {
    // Turn On talks to the service, which only answers between pumps: start it
    // outside the fake clock and then let both queues run until it settles.
    var settled = false;
    await tester.runAsync(() async {
      unawaited(app.model.turnOn().whenComplete(() => settled = true));
    });
    await pumpUntil(tester, () => settled, what: 'Turn On');
    if (!app.model.desiredOn) {
      throw StateError('Turn On failed: ${app.appLog.join(', ')}');
    }
  }
  if (until != null) {
    await pumpUntil(tester, () => until(app), what: 'the state the test needs');
  }
  return app;
}

/// Pushes a running status (with the plan the model applied) and, optionally,
/// one traffic sample, then pumps until the model has both.
Future<void> goRunning(
  WidgetTester tester,
  Harness app, {
  Map<String, TunnelState>? tunnels,
  TrafficSnapshot? traffic,
}) async {
  await tester.runAsync(() async {
    app.service.current.pushStatus(
      running(planHash: app.model.lastPlan!.planHash, tunnels: tunnels),
    );
    if (traffic != null) {
      app.service.current.push(ServiceEvent.trafficChanged, traffic.toJson());
    }
  });
  await pumpUntil(
    tester,
    () =>
        app.model.globalState.isRunning &&
        (traffic == null || app.model.traffic != null),
    what: 'the running status',
  );
}
