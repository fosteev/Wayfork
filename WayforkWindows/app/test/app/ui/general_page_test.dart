import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/diagnostics_exporter.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/general_page.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/settings.dart';

import '../fakes.dart';
import '../lifecycle_fakes.dart';
import 'ui_harness.dart';

/// The page with the Explorer calls recorded instead of shelled out and the
/// diagnostics bundle built from a shell that runs nothing.
({
  Widget widget,
  List<String> folders,
  List<int> settings,
  List<String> revealed,
  FakeFilePicker picker,
  AppNavigator navigator,
})
page(Harness app, {AppNavigator? navigator}) {
  final folders = <String>[];
  final settings = <int>[];
  final revealed = <String>[];
  final picker = FakeFilePicker();
  final pageNavigator = navigator ?? AppNavigator();
  return (
    widget: scoped(
      app.model,
      pageNavigator,
      GeneralPage(
        picker: picker,
        diagnostics: DiagnosticsExporter(
          shell: (command) async => 'output of $command',
          now: () => DateTime(2026, 8, 28, 15, 30, 45),
        ),
        openFolder: (path) async => folders.add(path),
        openSettings: () async => settings.add(1),
        reveal: (path) async => revealed.add(path),
      ),
    ),
    folders: folders,
    settings: settings,
    revealed: revealed,
    picker: picker,
    navigator: pageNavigator,
  );
}

/// A directory that goes away with the test.
Future<Directory> temporaryDirectory(WidgetTester tester) async {
  final directory = (await tester.runAsync(
    () async => Directory.systemTemp.createTemp('wayfork-backup'),
  ))!;
  addTearDown(() => tester.runAsync(() => directory.delete(recursive: true)));
  return directory;
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

  testWidgets('Export… writes the file the save dialog named', (tester) async {
    final app = await boot(tester);
    final view = page(app);
    final directory = await temporaryDirectory(tester);
    final path = '${directory.path}${Platform.pathSeparator}export.json';
    view.picker.savePath = path;

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Export…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export…'));
    await tester.pumpAndSettle();
    expect(find.text('Export tunnels and rules'), findsOneWidget);
    expect(find.textContaining('3 tunnels, 6 rules'), findsOneWidget);

    // The checkbox is what puts the secrets in the file.
    await tester.tap(find.text('Include secrets (keys, passwords, UUIDs)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('plain text'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Export…'));
    await pumpUntil(
      tester,
      () => File(path).existsSync(),
      what: 'the export file',
    );
    await tester.pumpAndSettle();

    expect(view.picker.suggestedName, 'wayfork-export.json');
    final written = File(path).readAsStringSync();
    expect(written, contains('"format" : "wayfork-export"'));
    expect(written, contains('"Work"'));
    expect(written, contains('"includesSecrets" : true'));
  });

  testWidgets('Import… merges what the file holds', (tester) async {
    final app = await boot(tester);
    final view = page(app);
    final directory = await temporaryDirectory(tester);
    final path = '${directory.path}${Platform.pathSeparator}import.json';
    await tester.runAsync(() async {
      final document = await app.model.exportDocument(includeSecrets: false);
      await File(path).writeAsString(document.encode());
      await app.model.rename(app.sample.work.id, 'Renamed');
    });
    view.picker.file = path;

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Import…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import…'));
    await pumpUntil(
      tester,
      () => find.text('Import tunnels and rules').evaluate().isNotEmpty,
      what: 'the import sheet',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('secrets not included'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
    await pumpUntil(
      tester,
      () => app.model.store.tunnel(app.sample.work.id)?.name == 'Work',
      what: 'the merged tunnel name',
    );
    await tester.pumpAndSettle();
    expect(app.model.store.tunnels, hasLength(3));
  });

  testWidgets('Replace all asks before it discards anything', (tester) async {
    final app = await boot(tester);
    final view = page(app);
    final directory = await temporaryDirectory(tester);
    final path = '${directory.path}${Platform.pathSeparator}import.json';
    await tester.runAsync(() async {
      final document = await app.model.exportDocument(includeSecrets: false);
      await File(path).writeAsString(document.encode());
      await app.model.addRule(
        pattern: 'later.example.com',
        match: RuleMatch.suffix,
        target: const RuleTargetDirect(),
      );
    });
    view.picker.file = path;

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Import…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import…'));
    await pumpUntil(
      tester,
      () => find.text('Import tunnels and rules').evaluate().isNotEmpty,
      what: 'the import sheet',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace all'));
    await tester.pumpAndSettle();
    expect(find.text('Replace everything?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await pumpUntil(
      tester,
      () => app.model.store.rules.length == 6,
      what: 'the replaced rules',
    );
    await tester.pumpAndSettle();
    expect(
      app.model.store.rules.map((rule) => rule.pattern),
      isNot(contains('later.example.com')),
    );
  });

  testWidgets('Export Diagnostics… writes a bundle and shows it', (
    tester,
  ) async {
    final app = await boot(tester);
    final view = page(app);
    final directory = await temporaryDirectory(tester);
    final path = '${directory.path}${Platform.pathSeparator}bundle.zip';
    view.picker.savePath = path;

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Export Diagnostics…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Diagnostics…'));
    await tester.pumpAndSettle();
    expect(find.text('Export Diagnostics'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Export…'));
    await pumpUntil(
      tester,
      () => view.revealed.isNotEmpty,
      what: 'the diagnostics bundle',
    );
    await tester.pumpAndSettle();

    expect(
      view.picker.suggestedName,
      'wayfork-diagnostics-20260828-153045.zip',
    );
    expect(view.revealed, [path]);
    final bytes = File(path).readAsBytesSync();
    expect(bytes.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    expect(
      String.fromCharCodes(bytes),
      allOf(
        contains('wayfork-diagnostics/system.txt'),
        contains('wayfork-diagnostics/store.json'),
      ),
    );
  });

  testWidgets('the navigator opens the diagnostics sheet on arrival', (
    tester,
  ) async {
    final app = await boot(tester);
    final navigator = AppNavigator();
    final view = page(app, navigator: navigator);

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    expect(find.text('Export Diagnostics'), findsNothing);

    navigator.exportDiagnostics();
    await tester.pumpAndSettle();
    expect(find.text('Export Diagnostics'), findsOneWidget);
    await tester.tap(find.widgetWithText(Button, 'Cancel'));
    await tester.pumpAndSettle();
    expect(view.picker.saveCalls, 0);
  });
}
