import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/links/proxy_link_parser.dart';
import 'package:wayfork/core/links/subscription_decoder.dart';
import 'package:wayfork/core/links/subscription_fetcher.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';

/// What the dialog was closed with: one pasted link, or the checked servers
/// of a fetched subscription (with the host, which is all the log may see).
sealed class AddLinkOutcome {
  const AddLinkOutcome();
}

final class AddLinkSingle extends AddLinkOutcome {
  const AddLinkSingle(this.link);

  final ProxyLink link;
}

final class AddLinkSubscription extends AddLinkOutcome {
  const AddLinkSubscription(this.links, {required this.host});

  final List<ProxyLink> links;
  final String host;
}

/// "Add Tunnel from Link" / "Replace Link" with the live parse preview of
/// docs/design/02-ux.md. One sheet for every supported scheme, so a user who
/// pasted a link never has to know which menu item matches it; the same field
/// takes a subscription URL, fetched on request into a checklist. Returns the
/// outcome, or null when it was cancelled; storing it is the caller's job.
/// `store` is what the checklist compares against and what bounds it; `fetch`
/// is replaceable for tests.
Future<AddLinkOutcome?> showAddLinkDialog(
  BuildContext context, {
  bool replacing = false,
  Store? store,
  Future<String> Function(Uri url)? fetch,
}) => showDialog<AddLinkOutcome>(
  context: context,
  builder: (context) =>
      AddLinkDialog(replacing: replacing, store: store, fetch: fetch),
);

/// Replace-link callers want exactly one link back.
Future<ProxyLink?> showReplaceLinkDialog(BuildContext context) async =>
    switch (await showAddLinkDialog(context, replacing: true)) {
      AddLinkSingle(:final link) => link,
      _ => null,
    };

const _schemes = ['vless://', 'ss://', 'trojan://', 'vmess://', 'https://'];

class AddLinkDialog extends StatefulWidget {
  const AddLinkDialog({
    this.replacing = false,
    this.store,
    this.fetch,
    super.key,
  });

  final bool replacing;
  final Store? store;
  final Future<String> Function(Uri url)? fetch;

  @override
  State<AddLinkDialog> createState() => _AddLinkDialogState();
}

/// What the dialog is doing with a pasted subscription URL.
sealed class _Subscription {
  const _Subscription(this.host);

  final String host;
}

final class _Fetching extends _Subscription {
  const _Fetching(super.host);
}

final class _Loaded extends _Subscription {
  const _Loaded(super.host, this.entries, this.checked);

  final List<SubscriptionEntry> entries;
  final Set<int> checked;
}

class _AddLinkDialogState extends State<AddLinkDialog> {
  final _controller = TextEditingController();
  ProxyLink? _parsed;
  String? _error;
  _Subscription? _subscription;
  var _fetchGeneration = 0;

  Store get _store => widget.store ?? Store();

