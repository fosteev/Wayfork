import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/rules_page.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';

import '../../core/app/sample_store.dart';
import '../fakes.dart';
import '../lifecycle_fakes.dart';
import 'ui_harness.dart';

/// The page with the picker its "Application…" uses and the actions it emits.
({Widget widget, FakeFilePicker picker, List<AppAction> performed}) page(
  Harness app,
  AppNavigator navigator,
) {
  final picker = FakeFilePicker();
  final performed = <AppAction>[];
  return (
    widget: scoped(
      app.model,
      navigator,
      RulesPage(picker: picker, onAction: performed.add),
    ),
    picker: picker,
    performed: performed,
  );
}

/// The group order on screen: Direct, then the tunnels of the store.
Future<void> openGroupMenu(WidgetTester tester, int group, String item) async {
  await tester.tap(find.byType(DropDownButton).at(group));
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
  testWidgets('Direct comes first and every tunnel gets a group', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('exceptions'), findsOneWidget);
    expect(find.text('0 rules'), findsOneWidget);
    expect(find.text('3 rules'), findsOneWidget, reason: 'Work');
    expect(find.text('2 rules'), findsOneWidget, reason: 'Home');
    expect(find.text('1 rule'), findsOneWidget, reason: 'Lab');
    expect(
      tester.getTopLeft(find.text('Direct')).dy,
      lessThan(tester.getTopLeft(find.text('Work')).dy),
    );
    // The rows carry the pattern and its match.
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('*.cdn.example.com'), findsOneWidget);
    expect(find.text('Wildcard'), findsOneWidget);
  });

  testWidgets('+ Domain adds a rule at the end of its group', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await openGroupMenu(tester, 2, 'Domain');
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

    await openGroupMenu(tester, 0, 'Domain');
    await submit(tester, 'not a domain');

    expect(find.text('Not a valid domain'), findsOneWidget);
    expect(find.byType(RuleEditor), findsOneWidget);
    expect(app.model.store.exceptions, isEmpty);
  });

  testWidgets('the match follows what is typed', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await openGroupMenu(tester, 1, 'Domain');
    await tester.enterText(find.byType(RuleEditor), '*.shop.example.com');
    await tester.pumpAndSettle();
    // Suffix, Exact, Wildcard and IP are the options; the editor picked one.
    expect(find.text('Wildcard'), findsNWidgets(2), reason: 'row and editor');

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

    await tester.enterText(find.widgetWithText(TextBox, 'Search rules'), 'cdn');
    await tester.pumpAndSettle();

    expect(find.text('*.cdn.example.com'), findsOneWidget);
    expect(find.text('news.example.org'), findsNothing);
    expect(find.text('1 shown'), findsOneWidget);
  });

  testWidgets('the chips report paused, shadowed and a disabled tunnel', (
    tester,
  ) async {
    final sample = SampleStore();
    final store = sample.store.copyWith(
      tunnels: [
        sample.work,
        sample.home,
        sample.lab.copyWith(isEnabled: false),
      ],
      rules: [
        // An exception with the same pattern shadows the tunnel rule below.
        Rule(pattern: 'example.com', target: const RuleTargetDirect()),
        ...sample.store.rules,
      ],
    );
    final app = await boot(tester, store: store);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    expect(find.text('paused'), findsOneWidget, reason: 'old.example.com');
    expect(find.text('shadowed'), findsOneWidget);
    expect(find.text('tunnel disabled — goes direct'), findsOneWidget);
  });

  testWidgets('Application… adds an app rule and flags a missing .exe', (
    tester,
  ) async {
    final app = await boot(tester);
    final view = page(app, AppNavigator());
    view.picker.file = r'C:\Program Files\Example\example.exe';

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await openGroupMenu(tester, 0, 'Application…');

    final rule = app.model.store.exceptions.single;
    expect(rule.match, RuleMatch.app);
    expect(rule.pattern, r'C:\Program Files\Example\example.exe');
    expect(find.text('example'), findsOneWidget, reason: 'the name, not path');
    expect(find.text('App'), findsOneWidget);
    expect(find.text('not found'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('the context menu moves a rule to another group', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('news.example.org'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct (exception)'));
    await tester.pumpAndSettle();

    expect(app.model.store.exceptions.map((rule) => rule.pattern), [
      'news.example.org',
    ]);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('the context menu deletes a rule', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('docs.example.net'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(app.model.store.rulesForTunnel(app.sample.lab.id), isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('a rule dragged onto a group header joins it', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app, AppNavigator()).widget);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('docs.example.net')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getCenter(find.text('Direct')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(app.model.store.exceptions.map((rule) => rule.pattern), [
      'docs.example.net',
    ]);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('an app rule reveals its executable', (tester) async {
    final sample = SampleStore();
    final app = await boot(
      tester,
      store: sample.store.copyWith(
        rules: [
          Rule(
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

  testWidgets('without tunnels the page asks for one', (tester) async {
    final app = await boot(tester, store: Store.empty);
    final navigator = AppNavigator();

    await tester.pumpWidget(page(app, navigator).widget);
    await tester.pumpAndSettle();
    expect(
      find.text('Add a tunnel first; rules point domains at tunnels.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Add a tunnel…'));
    await tester.pumpAndSettle();
    expect(navigator.page, AppPage.tunnels);
  });
}
