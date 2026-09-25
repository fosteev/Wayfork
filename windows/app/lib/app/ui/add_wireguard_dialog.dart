import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/ui/tunnel_import.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/wireguard/wireguard_conf_parser.dart';

/// What the dialog hands back: the parsed config plus the name to use, which
/// is the file name when the config came from a picker (docs/design/02-ux.md).
typedef WireGuardImport = ({WireGuardImportResult result, String name});

/// "Add WireGuard Tunnel" / "Replace Config": a file picker or a paste area,
/// with the same live preview the link dialog has.
Future<WireGuardImport?> showAddWireGuardDialog(
  BuildContext context, {
  required FilePicker picker,
  bool replacing = false,
}) => showDialog<WireGuardImport>(
  context: context,
  builder: (context) =>
      AddWireGuardDialog(picker: picker, replacing: replacing),
);

class AddWireGuardDialog extends StatefulWidget {
  const AddWireGuardDialog({
    required this.picker,
    this.replacing = false,
    super.key,
  });

  final FilePicker picker;
  final bool replacing;

  @override
  State<AddWireGuardDialog> createState() => _AddWireGuardDialogState();
}

class _AddWireGuardDialogState extends State<AddWireGuardDialog> {
  final _controller = TextEditingController();
  WireGuardImportResult? _parsed;
  String _name = '';
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    final path = await widget.picker.openFile(
      label: 'WireGuard config',
      extensions: const ['conf'],
      confirmButtonText: widget.replacing ? 'Replace' : 'Import',
    );
    if (path == null || !mounted) return;
    final String text;
    try {
      text = await File(path).readAsString();
    } on Object catch (error) {
      setState(() {
        _parsed = null;
        _error = 'Cannot read file: $error';
      });
      return;
    }
    if (!mounted) return;
    _name = TunnelImporter.tunnelName(path);
    _controller.text = text;
    _parse(text);
  }

  void _parse(String input) {
    if (input.trim().isEmpty) {
      setState(() {
        _parsed = null;
        _error = null;
      });
      return;
    }
    try {
      final result = WireGuardConfParser.parse(input);
      setState(() {
        _parsed = result;
        _error = null;
      });
    } on WireGuardImportException catch (error) {
      setState(() {
        _parsed = null;
        _error = 'Not a valid WireGuard config: ${error.message}';
      });
    }
  }

  void _commit() {
    final parsed = _parsed;
    if (parsed == null) return;
    Navigator.of(context).pop((result: parsed, name: _name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final parsed = _parsed;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text(widget.replacing ? 'Replace Config' : 'Add WireGuard Tunnel'),
      // The conf box plus the preview and the warning outgrow a short window,
      // so the content scrolls rather than overflowing.
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Button(
                onPressed: _chooseFile,
                child: const Text('Choose File…'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 130,
              child: TextBox(
                controller: _controller,
                maxLines: null,
                expands: true,
                placeholder: '[Interface]\nPrivateKey = …',
                style: const TextStyle(fontFamily: 'Consolas'),
                onChanged: _parse,
              ),
            ),
            if (parsed != null) ...[
              const SizedBox(height: 12),
              _Preview(result: parsed, name: _name),
              if (allowedIPsWarning(parsed.meta) case final warning?) ...[
                const SizedBox(height: 8),
                SecondaryText(
                  warning,
                  color: theme.resources.systemFillColorCaution,
                  maxLines: 3,
                  overflow: TextOverflow.clip,
                ),
              ],
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

/// Warns when the peer would drop what Wayfork routes into the tunnel. The
/// check is a prefix subtraction, not a string compare: `0.0.0.0/1` plus
/// `128.0.0.0/1` covers everything and must not warn.
String? allowedIPsWarning(WireGuardMeta meta) {
  if (meta.peers.isEmpty) return null;
  final allowed = meta.peers.first.allowedIPs;
  final prefixes = allowed.map(IPv4Prefix.parse).nonNulls.toList();
  if (IPv4Prefix.parse('0.0.0.0/0')!.subtractingAll(prefixes).isEmpty) {
    return null;
  }
  return 'Routes only ${allowed.join(', ')} — traffic sent elsewhere through '
      'this tunnel is dropped by the peer';
}

class _Preview extends StatelessWidget {
  const _Preview({required this.result, required this.name});

  final WireGuardImportResult result;
  final String name;

  @override
  Widget build(BuildContext context) {
    final meta = result.meta;
    final peer = meta.peers.isEmpty ? null : meta.peers.first;
    return GroupCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _row(context, 'Name', name.isEmpty ? result.name : name),
              _row(context, 'Address', meta.addresses.join(', ')),
              _row(
                context,
                'Peer',
                peer == null ? '—' : '${peer.host}:${peer.port}',
              ),
              _row(
                context,
                'DNS',
                meta.discoveredDNS.isEmpty
                    ? 'Automatic'
                    : meta.discoveredDNS.join(', '),
              ),
              _row(context, 'MTU', meta.mtu?.toString() ?? 'Automatic'),
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
}