  bool get _isSubscriptionURL =>
      !widget.replacing && SubscriptionDecoder.isURL(_controller.text);

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  @override
  void dispose() {
    _fetchGeneration += 1;
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
    _fetchGeneration += 1;
    _subscription = null;
    if (trimmed.isEmpty) {
      setState(() {
        _parsed = null;
        _error = null;
      });
      return;
    }
    if (SubscriptionDecoder.isURL(trimmed)) {
      setState(() {
        _parsed = null;
        _error = widget.replacing
            ? 'Paste a single link; subscriptions add new tunnels.'
            : trimmed.toLowerCase().startsWith('https://')
            ? null
            : 'Subscriptions must use https.';
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
    if (parsed == null || _subscription != null) return;
    Navigator.of(context).pop(AddLinkSingle(parsed));
  }

  void _submit() {
    if (_subscription == null && _isSubscriptionURL) {
      unawaited(_fetch());
    } else {
      _commit();
    }
  }

  // Subscription

  bool _alreadyAdded(ProxyLink link) =>
      _store.tunnels.any((tunnel) => tunnel.kind == link.tunnelKind);

  Future<void> _fetch() async {
    if (widget.replacing || _subscription != null || _error != null) return;
    final url = Uri.tryParse(_controller.text.trim());
    if (url == null || url.host.isEmpty) {
      setState(() => _error = 'Not a valid URL.');
      return;
    }
    final host = url.host;
    final generation = ++_fetchGeneration;
    setState(() => _subscription = _Fetching(host));
    try {
      final body = await (widget.fetch ?? SubscriptionFetcher.fetch)(url);
      final entries = SubscriptionDecoder.decode(body);
      if (!mounted || generation != _fetchGeneration) return;
      // Servers already in the store start unchecked; the rest are wanted.
      final checked = <int>{
        for (var index = 0; index < entries.length; index++)
          if (entries[index] case SubscriptionLink(
            :final link,
          ) when !_alreadyAdded(link))
            index,
      };
      setState(() {
        _subscription = _Loaded(host, entries, checked);
        if (entries.isEmpty) _error = 'The subscription has no links.';
      });
    } on ProxyLinkException catch (error) {
      if (!mounted || generation != _fetchGeneration) return;
      setState(() {
        _subscription = null;
        _error = 'Cannot load the subscription: ${error.message}';
      });
    }
  }

  void _setChecked(int index, bool on) {
    if (_subscription case _Loaded(
      :final host,
      :final entries,
      :final checked,
    )) {
      setState(() {
        _subscription = _Loaded(
          host,
          entries,
          on ? {...checked, index} : {...checked}
            ..remove(index),
        );
      });
    }
  }

  void _commitSubscription() {
    if (_subscription case _Loaded(
      :final host,
      :final entries,
      :final checked,
    )) {
      final links = [
        for (var index = 0; index < entries.length; index++)
          if (entries[index] case SubscriptionLink(
            :final link,
          ) when checked.contains(index))
            link,
      ];
      if (links.isEmpty || links.length > _store.freeSlotCount) return;
      Navigator.of(context).pop(AddLinkSubscription(links, host: host));
    }
  }

  String get _title => switch ((widget.replacing, _subscription)) {
    (true, _) => 'Replace Link',
    (false, null) => 'Add Tunnel from Link',
    (false, _) => 'Add Tunnels from Subscription',
  };

  static String _summary(List<SubscriptionEntry> entries) {
    final links = entries.whereType<SubscriptionLink>().length;
    final skipped = entries.length - links;
    final result = StatusText.count(links, 'server');
    return skipped > 0 ? '$result, $skipped skipped' : result;
  }

  Widget _checklist(BuildContext context, _Loaded loaded) {
    final resources = FluentTheme.of(context).resources;
    // Not a GroupCard: its Column would take the whole height cap, and the
    // list has to shrink to its rows so a short subscription stays short.
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: resources.cardBackgroundFillColorDefault,
        border: Border.all(color: resources.cardStrokeColorDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (var index = 0; index < loaded.entries.length; index++)
            switch (loaded.entries[index]) {
              SubscriptionLink(:final link) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Checkbox(
                  checked: loaded.checked.contains(index),
                  onChanged: (value) => _setChecked(index, value ?? false),
                  content: Flexible(
                    child: _ChecklistRow(
                      link: link,
                      alreadyAdded: _alreadyAdded(link),
                    ),
                  ),
                ),
              ),
              SubscriptionSkipped(:final line, :final reason) => Padding(
                padding: const EdgeInsets.only(left: 28, top: 2, bottom: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: SecondaryText(
                        'line $line',
                        color: resources.textFillColorTertiary,
                      ),
                    ),
                    Expanded(
                      child: SecondaryText(
                        reason,
                        color: resources.textFillColorTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            },
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final parsed = _parsed;
    final subscription = _subscription;
    final loaded = subscription is _Loaded ? subscription : null;
    final free = _store.freeSlotCount;
    final tooMany = loaded != null && loaded.checked.length > free;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text(_title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextBox(
            controller: _controller,
            autofocus: true,
            enabled: subscription == null,
            placeholder:
                'vless:// ss:// trojan:// vmess:// or a subscription https://',
            style: const TextStyle(fontFamily: 'Consolas'),
            onChanged: _parse,
            onSubmitted: (_) => _submit(),
          ),
          if (parsed != null) ...[
            const SizedBox(height: 12),
            _Preview(link: parsed),
          ],
          if (subscription is _Fetching) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: ProgressRing(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                SecondaryText('Fetching ${subscription.host}…'),
              ],
            ),
          ],
          if (loaded != null) ...[
            const SizedBox(height: 12),
            _checklist(context, loaded),
            const SizedBox(height: 8),
            SecondaryText(
              '${loaded.host} · ${_summary(loaded.entries)} · '
              '${tooMany ? 'only ${StatusText.count(free, 'slot')} free' : '${loaded.checked.length} of ${StatusText.count(free, 'free slot')}'}',
              color: tooMany ? theme.resources.systemFillColorCritical : null,
            ),
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
        if (subscription == null && _isSubscriptionURL)
          FilledButton(
            onPressed: _error == null ? () => unawaited(_fetch()) : null,
            child: const Text('Fetch'),
          )
        else if (loaded != null)
          FilledButton(
            onPressed: loaded.checked.isEmpty || tooMany
                ? null
                : _commitSubscription,
            child: Text(
              loaded.checked.isEmpty
                  ? 'Add'
                  : 'Add ${StatusText.count(loaded.checked.length, 'tunnel')}',
            ),
          )
        else
          FilledButton(
            onPressed: parsed == null || subscription != null ? null : _commit,
            child: Text(widget.replacing ? 'Replace' : 'Add'),
          ),
      ],
    );
  }
}

/// One server of a fetched subscription: name, kind, server and what
/// defines it, plus the "already added" note.
class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.link, required this.alreadyAdded});

  final ProxyLink link;
  final bool alreadyAdded;

  @override
  Widget build(BuildContext context) {
    final name = link.linkName.isEmpty ? link.server : link.linkName;
    final kind = StatusText.typeBadge(link.tunnelKind);
    final detail = switch (link) {
      ProxyLinkShadowsocks(:final result) => result.meta.method,
      ProxyLinkVLESS(:final result) =>
        result.meta.security.jsonValue.toUpperCase(),
      ProxyLinkTrojan(:final result) =>
        result.meta.security.jsonValue.toUpperCase(),
      ProxyLinkVMess(:final result) =>
        result.meta.tlsSecurity.jsonValue.toUpperCase(),
    };
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        SizedBox(width: 90, child: SecondaryText(kind)),
        Expanded(
          child: Text(
            '${link.server}:${link.port}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        SecondaryText(detail),
        if (alreadyAdded) ...[
          const SizedBox(width: 8),
          const SecondaryText('already added'),
        ],
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
