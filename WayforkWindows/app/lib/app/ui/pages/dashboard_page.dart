import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/feature_text.dart';
import 'package:wayfork/core/app/rule_editing.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/app/traffic_format.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/model/tunnel_group.dart';
import 'package:wayfork/core/rules/fake_ip.dart';

/// Dashboard (docs/design/prototype/windows.html, boards 3 and 9): the global
/// toggle with the summary sentence, three summary tiles, the enabled tunnels
/// and groups as cards with their latency and rates, the *Recent* section (F15)
/// and the quick-add field. The same content as the macOS popover.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final navigator = NavigationScope.of(context);
    final enabled = model.store.tunnels.where((t) => t.isEnabled).toList();
    final groups = model.store.groups.where((g) => g.isEnabled).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(model: model, navigator: navigator),
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
                      title: 'Add a VPN you already have',
                      hint:
                          'An OpenVPN file (.ovpn), a VLESS or WireGuard link, '
                          'or a subscription URL. Then tell Wayfork which sites '
                          'go through it — the rest of your traffic is not '
                          'touched.',
                      button: 'Add a tunnel…',
                      onPressed: () => navigator.go(AppPage.tunnels),
                    )
                  : enabled.isEmpty
                  ? _EmptyState(
                      title: 'Every tunnel is off.',
                      hint: 'Turn one on in Tunnels to route through it.',
                      button: 'Manage tunnels…',
                      onPressed: () => navigator.go(AppPage.tunnels),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        GroupCard(
                          children: [
                            for (final tunnel in enabled)
                              _TunnelCard(model: model, tunnel: tunnel),
                            for (final group in groups)
                              _GroupCardView(model: model, group: group),
                            if (model.globalState.isRunning)
                              _DirectRow(model: model),
                          ],
                        ),
                        if (model.globalState.isRunning) ...[
                          const SizedBox(height: 12),
                          RecentSection(model: model),
                        ],
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
  const _Header({required this.model, required this.navigator});

  final AppModel model;
  final AppNavigator navigator;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final failed = model.recentFailedCount;
    return Row(
      children: [
        const PageTitle('Dashboard'),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SecondaryText(model.summary, maxLines: 2),
              // F19: one red line while something failed in the last 5 minutes.
              if (failed > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.warning,
                      size: 11,
                      color: theme.resources.systemFillColorCritical,
                    ),
                    const SizedBox(width: 4),
                    SecondaryText(
                      FailedText.flyoutLine(failed),
                      color: theme.resources.systemFillColorCritical,
                    ),
                    const SizedBox(width: 6),
                    HyperlinkButton(
                      onPressed: () => navigator.showLogs(),
                      child: const Text('Show'),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: model.desiredOn ? 'Turn Wayfork off' : 'Turn Wayfork on',
          child: ToggleSwitch(
            checked: model.desiredOn,
            // Dead while starting or stopping, as in the tray menu.
            onChanged: model.transition != null || model.store.tunnels.isEmpty
                ? null
                : (_) => unawaited(model.toggle()),
          ),
        ),
      ],
    );
  }
}

/// `4 tunnels · 2 up`, `8 sites · 2 stay outside`, the combined rate.
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
    final sites = StatusText.activeRuleCount(store);
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
            value: '$sites',
            caption:
                '${StatusText.count(sites, 'site')} via tunnels · '
                '$exceptions stay outside',
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

/// Line 2 of a card: the status word, then the rates while connected, then
/// the facts (docs/design/02-ux.md, "Variant C").
class _CardLine2 extends StatelessWidget {
  const _CardLine2({
    required this.card,
    required this.counters,
    required this.showsRate,
  });

