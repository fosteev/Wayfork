import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/links/proxy_link_parser.dart';
import 'package:wayfork/core/links/subscription_decoder.dart';

import '../fixtures.dart';

String _kind(ProxyLink link) => switch (link) {
  ProxyLinkVLESS() => 'vless',
  ProxyLinkShadowsocks() => 'shadowsocks',
  ProxyLinkTrojan() => 'trojan',
  ProxyLinkVMess() => 'vmess',
};

void main() {
  test('decodes the recorded subscription bodies exactly as Swift does', () {
    final fixture =
        jsonDecode(Fixtures.text('links/subscription.json'))
            as Map<String, Object?>;
    for (final testCase in (fixture['cases']! as List).cast<Map>()) {
      final name = testCase['name'];
      final body = testCase['body']! as String;
      final expected = testCase['expected'] as Map?;
      if (expected == null) {
        final error = testCase['error']! as Map;
        expect(
          () => SubscriptionDecoder.decode(body),
          throwsA(
            ProxyLinkException(
              error['case'] == 'unsupported'
                  ? ProxyLinkError.unsupported
                  : ProxyLinkError.invalid,
              error['message']! as String,
            ),
          ),
          reason: '$name should be refused',
        );
        continue;
      }
      final entries = SubscriptionDecoder.decode(body);
      expect(
        [
          for (final entry in entries.whereType<SubscriptionLink>())
            {
              'line': entry.line,
              'kind': _kind(entry.link),
              'name': entry.link.linkName,
              'server': entry.link.server,
              'port': entry.link.port,
            },
        ],
        expected['links'],
        reason: '$name links differ from the record',
      );
      expect(
        [
          for (final entry in entries.whereType<SubscriptionSkipped>())
            {'line': entry.line, 'reason': entry.reason},
        ],
        expected['skipped'],
        reason: '$name skipped lines differ from the record',
      );
    }
  });

  test('entries keep the original line', () {
    const uri = 'trojan://fake-password@tls.example.net:443#DE';
    final entries = SubscriptionDecoder.decode('  $uri  \n');
    final entry = entries.single as SubscriptionLink;
    expect(entry.line, 1);
    expect(entry.uri, uri);
    expect(entry.link.linkName, 'DE');
  });

  test('recognises a pasted URL', () {
    expect(SubscriptionDecoder.isURL(' https://example.net/sub#Name '), isTrue);
    expect(SubscriptionDecoder.isURL('HTTP://example.net/sub'), isTrue);
    expect(SubscriptionDecoder.isURL('vless://x@example.net:443'), isFalse);
    expect(SubscriptionDecoder.isURL(''), isFalse);
  });
}
