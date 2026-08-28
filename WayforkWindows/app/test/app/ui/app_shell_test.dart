import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/dashboard_page.dart';
import 'package:wayfork/core/ipc/payloads.dart';

import 'ui_harness.dart';

void main() {
  testWidgets('the shell shows the five pages and follows the navigator', (
    tester,
  ) async {
    final app = await boot(
      tester,
      status: RuntimeStatus.stopped,
      until: (app) => app.model.serviceIssue == null,
    );
    final navigator = AppNavigator();

    await tester.pumpWidget(shell(app.model, navigator, []));
    await tester.pumpAndSettle();
    for (final page in AppPage.values) {
      expect(find.text(page.title), findsWidgets, reason: page.title);
    }
    expect(find.byType(DashboardPage), findsOneWidget);

    navigator.showLogs();
    await tester.pumpAndSettle();
    expect(find.textContaining('Logs —'), findsOneWidget);
  });

  testWidgets('a missing service shows the banner and its repair button', (
    tester,
  ) async {
    final app = await boot(
      tester,
      serviceAvailable: false,
      until: (app) => app.model.serviceIssue?.kind == ServiceIssueKind.missing,
    );
    final performed = <AppAction>[];

    await tester.pumpWidget(shell(app.model, AppNavigator(), performed));
    await tester.pumpAndSettle();
    expect(find.text('The Wayfork service is not running'), findsOneWidget);
    expect(find.text('Repair the installation'), findsOneWidget);

    await tester.tap(find.text('Repair Installation'));
    await tester.pumpAndSettle();
    expect(performed, [const AppAction.repairInstallation()]);
  });

  testWidgets('a connected service shows no banner', (tester) async {
    final app = await boot(
      tester,
      until: (app) => app.model.serviceIssue == null,
    );

    await tester.pumpWidget(shell(app.model, AppNavigator(), []));
    await tester.pumpAndSettle();
    expect(find.byType(InfoBar), findsNothing);
  });

  testWidgets('an alert is a dialog whose button runs its action', (
    tester,
  ) async {
    final backup = File(r'C:\Users\me\AppData\Local\Wayfork\store.bad.json');
    final app = await boot(
      tester,
      corruptBackup: backup,
      until: (app) => app.model.alerts.isNotEmpty,
    );
    final performed = <AppAction>[];
    expect(app.model.alerts, hasLength(1));

    await tester.pumpWidget(shell(app.model, AppNavigator(), performed));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsOneWidget);
    expect(find.text('Settings were reset'), findsOneWidget);

    await tester.tap(find.text('Show in Explorer'));
    await tester.pumpAndSettle();
    expect(performed, [AppAction.revealFile(backup.path)]);
    expect(app.model.alerts, isEmpty);
    expect(find.byType(ContentDialog), findsNothing);
  });

  testWidgets('Close dismisses an alert without running anything', (
    tester,
  ) async {
    final app = await boot(
      tester,
      corruptBackup: File(r'C:\Users\me\store.bad.json'),
      until: (app) => app.model.alerts.isNotEmpty,
    );
    final performed = <AppAction>[];

    await tester.pumpWidget(shell(app.model, AppNavigator(), performed));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(performed, isEmpty);
    expect(app.model.alerts, isEmpty);
    expect(find.byType(ContentDialog), findsNothing);
  });
}
