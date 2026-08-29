import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/services/running_apps.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/running_app.dart';

/// "Add Application Rule" (F10): the apps that are running right now, because
/// that is how a user knows an app — not by its install path. Returns the
/// chosen `.exe`, or null when the dialog was cancelled; the rule is the
/// caller's job.
Future<String?> showPickApplicationDialog(
  BuildContext context, {
  required RunningAppSource apps,
  required FilePicker picker,
}) => showDialog<String>(
  context: context,
  builder: (context) => PickApplicationDialog(apps: apps, picker: picker),
);

class PickApplicationDialog extends StatefulWidget {
  const PickApplicationDialog({
    required this.apps,
    required this.picker,
    super.key,
  });

  final RunningAppSource apps;

  /// Behind "Browse…", for an app that is not running.
  final FilePicker picker;

  @override
  State<PickApplicationDialog> createState() => _PickApplicationDialogState();
}

class _PickApplicationDialogState extends State<PickApplicationDialog> {
  final _search = TextEditingController();
  List<RunningApp> _apps = const [];
  String? _selected;
  DateTime? _selectedAt;
  String? _error;
  bool _loading = true;
  bool _background = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    List<RunningApp> apps;
    try {
      apps = await widget.apps.list(includeBackground: _background);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _apps = const [];
        _error = 'Could not read the running applications: $error';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _apps = apps;
      // A refresh can retire what was selected.
      if (!apps.any((app) => app.path == _selected)) _selected = null;
    });
  }

  Future<void> _browse() async {
    final path = await widget.picker.openFile(
      label: 'Applications',
      extensions: const ['exe'],
      confirmButtonText: 'Add Rule',
    );
    if (path == null || !mounted) return;
    Navigator.of(context).pop(path);
  }

  /// Windows picks from a list with one click and commits with two. A double
  /// tap recognizer of its own would sit in the gesture arena and delay every
  /// single click by its timeout, so the second click is spotted here instead.
  void _select(String path) {
    final now = DateTime.now();
    final again =
        _selected == path &&
        _selectedAt != null &&
        now.difference(_selectedAt!) < const Duration(milliseconds: 400);
    setState(() {
      _selected = path;
      _selectedAt = now;
    });
    if (again) _commit(path);
  }

  void _commit([String? path]) {
    final chosen = path ?? _selected;
    if (chosen == null) return;
    Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final visible = RunningApps.search(_apps, _search.text);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      title: const Text('Add Application Rule'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextBox(
                  controller: _search,
                  autofocus: true,
                  placeholder: 'Search running applications',
                  prefix: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(FluentIcons.search, size: 12),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Refresh',
                child: IconButton(
                  icon: const Icon(FluentIcons.refresh, size: 14),
                  onPressed: _loading ? null : () => unawaited(_load()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 300,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.resources.dividerStrokeColorDefault,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: _list(theme, visible),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Checkbox(
                checked: _background,
                onChanged: _loading
                    ? null
                    : (checked) {
                        setState(() => _background = checked ?? false);
                        unawaited(_load());
                      },
                content: const Text('Show background processes'),
              ),
              const Spacer(),
              SecondaryText(
                _loading ? 'Reading…' : '${visible.length} of ${_apps.length}',
                color: theme.resources.textFillColorTertiary,
              ),
            ],
          ),
        ],
      ),
      actions: [
        Button(
          onPressed: () => unawaited(_browse()),
          child: const Text('Browse…'),
        ),
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected == null ? null : _commit,
          child: const Text('Add Rule'),
        ),
      ],
    );
  }

  Widget _list(FluentThemeData theme, List<RunningApp> apps) {
    if (_error case final error?) {
      return _Placeholder(
        text: error,
        color: theme.resources.systemFillColorCritical,
      );
    }
    if (_loading) return const Center(child: ProgressRing());
    if (apps.isEmpty) {
      return _Placeholder(
        text: _apps.isEmpty
            ? 'Nothing with a window is running. Turn on background processes, '
                  'or use Browse… to pick an .exe.'
            : 'No running application matches the search.',
        color: theme.resources.textFillColorSecondary,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: apps.length,
      itemBuilder: (context, index) {
        final app = apps[index];
        final selected = app.path == _selected;
        return Tooltip(
          message: app.windowTitle ?? app.path,
          child: ListTile.selectable(
            selected: selected,
            onPressed: () => _select(app.path),
            title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: SecondaryText(app.path, maxLines: 1),
            trailing: app.instances > 1
                ? Chip('${app.instances} processes')
                : null,
          ),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: SecondaryText(
        text,
        color: color,
        maxLines: 4,
        overflow: TextOverflow.clip,
      ),
    ),
  );
}
