import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/ui/add_link_dialog.dart';
import 'package:wayfork/core/links/proxy_link_parser.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';

const _vless =
    'vless://00000000-0000-4000-8000-000000000041@nl.example.net:443'
    '?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision'
    '&fp=firefox&sni=www.example.com&sid=&pbk=public-key#NL';
const _trojan = 'trojan://fake-password@tls.example.net:443#DE';
const _body = '$_vless\nhysteria2://x@hy.example.net:443#HY\n$_trojan\n';

/// Opens the dialog over an empty page; [opened] receives the future of what
/// it is closed with.
Future<void> _open(
  WidgetTester tester, {
  Store? store,
  required Future<String> Function(Uri url) fetch,
  required void Function(Future<AddLinkOutcome?> outcome) opened,
}) async {
  await tester.pumpWidget(
    FluentApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Button(
          onPressed: () =>
              opened(showAddLinkDialog(context, store: store, fetch: fetch)),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a subscription URL is fetched into a checklist', (tester) async {
    final requested = <Uri>[];
    late Future<AddLinkOutcome?> outcome;
    await _open(
      tester,
      fetch: (url) async {
        requested.add(url);
        return _body;
      },
      opened: (future) => outcome = future,
    );

    await tester.enterText(find.byType(TextBox), 'https://sub.example.net/x');
    await tester.pumpAndSettle();
    expect(requested, isEmpty, reason: 'nothing is fetched while typing');
    expect(find.text('Fetch'), findsOneWidget);

    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(requested.single.host, 'sub.example.net');
    expect(
      find.text('sub.example.net · 2 servers, 1 skipped · 2 of 32 free slots'),
      findsOneWidget,
    );
    expect(find.text('unsupported scheme hysteria2://'), findsOneWidget);
    expect(find.text('Add 2 tunnels'), findsOneWidget);

    await tester.tap(find.text('NL'));
    await tester.pumpAndSettle();
    expect(find.text('Add 1 tunnel'), findsOneWidget);
    await tester.tap(find.text('Add 1 tunnel'));
    await tester.pumpAndSettle();

    final result = await outcome as AddLinkSubscription;
    expect(result.host, 'sub.example.net');
    expect(result.links.single, isA<ProxyLinkTrojan>());
  });

  testWidgets('servers already in the store start unchecked', (tester) async {
    final existing = ProxyLinkParser.parse(_vless) as ProxyLinkVLESS;
    final store = Store(
      tunnels: [
        Tunnel(
          name: 'NL',
          slot: 0,
          kind: TunnelKindVLESS(existing.result.meta),
        ),
      ],
    );
    await _open(
      tester,
      store: store,
      fetch: (_) async => _body,
      opened: (_) {},
    );
    await tester.enterText(find.byType(TextBox), 'https://sub.example.net/x');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(find.text('already added'), findsOneWidget);
    expect(find.text('Add 1 tunnel'), findsOneWidget);
  });

  testWidgets('fetch errors and plain http are shown inline', (tester) async {
    await _open(
      tester,
      fetch: (_) async => throw const ProxyLinkException(
        ProxyLinkError.invalid,
        'server answered 404',
      ),
      opened: (_) {},
    );
    await tester.enterText(find.byType(TextBox), 'http://sub.example.net/x');
    await tester.pumpAndSettle();
    expect(find.text('Subscriptions must use https.'), findsOneWidget);

    await tester.enterText(find.byType(TextBox), 'https://sub.example.net/x');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(
      find.text('Cannot load the subscription: server answered 404'),
      findsOneWidget,
    );
    expect(
      find.text('Fetch'),
      findsOneWidget,
      reason: 'the URL can be retried',
    );
  });

  testWidgets('replace mode refuses a subscription URL', (tester) async {
    late Future<ProxyLink?> outcome;
    await tester.pumpWidget(
      FluentApp(
        home: Builder(
          builder: (context) => Button(
            onPressed: () => outcome = showReplaceLinkDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox), 'https://sub.example.net/x');
    await tester.pumpAndSettle();
    expect(
      find.text('Paste a single link; subscriptions add new tunnels.'),
      findsOneWidget,
    );
    expect(find.text('Fetch'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await outcome, isNull);
  });
}
