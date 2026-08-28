import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/add_vless_dialog.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/pages/tunnel_details.dart';
import 'package:wayfork/app/ui/tunnel_import.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/model/tunnel.dart';

/// Tunnels (docs/design/prototype/windows.html, board 4): rows that expand in
/// place — no master/detail split — with `+ Add` for the two import paths.
/// A `.ovpn` dropped anywhere in the window lands here as well (the drop
/// target is the shell).
class TunnelsPage extends StatefulWidget {
  const TunnelsPage({required this.importer, super.key});

  final TunnelImporter importer;

  @override
  State<TunnelsPage> createState() => _TunnelsPageState();
}

class _TunnelsPageState extends State<TunnelsPage> {
  Future<void> _addVLESS() async {
    final model = AppScope.of(context);
    final result = await showAddVLESSDialog(context);
    if (result == null) return;
    final error = await model.addVLESS(result);
    if (error != null && mounted) {
      model.showAlert(AppAlert(title: 'Cannot add the tunnel', message: error));
    }
  }

  /// The expansion is model state (an import and the ✎ of a failed card both
  /// point at a tunnel), but a click here only moves the UI.
  void _toggle(AppModel model, Tunnel tunnel) => setState(() {
    model.expandedTunnelID = model.expandedTunnelID == tunnel.id
        ? null
        : tunnel.id;
  });

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const PageTitle('Tunnels'),
              const Spacer(),
              DropDownButton(
                leading: const Icon(FluentIcons.add, size: 12),
                title: const Text('Add'),
                items: [
                  MenuFlyoutItem(
                    text: const Text('Import OpenVPN Config…'),
                    onPressed: () =>
                        unawaited(widget.importer.importFromPicker()),
                  ),
                  MenuFlyoutItem(
                    text: const Text('Add VLESS from URL…'),
                    onPressed: () => unawaited(_addVLESS()),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: model.store.tunnels.isEmpty
                ? _emptyState(context)
                : SingleChildScrollView(
                    child: GroupCard(
                      children: [
                        for (final tunnel in model.store.tunnels)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _TunnelRow(
                                tunnel: tunnel,
                                expanded: model.expandedTunnelID == tunnel.id,
                                onTap: () => _toggle(model, tunnel),
                              ),
                              if (model.expandedTunnelID == tunnel.id)
                                tunnel.kind.isOpenVPN
                                    ? OpenVPNDetail(
                                        key: ValueKey('detail-${tunnel.id}'),
                                        tunnel: tunnel,
                                        importer: widget.importer,
                                      )
                                    : VLESSDetail(
                                        key: ValueKey('detail-${tunnel.id}'),
                                        tunnel: tunnel,
                                      ),
                            ],
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SecondaryText(
      'No tunnels yet. Import an OpenVPN config or add a VLESS URL with '
      '+ Add, or drop a .ovpn file on the window.',
      maxLines: 3,
      overflow: TextOverflow.clip,
    ),
  );
}

/// Glyph, name, badge, one-line state, the enabled switch and the chevron.
class _TunnelRow extends StatelessWidget {
  const _TunnelRow({
    required this.tunnel,
    required this.expanded,
    required this.onTap,
  });

  final Tunnel tunnel;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final theme = FluentTheme.of(context);
    final summary = model.rowSummary(tunnel);
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
                tunnel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            TypeBadge(kind: tunnel.kind),
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
            Tooltip(
              message: tunnel.isEnabled ? 'Disable' : 'Enable',
              child: ToggleSwitch(
                checked: tunnel.isEnabled,
                onChanged: (enabled) =>
                    unawaited(model.setEnabled(tunnel.id, enabled)),
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
