import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/rule_list_dialog.dart';
import 'package:wayfork/app/ui/pages/rules_page.dart';
import 'package:wayfork/app/ui/widgets/rule_lists.dart';
import 'package:wayfork/core/app/running_app.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/rule_list.dart';
import 'package:wayfork/core/model/store.dart';

import '../fakes.dart';
import '../lifecycle_fakes.dart';
import 'ui_harness.dart';

Widget dialogHost(Harness app, {String? initial, FakeRunningApps? apps}) =>
    scoped(
      app.model,
      AppNavigator(),
      Builder(
        builder: (context) => Button(
          onPressed: () => unawaited(
            showNewRuleList(
              context,
              app.model,
              initialInput: initial,
              picker: FakeFilePicker(),
              apps: apps ?? FakeRunningApps(),
            ),
          ),
          child: const Text('Open'),
        ),
      ),
    );
Future<void> open(WidgetTester tester, Widget host) async {
  await tester.pumpWidget(host);
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> token(WidgetTester tester, String value) async {
  await tester.enterText(find.byKey(const ValueKey('list-tokens')), value);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Fluent list routes, pins, pause and header preferences share the source list',
    (tester) async {
      final list = RuleList(
        name: 'Chat',
        target: const RuleListEverythingElse(),
      );
      final row = Rule(pattern: 'chat.example', listID: list.id);
      final app = await boot(
        tester,
        store: Store(lists: [list], rules: [row]),
      );
      await tester.pumpWidget(
        scoped(
          app.model,
          AppNavigator(),
          RulesPage(
            picker: FakeFilePicker(),
            runningApps: FakeRunningApps(),
            onAction: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(RuleRouteMenu).at(1),
          matching: find.byType(DropDownButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct').last);
      await tester.pumpAndSettle();
      expect(
        app.model.store.list(list.id)!.target,
        const RuleListExit(RuleTargetDirect()),
      );
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('chat.example'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Route this one via'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct').last);
      await tester.pumpAndSettle();
      expect(app.model.store.rules.single.target, const RuleTargetDirect());
      expect(find.text('Pinned · Direct'), findsOneWidget);
      await tester.tap(find.byType(ToggleSwitch));
      await tester.pumpAndSettle();
      expect(app.model.store.list(list.id)!.isEnabled, isFalse);
      expect(app.model.store.rules.single.isEnabled, isTrue);
      expect(app.model.store.rules.single.target, const RuleTargetDirect());
      await tester.tap(find.byKey(ValueKey('list-menu-${list.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(ContentDialog),
          matching: find.byType(TextBox),
        ),
        'Chat renamed',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(app.model.store.list(list.id)!.name, 'Chat renamed');
      await tester.tap(find.byKey(ValueKey('list-menu-${list.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Color'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Color 3'));
      await tester.pumpAndSettle();
      expect(app.model.store.list(list.id)!.color, 2);
      await tester.tap(find.byKey(ValueKey('list-menu-${list.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('✓ Show in tray'));
      await tester.pumpAndSettle();
      expect(app.model.store.list(list.id)!.showInMenu, isFalse);
      await tester.tap(find.text('chat.example'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use list route'));
      await tester.pumpAndSettle();
      expect(app.model.store.rules.single.target, isNull);
      await tester.pump(const Duration(seconds: 11));
    },
  );

  testWidgets(
    'New list creates domains/IP/app tokens atomically with the chosen membership',
    (tester) async {
      final app = await boot(tester);
      final saves = app.storage.saved.length;
      await open(
        tester,
        dialogHost(
          app,
          apps: FakeRunningApps(
            apps: const [
              RunningApp(
                path: r'C:\Apps\Notion.exe',
                name: 'Notion',
                hasWindow: true,
              ),
            ],
          ),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('list-name')), 'Notion');
      await token(tester, 'notion.so;203.0.113.0/24');
      await tester.ensureVisible(find.text('Choose App…'));
      await tester.tap(find.text('Choose App…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notion').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Rule'));
      await tester.pumpAndSettle();
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(r'C:\Apps\Extra.exe')],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        app.storage.saved.length,
        saves,
        reason: 'tokens and picker only edit draft',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      final list = app.model.store.lists.first;
      expect(list.name, 'Notion');
      expect(list.target, const RuleListEverythingElse());
      final rows = app.model.store.rulesIn(list.id);
      expect(rows.map((r) => r.match).toSet(), {
        RuleMatch.suffix,
        RuleMatch.ip,
        RuleMatch.app,
      });
      expect(rows.every((r) => r.target == null), isTrue);
      expect(app.storage.saved.length, saves + 1);
    },
  );

  testWidgets(
    'duplicate names and invalid initial token keep store unchanged until corrected',
    (tester) async {
      final app = await boot(tester);
      final before = app.model.store;
      await open(tester, dialogHost(app, initial: 'not a domain'));
      await tester.enterText(find.byKey(const ValueKey('list-name')), 'Draft');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(app.model.store, before);
      expect(find.text('Not a valid domain'), findsOneWidget);
      expect(
        tester
            .widget<TextBox>(find.byKey(const ValueKey('list-tokens')))
            .controller!
            .text,
        'not a domain',
      );
      await token(tester, 'new.example');
      await tester.enterText(
        find.byKey(const ValueKey('list-name')),
        before.lists.first.name,
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(
        find.text('Use a unique list name (1–40 characters).'),
        findsOneWidget,
      );
      expect(app.model.store, before);
      await tester.enterText(find.byKey(const ValueKey('list-name')), 'Valid');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(app.model.store.lists.first.name, 'Valid');
    },
  );

  testWidgets(
    'Recent hosts sharing a suffix stay coherent when unchecked or token removed',
    (tester) async {
      final app = await boot(tester, on: true);
      final now = DateTime.now();
      await goRunning(
        tester,
        app,
        traffic: TrafficSnapshot(
          sampledAt: now,
          interval: 1,
          tunnels: const {},
          direct: const TrafficCounters(),
          recentHosts: [
            RecentHost(host: 'a.notion.so', exit: 'direct', lastSeen: now),
            RecentHost(host: 'b.notion.so', exit: 'direct', lastSeen: now),
          ],
        ),
      );
      await open(tester, dialogHost(app));
      await tester.enterText(find.byKey(const ValueKey('list-name')), 'Notion');
      await tester.ensureVisible(find.text('a.notion.so'));
      await tester.tap(find.text('a.notion.so'));
      await tester.pumpAndSettle();
      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes.every((b) => b.checked == true), isTrue);
      await tester.tap(find.text('b.notion.so'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((b) => b.checked == false),
        isTrue,
      );
      await tester.tap(find.text('a.notion.so'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('notion.so · suffix ×'));
      await tester.tap(find.text('notion.so · suffix ×'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((b) => b.checked == false),
        isTrue,
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(app.model.store.rulesIn(app.model.store.lists.first.id), isEmpty);
      expect(
        app.model.hiddenRecentHosts,
        isEmpty,
        reason: 'removing chip must not hide unchecked hosts',
      );
      await tester.pump(const Duration(seconds: 31));
    },
  );

  testWidgets(
    'Rules and Dashboard fit minimum window with long names and dark theme',
    (tester) async {
      tester.view.physicalSize = const Size(880, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = await boot(tester);
      await app.model.editRuleList(
        app.model.store.lists.first.id,
        (l) => l.copyWith(name: 'A very long purpose list name of forty x'),
      );
      await app.model.rename(app.sample.work.id, 'T' * 40);
      final nav = AppNavigator()..go(AppPage.rules);
      await tester.pumpWidget(shell(app.model, nav, []));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      nav.go(AppPage.dashboard);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Test the shared selector at the narrow width of the tray, with a dark theme.
      await tester.pumpWidget(
        FluentApp(
          theme: FluentThemeData(brightness: Brightness.dark),
          home: Center(
            child: SizedBox(
              width: 360,
              child: RuleRouteMenu(
                model: app.model,
                value: const RuleListEverythingElse(),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Undo expires after ten seconds and disposal cancels its timer', (
    tester,
  ) async {
    final app = await boot(tester);
    final list = app.model.store.lists.first;
    await app.model.setListTarget(list.id, const RuleListEverythingElse());
    await tester.pumpWidget(
      scoped(app.model, AppNavigator(), const ListRouteUndoBar()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(app.model.listRouteUndo, isNull);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets(
    'Ctrl multiselection moves rows together and list drag reaches end target',
    (tester) async {
      final first = RuleList(
        name: 'First',
        target: const RuleListExit(RuleTargetDirect()),
      );
      final second = RuleList(
        name: 'Second',
        target: const RuleListEverythingElse(),
      );
      final a = Rule(pattern: 'a.example', listID: first.id),
          b = Rule(
            pattern: 'b.example',
            listID: first.id,
            target: const RuleTargetDirect(),
          );
      final app = await boot(
        tester,
        store: Store(lists: [first, second], rules: [a, b]),
      );
      app.model.listPreferences.expanded.addAll([first.id, second.id]);
      await tester.pumpWidget(
        scoped(
          app.model,
          AppNavigator(),
          RulesPage(
            picker: FakeFilePicker(),
            runningApps: FakeRunningApps(),
            onAction: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('a.example'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('b.example'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('a.example'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to list'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second').last);
      await tester.pumpAndSettle();
      expect(app.model.store.rulesIn(second.id).map((r) => r.id), [a.id, b.id]);
      expect(
        app.model.store.rulesIn(second.id).last.target,
        const RuleTargetDirect(),
      );
      final grip = find.byTooltip('Drag to reorder lists').first;
      final end = find.byKey(const ValueKey('list-order-end'));
      await tester.ensureVisible(end);
      final gesture = await tester.startGesture(tester.getCenter(grip));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(tester.getCenter(end));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.model.store.lists.map((l) => l.id), [second.id, first.id]);
    },
  );
}
