part of 'app_model.dart';

final class ListRouteUndo {
  const ListRouteUndo(this.listID, this.before, this.after, this.revision);
  final String listID;
  final RuleListTarget before;
  final RuleListTarget after;
  final int revision;
}

extension AppModelLists on AppModel {
  String? get preferredListID {
    final last = listPreferences.lastUsed;
    if (last != null && _store.list(last) != null) return last;
    return _store.lists.where((list) => list.isEnabled).firstOrNull?.id;
  }

  void useList(String id) {
    if (_store.list(id) == null) return;
    listPreferences.lastUsed = id;
    listPreferences.save();
  }

  void expandList(String id, bool expanded) {
    if (expanded) {
      listPreferences.expanded.add(id);
    } else {
      listPreferences.expanded.remove(id);
    }
    listPreferences.save();
    _changed();
  }

  List<RuleList> get menuLists {
    if (_store.lists.length < 2) return const [];
    final eligible = _store.lists.where((list) => list.showInMenu).toList();
    if (eligible.length > 6) {
      eligible.sort((a, b) {
        final time = (listPreferences.switched[b.id] ?? DateTime(1970))
            .compareTo(listPreferences.switched[a.id] ?? DateTime(1970));
        return time != 0 ? time : a.id.compareTo(b.id);
      });
    }
    return eligible.take(6).toList();
  }

  int get menuListsOverflow => _store.lists.length < 2
      ? 0
      : math.max(0, _store.lists.where((l) => l.showInMenu).length - 6);

  String listTargetName(RuleListTarget target) => switch (target) {
    RuleListEverythingElse() => 'Everything else',
    RuleListExit(:final exit) => exit.isDirect ? 'Direct' : targetName(exit),
  };

  String get everythingElseName => recentExitName ?? 'Direct';

  String listTargetDetail(RuleListTarget target) {
    if (target is RuleListEverythingElse) return everythingElseName;
    final exit = (target as RuleListExit).exit;
    final id = exit.exitID;
    if (id == null) return '';
    if (_store.tunnel(id) case final tunnel?) {
      if (!tunnel.isEnabled) return 'Disabled';
      if (_missingSecrets.contains(id)) return 'Missing secret';
      final summary = rowSummary(tunnel);
      if (summary.isError) return 'Not reachable';
      final sample = latency(tunnel);
      return sample?.milliseconds == null ? '' : '${sample!.milliseconds} ms';
    }
    if (_store.group(id) case final group?) {
      if (!group.isEnabled || _store.enabledMembers(group).isEmpty) {
        return 'Disabled';
      }
      if (_store
          .enabledMembers(group)
          .every((m) => _missingSecrets.contains(m.id))) {
        return 'Missing secret';
      }
      if (groupRowSummary(group).isError) return 'Not reachable';
      final member = _traffic?.groups[id]?.activeMember;
      final name = member == null ? null : _store.exitName(member);
      final sample = groupLatency(group);
      return [
        ?name,
        if (sample?.milliseconds != null) '${sample!.milliseconds} ms',
      ].join(' · ');
    }
    return 'Missing exit';
  }

  Future<void> setListTarget(String id, RuleListTarget target) async {
    final list = _store.list(id);
    if (list == null || list.target == target) return;
    // update executes the store mutation before its first await; capture its revision
    // to prevent a concurrent newer switch from acquiring an old Undo afterwards.
    final pending = update(
      (store) => store.updateList(id, (l) => l.copyWith(target: target)),
    );
    final revision = _listRouteRevision;
    listPreferences.switched[id] = _now();
    listPreferences.save();
    await pending;
    if (_listRouteRevision != revision || _store.list(id)?.target != target) {
      return;
    }
    _listUndo = ListRouteUndo(id, list.target, target, revision);
    _listUndoTimer?.cancel();
    _listUndoTimer = Timer(const Duration(seconds: 10), () {
      _listUndo = null;
      _changed();
    });
    _changed();
  }

  Future<void> undoListRoute() async {
    final undo = _listUndo;
    if (undo == null ||
        undo.revision != _listRouteRevision ||
        _store.list(undo.listID)?.target != undo.after) {
      return;
    }
    _listUndoTimer?.cancel();
    _listUndo = null;
    await update(
      (store) => store.updateList(
        undo.listID,
        (list) => list.copyWith(target: undo.before),
      ),
    );
  }

  Future<String?> createRuleList({
    required String name,
    required RuleListTarget target,
    int? color,
    List<Rule> rows = const [],
  }) async {
    final list = RuleList(name: name.trim(), target: target, color: color);
    final candidate = _store.createList(list);
    var next = candidate;
    final normalized = <Rule>[];
    for (final row in rows) {
      switch (RuleEditing.normalize(
        row.pattern,
        match: row.match,
        network: row.network,
        listID: list.id,
        store: next,
      )) {
        case RuleEditingFailed(:final failure):
          return RuleEditing.message(failure);
        case RuleEditingSuccess(:final pattern):
          final value = row.copyWith(
            pattern: pattern,
            listID: list.id,
            target: null,
          );
          normalized.add(value);
          next = next.copyWith(rules: [...next.rules, value]);
      }
    }
    await update(
      (store) => store
          .createList(list)
          .copyWith(rules: [...store.rules, ...normalized]),
    );
    useList(list.id);
    expandList(list.id, true);
    return null;
  }

  Future<void> editRuleList(String id, RuleList Function(RuleList) edit) =>
      update((store) => store.updateList(id, edit));
  Future<void> deleteRuleList(String id) =>
      update((store) => store.deleteList(id));
  Future<void> reorderRuleList(String id, {String? before}) => update((store) {
    final next = [...store.lists]..removeWhere((l) => l.id == id);
    final index = before == null
        ? next.length
        : next.indexWhere((l) => l.id == before);
    return store.reorderList(id, index < 0 ? next.length : index);
  });

  /// Preserve source order and pins, including multi-row moves within one list.
  Future<void> moveRules(
    Set<String> ids,
    String listID, {
    String? before,
  }) => update((store) {
    if (ids.contains(before) || store.list(listID) == null) return store;
    final moved = [
      for (final list in store.lists)
        ...store.rulesIn(list.id).where((r) => ids.contains(r.id)),
    ];
    final remaining = store.rules.where((r) => !ids.contains(r.id)).toList();
    var index = before == null
        ? -1
        : remaining.indexWhere((r) => r.id == before && r.listID == listID);
    if (index < 0) {
      final last = remaining.lastIndexWhere((r) => r.listID == listID);
      index = last < 0 ? remaining.length : last + 1;
    }
    remaining.insertAll(index, moved.map((r) => r.copyWith(listID: listID)));
    return store.copyWith(rules: remaining);
  });

  Future<void> pinRule(String id, RuleTarget? target) =>
      update((store) => store.pinRule(id, target));

  String removedRulesMessage(Set<RuleTarget> exits) {
    var remaining = _store;
    for (final exit in exits) {
      remaining = remaining.removeRulesBoundTo(exit);
    }
    final removed = _store.rules
        .where((r) => !remaining.rules.any((kept) => kept.id == r.id))
        .toList();
    final affected = _store.lists
        .where(
          (l) =>
              exits.contains(
                l.target is RuleListExit
                    ? (l.target as RuleListExit).exit
                    : null,
              ) ||
              removed.any((r) => r.listID == l.id),
        )
        .map((l) => l.name)
        .toList();
    return '${StatusText.count(removed.length, 'rule')} will be removed${affected.isEmpty ? '' : ' from ${affected.join(', ')}'}. List shells and pins to other exits stay.';
  }
}
