import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/rules/fake_ip.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';
import 'package:wayfork/core/rules/rule_validator.dart';
import 'package:wayfork/core/singbox/rule_set_generator.dart';

/// Rules (docs/design/prototype/windows.html, board 5): the Direct group of
/// exceptions (F8) on top, then one group per tunnel, inline editing, drag to
/// reorder or move between groups, and the chips `RuleValidator` produces.
/// Every edit goes straight into the model, which re-applies on its debounce —
/// what the model refuses is shown next to the row that caused it.
class RulesPage extends StatefulWidget {
  const RulesPage({required this.picker, required this.onAction, super.key});

  /// The common dialog behind "Application…" (F10).
  final FilePicker picker;

  final void Function(AppAction action) onAction;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  final _search = TextEditingController();

  /// The rule whose pattern is being edited, if any.
  String? _editingRuleID;

  /// The group whose `+` opened an empty row, if any.
  RuleTarget? _addingTo;

  /// Message from the model per group, cleared by the next edit there.
  final _errors = <RuleTarget, String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _edit(String? ruleID) => setState(() {
    _editingRuleID = ruleID;
    _addingTo = null;
    _errors.clear();
  });

  void _add(RuleTarget target) => setState(() {
    _editingRuleID = null;
    _addingTo = target;
    _errors.clear();
  });

  void _finishEditing() => setState(() {
    _editingRuleID = null;
    _addingTo = null;
  });

  void _setError(RuleTarget target, String? message) => setState(() {
    if (message == null) {
      _errors.remove(target);
    } else {
      _errors[target] = message;
    }
  });

  /// F10 on Windows: an `.exe`, not a bundle. The picked path goes through
  /// the same `addRule` as a typed pattern, so an unusable path is refused
  /// with the model's own message.
  Future<void> _chooseApplication(RuleTarget target) async {
    final model = AppScope.of(context);
    _finishEditing();
    final path = await widget.picker.openFile(
      label: 'Applications',
      extensions: const ['exe'],
      confirmButtonText: 'Add Rule',
    );
    if (path == null) return;
    final error = await model.addRule(
      pattern: path,
      match: RuleMatch.app,
      target: target,
    );
    if (mounted) _setError(target, error);
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final navigator = NavigationScope.of(context);
    final tunnels = model.store.tunnels;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const PageTitle('Rules'),
              const Spacer(),
              SizedBox(
                width: 220,
                child: TextBox(
                  controller: _search,
                  placeholder: 'Search rules',
                  prefix: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(FluentIcons.search, size: 12),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (tunnels.isEmpty)
            _NoTunnels(onAddTunnel: () => navigator.go(AppPage.tunnels))
          else
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (model.store.rules.isEmpty && _addingTo == null) ...[
                      SecondaryText(
                        'No rules yet — everything goes direct. Add one here '
                        'or from the Dashboard.',
                        maxLines: 2,
                        overflow: TextOverflow.clip,
                      ),
                      const SizedBox(height: 10),
                    ],
                    for (final group in [
                      const RuleTargetDirect(),
                      for (final tunnel in tunnels) RuleTargetTunnel(tunnel.id),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _RuleGroup(
                          target: group,
                          tunnel: model.store.tunnel(group.tunnelID ?? ''),
                          search: _search.text,
                          editingRuleID: _editingRuleID,
                          isAdding: _addingTo == group,
                          error: _errors[group],
                          onEdit: _edit,
                          onAdd: () => _add(group),
                          onChooseApplication: () =>
                              unawaited(_chooseApplication(group)),
                          onEditFinished: _finishEditing,
                          onError: (message) => _setError(group, message),
                          onAction: widget.onAction,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NoTunnels extends StatelessWidget {
  const _NoTunnels({required this.onAddTunnel});

  final VoidCallback onAddTunnel;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Add a tunnel first; rules point domains at tunnels.'),
        const SizedBox(height: 10),
        Button(onPressed: onAddTunnel, child: const Text('Add a tunnel…')),
      ],
    ),
  );
}

/// One group: the Direct exceptions or a tunnel, with its rows, the row being
/// added and whatever the model refused last.
class _RuleGroup extends StatelessWidget {
  const _RuleGroup({
    required this.target,
    required this.tunnel,
    required this.search,
    required this.editingRuleID,
    required this.isAdding,
    required this.error,
    required this.onEdit,
    required this.onAdd,
    required this.onChooseApplication,
    required this.onEditFinished,
    required this.onError,
    required this.onAction,
  });

  final RuleTarget target;
  final Tunnel? tunnel;
  final String search;
  final String? editingRuleID;
  final bool isAdding;
  final String? error;
  final void Function(String? ruleID) onEdit;
  final VoidCallback onAdd;
  final VoidCallback onChooseApplication;
  final VoidCallback onEditFinished;
  final void Function(String? message) onError;
  final void Function(AppAction action) onAction;

  bool get _isDirect => target.isDirect;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final rules = model.store.rulesFor(target);
    final visible = _visible(model, rules);
    final issues = model.ruleIssues;
    final tunnel = this.tunnel;
    return Opacity(
      opacity: tunnel != null && !tunnel.isEnabled ? 0.55 : 1,
      child: GroupCard(
        children: [
          _header(context, model, rules.length, visible.length),
          for (final rule in visible)
            _RuleRow(
              key: ValueKey(rule.id),
              rule: rule,
              issues: issues[rule.id] ?? const [],
              isEditing: editingRuleID == rule.id,
              onEdit: onEdit,
              onEditFinished: onEditFinished,
              onError: onError,
              onAction: onAction,
            ),
          if (isAdding)
            RuleEditor(
              key: ValueKey('new-${_key(target)}'),
              onSubmit: (pattern, match) =>
                  model.addRule(pattern: pattern, match: match, target: target),
              onDone: onEditFinished,
              hint: 'Enter to add, Esc to discard',
            ),
          if (error case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 12, 6),
              child: SecondaryText(
                message,
                color: FluentTheme.of(
                  context,
                ).resources.systemFillColorCritical,
                maxLines: 2,
              ),
            ),
          if (_isDirect)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 12, 6),
              child: SecondaryText(
                'Local names (${RuleSetGenerator.builtInDirectSuffixes.take(4).join(', ')}) '
                'are always direct.',
                color: FluentTheme.of(context).resources.textFillColorTertiary,
              ),
            ),
        ],
      ),
    );
  }