  final TunnelPresentation card;
  final TrafficCounters? counters;
  final bool showsRate;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final color = card.isError
        ? theme.resources.systemFillColorCritical
        : theme.resources.textFillColorSecondary;
    final children = <Widget>[
      Text(
        card.status,
        style: theme.typography.caption?.copyWith(
          fontWeight: FontWeight.w500,
          color: card.isError
              ? theme.resources.systemFillColorCritical
              : theme.resources.textFillColorPrimary,
        ),
      ),
    ];
    if (showsRate) {
      children.add(SecondaryText(' · ', color: color));
      if (counters?.isIdle ?? true) {
        children.add(SecondaryText('Idle', color: color));
      } else {
        children.add(RateLabel(counters: counters));
        if ((counters?.oneWayUDPFlows ?? 0) case final flows when flows > 0) {
          children.add(const SizedBox(width: 6));
          children.add(_OneWayUDPHint(count: flows));
        }
      }
    }
    if (card.detail.isNotEmpty) {
      children.add(SecondaryText(' · ', color: color));
      children.add(Flexible(child: SecondaryText(card.detail, color: color)));
    }
    return Row(children: children);
  }
}

/// One tunnel: glyph, name, `Default` badge, latency + sparkline, the action
/// the state asks for; line 2 with the status word.
class _TunnelCard extends StatelessWidget {
  const _TunnelCard({required this.model, required this.tunnel});

