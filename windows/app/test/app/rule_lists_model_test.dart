import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/rule_list_preferences.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/rule_list.dart';
import 'package:wayfork/core/model/store.dart';

import 'fakes.dart';

void main() {
  test(
    'one list switch saves/applies once, preserves pins; Undo restores binding only',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.startOn();
      final list = h.model.store.lists.first;
      final row = h.model.store.rulesIn(list.id).first;
      await h.model.pinRule(row.id, const RuleTargetDirect());
      await h.settle();
      final applies = h.service.applied.length, saves = h.storage.saved.length;
      await h.model.setListTarget(
        list.id,
        RuleListExit(RuleTargetTunnel(h.sample.home.id)),
      );
      await h.settle();
      expect(h.storage.saved.length, saves + 1);
      expect(h.service.applied.length, applies + 1);
      expect(
        h.model.store.rules.firstWhere((r) => r.id == row.id).target,
        const RuleTargetDirect(),
      );
      await h.model.setRuleNote(row.id, 'keep this newer note');
      await h.model.undoListRoute();
      expect(h.model.store.list(list.id)!.target, list.target);
      expect(
        h.model.store.rules.firstWhere((r) => r.id == row.id).note,
        'keep this newer note',
      );
    },
  );

  test('newer external edit, ABA and deletion invalidate stale Undo', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.start();
    final list = h.model.store.lists.first;
    const changed = RuleListExit(RuleTargetDirect());
    await h.model.setListTarget(list.id, changed);
    await h.model.editRuleList(list.id, (l) => l.copyWith(target: list.target));
    await h.model.editRuleList(list.id, (l) => l.copyWith(target: changed));
    expect(h.model.listRouteUndo, isNull);
    await h.model.undoListRoute();
    expect(h.model.store.list(list.id)!.target, changed);
    await h.model.setListTarget(list.id, list.target);
    await h.model.deleteRuleList(list.id);
    expect(h.model.listRouteUndo, isNull);
    await h.model.undoListRoute();
    expect(h.model.store.list(list.id), isNull);
  });

  test(
    'list creation is atomic and scoped duplicates cannot alter a sibling list',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      final before = h.model.store;
      final saves = h.storage.saved.length;
      expect(
        await h.model.createRuleList(
          name: 'Invalid',
          target: const RuleListEverythingElse(),
          rows: [
            Rule(pattern: 'good.example'),
            Rule(pattern: 'bad domain'),
          ],
        ),
        isNotNull,
      );
      expect(h.model.store, before);
      expect(h.storage.saved.length, saves);
      await expectLater(
        h.model.createRuleList(
          name: before.lists.first.name,
          target: const RuleListEverythingElse(),
        ),
        throwsFormatException,
      );
      expect(h.model.store, before);
      expect(
        await h.model.createRuleList(
          name: 'Copy',
          target: const RuleListEverythingElse(),
          rows: [Rule(pattern: 'example.com')],
        ),
        isNull,
      );
      final copy = h.model.store.lists.first;
      expect(copy.name, 'Copy');
      await h.model.quickAdd(
        input: 'example.com',
        target: const RuleTargetDirect(),
        listID: copy.id,
      );
      expect(h.model.store.rulesIn(copy.id).single.target, isNull);
      expect(
        h.model.store.rulesIn(before.lists.first.id),
        before.rulesIn(before.lists.first.id),
      );
      final savesAfter = h.storage.saved.length;
      expect(
        await h.model.addRule(
          pattern: 'example.com',
          match: RuleMatch.suffix,
          target: const RuleTargetDirect(),
          listID: copy.id,
        ),
        isNotNull,
      );
      expect(h.storage.saved.length, savesAfter);
    },
  );

  test(
    'multi-row moves preserve relative order and pins within and between lists',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      final list = h.model.store.lists.first;
      final rows = h.model.store.rulesIn(list.id);
      await h.model.pinRule(rows.first.id, const RuleTargetDirect());
      await h.model.moveRules({rows.first.id, rows[1].id}, list.id);
      expect(h.model.store.rulesIn(list.id).map((r) => r.id), [
        rows[2].id,
        rows.first.id,
        rows[1].id,
      ]);
      final destination = h.model.store.lists[1];
      await h.model.moveRules(
        {rows.first.id, rows[1].id},
        destination.id,
        before: h.model.store.rulesIn(destination.id).first.id,
      );
      final moved = h.model.store.rulesIn(destination.id);
      expect(moved.take(2).map((r) => r.id), [rows.first.id, rows[1].id]);
      expect(moved.first.target, const RuleTargetDirect());
      expect(moved[1].target, isNull);
    },
  );

  test(
    'pause and default-follow retain binding and Direct pins without rewriting rows',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      final list = h.model.store.lists.first;
      final row = h.model.store.rulesIn(list.id).first;
      await h.model.pinRule(row.id, const RuleTargetDirect());
      await h.model.setListTarget(list.id, const RuleListEverythingElse());
      final rows = h.model.store.rules;
      await h.model.editRuleList(list.id, (l) => l.copyWith(isEnabled: false));
      expect(h.model.store.rules, rows);
      await h.model.setDefaultTunnel(h.sample.home.id);
      expect(h.model.store.rules, rows);
      expect(
        h.model.store.list(list.id)!.target,
        const RuleListEverythingElse(),
      );
      expect(h.model.listTargetDetail(const RuleListEverythingElse()), 'Home');
    },
  );

  test(
    'six-list recency selection and hiding never reorder matching',
    () async {
      final lists = [
        for (var i = 0; i < 9; i++)
          RuleList(
            id: '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            name: 'List $i',
            target: const RuleListExit(RuleTargetDirect()),
          ),
      ];
      final h = Harness(store: Store(lists: lists));
      addTearDown(h.dispose);
      await h.start();
      expect(
        h.model.menuLists.map((l) => l.id),
        lists.take(6).map((l) => l.id),
      );
      await h.model.setListTarget(
        lists.last.id,
        const RuleListEverythingElse(),
      );
      expect(h.model.menuLists.first.id, lists.last.id);
      expect(h.model.menuLists, hasLength(6));
      expect(h.model.menuListsOverflow, 3);
      expect(h.model.store.lists.map((l) => l.id), lists.map((l) => l.id));
      await h.model.editRuleList(
        lists.last.id,
        (l) => l.copyWith(showInMenu: false),
      );
      expect(h.model.menuLists.any((l) => l.id == lists.last.id), isFalse);
      expect(h.model.store.lists.last.id, lists.last.id);
    },
  );

  test(
    'exit-delete counts actual removed rows and names shells with surviving pins',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.start();
      final list = h.model.store.lists.first;
      final row = h.model.store.rulesIn(list.id).first;
      await h.model.pinRule(row.id, RuleTargetTunnel(h.sample.home.id));
      final message = h.model.deleteTunnelMessage(h.sample.work.id)!;
      expect(message, contains('2 rules'));
      expect(message, contains(list.name));
      await h.model.deleteTunnel(h.sample.work.id);
      expect(h.model.store.list(list.id), isNotNull);
      expect(h.model.store.rulesIn(list.id).single.id, row.id);
    },
  );

  test('UI preferences roundtrip independently of portable store', () async {
    final dir = await Directory.systemTemp.createTemp('wayfork-list-prefs-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/ui.json');
    final prefs = RuleListPreferences(file: file);
    prefs.lastUsed = 'list-id';
    prefs.expanded.add('list-id');
    prefs.switched['list-id'] = DateTime.utc(2026);
    prefs.initialized = true;
    prefs.save();
    prefs.lastUsed = 'other';
    prefs.save();
    final restored = RuleListPreferences(file: file);
    expect(restored.lastUsed, 'other');
    expect(restored.expanded, {'list-id'});
    expect(restored.switched['list-id'], DateTime.utc(2026));
    expect(restored.initialized, isTrue);
  });
}
