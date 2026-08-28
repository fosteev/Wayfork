import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/pages/tunnel_details.dart';
import 'package:wayfork/app/ui/pages/tunnels_page.dart';
import 'package:wayfork/app/ui/tunnel_import.dart';
import 'package:wayfork/core/model/store.dart';

import '../fakes.dart';
import '../lifecycle_fakes.dart';
import 'ui_harness.dart';

const vlessURI =
    'vless://00000000-0000-4000-8000-000000000001@example.com:443'
    '?encryption=none&security=reality&sni=example.com&fp=chrome'
    '&pbk=public-key&sid=short-id&type=tcp#Reality';

/// The page with a picker whose answers the test sets.
({Widget widget, FakeFilePicker picker, List<List<String>> asked}) page(
  Harness app,
  AppNavigator navigator, {
  bool folderConfirmed = true,
}) {
  final picker = FakeFilePicker();
  final asked = <List<String>>[];
  return (
    widget: scoped(
      app.model,
      navigator,
      TunnelsPage(
        importer: TunnelImporter(
          model: app.model,
          picker: picker,
          confirmFolder: (missing) async {
            asked.add(missing);
            return folderConfirmed;
          },
        ),
      ),
    ),
    picker: picker,
    asked: asked,
  );
}

void main() {
  testWidgets('every tunnel is a row, and one expands at a time', (
    tester,
  ) async {
    final app = await boot(tester);
    final view = page(app, AppNavigator());

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Lab'), findsOneWidget);
    expect(find.byType(OpenVPNDetail), findsNothing);

    await tester.tap(find.text('Work').first);
    await tester.pumpAndSettle();
    expect(app.model.expandedTunnelID, app.sample.work.id);
    expect(find.byType(OpenVPNDetail), findsOneWidget);
    expect(find.text('vpn.example.com:1194 · udp'), findsOneWidget);
    expect(find.text('not connected'), findsOneWidget);

    // The expanded row repeats the name in its Name field, so the row itself
    // is the first match.
    await tester.tap(find.text('Home').first);
    await tester.pumpAndSettle();
    expect(find.byType(OpenVPNDetail), findsNothing);
    expect(find.byType(VLESSDetail), findsOneWidget);

    await tester.tap(find.text('Home').first);
    await tester.pumpAndSettle();
    expect(app.model.expandedTunnelID, isNull);
  });

  testWidgets('the row switch enables and disables a tunnel', (tester) async {
    final app = await boot(tester);
    final view = page(app, AppNavigator());

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ToggleSwitch).first);
    await tester.pumpAndSettle();

    expect(app.model.store.tunnel(app.sample.work.id)?.isEnabled, isFalse);
  });

  testWidgets('the expanded row renames, sets the default and deletes', (
    tester,
  ) async {
    final app = await boot(tester);
    app.model.expandedTunnelID = app.sample.work.id;
    final view = page(app, AppNavigator());

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextBox).first, 'Office');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.model.store.tunnel(app.sample.work.id)?.name, 'Office');

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(app.model.store.defaultTunnelID, app.sample.work.id);

    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(
      find.text('Delete Office and its 3 rules? The rules go with it.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(app.model.store.tunnel(app.sample.work.id), isNull);
    expect(app.model.store.rules, hasLength(3));
    expect(app.model.store.defaultTunnelID, isNull);
  });

  testWidgets('a rejected name keeps the old one and says why', (tester) async {
    final app = await boot(tester);
    app.model.expandedTunnelID = app.sample.work.id;
    final view = page(app, AppNavigator());

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox).first, 'Home');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Another tunnel is already called Home'), findsOneWidget);
    expect(app.model.store.tunnel(app.sample.work.id)?.name, 'Work');
  });

  testWidgets('a VLESS row masks its UUID and can copy the full URI', (
    tester,
  ) async {
    final app = await boot(tester);
    app.model.expandedTunnelID = app.sample.home.id;
    final view = page(app, AppNavigator());

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('••••••••'), findsOneWidget);
    expect(find.textContaining(sampleVLESSUUID), findsNothing);
    expect(
      tester
          .widget<Button>(
            find.ancestor(of: find.text('Copy'), matching: find.byType(Button)),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Import OpenVPN Config… adds the file the picker returned', (
    tester,
  ) async {
    final app = await boot(tester, store: Store.empty);
    final view = page(app, AppNavigator());
    final file = File('${Directory.systemTemp.path}/wayfork-import.ovpn');
    // Real file I/O only runs outside the tester's fake clock.
    await tester.runAsync(
      () => file.writeAsString('client\nremote vpn.example.com 1194 udp\n'),
    );
    addTearDown(file.deleteSync);
    view.picker.file = file.path;

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    expect(find.textContaining('No tunnels yet.'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OpenVPN Config…'));
    await pumpUntil(
      tester,
      () => app.model.store.tunnels.isNotEmpty,
      what: 'the imported tunnel',
    );

    // The store change schedules an apply; its debounce must fire before the
    // test ends or the tester finds a timer still pending.
    await tester.pump(const Duration(milliseconds: 100));

    final tunnel = app.model.store.tunnels.single;
    expect(tunnel.name, 'wayfork-import');
    expect(tunnel.kind.openVPN?.remotes.single.host, 'vpn.example.com');
    expect(app.model.expandedTunnelID, tunnel.id);
    expect(view.picker.openCalls, 1);
  });

  testWidgets('Add VLESS from URL… previews the link before storing it', (
    tester,
  ) async {
    final app = await boot(tester, store: Store.empty);
    final view = page(app, AppNavigator());

    await tester.pumpWidget(view.widget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add VLESS from URL…'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextBox).last, vlessURI);
    await tester.pumpAndSettle();
    expect(find.text('example.com:443'), findsOneWidget);
    expect(
      find.text('REALITY · SNI example.com · fingerprint chrome'),
      findsOneWidget,
    );

    await tester.tap(find.text('Add').last);
    await pumpUntil(
      tester,
      () => app.model.store.tunnels.isNotEmpty,
      what: 'the added tunnel',
    );
    await tester.pump(const Duration(milliseconds: 100));

    final tunnel = app.model.store.tunnels.single;
    expect(tunnel.name, 'Reality');
    expect(tunnel.kind.vless?.server, 'example.com');
  });
}
