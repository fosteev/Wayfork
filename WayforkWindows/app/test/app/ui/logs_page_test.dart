import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/logs_page.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

import 'ui_harness.dart';

/// A service line, as `LogCenter.receive` gets it off the pipe.
LogLine line(String source, String message, {LogLevel level = LogLevel.info}) =>
    LogLine(source: source, level: level, message: message);

void main() {
  testWidgets('every line shows its source, level and message', (tester) async {
    final app = await boot(tester);
    app.logs.receive([
      line('daemon', 'apply plan v7: 3 tunnels, 8 rules'),
      line('sing-box', 'inbound/tun[tun-in]: started at Wayfork'),
      line('daemon', 'route 0.0.0.0/0 via 10.8.0.1', level: LogLevel.warning),
    ]);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const LogsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('apply plan v7: 3 tunnels, 8 rules'), findsOneWidget);
    expect(find.text('daemon'), findsNWidgets(2), reason: 'two daemon rows');
    expect(find.text('INFO'), findsWidgets);
    expect(find.text('WARN'), findsOneWidget);
  });

  testWidgets('the source picker keeps one source', (tester) async {
    final app = await boot(tester);
    app.logs.receive([
      line('daemon', 'service ready'),
      line('sing-box', 'started at Wayfork'),
    ]);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const LogsPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ComboBox<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sing-box').last);
    await tester.pumpAndSettle();

    expect(find.text('started at Wayfork'), findsOneWidget);
    expect(find.text('service ready'), findsNothing);
    expect(
      find.text('1 of ${app.logs.lines.length} lines'),
      findsOneWidget,
      reason: 'the app logged its own start-up lines too',
    );
  });

  testWidgets('the level floor hides the noisier lines', (tester) async {
    final app = await boot(tester);
    app.logs.minimumLevel = LogLevel.debug;
    app.logs.receive([
      line('sing-box', 'PUSH_REPLY seen', level: LogLevel.debug),
      line('sing-box', 'started at Wayfork'),
    ]);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const LogsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('PUSH_REPLY seen'), findsOneWidget);

    await tester.tap(find.byType(ComboBox<LogLevel>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Info').last);
    await tester.pumpAndSettle();

    expect(find.text('PUSH_REPLY seen'), findsNothing);
    expect(find.text('started at Wayfork'), findsOneWidget);
  });

  testWidgets('search matches the message and the source', (tester) async {
    final app = await boot(tester);
    app.logs.receive([
      line('daemon', 'NRPT applied'),
      line('sing-box', 'started at Wayfork'),
    ]);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const LogsPage()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextBox, 'Search'), 'nrpt');
    await tester.pumpAndSettle();

    expect(find.text('NRPT applied'), findsOneWidget);
    expect(find.text('started at Wayfork'), findsNothing);
  });

  testWidgets('Clear empties the ring buffer', (tester) async {
    final app = await boot(tester);
    app.logs.receive([line('daemon', 'service ready')]);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const LogsPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(app.logs.lines, isEmpty);
    expect(find.text('No log lines yet.'), findsOneWidget);
  });

  testWidgets('"Show Log" preselects the tunnel and names it', (tester) async {
    final app = await boot(tester);
    final navigator = AppNavigator();
    app.logs.receive([
      line('daemon', 'service ready'),
      line(
        'openvpn:${app.sample.work.id}',
        'Initialization Sequence Completed',
      ),
    ]);
    navigator.showLogs(source: 'openvpn:${app.sample.work.id}');

    await tester.pumpWidget(scoped(app.model, navigator, const LogsPage()));
    await tester.pumpAndSettle();

    expect(find.text('Initialization Sequence Completed'), findsOneWidget);
    expect(find.text('service ready'), findsNothing);
    // The id is never shown: the picker and the rows carry the tunnel's name.
    expect(find.text('openvpn:Work'), findsNWidgets(2));
    expect(navigator.logSource, isNull, reason: 'consumed once');
  });

  testWidgets('Copy puts the visible lines on the clipboard', (tester) async {
    final app = await boot(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(((call.arguments as Map)['text'] as String?) ?? '');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    app.logs.receive([
      line('daemon', 'service ready'),
      line('sing-box', 'started at Wayfork', level: LogLevel.error),
    ]);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const LogsPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('daemon  INFO  service ready'));
    expect(copied.single, contains('sing-box  ERROR  started at Wayfork'));
  });

  testWidgets('Follow renders the tail, not the whole ring', (tester) async {
    final app = await boot(tester);
    const total = LogsPage.followWindow * 3;
    app.logs.receive([
      for (var index = 0; index < total; index++) line('daemon', 'line $index'),
    ]);

    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const LogsPage()),
    );
    await tester.pumpAndSettle();

    // Following the whole ring makes every batch walk thousands of rows to
    // reach the end of the list, which is what used to freeze the window.
    ListView list() => tester.widget<ListView>(find.byType(ListView));
    expect(list().semanticChildCount, LogsPage.followWindow);
    expect(find.text('line ${total - 1}'), findsOneWidget);
    expect(find.text('line 0'), findsNothing);

    // Scrolling back stops the follow, so the whole ring is reachable.
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(list().semanticChildCount, greaterThanOrEqualTo(total));
    expect(
      tester
          .widget<ToggleButton>(find.widgetWithText(ToggleButton, 'Follow'))
          .checked,
      isFalse,
    );
  });
}
