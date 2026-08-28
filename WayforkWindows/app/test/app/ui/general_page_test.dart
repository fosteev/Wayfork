import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/general_page.dart';
import 'package:wayfork/core/model/settings.dart';

import '../fakes.dart';
import 'ui_harness.dart';

/// The page with both Explorer calls recorded instead of shelled out.
({
  Widget widget,
  List<String> folders,
  List<int> settings,
  List<AppAction> performed,
})
page(Harness app) {
  final folders = <String>[];
  final settings = <int>[];
  final performed = <AppAction>[];
  return (
    widget: scoped(
      app.model,
      AppNavigator(),
      GeneralPage(
        onAction: performed.add,
        openFolder: (path) async => folders.add(path),
        openSettings: () async => settings.add(1),
      ),
    ),
    folders: folders,
    settings: settings,
    performed: performed,
  );
}

/// The control on the right-hand side of the row labelled [label].
Finder controlFor<T extends Widget>(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.byType(T),
);

void main() {
  testWidgets('the startup and reliability toggles write the settings', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app).widget);
    await tester.pumpAndSettle();

    await tester.tap(controlFor<ToggleSwitch>('Start Wayfork at sign-in'));
    await tester.pumpAndSettle();
    expect(app.model.settings.launchAtLogin, isTrue);
    expect(app.launchAtLogin.isEnabled, isTrue, reason: 'the registry half');

    await tester.tap(controlFor<ToggleSwitch>('Connect on launch'));
    await tester.pumpAndSettle();
    expect(app.model.settings.connectOnLaunch, isTrue);

    await tester.tap(
      controlFor<ToggleSwitch>('Reconnect tunnels automatically'),
    );
    await tester.pumpAndSettle();
    expect(app.model.settings.autoReconnect, isFalse);
  });

  testWidgets('the log level reaches the settings and the ring buffer', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app).widget);
    await tester.pumpAndSettle();

    await tester.tap(controlFor<ComboBox<LogLevel>>('Level'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Debug').last);
    await tester.pumpAndSettle();

    expect(app.model.settings.logLevel, LogLevel.debug);
    expect(app.logs.minimumLevel, LogLevel.debug);
    expect(find.text('Debug logs may include hostnames.'), findsOneWidget);
  });

  testWidgets('the retention is clamped and kept', (tester) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app).widget);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(NumberBox<int>), '14');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.model.settings.logRetentionDays, 14);
  });

  testWidgets('custom resolvers are validated before they are stored', (
    tester,
  ) async {
    final app = await boot(tester);
    await tester.pumpWidget(page(app).widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(find.text('Enter at least one resolver address'), findsOneWidget);

    final field = controlFor<TextBox>('Direct traffic resolver');
    await tester.enterText(field, 'not an address');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Not an IP address'), findsOneWidget);
    expect(app.model.settings.directDNS, const DirectDNSSystem());

    await tester.enterText(field, '1.1.1.1, 9.9.9.9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      app.model.settings.directDNS,
      DirectDNSCustom(const ['1.1.1.1', '9.9.9.9']),
    );

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(app.model.settings.directDNS, const DirectDNSSystem());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('Open Logs Folder opens the log directory', (tester) async {
    final app = await boot(tester);
    final view = page(app);

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Logs Folder'));
    await tester.pumpAndSettle();
    expect(view.folders, hasLength(1));
    expect(view.folders.single, contains('Wayfork'));
  });

  testWidgets('the service row carries the version, Repair… the installer', (
    tester,
  ) async {
    final app = await boot(
      tester,
      until: (app) => app.model.serviceInfo != null,
    );
    final view = page(app);

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    expect(find.text('Wayfork service running'), findsOneWidget);
    expect(find.text('· v0.1.0 · LocalSystem'), findsOneWidget);
    expect(find.text('sing-box 1.12 · OpenVPN 2.7.6'), findsOneWidget);

    await tester.ensureVisible(find.text('Repair…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair…'));
    await tester.pumpAndSettle();
    expect(find.text('Repair the Wayfork service'), findsOneWidget);
    await tester.tap(find.text('Open Installed Apps'));
    await tester.pumpAndSettle();
    expect(view.settings, hasLength(1));
  });

  testWidgets('a missing service is what the row says', (tester) async {
    final app = await boot(
      tester,
      serviceAvailable: false,
      until: (app) => app.model.serviceIssue?.needsRepair ?? false,
    );

    await tester.pumpWidget(page(app).widget);
    await tester.pumpAndSettle();
    expect(find.text('The Wayfork service is not running'), findsOneWidget);
    expect(find.text('service not connected'), findsOneWidget);
  });

  testWidgets('Export Diagnostics… emits the action', (tester) async {
    final app = await boot(tester);
    final view = page(app);

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Export Diagnostics…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Diagnostics…'));
    await tester.pumpAndSettle();
    expect(view.performed, [const AppAction.exportDiagnostics()]);
  });
}
