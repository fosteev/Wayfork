import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

/// Logs (docs/design/prototype/windows.html, board 7; docs/design/06-logging.md):
/// the `LogCenter` ring buffer with the source filter, a level floor, search,
/// follow and copy/clear. The macOS Logs *window* is a page here, and "Show
/// Log" on a failed tunnel arrives through `AppNavigator.logSource`.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// null is "All sources".
  String? _source;
  LogLevel _level = LogLevel.debug;
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
    return ListenableBuilder(
      listenable: model.logs,
      builder: (context, _) {
        final lines = _visible(model);
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
              Expanded(child: _lines(context, model, lines)),
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
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              itemCount: lines.length,
              itemBuilder: (context, index) => _LogRow(
                line: lines[index],
                source: _displayName(model, lines[index].source),
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
