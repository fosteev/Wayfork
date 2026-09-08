import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/wireguard/wireguard_conf_parser.dart';

import '../fixtures.dart';

const _accepted = ['basic', 'split', 'preshared', 'two-peers'];

void main() {
  test('parses the recorded WireGuard configs exactly as Swift does', () {
    for (final name in _accepted) {
      final parsed = WireGuardConfParser.parse(
        Fixtures.text('wireguard/$name.conf'),
      );
      final expected =
          jsonDecode(Fixtures.text('wireguard/$name.expected.json'))
              as Map<String, Object?>;
      expect(
        parsed.toJson(),
        expected,
        reason: '$name differs from the record',
      );
    }
  });

  test('rejects the recorded invalid configs with the recorded reasons', () {
    final rejected =
        jsonDecode(Fixtures.text('wireguard/rejected.json'))
            as Map<String, Object?>;
    for (final entry in rejected.entries) {
      final record = entry.value as Map<String, Object?>;
      final expected = WireGuardImportException(
        record['case'] == 'unsupported'
            ? WireGuardImportError.unsupported
            : WireGuardImportError.invalid,
        record['message'] as String,
      );
      expect(
        () => WireGuardConfParser.parse(
          Fixtures.text('wireguard/${entry.key}.conf'),
        ),
        throwsA(expected),
        reason: entry.key,
      );
    }
  });

  test('strips comments, lowercases keys and normalizes a bare address', () {
    final parsed = WireGuardConfParser.parse('''
[INTERFACE] # comment
PRIVATEKEY = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8= ; comment
ADDRESS = 10.1.0.2
[peer]
publickey = ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=
endpoint = comments.example.net:51820 ; comment
allowedips = 10.0.0.5, ::/0 # IPv6 is dropped, the bare IPv4 becomes /32
''');
    expect(parsed.meta.addresses, ['10.1.0.2/32']);
    expect(parsed.meta.peers.single.host, 'comments.example.net');
    expect(parsed.meta.peers.single.allowedIPs, ['10.0.0.5/32']);
  });
}
