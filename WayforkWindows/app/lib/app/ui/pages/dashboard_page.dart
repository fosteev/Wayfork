import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/rule_editing.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/app/traffic_format.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/rules/fake_ip.dart';

/// Dashboard (docs/design/prototype/windows.html, board 3): the global toggle,
/// three summary tiles, the enabled tunnels with their live rates and the
/// quick-add field. Same content as the macOS popover — on Windows it is a
/// page, and the tray flyout is the short version.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final navigator = NavigationScope.of(context);
    final enabled = model.store.tunnels.where((t) => t.isEnabled).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(model: model),
          const SizedBox(height: 14),
          _StatTiles(model: model),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: SecondaryText('Tunnels'),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: model.store.tunnels.isEmpty
                  ? _EmptyState(
                      title: 'No tunnels yet.',
                      hint:
                          'Import an OpenVPN config or add a VLESS URL in '
                          'Tunnels, or drop a .ovpn file on the window.',
                      button: 'Add a tunnel…',
                      onPressed: () => navigator.go(AppPage.tunnels),
                    )
                  : enabled.isEmpty
                  ? _EmptyState(
                      title: 'All tunnels are disabled.',
                      hint: 'Enable one in Tunnels to route through it.',
                      button: 'Manage tunnels…',
                      onPressed: () => navigator.go(AppPage.tunnels),
                    )
                  : GroupCard(
                      children: [
                        for (final tunnel in enabled)
                          _TunnelCard(model: model, tunnel: tunnel),
                        if (model.globalState.isRunning)
                          _DirectRow(model: model),
                      ],
                    ),
            ),
          ),
          if (enabled.isNotEmpty) ...[
            const SizedBox(height: 12),
            QuickAddBar(model: model, navigator: navigator),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const PageTitle('Dashboard'),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: SecondaryText(model.summary, maxLines: 2),
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: model.desiredOn ? 'Turn Wayfork off' : 'Turn Wayfork on',
          child: ToggleSwitch(
            checked: model.desiredOn,
            // Dead while starting or stopping, as in the tray menu.
            onChanged: model.transition != null
                ? null
                : (_) => unawaited(model.toggle()),
          ),
        ),
      ],
    );
  }
}

/// `4 tunnels · 2 up`, `8 rules · 2 exceptions`, the combined rate.
class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final store = model.store;
    final up = store.tunnels
        .where((t) => t.isEnabled && model.card(t).glyph == StatusGlyph.up)
        .length;
    final rules = StatusText.activeRuleCount(store);
    final exceptions = StatusText.activeExceptionCount(store);
    final traffic = model.traffic;
    return Row(
      children: [
        Expanded(
          child: _Tile(
            value: '${store.tunnels.length}',
            caption:
                '${StatusText.count(store.tunnels.length, 'tunnel')} · '
                '$up up',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Tile(
            value: '$rules',
            caption:
                '${StatusText.count(rules, 'rule')} · '
                '$exceptions ${exceptions == 1 ? 'exception' : 'exceptions'}',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Tile(
            value: traffic == null
                ? '↓ —'
                : '↓ ${TrafficFormat.rate(_total(traffic, down: true))}',
            caption: traffic == null
                ? '↑ — total'
                : '↑ ${TrafficFormat.rate(_total(traffic, down: false))} total',
            valueColor: theme.accentColor.defaultBrushFor(theme.brightness),
          ),
        ),
      ],
    );
  }

  /// Every tunnel plus what bypasses them: the figure the taskbar-level
  /// question "how much is Wayfork moving" asks for (F9).
  static double _total(TrafficSnapshot traffic, {required bool down}) {
    var sum = down
        ? traffic.direct.downBytesPerSecond
        : traffic.direct.upBytesPerSecond;
    for (final counters in traffic.tunnels.values) {
      sum += down ? counters.downBytesPerSecond : counters.upBytesPerSecond;
    }
    return sum;
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.value, required this.caption, this.valueColor});

  final String value;
  final String caption;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        border: Border.all(color: theme.resources.cardStrokeColorDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.typography.subtitle?.copyWith(color: valueColor),
          ),
          const SizedBox(height: 2),
          SecondaryText(caption),
        ],
      ),
    );
  }
}

