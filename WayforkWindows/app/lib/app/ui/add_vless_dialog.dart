import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/vless/vless_uri_parser.dart';

/// "Add VLESS Tunnel" / "Replace VLESS URL" with the live parse preview of
/// docs/design/02-ux.md. Returns the parsed URI, or null when it was
/// cancelled; storing it is the caller's job.
Future<VLESSImportResult?> showAddVLESSDialog(
  BuildContext context, {
  bool replacing = false,
}) => showDialog<VLESSImportResult>(
  context: context,
  builder: (context) => AddVLESSDialog(replacing: replacing),
);

class AddVLESSDialog extends StatefulWidget {
  const AddVLESSDialog({this.replacing = false, super.key});

  final bool replacing;

  @override
  State<AddVLESSDialog> createState() => _AddVLESSDialogState();
}

class _AddVLESSDialogState extends State<AddVLESSDialog> {
  final _controller = TextEditingController();
  VLESSImportResult? _parsed;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// A `vless://` URI on the clipboard is what the user almost always came
  /// here with.
  Future<void> _prefill() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty || _controller.text.isNotEmpty) return;
    if (!text.toLowerCase().startsWith('vless://')) return;
    _controller.text = text;
    _parse(text);
  }

  void _parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _parsed = null;
        _error = null;
      });
      return;
    }
    try {
      final result = VLESSURIParser.parse(trimmed);
      setState(() {
        _parsed = result;
        _error = null;
      });
    } on VLESSImportException catch (error) {
      setState(() {
        _parsed = null;
        _error = switch (error.kind) {
          VLESSImportError.invalid =>
            'Not a valid vless:// URL: ${error.message}',
          VLESSImportError.unsupported =>
            error.message.toLowerCase().contains('not supported')
                ? error.message
                : '${error.message} is not supported yet.',
        };
      });
    }
  }

  void _commit() {
    final parsed = _parsed;
    if (parsed == null) return;
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final parsed = _parsed;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text(widget.replacing ? 'Replace VLESS URL' : 'Add VLESS Tunnel'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextBox(
            controller: _controller,
            autofocus: true,
            placeholder: 'vless://…',
            style: const TextStyle(fontFamily: 'Consolas'),
            onChanged: _parse,
            onSubmitted: (_) => _commit(),
          ),
          if (parsed != null) ...[
            const SizedBox(height: 12),
            _Preview(result: parsed),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            SecondaryText(
              error,
              color: theme.resources.systemFillColorCritical,
              maxLines: 3,
              overflow: TextOverflow.clip,
            ),
          ],
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: parsed == null ? null : _commit,
          child: Text(widget.replacing ? 'Replace' : 'Add'),
        ),
      ],
    );
  }
}

/// What the URI turned into, so the user can see it before it is stored.
class _Preview extends StatelessWidget {
  const _Preview({required this.result});

  final VLESSImportResult result;

  @override
  Widget build(BuildContext context) {
    final meta = result.meta;
    return GroupCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _row(
                context,
                'Name',
                result.name.isEmpty ? meta.server : result.name,
              ),
              _row(context, 'Server', '${meta.server}:${meta.port}'),
              _row(context, 'Security', _security(meta)),
              _row(context, 'Transport', _transport(meta)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 80, child: SecondaryText(key, maxLines: 1)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );

  static String _security(VLESSMeta meta) {
    var text = meta.security.jsonValue.toUpperCase();
    if (meta.sni case final sni?) text += ' · SNI $sni';
    if (meta.fingerprint case final fingerprint?) {
      text += ' · fingerprint $fingerprint';
    }
    return text;
  }

  static String _transport(VLESSMeta meta) {
    var text = switch (meta.transport) {
      VLESSTransportTCP() => 'tcp',
      VLESSTransportWS(:final path, :final host) =>
        host == null ? 'ws $path' : 'ws $path · host $host',
      VLESSTransportGRPC(:final serviceName) => 'gRPC $serviceName',
    };
    if (meta.flow case final flow?) text += ' · flow $flow';
    return text;
  }
}
