import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/ui/add_vless_dialog.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/tunnel_import.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/tunnel.dart';

/// The expanded OpenVPN row (docs/design/prototype/windows.html, board 4):
/// server and adapter as the spike found them, the secrets, the DNS choice and
/// the footer with Reconnect and Delete.
class OpenVPNDetail extends StatefulWidget {
  const OpenVPNDetail({
    required this.tunnel,
    required this.importer,
    super.key,
  });

  final Tunnel tunnel;
  final TunnelImporter importer;

  @override
  State<OpenVPNDetail> createState() => _OpenVPNDetailState();
}

class _OpenVPNDetailState extends State<OpenVPNDetail> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  final _dns = TextEditingController();
  final _nameFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _passphraseFocus = FocusNode();
  final _dnsFocus = FocusNode();

  String? _nameError;
  String? _dnsError;
  bool _customDNS = false;
  Credentials? _storedCredentials;
  String _storedPassphrase = '';

  AppModel get _model => AppScope.of(context);
  OpenVPNMeta get _meta =>
      widget.tunnel.kind.openVPN ??
      OpenVPNMeta(
        remotes: const [],
        needsCredentials: false,
        needsKeyPassphrase: false,
        configHash: '',
      );

  @override
  void initState() {
    super.initState();
    _name.text = widget.tunnel.name;
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) unawaited(_commitName());
    });
    for (final focus in [_usernameFocus, _passwordFocus]) {
      focus.addListener(() {
        if (!focus.hasFocus) unawaited(_commitCredentials());
      });
    }
    _passphraseFocus.addListener(() {
      if (!_passphraseFocus.hasFocus) unawaited(_commitPassphrase());
    });
    _dnsFocus.addListener(() {
      if (!_dnsFocus.hasFocus) _commitDNS();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    for (final controller in [_name, _username, _password, _passphrase, _dns]) {
      controller.dispose();
    }
    for (final focus in [
      _nameFocus,
      _usernameFocus,
      _passwordFocus,
      _passphraseFocus,
      _dnsFocus,
    ]) {
      focus.dispose();
    }
    super.dispose();
  }

  /// Secrets come out of DPAPI, so the fields fill in a frame later.
  Future<void> _load() async {
    final credentials = await _model.credentials(widget.tunnel.id);
    final passphrase = await _model.keyPassphrase(widget.tunnel.id);
    if (!mounted) return;
    setState(() {
      _storedCredentials = credentials;
      _username.text = credentials?.username ?? '';
      _password.text = credentials?.password ?? '';
      _storedPassphrase = passphrase ?? '';
      _passphrase.text = _storedPassphrase;
      switch (_meta.dns) {
        case TunnelDNSAuto():
          _customDNS = false;
        case TunnelDNSCustom(:final servers):
          _customDNS = true;
          _dns.text = servers.join(', ');
      }
    });
    _takeFocus();
  }

  /// The ✎ of a failed card (and a fresh import) says which field to land in.
  void _takeFocus() {
    final model = _model;
    if (model.expandedTunnelID != widget.tunnel.id) return;
    final pending = model.pendingFocus;
    if (pending == null) return;
    model.pendingFocus = null;
    switch (pending) {
      case TunnelField.name:
        _nameFocus.requestFocus();
      case TunnelField.username:
        _usernameFocus.requestFocus();
      case TunnelField.password:
        _passwordFocus.requestFocus();
      case TunnelField.keyPassphrase:
        _passphraseFocus.requestFocus();
      case TunnelField.config || TunnelField.url:
        break;
    }
  }

  Future<void> _commitName() async {
    if (_name.text == widget.tunnel.name) return;
    final error = await _model.rename(widget.tunnel.id, _name.text);
    if (!mounted) return;
    setState(() => _nameError = error);
  }

  Future<void> _commitCredentials() async {
    final stored = _storedCredentials;
    if (stored?.username == _username.text &&
        stored?.password == _password.text) {
      return;
    }
    if (stored == null && _username.text.isEmpty && _password.text.isEmpty) {
      return;
    }
    await _model.setCredentials(
      widget.tunnel.id,
      username: _username.text,
      password: _password.text,
    );
    if (!mounted) return;
    _storedCredentials = _username.text.isEmpty && _password.text.isEmpty
        ? null
        : Credentials(username: _username.text, password: _password.text);
  }

  Future<void> _commitPassphrase() async {
    if (_passphrase.text == _storedPassphrase) return;
    await _model.setKeyPassphrase(widget.tunnel.id, _passphrase.text);
    if (!mounted) return;
    _storedPassphrase = _passphrase.text;
  }

  void _commitDNS() {
    if (!_customDNS) return;
    final servers = _dns.text
        .split(RegExp('[, ]'))
        .map((server) => server.trim())
        .where((server) => server.isNotEmpty)
        .toList();
    if (servers.isEmpty ||
        servers.any((server) => InternetAddress.tryParse(server) == null)) {
      setState(() {
        _dnsError = servers.isEmpty
            ? 'Enter at least one resolver address'
            : 'Not an IP address';
      });
      return;
    }
    setState(() => _dnsError = null);
    final dns = TunnelDNSCustom(servers);
    if (_meta.dns != dns) unawaited(_model.setDNS(widget.tunnel.id, dns));
  }

  void _setCustomDNS(bool custom) {
    setState(() {
      _customDNS = custom;
      if (!custom) _dnsError = null;
    });
    if (custom) {
      _commitDNS();
    } else {
      unawaited(_model.setDNS(widget.tunnel.id, const TunnelDNSAuto()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    final tunnel = widget.tunnel;
    final meta = _meta;
    final discovered = model.discoveredDNS(tunnel);
    return DetailPane(
      children: [
        DetailRow(label: 'Server', child: MonoText(_servers(meta))),
        DetailRow(
          label: 'Adapter',
          child: MonoText(_adapter(model.tunnelState(tunnel.id))),
        ),
        DetailRow(
          label: 'Name',
          child: FieldWithError(
            error: _nameError,
            child: SizedBox(
              width: 240,
              child: TextBox(
                controller: _name,
                focusNode: _nameFocus,
                onSubmitted: (_) => unawaited(_commitName()),
              ),
            ),
          ),
        ),
        if (meta.needsCredentials)
          DetailRow(
            label: 'Credentials',
            child: Row(
              children: [
                SizedBox(
                  width: 150,
                  child: TextBox(
                    controller: _username,
                    focusNode: _usernameFocus,
                    placeholder: 'Username',
                    onSubmitted: (_) => unawaited(_commitCredentials()),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  // `PasswordBox` disposes a focus node it was handed, so the
                  // secret fields are obscured text boxes instead.
                  child: TextBox(
                    controller: _password,
                    focusNode: _passwordFocus,
                    obscureText: true,
                    maxLines: 1,
                    placeholder: 'Password',
                    onSubmitted: (_) => unawaited(_commitCredentials()),
                  ),
                ),
              ],
            ),
          ),
        if (meta.needsKeyPassphrase)
          DetailRow(
            label: 'Key passphrase',
            child: SizedBox(
              width: 240,
              child: TextBox(
                controller: _passphrase,
                focusNode: _passphraseFocus,
                obscureText: true,
                maxLines: 1,
                placeholder: 'Passphrase',
                onSubmitted: (_) => unawaited(_commitPassphrase()),
              ),
            ),
          ),
        DetailRow(
          label: 'DNS',
          child: FieldWithError(
            error: _dnsError,
            child: Row(
              children: [
                RadioGroup<bool>(
                  groupValue: _customDNS,
                  onChanged: (custom) => _setCustomDNS(custom ?? false),
                  child: Row(
                    children: [
                      RadioButton(
                        value: false,
                        content: Text(
                          discovered.isEmpty
                              ? 'Automatic'
                              : 'Automatic (${discovered.join(', ')})',
                        ),
                      ),
                      const SizedBox(width: 14),
                      const RadioButton(value: true, content: Text('Custom')),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 160,
                  child: TextBox(
                    controller: _dns,
                    focusNode: _dnsFocus,
                    enabled: _customDNS,
                    placeholder: '10.8.0.1',
                    onSubmitted: (_) => _commitDNS(),
                  ),
                ),
              ],
            ),
          ),
        ),
        DetailRow(
          label: 'Config',
          child: Row(
            children: [
              SecondaryText(_configLine(tunnel, meta)),
              const SizedBox(width: 8),
              Button(
                onPressed: () =>
                    unawaited(widget.importer.replaceConfig(tunnel.id)),
                child: const Text('Replace…'),
              ),
            ],
          ),
        ),
        DetailRow(
          label: '',
          child: DefaultTunnelToggle(tunnel: tunnel),
        ),
        DetailRow(
          label: '',
          child: TunnelFooter(
            tunnel: tunnel,
            onReconnect: () => unawaited(model.reconnect(tunnel.id)),
          ),
        ),
      ],
    );
  }

  static String _servers(OpenVPNMeta meta) => meta.remotes.isEmpty
      ? '—'
      : meta.remotes
            .map((remote) => '${remote.host}:${remote.port} · ${remote.proto}')
            .join(', ');

  /// The spike's reality: a named dco adapter, not a `utun` unit
  /// (docs/design/08-windows.md).
  static String _adapter(TunnelState? state) => switch (state) {
    TunnelStateConnected(:final ip, :final interface) => '$interface · $ip',
    _ => 'not connected',
  };

  static String _configLine(Tunnel tunnel, OpenVPNMeta meta) {
    final date = tunnel.createdAt.toLocal();
    final day = '${date.year}-${_two(date.month)}-${_two(date.day)}';
    final hash = meta.configHash;
    final short = hash.length > 8
        ? '${hash.substring(0, 4)}…${hash.substring(hash.length - 4)}'
        : hash;
    return '$day · $short';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// The expanded VLESS row: name, the URI with its UUID masked, footer.
class VLESSDetail extends StatefulWidget {
  const VLESSDetail({required this.tunnel, super.key});

  final Tunnel tunnel;

  @override
  State<VLESSDetail> createState() => _VLESSDetailState();
}

class _VLESSDetailState extends State<VLESSDetail> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  String? _nameError;

  AppModel get _model => AppScope.of(context);

  @override
  void initState() {
    super.initState();
    _name.text = widget.tunnel.name;
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) unawaited(_commitName());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeFocus());
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _takeFocus() {
    if (!mounted) return;
    final model = _model;
    if (model.expandedTunnelID != widget.tunnel.id) return;
    final pending = model.pendingFocus;
    if (pending == null) return;
    model.pendingFocus = null;
    if (pending == TunnelField.url) {
      unawaited(_replace());
    } else {
      _nameFocus.requestFocus();
    }
  }

  Future<void> _commitName() async {
    if (_name.text == widget.tunnel.name) return;
    final error = await _model.rename(widget.tunnel.id, _name.text);
    if (!mounted) return;
    setState(() => _nameError = error);
  }

  Future<void> _copy() async {
    final uri = await _model.vlessURI(widget.tunnel);
    if (uri == null) return;
    await Clipboard.setData(ClipboardData(text: uri));
  }

  Future<void> _replace() async {
    final result = await showAddVLESSDialog(context, replacing: true);
    if (result == null) return;
    final error = await _model.replaceVLESS(widget.tunnel.id, result);
    if (error != null && mounted) {
      _model.showAlert(
        AppAlert(title: 'Cannot replace the URL', message: error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    final tunnel = widget.tunnel;
    return DetailPane(
      children: [
        DetailRow(
          label: 'Name',
          child: FieldWithError(
            error: _nameError,
            child: SizedBox(
              width: 240,
              child: TextBox(
                controller: _name,
                focusNode: _nameFocus,
                onSubmitted: (_) => unawaited(_commitName()),
              ),
            ),
          ),
        ),
        DetailRow(
          label: 'URL',
          child: Row(
            children: [
              Expanded(child: MonoText(model.maskedVLESSURI(tunnel))),
              const SizedBox(width: 8),
              Button(
                onPressed: model.missingSecrets.contains(tunnel.id)
                    ? null
                    : () => unawaited(_copy()),
                child: const Text('Copy'),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed: () => unawaited(_replace()),
                child: const Text('Replace URL…'),
              ),
            ],
          ),
        ),
        DetailRow(
          label: '',
          child: DefaultTunnelToggle(tunnel: tunnel),
        ),
        DetailRow(
          label: '',
          child: TunnelFooter(tunnel: tunnel),
        ),
      ],
    );
  }
}

/// "Route everything else through this tunnel" (F8): only one tunnel holds it,
/// so turning it on here takes it away from whichever tunnel had it.
class DefaultTunnelToggle extends StatelessWidget {
  const DefaultTunnelToggle({required this.tunnel, super.key});

  final Tunnel tunnel;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final hint = model.defaultTunnelHint(tunnel);
    final theme = FluentTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          checked: model.isDefaultTunnel(tunnel.id),
          onChanged: (checked) => unawaited(
            model.setDefaultTunnel(checked ?? false ? tunnel.id : null),
          ),
          content: const Text('Route everything else through this tunnel'),
        ),
        const SizedBox(height: 2),
        SecondaryText(
          hint.text,
          color: hint.isWarning ? theme.resources.systemFillColorCaution : null,
          maxLines: 3,
          overflow: TextOverflow.clip,
        ),
      ],
    );
  }
}

/// `3 rules · Show … Reconnect · Delete…`.
class TunnelFooter extends StatelessWidget {
  const TunnelFooter({required this.tunnel, this.onReconnect, super.key});

  final Tunnel tunnel;

  /// Only OpenVPN tunnels have a process to restart.
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final navigator = NavigationScope.of(context);
    final theme = FluentTheme.of(context);
    return Row(
      children: [
        SecondaryText(
          StatusText.count(model.ruleCountForTunnel(tunnel.id), 'rule'),
        ),
        HyperlinkButton(
          onPressed: () => navigator.go(AppPage.rules),
          child: const Text('Show'),
        ),
        const Spacer(),
        if (onReconnect case final reconnect?)
          Button(
            onPressed: model.globalState.isRunning && tunnel.isEnabled
                ? reconnect
                : null,
            child: const Text('Reconnect'),
          ),
        const SizedBox(width: 8),
        Button(
          onPressed: () => unawaited(_delete(context, model)),
          child: Text(
            'Delete…',
            style: TextStyle(color: theme.resources.systemFillColorCritical),
          ),
        ),
      ],
    );
  }

  /// The rules go with the tunnel, so the confirmation says how many.
  Future<void> _delete(BuildContext context, AppModel model) async {
    final message = model.deleteTunnelMessage(tunnel.id);
    if (message == null) return;
    final confirmed = await showQuestionDialog(
      context,
      title: 'Delete tunnel',
      message: message,
      confirm: 'Delete',
      destructive: true,
    );
    if (confirmed) await model.deleteTunnel(tunnel.id);
  }
}

/// The expansion's body: a tinted pane of label/value rows.
class DetailPane extends StatelessWidget {
  const DetailPane({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: FluentTheme.of(context).resources.subtleFillColorSecondary,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );
}

class DetailRow extends StatelessWidget {
  const DetailRow({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, right: 10),
            child: Align(
              alignment: Alignment.centerRight,
              child: SecondaryText(label),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    ),
  );
}