/// One tunnel: glyph, name, badge, rate and the action the state asks for.
class _TunnelCard extends StatelessWidget {
  const _TunnelCard({required this.model, required this.tunnel});

  final AppModel model;
  final Tunnel tunnel;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final card = model.card(tunnel);
    // Rates only for connected / ready tunnels while routing is on (F9).
    final showsRate =
        model.globalState.isRunning && card.glyph == StatusGlyph.up;
    return HoverButton(
      onPressed: () => _open(context),
      builder: (context, states) => Opacity(
        opacity: card.isDimmed ? 0.55 : 1,
        child: Container(
          color: states.isHovered
              ? theme.resources.subtleFillColorSecondary
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusGlyphView(glyph: card.glyph),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      tunnel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TypeBadge(kind: tunnel.kind),
                  const Spacer(),
                  if (showsRate) ...[
                    RateLabel(counters: model.trafficCounters(tunnel)),
                    if ((model.trafficCounters(tunnel)?.oneWayUDPFlows ?? 0)
                        case final flows when flows > 0) ...[
                      const SizedBox(width: 6),
                      _OneWayUDPHint(count: flows),
                    ],
                  ],
                  if (card.action case final action?) ...[
                    const SizedBox(width: 8),
                    _CardAction(model: model, tunnel: tunnel, action: action),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: SecondaryText(
                  card.detail,
                  color: card.isError
                      ? theme.resources.systemFillColorCritical
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The card is a shortcut to the tunnel's row in Tunnels.
  void _open(BuildContext context) {
    model.expandedTunnelID = tunnel.id;
    NavigationScope.of(context).go(AppPage.tunnels);
  }
}

/// Orange ⚠ between the rate and the action when a tunnel has UDP flows that
/// send but receive nothing — a server dropping UDP (H3, docs/design/02-ux.md).
class _OneWayUDPHint extends StatelessWidget {
  const _OneWayUDPHint({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: TrafficFormat.oneWayUDPHint(count),
    child: Icon(FluentIcons.warning, size: 12, color: Colors.orange),
  );
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.model,
    required this.tunnel,
    required this.action,
  });

  final AppModel model;
  final Tunnel tunnel;
  final TunnelCardAction action;

  @override
  Widget build(BuildContext context) {
    switch (action) {
      case TunnelCardActionReconnect():
        return Tooltip(
          message: 'Reconnect',
          child: IconButton(
            icon: const Icon(FluentIcons.refresh, size: 12),
            onPressed: () => unawaited(model.reconnect(tunnel.id)),
          ),
        );
      case TunnelCardActionEdit(:final action):
        final showsLog = action == FailureAction.showLog;
        return Tooltip(
          message: showsLog ? 'Show Log' : 'Fix in Tunnels',
          child: IconButton(
            icon: Icon(
              showsLog ? FluentIcons.text_document : FluentIcons.edit,
              size: 12,
            ),
            onPressed: () => model.perform(action, tunnel),
          ),
        );
      case TunnelCardActionEnable():
        return Button(
          onPressed: () => unawaited(model.setEnabled(tunnel.id, true)),
          child: const Text('Enable'),
        );
    }
  }
}

/// What bypasses the tunnels (F9). No action, no background of its own.
class _DirectRow extends StatelessWidget {
  const _DirectRow({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        StatusGlyphView(glyph: StatusGlyph.idle),
        const SizedBox(width: 8),
        Expanded(
          child: SecondaryText(
            TrafficFormat.directRowTitle(
              hasDefaultTunnel: model.effectiveDefaultTunnel != null,
            ),
          ),
        ),
        RateLabel(counters: model.directTraffic),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.hint,
    required this.button,
    required this.onPressed,
  });

  final String title;
  final String hint;
  final String button;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title),
      const SizedBox(height: 4),
      SecondaryText(hint, maxLines: 3, overflow: TextOverflow.clip),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: Button(onPressed: onPressed, child: Text(button)),
      ),
    ],
  );
}

