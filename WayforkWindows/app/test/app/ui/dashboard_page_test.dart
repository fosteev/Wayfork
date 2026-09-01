import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/dashboard_page.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/traffic_format.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';

import '../../core/ipc/fake_service.dart';
import '../fakes.dart';
import 'ui_harness.dart';

final connectedWork = TunnelState.connected(
  ip: '10.8.0.27',
  interface: 'Wayfork-1',
  since: fakeSince,
);

void main() {
  testWidgets('the tiles count tunnels, rules and the combined rate', (
    tester,
  ) async {
    final app = await boot(tester, on: true);
    await goRunning(
      tester,
      app,
      tunnels: {app.sample.work.id: connectedWork},
      traffic: TrafficSnapshot(
        sampledAt: fakeSince,
        interval: 1,
        tunnels: {
          app.sample.work.id: const TrafficCounters(
            downBytesPerSecond: 1200000,
            upBytesPerSecond: 80000,
          ),
        },
        direct: const TrafficCounters(
          downBytesPerSecond: 300000,
          upBytesPerSecond: 5000,
        ),
      ),
    );

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();

    // Lab has no config in the store, so it is down: two of three are up.
    expect(find.text('3 tunnels · 2 up'), findsOneWidget);
    // Five active rules; the sixth is disabled, none of them an exception.
    expect(find.text('5 rules · 0 exceptions'), findsOneWidget);
    expect(find.text('↓ 1.5 MB/s'), findsOneWidget);
    expect(find.text('↑ 85 KB/s total'), findsOneWidget);

    // Let the staleness timer fire: the tester refuses to end a test with a
    // pending one.
    await tester.pump(const Duration(seconds: 31));
    expect(find.text('↓ —'), findsOneWidget);
  });

  testWidgets('one-way UDP flows put a warning hint on the tunnel card', (
    tester,
  ) async {
    final app = await boot(tester, on: true);
    await goRunning(
      tester,
      app,
      tunnels: {app.sample.work.id: connectedWork},
      traffic: TrafficSnapshot(
        sampledAt: fakeSince,
        interval: 1,
        tunnels: {
          app.sample.work.id: const TrafficCounters(
            upBytesPerSecond: 80000,
            oneWayUDPFlows: 2,
          ),
        },
        direct: TrafficCounters.zero,
      ),
    );

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(FluentIcons.warning), findsOneWidget);
    expect(find.byTooltip(TrafficFormat.oneWayUDPHint(2)), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('every enabled tunnel gets a card, Direct closes the list', (
    tester,
  ) async {
    final app = await boot(tester, on: true);
    await goRunning(tester, app, tunnels: {app.sample.work.id: connectedWork});

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();

    // The names also fill the quick-add picker, so the rows are counted by
    // their glyphs: three tunnels and Direct.
    expect(find.byType(StatusGlyphView), findsNWidgets(4));
    expect(find.text('OpenVPN'), findsNWidgets(2));
    expect(find.text('VLESS'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(
      find.text('connected · 10.8.0.27 on Wayfork-1 · 3 rules'),
      findsOneWidget,
    );
  });

  testWidgets('the header toggle turns routing off', (tester) async {
    final app = await boot(tester, on: true);
    // The toggle is dead while a transition is in flight, so the status has to
    // land first.
    await goRunning(tester, app);
    expect(app.model.desiredOn, isTrue);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ToggleSwitch).first);
    await tester.pumpAndSettle();
    expect(app.model.desiredOn, isFalse);

    // The stop travels to the service and back; the pulse it runs meanwhile is
    // a timer the tester would otherwise find still pending.
    await pumpUntil(
      tester,
      () => app.model.transition == null,
      what: 'the stop to settle',
    );
  });

  testWidgets('quick add stores a rule for the selected tunnel', (
    tester,
  ) async {
    final app = await boot(tester, on: true);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox), 'shop.example.com');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    final rule = app.model.store.rules.last;
    expect(rule.pattern, 'shop.example.com');
    expect(rule.target, RuleTargetTunnel(app.sample.work.id));
    expect(find.text('shop.example.com'), findsNothing, reason: 'field clears');
  });

  testWidgets('an invalid pattern stays in the field with its message', (
    tester,
  ) async {
    final app = await boot(tester, on: true);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox), 'not a domain');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('not a domain'), findsOneWidget);
    expect(app.model.store.rules, hasLength(6));
  });

  testWidgets('an existing pattern turns Add into Update', (tester) async {
    final app = await boot(tester, on: true);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox), 'news.example.org');
    await tester.pumpAndSettle();

    expect(find.text('Update'), findsOneWidget);
    expect(find.text('Add'), findsNothing);
  });

  testWidgets('an empty store sends the user to Tunnels', (tester) async {
    final app = await boot(tester, store: Store.empty);
    final navigator = AppNavigator();

    await tester.pumpWidget(
      scoped(app.model, navigator, const DashboardPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('No tunnels yet.'), findsOneWidget);

    await tester.tap(find.text('Add a tunnel…'));
    await tester.pumpAndSettle();
    expect(navigator.page, AppPage.tunnels);
  });

  testWidgets('a failed tunnel offers the fix its failure asks for', (
    tester,
  ) async {
    final app = await boot(tester, on: true);
    await tester.runAsync(() async {
      app.service.current.pushStatus(
        running(
          planHash: app.model.lastPlan!.planHash,
          tunnels: {
            app.sample.work.id: const TunnelState.failed(
              reason: 'ovpn.authFailed',
              permanent: true,
            ),
          },
        ),
      );
      await waitFor(
        () => app.model.card(app.sample.work).isError,
        what: 'the failed card',
      );
    });

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const DashboardPage()),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('failed: server rejected username/password'),
      findsOneWidget,
    );

    // Lab is broken too (no config in the store); Work's card comes first.
    await tester.tap(find.byIcon(FluentIcons.edit).first);
    await tester.pumpAndSettle();
    expect(app.model.expandedTunnelID, app.sample.work.id);
  });
}
