import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/ui/pick_application_dialog.dart';
import 'package:wayfork/core/app/running_app.dart';

import '../lifecycle_fakes.dart';

const chrome = RunningApp(
  path: r'C:\Program Files\Chrome\chrome.exe',
  name: 'Google Chrome',
  windowTitle: 'Wayfork — GitHub',
  hasWindow: true,
  instances: 12,
);
const telegram = RunningApp(
  path: r'C:\Apps\telegram.exe',
  name: 'Telegram Desktop',
  windowTitle: 'Telegram',
  hasWindow: true,
);
const updater = RunningApp(path: r'C:\Apps\updater.exe', name: 'Updater');

/// Opens the dialog the way the Rules page does and hands back what it
/// returned once it closes.
Future<String?> Function() open(
  WidgetTester tester, {
  required FakeRunningApps apps,
  required FakeFilePicker picker,
}) {
  String? chosen;
  var done = false;
  return () async {
    await tester.pumpWidget(
      FluentApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) => Button(
            child: const Text('open'),
            onPressed: () async {
              chosen = await showPickApplicationDialog(
                context,
                apps: apps,
                picker: picker,
              );
              done = true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return done ? chosen : null;
  };
}

void main() {
  testWidgets('lists the running apps and returns the chosen path', (
    tester,
  ) async {
    final apps = FakeRunningApps(apps: const [chrome, telegram]);
    final picker = FakeFilePicker();
    final show = open(tester, apps: apps, picker: picker);

    await show();
    expect(find.text('Google Chrome'), findsOneWidget);
    expect(find.text(chrome.path), findsOneWidget, reason: 'path as subtitle');
    expect(find.text('12 processes'), findsOneWidget);
    expect(find.text('2 of 2'), findsOneWidget);

    await tester.tap(find.text('Telegram Desktop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Rule'));
    await tester.pumpAndSettle();

    expect(find.byType(PickApplicationDialog), findsNothing);
    expect(apps.lastIncludedBackground, isFalse);
  });

  testWidgets('a double click adds the app it landed on', (tester) async {
    final show = open(
      tester,
      apps: FakeRunningApps(apps: const [chrome, telegram]),
      picker: FakeFilePicker(),
    );

    await show();
    await tester.tap(find.text('Google Chrome'));
    await tester.pump();
    await tester.tap(find.text('Google Chrome'));
    await tester.pumpAndSettle();

    expect(find.byType(PickApplicationDialog), findsNothing);
  });

  testWidgets('Add Rule stays disabled until something is selected', (
    tester,
  ) async {
    final show = open(
      tester,
      apps: FakeRunningApps(apps: const [chrome]),
      picker: FakeFilePicker(),
    );

    await show();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add Rule'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('the search box filters the list', (tester) async {
    final show = open(
      tester,
      apps: FakeRunningApps(apps: const [chrome, telegram]),
      picker: FakeFilePicker(),
    );

    await show();
    await tester.enterText(find.byType(TextBox), 'teleg');
    await tester.pumpAndSettle();

    expect(find.text('Google Chrome'), findsNothing);
    expect(find.text('Telegram Desktop'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
  });

  testWidgets('the background toggle asks the source again', (tester) async {
    final apps = FakeRunningApps(
      apps: const [chrome],
      background: const [updater],
    );
    final show = open(tester, apps: apps, picker: FakeFilePicker());

    await show();
    expect(find.text('Updater'), findsNothing);

    await tester.tap(find.text('Show background processes'));
    await tester.pumpAndSettle();

    expect(apps.lastIncludedBackground, isTrue);
    expect(apps.calls, 2);
    expect(find.text('Updater'), findsOneWidget);
  });

  testWidgets('Browse… falls back to the file dialog', (tester) async {
    final picker = FakeFilePicker(file: r'C:\Elsewhere\app.exe');
    final show = open(tester, apps: FakeRunningApps(), picker: picker);

    await show();
    expect(
      find.textContaining('Nothing with a window is running'),
      findsOneWidget,
    );

    await tester.tap(find.text('Browse…'));
    await tester.pumpAndSettle();

    expect(picker.openCalls, 1);
    expect(find.byType(PickApplicationDialog), findsNothing);
  });

  testWidgets('a failing enumeration is reported, not thrown', (tester) async {
    final apps = FakeRunningApps()..failure = StateError('EnumWindows failed');
    final show = open(tester, apps: apps, picker: FakeFilePicker());

    await show();

    expect(
      find.textContaining('Could not read the running applications'),
      findsOneWidget,
    );
  });
}
