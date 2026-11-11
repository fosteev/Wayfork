import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/services/running_apps.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/pages/dashboard_page.dart';
import 'package:wayfork/app/ui/pick_application_dialog.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/rule_list.dart';
import 'package:wayfork/app/ui/rule_list_dialog.dart';
import 'package:wayfork/app/ui/widgets/rule_lists.dart';
import 'package:wayfork/core/rules/fake_ip.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';
import 'package:wayfork/core/rules/rule_validator.dart';
import 'package:wayfork/core/singbox/rule_set_generator.dart';

/// F24: purpose lists own routing; exit ordering is never a UI grouping key.
class RulesPage extends StatefulWidget {
  const RulesPage({
    required this.picker,
    required this.runningApps,
    required this.onAction,
    super.key,
  });
  final FilePicker picker;
  final RunningAppSource runningApps;
  final void Function(AppAction action) onAction;
  @override
  State<RulesPage> createState() => _RulesPageState();
}

final class _ListDrag {
  const _ListDrag(this.id);
  final String id;
}

final class _RowsDrag {
  _RowsDrag(Set<String> ids) : ids = Set.of(ids);
  final Set<String> ids;
}

class _RulesPageState extends State<RulesPage> {
  final _search = TextEditingController();
  String? _editingRuleID;
  String? _addingTo;
  String? _anchor;
  final _selected = <String>{};
  final _errors = <String, String>{};
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final model = AppScope.of(context);
    if (!_initialized) {
      _initialized = true;
      if (!model.listPreferences.initialized && model.store.lists.isNotEmpty) {
        model.listPreferences.initialized = true;
        model.listPreferences.expanded.add(model.store.lists.first.id);
        model.listPreferences.save();
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _edit(String? id) => setState(() {
    _editingRuleID = id;
    _addingTo = null;
    _errors.clear();
  });
  void _done() => setState(() {
    _editingRuleID = null;
    _addingTo = null;
  });
  void _error(String listID, String? message) => setState(() {
    if (message == null) {
      _errors.remove(listID);
    } else {
      _errors[listID] = message;
    }
  });
  void _select(String id) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    setState(() {
      final model = AppScope.of(context);
      if (keys.contains(LogicalKeyboardKey.shiftLeft) ||
          keys.contains(LogicalKeyboardKey.shiftRight)) {
        final rows = [
          for (final list in model.store.lists) ...model.store.rulesIn(list.id),
        ].map((r) => r.id).toList();
        final a = rows.indexOf(_anchor ?? id), b = rows.indexOf(id);
        if (a >= 0 && b >= 0) {
          _selected.addAll(rows.sublist(a < b ? a : b, (a > b ? a : b) + 1));
        }
      } else if (keys.contains(LogicalKeyboardKey.controlLeft) ||
          keys.contains(LogicalKeyboardKey.controlRight)) {
        if (!_selected.add(id)) _selected.remove(id);
        _anchor = id;
      } else {
        _selected
          ..clear()
          ..add(id);
        _anchor = id;
      }
    });
  }

  Future<void> _app(String listID) async {
    final model = AppScope.of(context);
    final path = await showPickApplicationDialog(
      context,
      apps: widget.runningApps,
      picker: widget.picker,
    );
    if (!mounted || path == null || model.store.list(listID) == null) return;
    final error = await model.addRule(
      pattern: path,
      match: RuleMatch.app,
      target: const RuleTargetDirect(),
      listID: listID,
    );
    if (mounted) _error(listID, error);
  }

  Future<void> _rename(RuleList list) async {
    final controller = TextEditingController(text: list.name);
    String? error;
    final model = AppScope.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => ContentDialog(
          title: const Text('Rename list'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextBox(controller: controller, maxLength: 40),
              if (error != null) Text(error!),
            ],
          ),
          actions: [
            Button(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await model.editRuleList(
                    list.id,
                    (l) => l.copyWith(name: controller.text.trim()),
                  );
                  if (context.mounted) Navigator.of(context).pop();
                } on FormatException {
                  setDialog(
                    () => error = 'Use a unique name (1–40 characters).',
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _delete(RuleList list) async {
    final model = AppScope.of(context);
    final count = model.store.rulesIn(list.id).length;
    if (await showQuestionDialog(
          context,
          title: 'Delete list',
          message: 'Delete ${list.name} and its $count rules?',
          confirm: 'Delete',
        ) &&
        model.store.list(list.id) != null) {
      await model.deleteRuleList(list.id);
    }
  }

  Widget _row(AppModel model, Rule rule, {bool search = false}) => Opacity(
    opacity: model.store.list(rule.listID!)?.isEnabled == false ? 0.55 : 1,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (search)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: SecondaryText(
              '${model.store.list(rule.listID!)?.name} → ${model.listTargetName(model.store.declaredTarget(rule)!)}',
            ),
          ),
        _RuleRow(
          key: ValueKey(rule.id),
          rule: rule,
          issues: model.ruleIssues[rule.id] ?? const [],
          isEditing: _editingRuleID == rule.id,
          onEdit: _edit,
          onEditFinished: _done,
          onError: (message) => _error(rule.listID!, message),
          onAction: widget.onAction,
          selectedIDs: _selected,
          onSelect: _select,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final theme = FluentTheme.of(context);
    final needle = _search.text.trim().toLowerCase();
    final lists = model.store.lists;
    final filtered = [
      for (final l in lists)
        ...model.store
            .rulesIn(l.id)
            .where(
              (r) =>
                  r.pattern.toLowerCase().contains(needle) ||
                  (r.note ?? '').toLowerCase().contains(needle) ||
                  l.name.toLowerCase().contains(needle),
            ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const PageTitle('Rules'),
              const SizedBox(width: 12),
              Expanded(
                child: TextBox(
                  controller: _search,
                  placeholder: 'Search sites and apps',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed: () => unawaited(
                  showNewRuleList(
                    context,
                    model,
                    picker: widget.picker,
                    apps: widget.runningApps,
                  ),
                ),
                child: const Text('New list'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          EverythingElseRow(model: model),
          const SizedBox(height: 8),
          const ListRouteUndoBar(),
          if (model.globalState.isRunning) ...[
            RecentStrip(model: model),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (needle.isNotEmpty) ...[
                    SecondaryText('${filtered.length} shown'),
                    GroupCard(
                      children: [
                        for (final rule in filtered)
                          _row(model, rule, search: true),
                      ],
                    ),
                  ] else ...[
                    if (lists.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'No lists yet. Create a list for sites, apps or IP ranges.',
                        ),
                      ),
                    for (final list in lists)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _list(model, list),
                      ),
                    DragTarget<_ListDrag>(
                      onAcceptWithDetails: (d) =>
                          unawaited(model.reorderRuleList(d.data.id)),
                      builder: (_, candidate, _) => Container(
                        key: const ValueKey('list-order-end'),
                        height: 30,
                        alignment: Alignment.center,
                        color: candidate.isEmpty
                            ? null
                            : theme.resources.subtleFillColorSecondary,
                        child: const SecondaryText(
                          'Drag a list here to move it to the end',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const SecondaryText(
                    'Direct exceptions first, then lists top to bottom and rows in order.',
                    maxLines: 2,
                  ),
                  SecondaryText(
                    'Local names (${RuleSetGenerator.builtInDirectSuffixes.take(4).join(', ')}) are always direct.',
                    maxLines: 2,
                  ),
                  for (final message in _errors.values)
                    SecondaryText(
                      message,
                      color: theme.resources.systemFillColorCritical,
                      maxLines: 3,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(AppModel model, RuleList list) {
    final theme = FluentTheme.of(context);
    final rows = model.store.rulesIn(list.id);
    final open = model.listPreferences.expanded.contains(list.id);
    final index = model.store.lists.indexOf(list);
    final targetDetail = model.listTargetDetail(list.target);
    return GroupCard(
      children: [
        DragTarget<Object>(
          onWillAcceptWithDetails: (d) =>
              d.data is _RowsDrag ||
              (d.data is _ListDrag && (d.data as _ListDrag).id != list.id),
          onAcceptWithDetails: (d) {
            final data = d.data;
            if (data is _ListDrag) {
              unawaited(model.reorderRuleList(data.id, before: list.id));
            } else if (data is _RowsDrag) {
              unawaited(model.moveRules(data.ids, list.id));
            }
          },
          builder: (_, candidate, _) => Container(
            color: candidate.isEmpty
                ? theme.resources.cardBackgroundFillColorSecondary
                : theme.resources.subtleFillColorSecondary,
            padding: const EdgeInsets.all(6),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Draggable<_ListDrag>(
                  data: _ListDrag(list.id),
                  feedback: _DragFeedback(text: list.name),
                  child: const Tooltip(
                    message: 'Drag to reorder lists',
                    child: Icon(FluentIcons.gripper_dots_vertical, size: 12),
                  ),
                ),
                IconButton(
                  key: ValueKey('expand-${list.id}'),
                  icon: Icon(
                    open ? FluentIcons.chevron_down : FluentIcons.chevron_right,
                    size: 10,
                  ),
                  onPressed: () => model.expandList(list.id, !open),
                ),
                Opacity(
                  opacity: list.isEnabled ? 1 : 0.5,
                  child: RuleListBadge(list),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    list.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                SecondaryText(
                  '${rows.length} rules${list.isEnabled ? '' : ' · Paused'}',
                ),
                RuleRouteMenu(
                  model: model,
                  value: list.target,
                  onChanged: (target) =>
                      unawaited(model.setListTarget(list.id, target)),
                ),
                Tooltip(
                  message: list.isEnabled
                      ? 'Pause ${list.name} (including pins)'
                      : 'Resume ${list.name}',
                  child: ToggleSwitch(
                    checked: list.isEnabled,
                    onChanged: (v) => unawaited(
                      model.editRuleList(
                        list.id,
                        (l) => l.copyWith(isEnabled: v),
                      ),
                    ),
                  ),
                ),
                DropDownButton(
                  key: ValueKey('list-menu-${list.id}'),
                  title: const Text('…'),
                  items: [
                    MenuFlyoutItem(
                      text: const Text('Rename…'),
                      onPressed: () =>
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) unawaited(_rename(list));
                          }),
                    ),
                    MenuFlyoutSubItem(
                      text: const Text('Color'),
                      showBehavior: SubItemShowAction.press,
                      items: (_) => [
                        for (var color = 0; color < 8; color++)
                          MenuFlyoutItem(
                            leading: Container(
                              width: 14,
                              height: 14,
                              color: ruleListColors[color],
                            ),
                            text: Text('Color ${color + 1}'),
                            onPressed: () => unawaited(
                              model.editRuleList(
                                list.id,
                                (l) => l.copyWith(color: color),
                              ),
                            ),
                          ),
                      ],
                    ),
                    MenuFlyoutItem(
                      text: const Text('Move up'),
                      onPressed: index == 0
                          ? null
                          : () => unawaited(
                              model.reorderRuleList(
                                list.id,
                                before: model.store.lists[index - 1].id,
                              ),
                            ),
                    ),
                    MenuFlyoutItem(
                      text: const Text('Move down'),
                      onPressed: index == model.store.lists.length - 1
                          ? null
                          : () => unawaited(
                              model.reorderRuleList(
                                list.id,
                                before: index + 2 < model.store.lists.length
                                    ? model.store.lists[index + 2].id
                                    : null,
                              ),
                            ),
                    ),
                    MenuFlyoutItem(
                      text: Text(list.isEnabled ? 'Pause list' : 'Resume list'),
                      onPressed: () => unawaited(
                        model.editRuleList(
                          list.id,
                          (l) => l.copyWith(isEnabled: !l.isEnabled),
                        ),
                      ),
                    ),
                    MenuFlyoutItem(
                      text: Text('${list.showInMenu ? '✓ ' : ''}Show in tray'),
                      onPressed: () => unawaited(
                        model.editRuleList(
                          list.id,
                          (l) => l.copyWith(showInMenu: !l.showInMenu),
                        ),
                      ),
                    ),
                    const MenuFlyoutSeparator(),
                    MenuFlyoutItem(
                      text: const Text('Delete list…'),
                      onPressed: () =>
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) unawaited(_delete(list));
                          }),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (targetDetail == 'Disabled' ||
            targetDetail == 'Missing secret' ||
            targetDetail == 'Missing exit' ||
            targetDetail == 'Not reachable')
          Padding(
            padding: const EdgeInsets.all(8),
            child: SecondaryText(
              targetDetail == 'Not reachable'
                  ? 'Matched connections fail through this exit; no Direct fallback.'
                  : '$targetDetail. Inherited rows are skipped; later lists can match. Valid pins still work.',
              maxLines: 3,
            ),
          ),
        if (!list.isEnabled && open)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SecondaryText(
              'Paused: all rows, including pins, are skipped. Other lists can match before Everything else.',
              maxLines: 3,
            ),
          ),
        if (open) ...[
          for (final rule in rows) _row(model, rule),
          if (_addingTo == list.id)
            RuleEditor(
              key: ValueKey('new-${list.id}'),
              onSubmit: (pattern, match, network) => model.addRule(
                pattern: pattern,
                match: match,
                network: network,
                target: const RuleTargetDirect(),
                listID: list.id,
              ),
              onDone: _done,
              hint: 'Enter to add, Esc to discard',
            ),
          DragTarget<_RowsDrag>(
            onAcceptWithDetails: (d) =>
                unawaited(model.moveRules(d.data.ids, list.id)),
            builder: (_, candidate, _) => Container(
              key: ValueKey('row-order-end-${list.id}'),
              color: candidate.isEmpty
                  ? null
                  : theme.resources.subtleFillColorSecondary,
              padding: const EdgeInsets.all(6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DropDownButton(
                  key: ValueKey('add-${list.id}'),
                  title: const Text('Add site or app'),
                  items: [
                    MenuFlyoutItem(
                      text: const Text('Site'),
                      onPressed: () => setState(() {
                        _addingTo = list.id;
                        _editingRuleID = null;
                      }),
                    ),
                    MenuFlyoutItem(
                      text: const Text('Application…'),
                      onPressed: () => unawaited(_app(list.id)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A rule: the enabled checkbox, the pattern (editable in place), its match,
/// the chips of `RuleValidator` and a free-form note. Dragging it moves it
/// inside its group or into another one; the right-click menu carries edit,
/// move and delete.
class _RuleRow extends StatefulWidget {
  const _RuleRow({
    required this.rule,
    required this.issues,
    required this.isEditing,
    required this.onEdit,
    required this.onEditFinished,
    required this.onError,
    required this.onAction,
    required this.selectedIDs,
    required this.onSelect,
    super.key,
  });

  final Set<String> selectedIDs;
  final ValueChanged<String> onSelect;
  final Rule rule;
  final List<RuleIssue> issues;
  final bool isEditing;
  final void Function(String? ruleID) onEdit;
  final VoidCallback onEditFinished;
  final void Function(String? message) onError;
  final void Function(AppAction action) onAction;

  @override
  State<_RuleRow> createState() => _RuleRowState();
}

class _RuleRowState extends State<_RuleRow> {
  final _menu = FlyoutController();
  final _note = TextEditingController();
  final _noteFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _note.text = widget.rule.note ?? '';
    _noteFocus.addListener(() {
      if (!_noteFocus.hasFocus) _commitNote();
    });
  }

  @override
  void didUpdateWidget(_RuleRow old) {
    super.didUpdateWidget(old);
    // A note edited elsewhere (import, another window) wins, but never while
    // the field is being typed into.
    if (!_noteFocus.hasFocus && widget.rule.note != old.rule.note) {
      _note.text = widget.rule.note ?? '';
    }
  }

  @override
  void dispose() {
    _menu.dispose();
    _note.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  void _commitNote() {
    if (_note.text.trim() == (widget.rule.note ?? '')) return;
    unawaited(AppScope.of(context).setRuleNote(widget.rule.id, _note.text));
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final rule = widget.rule;
    final theme = FluentTheme.of(context);
    if (widget.isEditing) {
      return RuleEditor(
        initialText: rule.pattern,
        initialMatch: rule.match,
        initialNetwork: rule.network,
        // An app rule's path is not typed: only its network is edited.
        lockPattern: rule.isApp,
        onSubmit: (pattern, match, network) => model.updateRule(
          rule.id,
          pattern: pattern,
          match: match,
          network: network,
        ),
        onDone: widget.onEditFinished,
        hint: 'Enter to save, Esc to discard',
      );
    }
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          Checkbox(
            checked: rule.isEnabled,
            onChanged: (enabled) =>
                unawaited(model.setRuleEnabled(rule.id, enabled ?? false)),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: rule.isApp
                ? _AppRuleLabel(path: rule.pattern)
                : MonoText(rule.pattern),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: rule.isApp
                ? SecondaryText(StatusText.matchWord(RuleMatch.app))
                : ComboBox<RuleMatch>(
                    isExpanded: true,
                    value: rule.match,
                    items: [
                      for (final match in RuleMatch.typedCases)
                        ComboBoxItem(
                          value: match,
                          child: Text(_matchTitle(match)),
                        ),
                    ],
                    onChanged: (match) => unawaited(_changeMatch(model, match)),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              children: _chips(context, model),
            ),
          ),
          Expanded(
            flex: 2,
            child: TextBox(
              controller: _note,
              focusNode: _noteFocus,
              placeholder: 'Note',
              onSubmitted: (_) => _commitNote(),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Drag selected rows to reorder or move to another list',
            child: Icon(
              FluentIcons.gripper_dots_vertical,
              size: 10,
              color: theme.resources.textFillColorTertiary,
            ),
          ),
        ],
      ),
    );
    return DragTarget<_RowsDrag>(
      onWillAcceptWithDetails: (details) => !details.data.ids.contains(rule.id),
      onAcceptWithDetails: (details) => unawaited(
        model.moveRules(details.data.ids, rule.listID!, before: rule.id),
      ),
      builder: (context, candidate, _) => Container(
        color: widget.selectedIDs.contains(rule.id)
            ? theme.resources.subtleFillColorSecondary
            : null,
        foregroundDecoration: candidate.isEmpty
            ? null
            : BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: theme.accentColor.defaultBrushFor(theme.brightness),
                    width: 2,
                  ),
                ),
              ),
        child: FlyoutTarget(
          controller: _menu,
          child: GestureDetector(
            onTap: () => widget.onSelect(rule.id),
            onDoubleTap: () => widget.onEdit(rule.id),
            onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
            child: Draggable<_RowsDrag>(
              data: _RowsDrag(
                widget.selectedIDs.contains(rule.id)
                    ? widget.selectedIDs
                    : {rule.id},
              ),
              feedback: _DragFeedback(text: rule.pattern),
              childWhenDragging: Opacity(opacity: 0.4, child: row),
              child: row,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _changeMatch(AppModel model, RuleMatch? match) async {
    if (match == null || match == widget.rule.match) return;
    final error = await model.updateRule(
      widget.rule.id,
      pattern: widget.rule.pattern,
      match: match,
    );
    if (mounted) widget.onError(error);
  }

  void _showMenu(Offset position) {
    final model = AppScope.of(context);
    final rule = widget.rule;
    unawaited(
      _menu.showFlyout(
        position: position,
        builder: (context) => MenuFlyout(
          items: [
            if (rule.isApp)
              MenuFlyoutItem(
                text: const Text('Show in Explorer'),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onAction(AppAction.revealFile(rule.pattern));
                },
              ),
            MenuFlyoutItem(
              text: const Text('Edit'),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onEdit(rule.id);
              },
            ),
            MenuFlyoutSubItem(
              text: const Text('Move to list'),
              showBehavior: SubItemShowAction.press,
              items: (context) => [
                for (final list in model.store.lists)
                  MenuFlyoutItem(
                    text: Text(list.name),
                    onPressed: () {
                      Navigator.of(context).pop();
                      unawaited(
                        model.moveRules(
                          widget.selectedIDs.contains(rule.id)
                              ? widget.selectedIDs
                              : {rule.id},
                          list.id,
                        ),
                      );
                    },
                  ),
              ],
            ),
            MenuFlyoutSubItem(
              text: const Text('Route this one via'),
              showBehavior: SubItemShowAction.press,
              items: (context) => [
                for (final group in model.store.groups)
                  MenuFlyoutItem(
                    text: Text(group.name),
                    onPressed: () {
                      Navigator.of(context).pop();
                      unawaited(
                        model.pinRule(rule.id, RuleTargetGroup(group.id)),
                      );
                    },
                  ),
                for (final tunnel in model.store.tunnels)
                  MenuFlyoutItem(
                    text: Text(tunnel.name),
                    onPressed: () {
                      Navigator.of(context).pop();
                      unawaited(
                        model.pinRule(rule.id, RuleTargetTunnel(tunnel.id)),
                      );
                    },
                  ),
                MenuFlyoutItem(
                  text: const Text('Direct'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    unawaited(model.pinRule(rule.id, const RuleTargetDirect()));
                  },
                ),
              ],
            ),
            if (rule.target != null)
              MenuFlyoutItem(
                text: const Text('Use list route'),
                onPressed: () {
                  Navigator.of(context).pop();
                  unawaited(model.pinRule(rule.id, null));
                },
              ),
            const MenuFlyoutSeparator(),
            MenuFlyoutItem(
              text: const Text('Delete'),
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(model.removeRule(rule.id));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// What the row says about itself beyond its pattern: paused, the issues
  /// `RuleValidator` found (F11) and a missing `.exe` (F10).
  List<Widget> _chips(BuildContext context, AppModel model) {
    final theme = FluentTheme.of(context);
    final caution = theme.resources.systemFillColorCaution;
    final critical = theme.resources.systemFillColorCritical;
    return [
      if (widget.rule.target case final target?)
        Tooltip(
          message: 'Keeps its own exit when the list changes',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(
                color: theme.resources.controlStrokeColorDefault,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Pinned · ${target.isDirect ? 'Direct' : model.targetName(target)}',
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
      if (!widget.rule.isEnabled) const Chip('paused'),
      if (widget.rule.network case final network?)
        Chip(
          _networkChip(network),
          tooltip:
              'Only ${network.jsonValue.toUpperCase()} traffic of this '
              '${widget.rule.isApp ? 'app' : 'range'} is matched',
        ),
      if (widget.rule.isApp && !_AppFile.exists(widget.rule.pattern))
        Chip(
          'not found',
          tint: caution,
          tooltip:
              '${widget.rule.pattern} is missing; the rule matches again '
              'once it is back',
        ),
      for (final issue in widget.issues)
        switch (issue) {
          RuleIssueShadowed(:final by) => SecondaryText(
            _shadowedHint(model, by),
          ),
          RuleIssueDuplicate() => Chip(
            'duplicate',
            tint: caution,
            tooltip:
                'Same pattern, match and network as an earlier rule of this list',
          ),
          RuleIssueCoversTunnelServer(:final tunnelName) => Chip(
            'warning',
            tint: critical,
            tooltip:
                'This pattern covers the server of $tunnelName; its own '
                'traffic would loop',
          ),
          RuleIssueCoversLocalNetwork(:final interface, :final network) => Chip(
            'warning',
            tint: caution,
            tooltip:
                'Covers your LAN ($interface, $network); devices in it go '
                'through the tunnel while Wayfork is on',
          ),
          RuleIssueTunnelDisabled() => SecondaryText(
            'paused — ${model.targetName(model.store.targetFor(widget.rule) ?? const RuleTargetDirect())} is off',
          ),
          RuleIssueTunnelMissing() => Chip('no tunnel', tint: critical),
          RuleIssueMissingSecret() => Chip('missing secret', tint: critical),
        },
    ];
  }

  String _shadowedHint(AppModel model, String by) {
    final earlier = model.store.rules
        .where((rule) => rule.id == by)
        .firstOrNull;
    if (earlier == null) return 'Never used — an earlier rule wins';
    final list = model.store.list(earlier.listID!);
    return 'Never used — ${list?.name ?? 'List'} → ${earlier.pattern} wins';
  }
}

/// The row in edit mode: pattern, match and the model's refusal under them.
/// Used both for an existing rule and for the empty row a group's `+` adds.
class RuleEditor extends StatefulWidget {
  const RuleEditor({
    required this.onSubmit,
    required this.onDone,
    required this.hint,
    this.initialText = '',
    this.initialMatch = RuleMatch.suffix,
    this.initialNetwork,
    this.lockPattern = false,
    super.key,
  });

  /// Returns the model's message, or null when the rule went through.
  final Future<String?> Function(
    String pattern,
    RuleMatch match,
    RuleNetwork? network,
  )
  onSubmit;

  /// Called once the row is committed or discarded.
  final VoidCallback onDone;

  final String hint;
  final String initialText;
  final RuleMatch initialMatch;

  /// F23: the rule's network; null = TCP and UDP.
  final RuleNetwork? initialNetwork;

  /// App rules: the path and match stay as they are, the network is edited.
  final bool lockPattern;

  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late RuleMatch _match;
  RuleNetwork? _network;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialText;
    _match = widget.initialMatch;
    _network = widget.initialNetwork;
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// F11: `*` switches to wildcard, an address or subnet to IP, and an IP
  /// edited back into a name returns to suffix. A pasted fake IP becomes the
  /// wildcard rule of the name behind it (`FakeIP`).
  void _onChanged(String text) {
    final translated = FakeIP.translate(text, AppScope.of(context).fakeIPs);
    setState(() {
      _error = null;
      if (translated case FakeIPPatternTranslation(:final pattern)) {
        _controller.value = TextEditingValue(
          text: pattern,
          selection: TextSelection.collapsed(offset: pattern.length),
        );
        _match = RulePattern.inferMatch(pattern);
        _network = RuleNetwork.normalized(_network, _match);
        return;
      }
      _match = switch (RulePattern.inferMatch(text)) {
        RuleMatch.wildcard => RuleMatch.wildcard,
        RuleMatch.ip => RuleMatch.ip,
        _ => _match == RuleMatch.ip ? RuleMatch.suffix : _match,
      };
      _network = RuleNetwork.normalized(_network, _match);
    });
  }

  Future<void> _submit() async {
    final message = await widget.onSubmit(
      _controller.text,
      _match,
      RuleNetwork.normalized(_network, _match),
    );
    if (!mounted) return;
    if (message == null) {
      widget.onDone();
    } else {
      setState(() => _error = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDone,
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(checked: true, onChanged: null),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  // A read-only field opens no input connection, so Enter
                  // would never reach onSubmitted. Bound on the field only:
                  // Enter on the focused Network combo still opens it.
                  child: CallbackShortcuts(
                    bindings: {
                      if (widget.lockPattern) ...{
                        const SingleActivator(LogicalKeyboardKey.enter): () =>
                            unawaited(_submit()),
                        const SingleActivator(
                          LogicalKeyboardKey.numpadEnter,
                        ): () =>
                            unawaited(_submit()),
                      },
                    },
                    child: TextBox(
                      controller: _controller,
                      focusNode: _focus,
                      readOnly: widget.lockPattern,
                      placeholder: 'example.com or 10.0.0.0/24',
                      onChanged: _onChanged,
                      onSubmitted: (_) => unawaited(_submit()),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 110,
                  child: widget.lockPattern
                      ? SecondaryText(_matchTitle(_match))
                      : ComboBox<RuleMatch>(
                          isExpanded: true,
                          value: _match,
                          items: [
                            for (final match in RuleMatch.typedCases)
                              ComboBoxItem(
                                value: match,
                                child: Text(_matchTitle(match)),
                              ),
                          ],
                          onChanged: (match) => setState(() {
                            _match = match ?? _match;
                            _network = RuleNetwork.normalized(_network, _match);
                          }),
                        ),
                ),
                if (_match.isApp || _match.isIP) ...[
                  const SizedBox(width: 10),
                  Tooltip(
                    message:
                        'UDP carries calls, voice and games; TCP carries '
                        'everything else.',
                    child: SizedBox(
                      width: 130,
                      child: ComboBox<_NetworkChoice>(
                        isExpanded: true,
                        value: _NetworkChoice.of(_network),
                        items: [
                          for (final choice in _NetworkChoice.values)
                            ComboBoxItem(
                              value: choice,
                              child: Text(choice.title),
                            ),
                        ],
                        onChanged: (choice) {
                          setState(() {
                            if (choice != null) _network = choice.network;
                          });
                          // Enter commits the row; keep it reachable.
                          _focus.requestFocus();
                        },
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: SecondaryText(
                    widget.hint,
                    color: theme.resources.textFillColorTertiary,
                  ),
                ),
              ],
            ),
            if (_error case final message?)
              Padding(
                padding: const EdgeInsets.only(top: 3, left: 30),
                child: SecondaryText(
                  message,
                  color: theme.resources.systemFillColorCritical,
                  maxLines: 2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The name of an app rule with its path as the tooltip (F10). Windows has no
/// bundle display name and no cheap way to the executable's icon from Dart, so
/// the file name without `.exe` is what the row shows.
class _AppRuleLabel extends StatelessWidget {
  const _AppRuleLabel({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final exists = _AppFile.exists(path);
    return Tooltip(
      message: path,
      child: Opacity(
        opacity: exists ? 1 : 0.6,
        child: Row(
          children: [
            Icon(
              FluentIcons.app_icon_default,
              size: 12,
              color: FluentTheme.of(context).resources.textFillColorSecondary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                RulePattern.appName(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Does the `.exe` of an app rule still exist? Rows rebuild on every model
/// notification, so the answer is cached for a few seconds — a rule whose app
/// was reinstalled picks itself up again without a restart.
abstract final class _AppFile {
  static const _ttl = Duration(seconds: 5);
  static final _cache = <String, ({DateTime at, bool exists})>{};

  static bool exists(String path) {
    final now = DateTime.now();
    final cached = _cache[path];
    if (cached != null && now.difference(cached.at) < _ttl) {
      return cached.exists;
    }
    final exists = File(path).existsSync();
    _cache[path] = (at: now, exists: exists);
    return exists;
  }
}

/// What follows the cursor while a rule is dragged.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        border: Border.all(color: theme.resources.cardStrokeColorDefault),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 12,
          color: theme.resources.textFillColorPrimary,
        ),
      ),
    );
  }
}

String _matchTitle(RuleMatch match) => StatusText.matchWord(match);

/// **Recent** as a strip above the sections (F15): three rows, *Show all*
/// for the rest; collapses to its header when nothing is new.
class RecentStrip extends StatefulWidget {
  const RecentStrip({required this.model, super.key});

  final AppModel model;

  @override
  State<RecentStrip> createState() => _RecentStripState();
}

class _RecentStripState extends State<RecentStrip> {
  static const rowLimit = 3;
  bool _showAll = false;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final theme = FluentTheme.of(context);
    final rows = model.recentHosts;
    final shown = _showAll ? rows : rows.take(rowLimit).toList();
    final went = switch (model.recentExitName) {
      null => 'direct',
      final name => 'via $name',
    };
    final minutes = AppModelFeatures.recentWindow.inMinutes;
    return GroupCard(
      children: [
        Container(
          color: theme.resources.cardBackgroundFillColorSecondary,
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                FluentIcons.clock,
                size: 12,
                color: theme.resources.textFillColorSecondary,
              ),
              const SizedBox(width: 8),
              const Text(
                'Recent',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SecondaryText(
                  rows.isEmpty
                      ? 'nothing new in the last $minutes min'
                      : 'went $went in the last $minutes min — add to a list',
                ),
              ),
              HyperlinkButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Hide' : 'Show'),
              ),
              if (_expanded && rows.length > rowLimit)
                HyperlinkButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(
                    _showAll ? 'Show fewer' : 'Show all ${rows.length}',
                  ),
                ),
            ],
          ),
        ),
        if (_expanded && shown.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _showAll ? 220 : 120),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final row in shown)
                    RecentRowView(model: model, row: row),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The Network field's options (board W20). A real enum, not a nullable
/// `RuleNetwork`, because a combo box reads a null value as "no selection".
enum _NetworkChoice {
  both('TCP and UDP', null),
  tcp('TCP only', RuleNetwork.tcp),
  udp('UDP only', RuleNetwork.udp);

  const _NetworkChoice(this.title, this.network);

  final String title;
  final RuleNetwork? network;

  static _NetworkChoice of(RuleNetwork? network) =>
      values.firstWhere((choice) => choice.network == network);
}

String _networkChip(RuleNetwork network) => _NetworkChoice.of(network).title;
