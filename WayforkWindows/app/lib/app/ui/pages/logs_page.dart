import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/pages/dashboard_page.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/feature_text.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

/// Logs (docs/design/prototype/windows.html, board 7; docs/design/06-logging.md):
/// the `LogCenter` ring buffer with the source filter, a level floor, search,
/// follow and copy/clear. The macOS Logs *window* is a page here, and "Show
/// Log" on a failed tunnel arrives through `AppNavigator.logSource`.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  /// How many lines Follow keeps on screen. Scrolling a lazy list to its end
  /// walks every row it holds, so following the whole ring rebuilt thousands
  /// of rows on every batch and froze the window; the tail is what Follow is
  /// for anyway, and switching it off brings the full ring back.
  static const followWindow = 400;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// null is "All sources".
  String? _source;
  LogLevel _level = LogLevel.debug;

  /// The Can't reach row whose lines are shown (F19), by host.
  String? _selectedFailed;
  bool _follow = true;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    // "Show Log" points at one tunnel; a later visit keeps the user's filter.
    final preselected = NavigationScope.of(context).takeLogSource();
    if (preselected != null) _source = preselected;
    // F19: the Dashboard's *Show* opens the page filtered to a host.
    if (model.logsPreselectedSearch case final host?) {
      _search.text = host;
      _level = LogLevel.debug;
      _selectedFailed = host;
      model.logsPreselectedSearch = null;
    }
    return ListenableBuilder(
      listenable: model.logs,
      builder: (context, _) {
        final lines = _visible(model);
        final shown = _follow && lines.length > LogsPage.followWindow
            ? lines.sublist(lines.length - LogsPage.followWindow)
            : lines;
        if (_follow) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, model, lines),
              const SizedBox(height: 10),
              _filters(context, model),
              const SizedBox(height: 10),
              // F19: what could not be reached, above the lines; a click
              // filters to the host.
              if (model.globalState.isRunning) ...[
                FailedPane(
                  model: model,
                  selectedHost: _selectedFailed,
                  onSelect: (row) => setState(() {
                    _selectedFailed = row?.host;
                    _search.text = row?.host ?? '';
                    if (row != null) _level = LogLevel.debug;
                  }),
                ),
                const SizedBox(height: 10),
              ],
              Expanded(child: _lines(context, model, shown)),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, AppModel model, List<LogLine> lines) =>
      Row(
        children: [
          const PageTitle('Logs'),
          const SizedBox(width: 10),
          Expanded(
            child: SecondaryText(
              '${lines.length} of ${model.logs.lines.length} lines',
              color: FluentTheme.of(context).resources.textFillColorTertiary,
            ),
          ),
          const SizedBox(width: 10),
          ToggleButton(
            checked: _follow,
            onChanged: (on) {
              setState(() => _follow = on);
              if (on) _scrollToEnd();
            },
            child: const Text('Follow'),
          ),
          const SizedBox(width: 8),
          Button(
            onPressed: () => unawaited(_copy(model, lines)),
            child: const Text('Copy'),
          ),
          const SizedBox(width: 8),
          Button(
            onPressed: model.logs.lines.isEmpty ? null : model.logs.clear,
            child: const Text('Clear'),
          ),
        ],
      );

  Widget _filters(BuildContext context, AppModel model) => Row(
    children: [
      SizedBox(
        width: 190,
        child: ComboBox<String?>(
          isExpanded: true,
          value: _source,
          placeholder: const Text('All sources'),
          items: [
            const ComboBoxItem<String?>(child: Text('All sources')),
            for (final source in _sources(model))
              ComboBoxItem<String?>(
                value: source,
                child: Text(
                  _displayName(model, source),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (source) => setState(() => _source = source),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 120,
        child: ComboBox<LogLevel>(
          isExpanded: true,
          value: _level,
          items: [
            for (final level in LogLevel.values)
              ComboBoxItem(value: level, child: Text(_levelTitle(level))),
          ],
          onChanged: (level) => setState(() => _level = level ?? _level),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: TextBox(
          controller: _search,
          placeholder: 'Search',
          prefix: const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(FluentIcons.search, size: 12),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
    ],
  );

  Widget _lines(BuildContext context, AppModel model, List<LogLine> lines) {
    final theme = FluentTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        border: Border.all(color: theme.resources.cardStrokeColorDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: lines.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.topLeft,
                child: SecondaryText(
                  model.logs.lines.isEmpty
                      ? 'No log lines yet.'
                      : 'No lines match the filter.',
                ),
              ),
            )
          // Scrolling back is what the scrollback is for, so reaching for it
          // stops the follow that would otherwise yank the view to the end
          // again — and brings the lines before the window back.
          : NotificationListener<UserScrollNotification>(
              onNotification: (notification) {
                if (_follow &&
                    notification.direction == ScrollDirection.forward) {
                  setState(() => _follow = false);
                }
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                itemCount: lines.length,
                itemBuilder: (context, index) => _LogRow(
                  line: lines[index],
                  source: _displayName(model, lines[index].source),
                ),
              ),
            ),
    );
  }

  /// Source, level and search, in the order that throws lines away fastest.
  List<LogLine> _visible(AppModel model) {
    final needle = _search.text.trim().toLowerCase();
    return [
      for (final line in model.logs.lines)
        if (line.level.rank <= _level.rank &&
            (_source == null || line.source == _source) &&
            (needle.isEmpty ||
                line.message.toLowerCase().contains(needle) ||
                _displayName(
                  model,
                  line.source,
                ).toLowerCase().contains(needle)))
          line,
    ];
  }

  /// The fixed sources first, then a row per OpenVPN tunnel, then whatever
  /// else the ring holds.
  List<String> _sources(AppModel model) {
    final ordered = <String>[LogCenter.appSource, 'daemon', 'sing-box'];
    for (final tunnel in model.store.tunnels) {
      if (tunnel.kind.isOpenVPN) ordered.add('openvpn:${tunnel.id}');
    }
    for (final line in model.logs.lines) {
      if (!ordered.contains(line.source)) ordered.add(line.source);
    }
    return ordered;
  }

  /// `openvpn:<id>` reads as `openvpn:<tunnel name>`.
  String _displayName(AppModel model, String source) {
    if (!source.startsWith('openvpn:')) return source;
    final tunnel = model.store.tunnel(source.substring(8));
    return tunnel == null ? source : 'openvpn:${tunnel.name}';
  }

  Future<void> _copy(AppModel model, List<LogLine> lines) => Clipboard.setData(
    ClipboardData(
      text: lines
          .map(
            (line) =>
                '${_time(line.ts)}  ${_displayName(model, line.source)}  '
                '${_levelLabel(line.level)}  ${line.message}',
          )
          .join('\n'),
    ),
  );

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }
}

/// One line: time, source, level and the message, all monospaced so the
/// columns line up the way a log viewer's do.
class _LogRow extends StatelessWidget {
  const _LogRow({required this.line, required this.source});

  final LogLine line;
  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final style = TextStyle(
      fontFamily: 'Consolas',
      fontSize: 11,
      color: theme.resources.textFillColorPrimary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              _time(line.ts),
              style: style.copyWith(
                color: theme.resources.textFillColorTertiary,
              ),
            ),
          ),
          SizedBox(
            width: 130,
            child: Text(
              source,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              _levelLabel(line.level),
              style: style.copyWith(color: _levelColor(theme, line.level)),
            ),
          ),
          Expanded(child: SelectableText(line.message, style: style)),
        ],
      ),
    );
  }
}

