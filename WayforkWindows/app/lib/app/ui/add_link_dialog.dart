import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/links/proxy_link_parser.dart';
import 'package:wayfork/core/model/tunnel.dart';

/// "Add Tunnel from Link" / "Replace Link" with the live parse preview of
/// docs/design/02-ux.md. One sheet for every supported scheme, so a user who
/// pasted a link never has to know which menu item matches it. Returns the
/// parsed link, or null when it was cancelled; storing it is the caller's job.
Future<ProxyLink?> showAddLinkDialog(
  BuildContext context, {
  bool replacing = false,
}) => showDialog<ProxyLink>(
  context: context,
  builder: (context) => AddLinkDialog(replacing: replacing),
);

const _schemes = ['vless://', 'ss://', 'trojan://', 'vmess://'];

class AddLinkDialog extends StatefulWidget {
  const AddLinkDialog({this.replacing = false, super.key});

  final bool replacing;

  @override
  State<AddLinkDialog> createState() => _AddLinkDialogState();
}

class _AddLinkDialogState extends State<AddLinkDialog> {
  final _controller = TextEditingController();
  ProxyLink? _parsed;
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

  /// A link on the clipboard is what the user almost always came here with.
  Future<void> _prefill() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty || _controller.text.isNotEmpty) return;
    final lowercased = text.toLowerCase();
    if (!_schemes.any(lowercased.startsWith)) return;
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
      final result = ProxyLinkParser.parse(trimmed);
      setState(() {
        _parsed = result;
        _error = null;
      });
    } on ProxyLinkException catch (error) {
      final scheme = _scheme(trimmed);
      setState(() {
        _parsed = null;
        _error = switch (error.kind) {
          ProxyLinkError.invalid =>
            'Not a valid $scheme link: ${error.message}',
          ProxyLinkError.unsupported =>
            error.message.toLowerCase().contains('not supported')
                ? error.message
                : '${error.message} is not supported yet.',
        };
      });
    }
  }

  /// The scheme the user typed, for the error text; "link" when there is none.
  static String _scheme(String input) {
    final end = input.indexOf('://');
    return end <= 0 ? 'link' : '${input.substring(0, end).toLowerCase()}://';
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
      title: Text(widget.replacing ? 'Replace Link' : 'Add Tunnel from Link'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextBox(
            controller: _controller,
            autofocus: true,
            placeholder: 'vless:// ss:// trojan:// vmess://',
            style: const TextStyle(fontFamily: 'Consolas'),
            onChanged: _parse,
            onSubmitted: (_) => _commit(),
          ),
          if (parsed != null) ...[
            const SizedBox(height: 12),
            _Preview(link: parsed),
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

/// What the link turned into, so the user can see it before it is stored.
class _Preview extends StatelessWidget {
  const _Preview({required this.link});

  final ProxyLink link;

  @override
  Widget build(BuildContext context) => GroupCard(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in _rows(link)) _row(context, row.$1, row.$2),
          ],
        ),
      ),
    ],
  );

  /// Kind and Name for every link, then whatever that kind is defined by
  /// (docs/design/02-ux.md).
  static List<(String, String)> _rows(ProxyLink link) => switch (link) {
    ProxyLinkVLESS(:final result) => [
      ('Kind', 'VLESS'),
      ('Name', _name(result.name, result.meta.server)),
      ('Server', '${result.meta.server}:${result.meta.port}'),
      (
        'Security',
        _security(
          result.meta.security,
          result.meta.sni,
          result.meta.fingerprint,
        ),
      ),
      ('Transport', _transport(result.meta.transport, result.meta.flow)),
    ],
    ProxyLinkShadowsocks(:final result) => [
      ('Kind', 'Shadowsocks'),
      ('Name', _name(result.name, result.meta.server)),
      ('Server', '${result.meta.server}:${result.meta.port}'),
      ('Method', result.meta.method),
    ],
    ProxyLinkTrojan(:final result) => [
      ('Kind', 'Trojan'),
      ('Name', _name(result.name, result.meta.server)),
      ('Server', '${result.meta.server}:${result.meta.port}'),
      (
        'Security',
        _security(
          result.meta.security,
          result.meta.sni,
          result.meta.fingerprint,
        ),
      ),
      ('Transport', _transport(result.meta.transport, null)),
    ],
    ProxyLinkVMess(:final result) => [
      ('Kind', 'VMess'),
      ('Name', _name(result.name, result.meta.server)),
      ('Server', '${result.meta.server}:${result.meta.port}'),
      (
        'Security',
        '${result.meta.security} · '
            '${_security(result.meta.tlsSecurity, result.meta.sni, result.meta.fingerprint)}',
      ),
      ('Transport', _transport(result.meta.transport, null)),
    ],
  };

  static String _name(String name, String server) =>
      name.isEmpty ? server : name;

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

  static String _security(
    TlsSecurity security,
    String? sni,
    String? fingerprint,
  ) {
    var text = security.jsonValue.toUpperCase();
    if (sni != null) text += ' · SNI $sni';
    if (fingerprint != null) text += ' · fingerprint $fingerprint';
    return text;
  }

  static String _transport(ProxyTransport transport, String? flow) {
    var text = switch (transport) {
      ProxyTransportTCP() => 'tcp',
      ProxyTransportWS(:final path, :final host) =>
        host == null ? 'ws $path' : 'ws $path · host $host',
      ProxyTransportGRPC(:final serviceName) => 'gRPC $serviceName',
    };
    if (flow != null) text += ' · flow $flow';
    return text;
  }
}
