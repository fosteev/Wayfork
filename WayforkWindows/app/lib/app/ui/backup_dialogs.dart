import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/import_export.dart';
import 'package:wayfork/core/app/status_text.dart';

/// The three sheets of the macOS General pane, as `ContentDialog`s: the export
/// options (docs/design/01-data-model.md, "Import / export"), the import
/// summary and the Export Diagnostics options (docs/design/06-logging.md).

/// Returns whether to include secrets, or null when cancelled.
Future<bool?> showExportDialog(
  BuildContext context, {
  required int tunnels,
  required int rules,
}) => showDialog<bool>(
  context: context,
  builder: (context) => _ExportDialog(tunnels: tunnels, rules: rules),
);

/// Returns the mode to import with, or null when cancelled. "Replace all"
/// asks once more before it comes back.
Future<ImportMode?> showImportDialog(
  BuildContext context,
  ImportPreview preview,
) => showDialog<ImportMode>(
  context: context,
  builder: (context) => _ImportDialog(preview: preview),
);

/// Returns whether to keep server addresses, or null when cancelled.
Future<bool?> showDiagnosticsDialog(BuildContext context) => showDialog<bool>(
  context: context,
  builder: (context) => const _DiagnosticsDialog(),
);

/// A dialog whose only control is one checkbox, with an optional warning that
/// appears when it is ticked.
class _OptionDialog extends StatefulWidget {
  const _OptionDialog({
    required this.title,
    required this.message,
    required this.option,
    required this.confirm,
    this.warning,
    this.note,
  });

  final String title;
  final String message;
  final String option;
  final String confirm;

  /// Shown in red while the checkbox is ticked.
  final String? warning;

  /// Always shown, under the checkbox.
  final String? note;

  @override
  State<_OptionDialog> createState() => _OptionDialogState();
}

class _OptionDialogState extends State<_OptionDialog> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 480),
      title: Text(widget.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SecondaryText(widget.message, maxLines: 6),
          const SizedBox(height: 12),
          Checkbox(
            checked: _checked,
            onChanged: (value) => setState(() => _checked = value ?? false),
            // The label is a sentence, and fluent_ui lays the box and its
            // content out in a bare Row: without this it overflows.
            content: Flexible(child: Text(widget.option)),
          ),
          if (_checked)
            if (widget.warning case final warning?) ...[
              const SizedBox(height: 8),
              SecondaryText(
                warning,
                color: theme.resources.systemFillColorCritical,
                maxLines: 3,
              ),
            ],
          if (widget.note case final note?) ...[
            const SizedBox(height: 8),
            SecondaryText(note, maxLines: 3),
          ],
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_checked),
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}

class _ExportDialog extends StatelessWidget {
  const _ExportDialog({required this.tunnels, required this.rules});

  final int tunnels;
  final int rules;

  @override
  Widget build(BuildContext context) => _OptionDialog(
    title: 'Export tunnels and rules',
    message:
        '${StatusText.count(tunnels, 'tunnel')}, '
        '${StatusText.count(rules, 'rule')} and settings go to '
        'wayfork-export.json.',
    option: 'Include secrets (keys, passwords, UUIDs)',
    warning:
        'The file will contain private keys and passwords in plain text, and '
        'inherits the permissions of the folder you save it in. Keep it '
        'private.',
    confirm: 'Export…',
  );
}

class _DiagnosticsDialog extends StatelessWidget {
  const _DiagnosticsDialog();

  @override
  Widget build(BuildContext context) => const _OptionDialog(
    title: 'Export Diagnostics',
    message:
        'A zip with logs, a sanitized configuration and system information '
        'for bug reports. Secrets are removed; server addresses are replaced '
        'by placeholders unless you include them.',
    option: 'Include server addresses',
    note: 'Log lines are copied as they are and may mention hostnames.',
    confirm: 'Export…',
  );
}

class _ImportDialog extends StatelessWidget {
  const _ImportDialog({required this.preview});

  final ImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final secrets = preview.includesSecrets
        ? 'included for ${preview.tunnelsWithSecrets}'
        : 'not included';
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520),
      title: const Text('Import tunnels and rules'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SecondaryText(
            '${StatusText.count(preview.tunnels, 'tunnel')}, '
            '${StatusText.count(preview.rules, 'rule')}; secrets $secrets.',
            maxLines: 3,
          ),
          if (!preview.includesSecrets) ...[
            const SizedBox(height: 8),
            SecondaryText(
              'Imported OpenVPN tunnels need their config re-attached and '
              'VLESS tunnels their URL before they can run.',
              maxLines: 3,
            ),
          ],
          if (preview.foreignAppRules > 0) ...[
            const SizedBox(height: 8),
            SecondaryText(
              '${StatusText.count(preview.foreignAppRules, 'app rule')} name '
              'an application from another platform and will never match here.',
              maxLines: 3,
            ),
          ],
          const SizedBox(height: 8),
          SecondaryText(
            'Merge adds new items and updates existing ones by id. Replace '
            'all discards the current tunnels, rules and settings.',
            maxLines: 3,
          ),
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        Button(
          onPressed: () => unawaited(_replace(context)),
          child: const Text('Replace all'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ImportMode.merge),
          child: const Text('Merge'),
        ),
      ],
    );
  }

  Future<void> _replace(BuildContext context) async {
    final navigator = Navigator.of(context);
    final confirmed = await showQuestionDialog(
      context,
      title: 'Replace everything?',
      message:
          "Current tunnels, rules and settings will be replaced by the file's.",
      confirm: 'Replace',
      destructive: true,
    );
    if (!confirmed) return;
    navigator.pop(ImportMode.replace);
  }
}
