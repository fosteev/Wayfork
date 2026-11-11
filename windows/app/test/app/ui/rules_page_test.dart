import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/rules_page.dart';
import 'package:wayfork/core/app/running_app.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/secrets/secret_store.dart';

import '../../core/app/sample_store.dart';
import '../fakes.dart';
import '../lifecycle_fakes.dart';
import 'ui_harness.dart';

/// The page with the two halves of its "Application…" — the running apps it
/// lists and the file dialog behind *Browse…* — and the actions it emits.
({
  Widget widget,
  FakeFilePicker picker,
  FakeRunningApps apps,
  List<AppAction> performed,
})
page(Harness app, AppNavigator navigator, {FakeRunningApps? apps}) {
  app.model.listPreferences.initialized = true;
  app.model.listPreferences.expanded.addAll(
    app.model.store.lists.map((l) => l.id),
  );
  final picker = FakeFilePicker();
  final running = apps ?? FakeRunningApps();
  final performed = <AppAction>[];
  return (
    widget: scoped(
      app.model,
      navigator,
      RulesPage(picker: picker, runningApps: running, onAction: performed.add),
    ),
    picker: picker,
    apps: running,
    performed: performed,
  );
}

/// The group order on screen: Direct, then the tunnels of the store.
Future<void> openGroupMenu(WidgetTester tester, int group, String item) async {
  await tester.ensureVisible(find.text('Add site or app').at(group));
  await tester.tap(find.text('Add site or app').at(group));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

Future<void> submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(RuleEditor).first, text);
  await tester.pumpAndSettle();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('purpose lists follow user order with a separate default line', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();
    expect(find.text('Everything else'), findsOneWidget);
    expect(find.text('Not via any tunnel'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Work').first).dy,
      lessThan(tester.getTopLeft(find.text('Home').first).dy),
    );
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('*.cdn.example.com'), findsOneWidget);
    expect(find.text('pattern'), findsOneWidget);
  });

  testWidgets('Site adds an inherited rule at the end of its list', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await openGroupMenu(tester, 1, 'Site');
    expect(find.byType(RuleEditor), findsOneWidget);
    await submit(tester, 'shop.example.com');

    final rule = app.model.store.rulesForTunnel(app.sample.home.id).last;
    expect(rule.pattern, 'shop.example.com');
    expect(rule.match, RuleMatch.suffix);
    expect(find.byType(RuleEditor), findsNothing, reason: 'the row committed');
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('a pattern the model refuses keeps the editor and says why', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await openGroupMenu(tester, 0, 'Site');
    await submit(tester, 'not a domain');

    expect(find.text('Not a valid domain'), findsOneWidget);
    expect(find.byType(RuleEditor), findsOneWidget);
    expect(app.model.store.exceptions, isEmpty);
  });

  testWidgets('the match follows what is typed', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await openGroupMenu(tester, 0, 'Site');
    await tester.enterText(find.byType(RuleEditor), '*.shop.example.com');
    await tester.pumpAndSettle();
    // Suffix, Exact, Wildcard and IP are the options; the editor picked one.
    expect(find.text('pattern'), findsNWidgets(2), reason: 'row and editor');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      app.model.store.rulesForTunnel(app.sample.work.id).last.match,
      RuleMatch.wildcard,
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('a double click edits the pattern in place', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('news.example.org'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('news.example.org'));
    await tester.pumpAndSettle();
    expect(find.byType(RuleEditor), findsOneWidget);

    await submit(tester, 'press.example.org');
    expect(
      app.model.store.rules.map((rule) => rule.pattern),
      contains('press.example.org'),
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('search narrows the rows and the header counts them', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextBox, 'Search sites and apps'),
      'cdn',
    );
    await tester.pumpAndSettle();

    expect(find.text('*.cdn.example.com'), findsOneWidget);
    expect(find.text('news.example.org'), findsNothing);
    expect(find.text('1 shown'), findsOneWidget);
  });

  testWidgets('the chips report paused, shadowed and a disabled tunnel', (
    tester,
  ) async {
    final sample = SampleStore();
    final destination = sample.store.ensureList(const RuleTargetDirect());
    final store = destination.store.copyWith(
      tunnels: [
        sample.work,
        sample.home,
        sample.lab.copyWith(isEnabled: false),
      ],
      rules: [
        // An exception with the same pattern shadows the tunnel rule below.
        Rule(
          pattern: 'example.com',
          target: const RuleTargetDirect(),
          listID: destination.listID,
        ),
        ...sample.store.rules,
      ],
    );
    final app = await boot(tester, store: store);
    await tester.runAsync(() async {
      await app.secrets.write(
        sampleOpenVPNConfig,
        SecretKey(SecretKind.ovpn, sample.work.id),
      );
      await app.model.recomputeMissingSecrets();
    });
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    expect(find.text('paused'), findsOneWidget, reason: 'old.example.com');
    expect(find.text('Never used — Direct → example.com wins'), findsOneWidget);
    expect(find.text('paused — Lab is off'), findsOneWidget);
  });

  testWidgets('Application… adds the app picked from the running ones', (
    tester,
  ) async {
    final app = await boot(tester);
    final view = page(
      app,
      AppNavigator(),
      apps: FakeRunningApps(
        apps: const [
          RunningApp(
            path: r'C:\Program Files\Example\example.exe',
            name: 'Example',
            windowTitle: 'Example — Untitled',
            hasWindow: true,
          ),
        ],
      ),
    );

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await openGroupMenu(tester, 0, 'Application…');
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Rule'));
    await tester.pumpAndSettle();

    expect(view.picker.openCalls, 0, reason: 'no file dialog on this path');
    final rule = app.model.store.rules
        .where((r) => r.match == RuleMatch.app)
        .single;
    expect(rule.match, RuleMatch.app);
    expect(rule.pattern, r'C:\Program Files\Example\example.exe');
    expect(find.text('example'), findsOneWidget, reason: 'the name, not path');
    expect(find.text('the app'), findsOneWidget);
    expect(find.text('not found'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('the context menu moves a rule to another group', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('news.example.org'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.pumpAndSettle();

    expect(
      app.model.store.rulesIn(app.model.store.lists.first.id).last.pattern,
      'news.example.org',
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('the context menu deletes a rule', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('docs.example.net'));
    await tester.tap(find.text('docs.example.net'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(app.model.store.rulesForTunnel(app.sample.lab.id), isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('a rule dragged onto a group header joins it', (tester) async {
    final app = await boot(tester);
    final view = page(app, AppNavigator()).widget;
    app.model.listPreferences.expanded.remove(app.model.store.lists.first.id);
    await tester.pumpWidget(view);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('docs.example.net'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('docs.example.net')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveBy(const Offset(16, 0));
    await tester.pump();
    // Bring the destination fully inside the capped scroll view while dragging.
    await tester.ensureVisible(find.text('Home').first);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('Home').first));
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(1, 1));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      app.model.store
          .rulesForTunnel(app.sample.home.id)
          .map((rule) => rule.pattern),
      contains('docs.example.net'),
    );
    expect(app.model.store.rulesForTunnel(app.sample.lab.id), isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('an app rule reveals its executable', (tester) async {
    final sample = SampleStore();
    final destination = sample.store.ensureList(const RuleTargetDirect());
    final app = await boot(
      tester,
      store: destination.store.copyWith(
        rules: [
          Rule(
            listID: destination.listID,
            pattern: r'C:\Program Files\Example\example.exe',
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
          ),
        ],
      ),
    );
    final view = page(app, AppNavigator());

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('example'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show in Explorer'));
    await tester.pumpAndSettle();

    expect(view.performed, [
      const AppAction.revealFile(r'C:\Program Files\Example\example.exe'),
    ]);
  });

  testWidgets('an app rule shows its network chip and edits the network', (
    tester,
  ) async {
    final sample = SampleStore();
    final destination = sample.store.ensureList(const RuleTargetDirect());
    final app = await boot(
      tester,
      store: destination.store.copyWith(
        rules: [
          Rule(
            listID: destination.listID,
            pattern: r'C:\Program Files\Example\example.exe',
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
            network: RuleNetwork.udp,
          ),
        ],
      ),
    );
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();
    expect(find.text('UDP only'), findsOneWidget, reason: 'the row chip');

    await tester.tap(find.text('example'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(RuleEditor), findsOneWidget);
    // The editor replaced the row; its field shows the current network.
    await tester.tap(find.text('UDP only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TCP only').last);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(app.model.store.exceptions.single.network, RuleNetwork.tcp);
    expect(find.text('TCP only'), findsOneWidget, reason: 'the row chip');
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('a new IP rule offers the network, a domain rule does not', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await openGroupMenu(tester, 0, 'Site');
    expect(find.text('TCP and UDP'), findsNothing);
    await tester.enterText(find.byType(RuleEditor), '203.0.113.0/24');
    await tester.pumpAndSettle();
    expect(find.text('TCP and UDP'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final rule = app.model.store.rulesForTunnel(app.sample.work.id).last;
    expect(rule.match, RuleMatch.ip);
    expect(rule.network, isNull);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('without tunnels Direct lists can still be created', (
    tester,
  ) async {
    final app = await boot(tester, store: Store.empty);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();
    expect(
      find.text('No lists yet. Create a list for sites, apps or IP ranges.'),
      findsOneWidget,
    );
    await tester.tap(find.text('New list'));
    await tester.pumpAndSettle();
    expect(find.text('Sites and apps'), findsOneWidget);
  });
}