String _time(DateTime ts) {
  final local = ts.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
      '.${local.millisecond.toString().padLeft(3, '0')}';
}

String _levelLabel(LogLevel level) =>
    level == LogLevel.warning ? 'WARN' : level.jsonValue.toUpperCase();

String _levelTitle(LogLevel level) => switch (level) {
  LogLevel.error => 'Error',
  LogLevel.warning => 'Warning',
  LogLevel.info => 'Info',
  LogLevel.debug => 'Debug',
};

Color _levelColor(FluentThemeData theme, LogLevel level) => switch (level) {
  LogLevel.error => theme.resources.systemFillColorCritical,
  LogLevel.warning => theme.resources.systemFillColorCaution,
  LogLevel.info => theme.accentColor.defaultBrushFor(theme.brightness),
  LogLevel.debug => theme.resources.textFillColorTertiary,
};

/// *Can't reach* (F19, docs/design/prototype/windows.html, board 16): one row
/// per site + app that could not be reached; clicking a row filters the log to
/// that host.
class FailedPane extends StatelessWidget {
  const FailedPane({
    required this.model,
    required this.selectedHost,
    required this.onSelect,
    super.key,
  });

  final AppModel model;
  final String? selectedHost;
  final void Function(FailedHost? row) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final rows = model.failedHosts;
    final appsUnknown =
        rows.isNotEmpty &&
        rows.every((row) => row.processPath == null) &&
        !model.blockCountingPossible;
    final selected = rows.where((row) => row.host == selectedHost).firstOrNull;
    return GroupCard(
      children: [
        Container(
          color: theme.resources.cardBackgroundFillColorSecondary,
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                FluentIcons.warning,
                size: 12,
                color: rows.isEmpty
                    ? theme.resources.textFillColorSecondary
                    : theme.resources.systemFillColorCritical,
              ),
              const SizedBox(width: 8),
              const Text(
                "Can't reach",
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SecondaryText(
                  rows.isEmpty
                      ? FailedText.empty(since: model.failedSince)
                      : FailedText.header(
                          count: rows.length,
                          since: model.failedSince,
                          appsUnknown: appsUnknown,
                        ),
                ),
              ),
              if (rows.isNotEmpty)
                HyperlinkButton(
                  onPressed: () {
                    for (final row in rows) {
                      model.hideFailed(row);
                    }
                    onSelect(null);
                  },
                  child: const Text('Clear'),
                ),
            ],
          ),
        ),
        if (rows.isNotEmpty) ...[
          _columns(context),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 132),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final row in rows)
                    _FailedRow(
                      model: model,
                      row: row,
                      isSelected: row.host == selectedHost,
                      onSelect: () => onSelect(row),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (selected != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: SecondaryText(
                    FailedText.showing(
                      host: selected.host,
                      tries: selected.count,
                      reason: model.failedReason(selected),
                      via: model.failedVia(selected),
                    ),
                  ),
                ),
                HyperlinkButton(
                  onPressed: () => onSelect(null),
                  child: const Text('Show all lines'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _columns(BuildContext context) {
    final theme = FluentTheme.of(context);
    final style = theme.typography.caption?.copyWith(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: theme.resources.textFillColorTertiary,
    );
    return Container(
      color: theme.resources.subtleFillColorTertiary,
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      child: Row(
        children: [
          SizedBox(
            width: _FailedRow.siteWidth,
            child: Text('SITE', style: style),
          ),
          SizedBox(
            width: _FailedRow.appWidth,
            child: Text('APP', style: style),
          ),
          SizedBox(
            width: _FailedRow.triesWidth,
            child: Text('TRIED', style: style),
          ),
          SizedBox(
            width: _FailedRow.whyWidth,
            child: Text('WHY', style: style),
          ),
          SizedBox(
            width: _FailedRow.viaWidth,
            child: Text('VIA', style: style),
          ),
          Text('LAST', style: style),
        ],
      ),
    );
  }
}

/// One pane row: site, app, tries, why, via, last; actions on hover.
class _FailedRow extends StatefulWidget {
  const _FailedRow({
    required this.model,
    required this.row,
    required this.isSelected,
    required this.onSelect,
  });

  final AppModel model;
  final FailedHost row;
  final bool isSelected;
  final VoidCallback onSelect;

  static const siteWidth = 240.0;
  static const appWidth = 90.0;
  static const triesWidth = 44.0;
  static const whyWidth = 140.0;
  static const viaWidth = 70.0;

  @override
  State<_FailedRow> createState() => _FailedRowState();
}

class _FailedRowState extends State<_FailedRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final row = widget.row;
    final theme = FluentTheme.of(context);
    final reason = model.failedReason(row);
    final isError = row.reason.kind != FailureKind.blocked;
    final detail = FailedText.detail(row.reason);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: Container(
          color: widget.isSelected
              ? theme.accentColor.withValues(alpha: 0.12)
              : null,
          padding: const EdgeInsets.fromLTRB(12, 3, 8, 3),
          child: Row(
            children: [
              SizedBox(
                width: _FailedRow.siteWidth,
                child: Row(
                  children: [
                    Icon(
                      FluentIcons.app_icon_default,
                      size: 14,
                      color: row.processPath == null
                          ? theme.resources.textFillColorTertiary
                          : theme.resources.textFillColorSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        row.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: _FailedRow.appWidth,
                child: SecondaryText(processName(row.processPath)),
              ),
              SizedBox(
                width: _FailedRow.triesWidth,
                child: Text(
                  FailedText.tries(row.count),
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              SizedBox(
                width: _FailedRow.whyWidth,
                child: Tooltip(
                  message: detail ?? reason,
                  child: Text(
                    reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isError
                          ? theme.resources.systemFillColorCritical
                          : theme.resources.textFillColorPrimary,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: _FailedRow.viaWidth,
                child: SecondaryText(model.failedVia(row)),
              ),
              SecondaryText(
                FailedText.lastSeen(
                  row.lastSeen,
                  now: model.traffic?.sampledAt ?? DateTime.now(),
                ),
              ),
              const Spacer(),
              if (_hovering || widget.isSelected) ...[
                if (row.reason.kind == FailureKind.blocked)
                  HyperlinkButton(
                    onPressed: () => unawaited(model.neverBlockFailed(row)),
                    child: const Text('Never block'),
                  )
                else if (model.canRouteFailed(row))
                  RouteViaMenu(
                    model: model,
                    header:
                        'Route ${model.recentRulePattern(row.host)} and '
                        'subdomains via…',
                    onPick: (target) =>
                        unawaited(model.routeFailed(row, via: target)),
                  ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Hide until the next Turn On',
                  child: IconButton(
                    icon: const Icon(FluentIcons.chrome_close, size: 9),
                    onPressed: () => model.hideFailed(row),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
