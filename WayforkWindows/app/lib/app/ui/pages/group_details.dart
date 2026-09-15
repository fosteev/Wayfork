import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/pages/tunnel_details.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/model/tunnel_group.dart';

/// Tunnels › the group rows (F16, docs/design/prototype/windows.html, boards
/// 11 and 15).

/// Header row of a group: accent square, name, `Group · fastest of A, B ·
/// using A · N sites`, the active member's latency, enabled switch, chevron.
class GroupRow extends StatelessWidget {
  const GroupRow({
    required this.group,
    required this.expanded,
    required this.onTap,
    super.key,
  });

  final TunnelGroup group;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final theme = FluentTheme.of(context);
    final summary = model.groupRowSummary(group);
    final latency = model.groupLatency(group);
    return HoverButton(
      onPressed: onTap,
      builder: (context, states) => Container(
        color: states.isHovered
            ? theme.resources.subtleFillColorSecondary
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            StatusGlyphView(glyph: summary.glyph),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 70, maxWidth: 180),
              child: Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SecondaryText(
                summary.text,
                color: summary.isError
                    ? theme.resources.systemFillColorCritical
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            if (model.globalState.isRunning &&
                summary.glyph == StatusGlyph.group) ...[
              LatencyLabel(sample: latency),
              if (latency != null) ...[
                const SizedBox(width: 6),
                SparklineView(sample: latency),
              ],
              const SizedBox(width: 10),
            ],
            Tooltip(
              message: group.isEnabled ? 'Turn off' : 'Turn on',
              child: ToggleSwitch(
                checked: group.isEnabled,
                onChanged: (enabled) =>
                    unawaited(model.setGroupEnabled(group.id, enabled)),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              expanded ? FluentIcons.chevron_down : FluentIcons.chevron_right,
              size: 10,
              color: theme.resources.textFillColorSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Expanded group (board 11): Name, Pick by, ordered Members with drag and
/// `+ Add member…`, Local proxy, Everything else, footer.
class GroupDetail extends StatefulWidget {
  const GroupDetail({required this.group, super.key});

  final TunnelGroup group;

  @override
  State<GroupDetail> createState() => _GroupDetailState();
}

class _GroupDetailState extends State<GroupDetail> {
  late final TextEditingController _name = TextEditingController(
    text: widget.group.name,
  );
  final _nameFocus = FocusNode();
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) unawaited(_commitName());
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _commitName() async {
    if (_name.text == widget.group.name) return;
    final error = await AppScope.of(
      context,
    ).renameGroup(widget.group.id, _name.text);
    if (mounted) setState(() => _nameError = error);
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final group = widget.group;
    final theme = FluentTheme.of(context);
    final candidates = model.candidateMembers(group);
    return DetailPane(
      children: [
        DetailRow(
          label: 'Name',
          child: FieldWithError(
            error: _nameError,
            child: SizedBox(
              width: 240,
              child: TextBox(
                controller: _name,
                focusNode: _nameFocus,
                onSubmitted: (_) => unawaited(_commitName()),
              ),
            ),
          ),
        ),
        DetailRow(
          label: 'Pick by',
          child: Row(
            children: [
              RadioGroup<GroupPolicy>(
                groupValue: group.policy,
                onChanged: (policy) {
                  if (policy != null) {
                    unawaited(model.setGroupPolicy(group.id, policy));
                  }
                },
                child: Row(
                  children: [
                    for (final policy in GroupPolicy.values) ...[
                      RadioButton(
                        value: policy,
                        content: Text(StatusText.policyWord(policy)),
                      ),
                      const SizedBox(width: 14),
                    ],
                  ],
                ),
              ),
              Flexible(
                child: SecondaryText(
                  StatusText.policyMeaning(group.policy, short: true),
                ),
              ),
            ],
          ),
        ),
        DetailRow(
          label: 'Members',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final row in model.groupMembers(group))
                _MemberRow(group: group, row: row),
              const SizedBox(height: 4),
              DropDownButton(
                leading: const Icon(FluentIcons.add, size: 12),
                title: const Text('Add member…'),
                disabled: candidates.isEmpty,
                items: [
                  for (final tunnel in candidates)
                    MenuFlyoutItem(
                      text: Text(tunnel.name),
                      onPressed: () =>
                          unawaited(model.addMember(group.id, tunnel.id)),
                    ),
                ],
              ),
            ],
          ),
        ),
        DetailRow(
          label: 'Local proxy',
          child: LocalProxyRow(exitID: group.id, exitName: group.name),
        ),
        DetailRow(
          label: 'Everything else',
          child: DefaultExitToggle(id: group.id, name: group.name),
        ),
        DetailRow(
          label: '',
          child: Row(
            children: [
              SecondaryText(
                StatusText.count(
                  model.store.rulesForGroup(group.id).length,
                  'site',
                ),
              ),
              HyperlinkButton(
                onPressed: () => NavigationScope.of(context).go(AppPage.rules),
                child: const Text('Show rules'),
              ),
              const Spacer(),
              Button(
                onPressed: () => unawaited(_delete(context, model)),
                child: Text(
                  'Delete…',
                  style: TextStyle(
                    color: theme.resources.systemFillColorCritical,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _delete(BuildContext context, AppModel model) async {
    final message = model.deleteGroupMessage(widget.group.id);
    if (message == null) return;
    final confirmed = await showQuestionDialog(
      context,
      title: 'Delete group',
      message: message,
      confirm: 'Delete',
      destructive: true,
    );
    if (confirmed) await model.deleteGroup(widget.group.id);
  }
}

/// Grip, dot, name, note, latency; drag onto another row to reorder, the
/// context menu to remove.
class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.group, required this.row});

  final TunnelGroup group;
  final GroupMemberRow row;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final theme = FluentTheme.of(context);
    final canRemove = model.canRemoveMember(group);
    final menu = FlyoutController();
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data != row.id && group.members.contains(details.data),
      onAcceptWithDetails: (details) =>
          unawaited(model.moveMember(group.id, details.data, before: row.id)),
      builder: (context, candidates, _) => Draggable<String>(
        data: row.id,
        feedback: DragFeedback(text: row.tunnel.name),
        child: FlyoutTarget(
          controller: menu,
          child: GestureDetector(
            onSecondaryTapUp: (details) => menu.showFlyout(
              builder: (context) => MenuFlyout(
                items: [
                  MenuFlyoutItem(
                    text: Text(
                      canRemove ? 'Remove from group' : 'Delete group…',
                    ),
                    onPressed: () => canRemove
                        ? unawaited(model.removeMember(group.id, row.id))
                        : null,
                  ),
                ],
              ),
            ),
            child: Container(
              width: 340,
              padding: const EdgeInsets.symmetric(vertical: 3),
              color: candidates.isNotEmpty
                  ? theme.accentColor.withValues(alpha: 0.12)
                  : null,
              child: Row(
                children: [
                  Icon(
                    FluentIcons.gripper_dots_vertical,
                    size: 12,
                    color: theme.resources.textFillColorTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GroupMemberRowView(
                      row: row,
                      showsLatency: model.globalState.isRunning,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Last row of the list: `+ New group…`, with a one-line hint until the first
/// group exists.
class NewGroupRow extends StatelessWidget {
  const NewGroupRow({required this.showsHint, required this.onTap, super.key});

  final bool showsHint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return HoverButton(
      onPressed: onTap,
      builder: (context, states) => Container(
        color: states.isHovered
            ? theme.resources.subtleFillColorSecondary
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(FluentIcons.add, size: 11, color: theme.accentColor),
            const SizedBox(width: 8),
            Text(
              'New group…',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: theme.accentColor,
              ),
            ),
            if (showsHint) ...[
              const SizedBox(width: 8),
              const Expanded(
                child: SecondaryText(
                  '— several tunnels behind one name, the fastest or the first '
                  'live one is used',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// New group dialog (board 15): name, members with tick + drag + latency,
/// policy radios; Create from two ticks on.
Future<void> showNewGroupDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => const _NewGroupDialog(),
);

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog();

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  late final TextEditingController _name;
  late List<String> _order;
  final Set<String> _ticked = {};
  GroupPolicy _policy = GroupPolicy.fastest;
  String? _error;

  @override
  void initState() {
    super.initState();
    final model = AppScope.of(context);
    _name = TextEditingController(text: model.nextGroupName);
    _order = model.store.tunnels.map((t) => t.id).toList();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final model = AppScope.of(context);
    final error = await model.createGroup(
      name: _name.text,
      members: _order.where(_ticked.contains).toList(),
      policy: _policy,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() => _error = error);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final theme = FluentTheme.of(context);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520),
      title: const Text('New group'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailRow(
            label: 'Name',
            child: SizedBox(width: 240, child: TextBox(controller: _name)),
          ),
          DetailRow(
            label: 'Members',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GroupCard(
                  children: [
                    for (final id in _order)
                      if (model.store.tunnel(id) case final tunnel?)
                        DragTarget<String>(
                          onWillAcceptWithDetails: (details) =>
                              details.data != id,
                          onAcceptWithDetails: (details) => setState(() {
                            final from = _order.indexOf(details.data);
                            var to = _order.indexOf(id);
                            if (from < 0 || to < 0) return;
                            _order.removeAt(from);
                            if (to > from) to -= 1;
                            _order.insert(to, details.data);
                          }),
                          builder: (context, candidates, _) =>
                              Draggable<String>(
                                data: id,
                                feedback: DragFeedback(text: tunnel.name),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  color: candidates.isNotEmpty
                                      ? theme.accentColor.withValues(
                                          alpha: 0.12,
                                        )
                                      : null,
                                  child: Row(
                                    children: [
                                      Icon(
                                        FluentIcons.gripper_dots_vertical,
                                        size: 12,
                                        color: theme
                                            .resources
                                            .textFillColorTertiary,
                                      ),
                                      const SizedBox(width: 8),
                                      Checkbox(
                                        checked: _ticked.contains(id),
                                        onChanged: (on) => setState(() {
                                          if (on ?? false) {
                                            _ticked.add(id);
                                          } else {
                                            _ticked.remove(id);
                                          }
                                        }),
                                        content: Text(tunnel.name),
                                      ),
                                      const Spacer(),
                                      if (model.globalState.isRunning)
                                        LatencyLabel(
                                          sample: model.latency(tunnel),
                                          fontSize: 11,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                        ),
                  ],
                ),
                const SizedBox(height: 4),
                const SecondaryText(
                  'Tick the tunnels to include; drag to set the order. A tunnel '
                  'that is down is skipped.',
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                ),
              ],
            ),
          ),
          DetailRow(
            label: 'Pick by',
            child: RadioGroup<GroupPolicy>(
              groupValue: _policy,
              onChanged: (policy) {
                if (policy != null) setState(() => _policy = policy);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final policy in GroupPolicy.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: RadioButton(
                        value: policy,
                        content: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(StatusText.policyWord(policy)),
                            SecondaryText(
                              StatusText.policyMeaning(policy, short: false),
                              maxLines: 2,
                              overflow: TextOverflow.clip,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_error case final error?)
            SecondaryText(
              error,
              color: theme.resources.systemFillColorCritical,
              maxLines: 2,
            ),
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ticked.length < TunnelGroup.minimumMembers
              ? null
              : () => unawaited(_create()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// What a dragged member looks like while it moves.
class DragFeedback extends StatelessWidget {
  const DragFeedback({required this.text, super.key});

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
          fontSize: 12,
          color: theme.resources.textFillColorPrimary,
        ),
      ),
    );
  }
}