  final AppModel model;
  final Tunnel tunnel;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final card = model.card(tunnel);
    final latency = model.latency(tunnel);
    final running = model.globalState.isRunning;
    // Rates only for connected tunnels while routing is on (F9); latency also
    // for the unreachable ones (F14).
    final showsRate = running && card.glyph == StatusGlyph.up;
    final showsLatency =
        running &&
        (card.glyph == StatusGlyph.up || card.status == 'Not reachable');
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
                  if (card.isDefault) ...[
                    const SizedBox(width: 6),
                    const AccentBadge('Default'),
                  ],
                  const Spacer(),
                  if (showsLatency) ...[
                    LatencyLabel(sample: latency),
                    if (latency != null) ...[
                      const SizedBox(width: 6),
                      SparklineView(sample: latency),
                    ],
                  ],
                  for (final action in card.actions) ...[
                    const SizedBox(width: 8),
                    _CardAction(model: model, tunnel: tunnel, action: action),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: _CardLine2(
                  card: card,
                  counters: model.trafficCounters(tunnel),
                  showsRate: showsRate,
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

/// One group card (F16): accent square, `Group` badge, the active member's
/// latency and sparkline, the group's own rates, then one line per member.
class _GroupCardView extends StatelessWidget {
  const _GroupCardView({required this.model, required this.group});

  final AppModel model;
  final TunnelGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final card = model.groupCard(group);
    final latency = model.groupLatency(group);
    final running =
        model.globalState.isRunning && card.glyph == StatusGlyph.group;
    return HoverButton(
      onPressed: () {
        model.expandedTunnelID = group.id;
        NavigationScope.of(context).go(AppPage.tunnels);
      },
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
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const AccentBadge('Group'),
                  if (card.isDefault) ...[
                    const SizedBox(width: 6),
                    const AccentBadge('Default'),
                  ],
                  const Spacer(),
                  if (running) ...[
                    LatencyLabel(sample: latency),
                    if (latency != null) ...[
                      const SizedBox(width: 6),
                      SparklineView(sample: latency),
                    ],
                  ],
                  if (card.actions.contains(
                    const TunnelCardAction.enable(),
                  )) ...[
                    const SizedBox(width: 8),
                    Button(
                      onPressed: () =>
                          unawaited(model.setGroupEnabled(group.id, true)),
                      child: const Text('Enable'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: _CardLine2(
                  card: card,
                  counters: model.groupTraffic(group),
                  showsRate: running,
                ),
              ),
              if (!card.isDimmed)
                Padding(
                  padding: const EdgeInsets.only(left: 18, top: 4),
                  child: Column(
                    children: [
                      for (final row in model.groupMembers(group))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: GroupMemberRowView(
                            row: row,
                            showsLatency: model.globalState.isRunning,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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
          message: 'Retry',
          child: IconButton(
            icon: const Icon(FluentIcons.refresh, size: 12),
            onPressed: () => unawaited(model.reconnect(tunnel.id)),
          ),
        );
      case TunnelCardActionEdit(:final action):
        return Tooltip(
          message: 'Open this tunnel in Tunnels',
          child: Button(
            onPressed: () => model.perform(action, tunnel),
            child: const Text('Fix…'),
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
        const Text(
          'Not via any tunnel',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SecondaryText(
            '· ${StatusText.count(StatusText.activeExceptionCount(model.store), 'site')}',
          ),
        ),
        RateLabel(counters: model.directTraffic),
      ],
    ),
  );
}

/// **Recent** (F15): up to five domains that went the default way, newest
/// first, each with a *Route via ▾* menu; × hides a row for the session.
class RecentSection extends StatelessWidget {
  const RecentSection({required this.model, this.rowLimit = 5, super.key});

  final AppModel model;
  final int rowLimit;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final rows = model.recentHosts;
    final went = switch (model.recentExitName) {
      null => 'direct',
      final name => 'via $name',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: Row(
            children: [
              SecondaryText(
                rows.isEmpty
                    ? 'Recent'
                    : 'Recent — went $went, last '
                          '${AppModelFeatures.recentWindow.inMinutes} min',
              ),
              const Spacer(),
              if (rows.isNotEmpty)
                SecondaryText(
                  '${rows.length.clamp(0, rowLimit)} of ${rows.length}',
                ),
            ],
          ),
        ),
        if (rows.isEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              color: theme.resources.cardBackgroundFillColorSecondary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  FluentIcons.clock,
                  size: 14,
                  color: theme.resources.textFillColorTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SecondaryText(
                    'Sites you open from now on show up here — the ones that '
                    'went $went because no rule said otherwise. One click '
                    'sends any of them through another tunnel.',
                    maxLines: 4,
                    overflow: TextOverflow.clip,
                  ),
                ),
              ],
            ),
          )
        else
          GroupCard(
            children: [
              for (final row in rows.take(rowLimit))
                RecentRowView(model: model, row: row),
            ],
          ),
      ],
    );
  }
}

/// One Recent row: app, domain, *Route via ▾*, ×.
class RecentRowView extends StatelessWidget {
  const RecentRowView({required this.model, required this.row, super.key});

  final AppModel model;
  final RecentHost row;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        children: [
          Icon(
            FluentIcons.app_icon_default,
            size: 14,
            color: theme.resources.textFillColorSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(row.host, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          SecondaryText(processName(row.processPath)),
          const SizedBox(width: 8),
          RouteViaMenu(
            model: model,
            header:
                'Route ${model.recentRulePattern(row.host)} and subdomains via…',
            onPick: (target) =>
                unawaited(model.routeRecent(row.host, via: target)),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: 'Hide until the next Turn On',
            child: IconButton(
              icon: const Icon(FluentIcons.chrome_close, size: 9),
              onPressed: () => model.hideRecent(row.host),
            ),
          ),
        ],
      ),
    );
  }
}

/// The executable's name for a process path, empty when unknown.
String processName(String? path) {
  if (path == null || path.isEmpty) return '';
  final name = path.split(RegExp(r'[\\/]')).last;
  return name.toLowerCase().endsWith('.exe')
      ? name.substring(0, name.length - 4)
      : name;
}

/// `Route via ▾`: every tunnel and group except the default one, then Direct.
class RouteViaMenu extends StatelessWidget {
  const RouteViaMenu({
    required this.model,
    required this.header,
    required this.onPick,
    super.key,
  });

  final AppModel model;
  final String header;
  final void Function(RuleTarget target) onPick;

  @override
  Widget build(BuildContext context) => DropDownButton(
    title: const Text('Route via'),
    items: [
      MenuFlyoutItem(text: Text(header), onPressed: null),
      const MenuFlyoutSeparator(),
      for (final target in model.recentTargets)
        MenuFlyoutItem(
          text: Text(model.targetName(target)),
          onPressed: () => onPick(target),
        ),
    ],
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
      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      SecondaryText(hint, maxLines: 4, overflow: TextOverflow.clip),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(onPressed: onPressed, child: Text(button)),
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

  /// Tunnels, then groups (F16), then *Not via any tunnel*.
  List<RuleTarget> _targets() => [
    for (final tunnel in widget.model.store.tunnels)
      if (tunnel.isEnabled) RuleTargetTunnel(tunnel.id),
    for (final group in widget.model.store.groups)
      if (group.isEnabled) RuleTargetGroup(group.id),
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
                placeholder: 'Site to route, e.g. example.com',
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
