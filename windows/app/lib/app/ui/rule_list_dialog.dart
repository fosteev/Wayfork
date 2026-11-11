import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/services/running_apps.dart';
import 'package:wayfork/app/ui/pick_application_dialog.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/app/ui/widgets/rule_lists.dart';
import 'package:wayfork/core/app/rule_editing.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/rule_list.dart';
import 'package:wayfork/core/rules/rule_pattern.dart';

Future<String?> showNewRuleList(
  BuildContext context,
  AppModel model, {
  FilePicker? picker,
  RunningAppSource? apps,
  String? initialInput,
}) => showDialog<String>(
  context: context,
  builder: (_) => RuleListDialog(
    model: model,
    picker: picker ?? WindowsFilePicker(),
    apps: apps ?? WindowsRunningApps(),
    initialInput: initialInput,
  ),
);

class RuleListDialog extends StatefulWidget {
  const RuleListDialog({
    required this.model,
    required this.picker,
    required this.apps,
    this.initialInput,
    super.key,
  });
  final AppModel model;
  final FilePicker picker;
  final RunningAppSource apps;
  final String? initialInput;
  @override
  State<RuleListDialog> createState() => _RuleListDialogState();
}

class _RuleListDialogState extends State<RuleListDialog> {
  final _name = TextEditingController();
  final _entry = TextEditingController();
  final _rows = <Rule>[];
  final _recent = <String>{};
  RuleListTarget _target = const RuleListEverythingElse();
  RuleMatch _match = RuleMatch.suffix;
  int? _color;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialInput case final text?) {
      _entry.text = text;
      _addInput(text);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _entry.dispose();
    super.dispose();
  }

  bool _token(String input, RuleMatch match) {
    try {
      final pattern = RulePattern.normalize(input, match: match);
      if (!_rows.any((r) => r.pattern == pattern && r.match == match)) {
        _rows.add(Rule(pattern: pattern, match: match));
      }
      _error = null;
      return true;
    } on RulePatternException catch (error) {
      _error = RuleEditing.patternMessage(error.kind);
      return false;
    }
  }

  bool _addInput(String input) {
    final app = input.trim().toLowerCase().endsWith('.exe');
    final pieces = app
        ? [input.trim()]
        : input.split(RegExp(r'[,;\r\n]+')).where((s) => s.isNotEmpty);
    var valid = true;
    for (final piece in pieces) {
      final inferred = RulePattern.inferMatch(piece);
      final match = app
          ? RuleMatch.app
          : inferred == RuleMatch.suffix
          ? _match
          : inferred;
      if (!_token(piece, match)) {
        valid = false;
        break;
      }
    }
    if (valid) _entry.clear();
    return valid;
  }

  Future<void> _chooseApp() async {
    final path = await showPickApplicationDialog(
      context,
      apps: widget.apps,
      picker: widget.picker,
    );
    if (!mounted || path == null) return;
    setState(() => _token(path, RuleMatch.app));
  }

  Future<void> _create() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (!_addInput(_entry.text)) {
        setState(() => _saving = false);
        return;
      }
      final message = await widget.model.createRuleList(
        name: _name.text,
        target: _target,
        color: _color,
        rows: _rows,
      );
      if (!mounted) return;
      if (message != null) {
        setState(() {
          _error = message;
          _saving = false;
        });
        return;
      }
      for (final host in _recent) {
        widget.model.hideRecent(host);
      }
      Navigator.of(context).pop(widget.model.preferredListID);
    } on FormatException {
      if (mounted) {
        setState(() {
          _error = 'Use a unique list name (1–40 characters).';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520),
      title: const Text('New list'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Name'),
            const SizedBox(height: 6),
            TextBox(
              key: const ValueKey('list-name'),
              controller: _name,
              placeholder: 'e.g. Claude',
              maxLength: 40,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              children: [
                for (var i = 0; i < ruleListColors.length; i++)
                  Tooltip(
                    message: 'Color ${i + 1}',
                    child: Button(
                      onPressed: () => setState(() => _color = i),
                      child: Container(
                        width: 16,
                        height: 16,
                        color: ruleListColors[i],
                        child: _color == i
                            ? const Icon(
                                FluentIcons.check_mark,
                                size: 10,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Route via'),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: RuleRouteMenu(
                model: widget.model,
                value: _target,
                onChanged: (target) => setState(() => _target = target),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Sites and apps'),
            const SizedBox(height: 6),
            DropTarget(
              onDragDone: (details) => setState(() {
                for (final f in details.files) {
                  _token(f.path, RuleMatch.app);
                }
              }),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: theme.resources.controlStrokeColorDefault,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final row in _rows)
                          Button(
                            onPressed: () => setState(() {
                              _rows.remove(row);
                              if (row.match == RuleMatch.suffix) {
                                _recent.removeWhere(
                                  (host) =>
                                      widget.model.recentRulePattern(host) ==
                                      row.pattern,
                                );
                              }
                            }),
                            child: Text(
                              '${row.isApp ? RulePattern.appName(row.pattern) : row.pattern} · ${row.match.name} ×',
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextBox(
                      key: const ValueKey('list-tokens'),
                      controller: _entry,
                      placeholder: 'Type a site or drop an .exe; Enter to add',
                      onSubmitted: (_) =>
                          setState(() => _addInput(_entry.text)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ComboBox<RuleMatch>(
                  value: _match,
                  items: [
                    for (final m in RuleMatch.typedCases)
                      ComboBoxItem(value: m, child: Text(m.name)),
                  ],
                  onChanged: (m) => setState(() => _match = m ?? _match),
                ),
                HyperlinkButton(
                  onPressed: () => unawaited(_chooseApp()),
                  child: const Text('Choose App…'),
                ),
              ],
            ),
            if (widget.model.recentHosts.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('From Recent · last 5 min'),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 132),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final row in widget.model.recentHosts)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Checkbox(
                            checked: _recent.contains(row.host),
                            content: Flexible(
                              child: Text(
                                row.host,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            onChanged: (checked) => setState(() {
                              final pattern = widget.model.recentRulePattern(
                                row.host,
                              );
                              if (checked == true) {
                                if (_token(pattern, RuleMatch.suffix)) {
                                  _recent.addAll(
                                    widget.model.recentHosts
                                        .where(
                                          (host) =>
                                              widget.model.recentRulePattern(
                                                host.host,
                                              ) ==
                                              pattern,
                                        )
                                        .map((host) => host.host),
                                  );
                                }
                              } else {
                                _recent.removeWhere(
                                  (host) =>
                                      widget.model.recentRulePattern(host) ==
                                      pattern,
                                );
                                _rows.removeWhere(
                                  (r) =>
                                      r.pattern == pattern &&
                                      r.match == RuleMatch.suffix,
                                );
                              }
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            SecondaryText('Goes to the top of the list order', maxLines: 2),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(
                  color: theme.resources.systemFillColorCritical,
                ),
              ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => unawaited(_create()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
