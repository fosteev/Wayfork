import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/rule_list.dart';

const ruleListColors = <Color>[
  Color(0xff0078d4),
  Color(0xffb65d42),
  Color(0xff607b48),
  Color(0xff7157b7),
  Color(0xff328451),
  Color(0xff5865f2),
  Color(0xffb16a17),
  Color(0xff68717a),
];

class RuleListBadge extends StatelessWidget {
  const RuleListBadge(this.list, {super.key});
  final RuleList list;
  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 20,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color:
          ruleListColors[list.color ??
              list.name.codeUnits.fold(0, (a, b) => a + b) % 8],
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      list.name.characters.first.toUpperCase(),
      style: const TextStyle(color: Colors.white, fontSize: 11),
    ),
  );
}

/// Shared list/default/pin selector. Menu labels carry live group member/latency.
class RuleRouteMenu extends StatelessWidget {
  const RuleRouteMenu({
    required this.model,
    required this.value,
    required this.onChanged,
    this.followDefault = true,
    super.key,
  });
  final AppModel model;
  final RuleListTarget value;
  final ValueChanged<RuleListTarget> onChanged;
  final bool followDefault;

  Widget _label(RuleListTarget binding) {
    final detail = model.listTargetDetail(binding);
    return Text(
      '${model.listTargetName(binding)}${detail.isEmpty ? '' : ' · $detail'}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    MenuFlyoutItem item(RuleListTarget target) => MenuFlyoutItem(
      text: _label(target),
      leading: value == target
          ? const Icon(FluentIcons.check_mark, size: 10)
          : null,
      onPressed: () => onChanged(target),
    );
    final tunnels = model.store.tunnels;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 210),
      child: DropDownButton(
        key: key,
        title: Flexible(child: _label(value)),
        items: [
          for (final group in model.store.groups)
            item(RuleListExit(RuleTargetGroup(group.id))),
          if (model.store.groups.isNotEmpty) const MenuFlyoutSeparator(),
          for (final tunnel in tunnels.take(6))
            item(RuleListExit(RuleTargetTunnel(tunnel.id))),
          if (tunnels.length > 6)
            MenuFlyoutSubItem(
              text: Text('${tunnels.length - 6} more…'),
              showBehavior: SubItemShowAction.press,
              items: (_) => [
                for (final tunnel in tunnels.skip(6))
                  item(RuleListExit(RuleTargetTunnel(tunnel.id))),
              ],
            ),
          if (tunnels.isNotEmpty) const MenuFlyoutSeparator(),
          item(const RuleListExit(RuleTargetDirect())),
          if (followDefault)
            MenuFlyoutItem(
              text: Text(
                'Same as Everything else · ${model.everythingElseName}',
              ),
              onPressed: () => onChanged(const RuleListEverythingElse()),
            ),
        ],
      ),
    );
  }
}

class EverythingElseRow extends StatelessWidget {
  const EverythingElseRow({required this.model, super.key});
  final AppModel model;
  @override
  Widget build(BuildContext context) => GroupCard(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Everything else',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            RuleRouteMenu(
              model: model,
              value: RuleListExit(
                model.store.defaultTunnelID == null
                    ? const RuleTargetDirect()
                    : model.store.group(model.store.defaultTunnelID!) != null
                    ? RuleTargetGroup(model.store.defaultTunnelID!)
                    : RuleTargetTunnel(model.store.defaultTunnelID!),
              ),
              followDefault: false,
              onChanged: (target) => unawaited(
                model.setDefaultTunnel((target as RuleListExit).exit.exitID),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class ListRouteUndoBar extends StatelessWidget {
  const ListRouteUndoBar({super.key});
  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final undo = model.listRouteUndo;
    if (undo == null) return const SizedBox.shrink();
    return InfoBar(
      title: Text(
        '${model.store.list(undo.listID)?.name ?? 'List'} → ${model.listTargetName(undo.after)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: const Text('Applied · Undo available for 10 s'),
      action: Button(
        onPressed: () => unawaited(model.undoListRoute()),
        child: const Text('Undo'),
      ),
    );
  }
}
