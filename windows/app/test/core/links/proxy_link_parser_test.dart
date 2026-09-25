import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/links/proxy_link_parser.dart';

import '../fixtures.dart';

/// The parsed link as the fixture records it: whatever the kind's result
/// encodes, so the file is comparable with the Swift one field for field.
Map<String, Object?> _json(ProxyLink link) => switch (link) {
  ProxyLinkVLESS(:final result) => {
    'uuid': result.uuid,
    'meta': result.meta.toJson(),
    'name': result.name,
  },
  ProxyLinkShadowsocks(:final result) => result.toJson(),
  ProxyLinkTrojan(:final result) => result.toJson(),
  ProxyLinkVMess(:final result) => result.toJson(),
};

void main() {
  for (final scheme in ['ss', 'trojan', 'vmess']) {
    test('parses the recorded $scheme links exactly as Swift does', () {
      final fixture =
          jsonDecode(Fixtures.text('links/$scheme.json'))
              as Map<String, Object?>;
      for (final entry in (fixture['accepted']! as List).cast<Map>()) {
        final parsed = ProxyLinkParser.parse(entry['uri']! as String);
        expect(
          _json(parsed),
          entry['expected'],
          reason: '${entry['name']} differs from the record',
        );
      }
    });

    test('rejects the recorded $scheme links with the recorded reasons', () {
      final fixture =
          jsonDecode(Fixtures.text('links/$scheme.json'))
              as Map<String, Object?>;
      for (final entry in (fixture['rejected']! as List).cast<Map>()) {
        final error = entry['error']! as Map;
        expect(
          () => ProxyLinkParser.parse(entry['uri']! as String),
          throwsA(
            ProxyLinkException(
              error['case'] == 'unsupported'
                  ? ProxyLinkError.unsupported
                  : ProxyLinkError.invalid,
              error['message']! as String,
            ),
          ),
          reason: entry['name']! as String,
        );
      }
    });
  }

  test('rebuilt links parse back to the same result', () {
    // Copy in the UI hands out a rebuilt link, so a link that survives a round
    // trip is the whole contract; the fixtures' own text is hand-written and
    // may order the query differently, so compare parses, not strings.
    for (final scheme in ['ss', 'trojan', 'vmess']) {
      final fixture =
          jsonDecode(Fixtures.text('links/$scheme.json'))
              as Map<String, Object?>;
      for (final entry in (fixture['accepted']! as List).cast<Map>()) {
        final parsed = ProxyLinkParser.parse(entry['uri']! as String);
        final rebuilt = switch (parsed) {
          ProxyLinkShadowsocks(:final result) => ProxyLinkParser.shadowsocksURI(
            result.meta,
            result.password,
            result.name,
          ),
          ProxyLinkTrojan(:final result) => ProxyLinkParser.trojanURI(
            result.meta,
            result.password,
            result.name,
          ),
          ProxyLinkVMess(:final result) => ProxyLinkParser.vmessURI(
            result.meta,
            result.uuid,
            result.name,
          ),
          ProxyLinkVLESS() => entry['uri']! as String,
        };
        expect(
          ProxyLinkParser.parse(rebuilt),
          parsed,
          reason: '${entry['name']} does not survive a round trip',
        );
      }
    }
  });

  test('dispatches on the scheme and refuses an unknown one', () {
    expect(
      ProxyLinkParser.parse(
        'vless://00000000-0000-4000-8000-000000000001@example.com:443'
        '?encryption=none&security=tls#V',
      ),
      isA<ProxyLinkVLESS>(),
    );
    expect(
      () => ProxyLinkParser.parse('hysteria2://pw@example.com:443'),
      throwsA(
        const ProxyLinkException(
          ProxyLinkError.invalid,
          'unsupported link scheme',
        ),
      ),
    );
  });
}