  List<Rule> _visible(AppModel model, List<Rule> rules) {
    final needle = search.trim().toLowerCase();
    if (needle.isEmpty) return rules;
    return rules
        .where(
          (rule) =>
              rule.pattern.toLowerCase().contains(needle) ||
              (rule.note ?? '').toLowerCase().contains(needle) ||
              (rule.isApp &&
                  RulePattern.appName(
                    rule.pattern,
                  ).toLowerCase().contains(needle)),
        )
        .toList();
  }

  Widget _header(BuildContext context, AppModel model, int total, int shown) {
    final theme = FluentTheme.of(context);
    final tunnel = this.tunnel;
    return DragTarget<String>(
      onAcceptWithDetails: (details) =>
          unawaited(model.moveRule(details.data, to: target)),
      builder: (context, candidate, _) => Container(
        color: candidate.isEmpty
            ? theme.resources.cardBackgroundFillColorSecondary
            : theme.resources.subtleFillColorSecondary,
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusGlyphView(
                  glyph: tunnel == null
                      ? StatusGlyph.idle
                      : model.rowSummary(tunnel).glyph,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    tunnel?.name ?? 'Direct',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 6),
                if (tunnel != null)
                  TypeBadge(kind: tunnel.kind)
                else
                  const Chip('exceptions'),
                const SizedBox(width: 6),
                Chip(StatusText.count(total, 'rule')),
                if (search.trim().isNotEmpty && shown != total) ...[
                  const SizedBox(width: 6),
                  SecondaryText(
                    '$shown shown',
                    color: theme.resources.textFillColorTertiary,
                  ),
                ],
                const Spacer(),
                DropDownButton(
                  title: const Icon(FluentIcons.add, size: 12),
                  items: [
                    MenuFlyoutItem(
                      text: const Text('Domain'),
                      onPressed: onAdd,
                    ),
                    MenuFlyoutItem(
                      text: const Text('Application…'),
                      onPressed: onChooseApplication,
                    ),
                  ],
                ),
              ],
            ),
            if (_isDirect)
              Padding(
                padding: const EdgeInsets.only(left: 18, top: 2),
                child: SecondaryText(
                  model.directGroupHint,
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _key(RuleTarget target) => target.tunnelID ?? 'direct';
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
    super.key,
  });

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
        onSubmit: (pattern, match) =>
            model.updateRule(rule.id, pattern: pattern, match: match),
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
                ? SecondaryText('App')
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
            message: 'Drag to reorder or move to another group',
            child: Icon(
              FluentIcons.gripper_dots_vertical,
              size: 10,
              color: theme.resources.textFillColorTertiary,
            ),
          ),
        ],
      ),
    );
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != rule.id,
      onAcceptWithDetails: (details) => unawaited(
        model.moveRule(details.data, to: rule.target, before: rule.id),
      ),
      builder: (context, candidate, _) => Container(
        decoration: candidate.isEmpty
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
            onDoubleTap: rule.isApp ? null : () => widget.onEdit(rule.id),
            onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
            child: Draggable<String>(
              data: rule.id,
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
              )
            else
              MenuFlyoutItem(
                text: const Text('Edit'),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onEdit(rule.id);
                },
              ),
            MenuFlyoutSubItem(
              text: const Text('Move to'),
              // Press, not the default hover: the submenu has to be reachable
              // from a keyboard and from a test as well as from a mouse.
              showBehavior: SubItemShowAction.press,
              items: (context) => [
                if (!rule.target.isDirect)
                  MenuFlyoutItem(
                    text: const Text('Direct (exception)'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      unawaited(
                        model.moveRule(rule.id, to: const RuleTargetDirect()),
                      );
                    },
                  ),
                for (final tunnel in model.store.tunnels)
                  if (tunnel.id != rule.tunnelID)
                    MenuFlyoutItem(
                      text: Text(tunnel.name),
                      onPressed: () {
                        Navigator.of(context).pop();
                        unawaited(
                          model.moveRule(
                            rule.id,
                            to: RuleTargetTunnel(tunnel.id),
                          ),
                        );
                      },
                    ),
              ],
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
      if (!widget.rule.isEnabled) const Chip('paused'),
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
          RuleIssueShadowed(:final by) => Chip(
            'shadowed',
            tint: caution,
            tooltip: _shadowedHint(model, by),
          ),
          RuleIssueDuplicate() => Chip(
            'duplicate',
            tint: caution,
            tooltip: 'Same pattern and match as an earlier rule of this group',
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
            'tunnel disabled — goes direct',
          ),
          RuleIssueTunnelMissing() => Chip('no tunnel', tint: critical),
        },
    ];
  }

  String _shadowedHint(AppModel model, String by) {
    final earlier = model.store.rules
        .where((rule) => rule.id == by)
        .firstOrNull;
    if (earlier == null) {
      return '${widget.rule.pattern} is already covered by an earlier group';
    }
    return earlier.target.isDirect
        ? '${widget.rule.pattern} is an exception'
        : '${widget.rule.pattern} is already routed via '
              '${model.targetName(earlier.target)}';
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
    super.key,
  });

  /// Returns the model's message, or null when the rule went through.
  final Future<String?> Function(String pattern, RuleMatch match) onSubmit;

  /// Called once the row is committed or discarded.
  final VoidCallback onDone;

  final String hint;
  final String initialText;
  final RuleMatch initialMatch;

  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late RuleMatch _match;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialText;
    _match = widget.initialMatch;
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
        return;
      }
      _match = switch (RulePattern.inferMatch(text)) {
        RuleMatch.wildcard => RuleMatch.wildcard,
        RuleMatch.ip => RuleMatch.ip,
        _ => _match == RuleMatch.ip ? RuleMatch.suffix : _match,
      };
    });
  }

  Future<void> _submit() async {
    final message = await widget.onSubmit(_controller.text, _match);
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
                  child: TextBox(
                    controller: _controller,
                    focusNode: _focus,
                    placeholder: 'example.com or 10.0.0.0/24',
                    onChanged: _onChanged,
                    onSubmitted: (_) => unawaited(_submit()),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 110,
                  child: ComboBox<RuleMatch>(
                    isExpanded: true,
                    value: _match,
                    items: [
                      for (final match in RuleMatch.typedCases)
                        ComboBoxItem(
                          value: match,
                          child: Text(_matchTitle(match)),
                        ),
                    ],
                    onChanged: (match) =>
                        setState(() => _match = match ?? _match),
                  ),
                ),
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

String _matchTitle(RuleMatch match) => switch (match) {
  RuleMatch.suffix => 'Suffix',
  RuleMatch.exact => 'Exact',
  RuleMatch.wildcard => 'Wildcard',
  RuleMatch.app => 'App',
  RuleMatch.ip => 'IP',
};