/// `[Route a domain…] [Tunnel ▾] [Add]` (docs/design/02-ux.md, "Quick add").
/// The tray's "Route a domain…" lands here: `AppNavigator.quickAdd` bumps a
/// token, and every bump takes the focus back to the field.
class QuickAddBar extends StatefulWidget {
  const QuickAddBar({required this.model, required this.navigator, super.key});

  final AppModel model;
  final AppNavigator navigator;

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  RuleTarget? _target;
  String? _error;
  int _seenToken = 0;

  @override
  void initState() {
    super.initState();
    _seenToken = widget.navigator.quickAddToken;
    _target = _initialTarget();
    unawaited(_prefill());
  }

  @override
  void didUpdateWidget(QuickAddBar old) {
    super.didUpdateWidget(old);
    final token = widget.navigator.quickAddToken;
    if (token != _seenToken) {
      _seenToken = token;
      _focus.requestFocus();
    }
    if (!_targets().contains(_target)) {
      _target = _initialTarget();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<RuleTarget> _targets() => [
    for (final tunnel in widget.model.store.tunnels)
      if (tunnel.isEnabled) RuleTargetTunnel(tunnel.id),
    const RuleTargetDirect(),
  ];

  /// The tunnel of the last quick add, else the first enabled one.
  RuleTarget? _initialTarget() {
    final targets = _targets();
    final last = widget.model.quickAddTarget;
    if (last != null && targets.contains(last)) return last;
    return targets.isEmpty ? null : targets.first;
  }

  /// A host on the clipboard is what quick add is usually for.
  Future<void> _prefill() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final candidate = QuickAdd.clipboardCandidate(data?.text);
    if (!mounted || candidate == null || _controller.text.isNotEmpty) return;
    setState(() => _controller.text = candidate);
  }

  void _onChanged(String value) {
    // A pasted fake IP becomes the wildcard rule of the name behind it
    // (`FakeIP`, docs/design/02-ux.md).
    final translated = FakeIP.translate(value, widget.model.fakeIPs);
    setState(() {
      _error = null;
      if (translated case FakeIPPatternTranslation(:final pattern)) {
        _controller.value = TextEditingValue(
          text: pattern,
          selection: TextSelection.collapsed(offset: pattern.length),
        );
      }
    });
  }

  Future<void> _submit() async {
    final target = _target;
    if (target == null || _controller.text.trim().isEmpty) return;
    final message = await widget.model.quickAdd(
      input: _controller.text,
      target: target,
    );
    if (!mounted) return;
    setState(() {
      _error = message;
      if (message == null) _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final model = widget.model;
    final isUpdate = QuickAdd.isUpdate(
      input: _controller.text,
      store: model.store,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextBox(
                controller: _controller,
                focusNode: _focus,
                placeholder: 'Route a domain…',
                onChanged: _onChanged,
                onSubmitted: (_) => unawaited(_submit()),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 150,
              child: ComboBox<RuleTarget>(
                isExpanded: true,
                value: _target,
                items: [
                  for (final target in _targets())
                    ComboBoxItem(
                      value: target,
                      child: Text(
                        model.targetName(target),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (target) => setState(() => _target = target),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _controller.text.trim().isEmpty || _target == null
                  ? null
                  : () => unawaited(_submit()),
              child: Text(isUpdate ? 'Update' : 'Add'),
            ),
          ],
        ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: SecondaryText(
              error,
              color: theme.resources.systemFillColorCritical,
              maxLines: 2,
            ),
          ),
      ],
    );
  }
}
