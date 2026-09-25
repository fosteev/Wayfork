import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/diagnostics/diagnostics_sanitizer.dart';

void main() {
  test('sanitizes store and sing-box documents', () {
    const input = r'''
{
  "tunnels": [
    {"id": "00000000-0000-4000-8000-000000000001",
     "kind": {"openVPN": {"remotes": [{"host": "example.com"}]}},
     "secrets": {"ovpn": "config", "password": "secret"}},
    {"kind": {"vless": {"server": "example.com", "realityPublicKey": "key"}},
     "uuid": "00000000-0000-4000-8000-000000000001"}
  ],
  "rules": [{"id": "rule-id", "tunnelID": "00000000-0000-4000-8000-000000000001"}],
  "outbounds": [{"server": "example.com", "tls": {
    "server_name": "example.com", "reality": {"public_key": "key", "short_id": "id"}},
    "transport": {"headers": {"Host": "secondary.example.com"}}}],
  "route": {"rules": [{"process_path": "/Users/developer/Applications/Browser.app"}]},
  "dns": {"servers": [{"server": "10.8.0.1"}, {"server": "172.16.0.1"},
    {"server": "192.168.1.1"}, {"server": "127.0.0.1"},
    {"server": "100.64.0.1"}, {"server": "fc00::1"}, {"server": "::1"}]},
  "certificate": "prefix -----BEGIN CERTIFICATE----- suffix"
}
''';

    final json = _object(DiagnosticsSanitizer.sanitizeJSON(input));
    final tunnels = json['tunnels']! as List<Object?>;
    final firstTunnel = tunnels[0]! as Map<String, Object?>;
    final secondTunnel = tunnels[1]! as Map<String, Object?>;
    final openVPN =
        ((firstTunnel['kind']! as Map<String, Object?>)['openVPN']!
            as Map<String, Object?>);
    final remote =
        (openVPN['remotes']! as List<Object?>)[0]! as Map<String, Object?>;
    final vless =
        ((secondTunnel['kind']! as Map<String, Object?>)['vless']!
            as Map<String, Object?>);
    final outbound =
        (json['outbounds']! as List<Object?>)[0]! as Map<String, Object?>;
    final tls = outbound['tls']! as Map<String, Object?>;
    final reality = tls['reality']! as Map<String, Object?>;
    final transport = outbound['transport']! as Map<String, Object?>;
    final headers = transport['headers']! as Map<String, Object?>;
    final route = json['route']! as Map<String, Object?>;
    final routeRule =
        (route['rules']! as List<Object?>)[0]! as Map<String, Object?>;
    final dns = json['dns']! as Map<String, Object?>;
    final dnsServers = dns['servers']! as List<Object?>;
    final rules = json['rules']! as List<Object?>;

    expect(remote['host'], 'server-1');
    expect(vless['server'], 'server-1');
    expect(outbound['server'], 'server-1');
    expect(tls['server_name'], 'server-1');
    expect(headers['Host'], 'server-2');
    expect(firstTunnel['secrets'], '<redacted>');
    expect(secondTunnel['uuid'], '<redacted>');
    expect(vless['realityPublicKey'], '<redacted>');
    expect(reality['public_key'], '<redacted>');
    expect(reality['short_id'], '<redacted>');
    expect(firstTunnel['id'], '00000000-0000-4000-8000-000000000001');
    final firstRule = rules[0]! as Map<String, Object?>;
    expect(firstRule['id'], 'rule-id');
    expect(firstRule['tunnelID'], '00000000-0000-4000-8000-000000000001');
    expect(routeRule['process_path'], '~/Applications/Browser.app');
    expect(
      dnsServers
          .map((item) => (item! as Map<String, Object?>)['server'])
          .toList(),
      [
        '10.8.0.1',
        '172.16.0.1',
        '192.168.1.1',
        '127.0.0.1',
        '100.64.0.1',
        'fc00::1',
        '::1',
      ],
    );
    expect(json['certificate'], '<redacted>');
  });

  test('optionally keeps addresses but always redacts secrets', () {
    const input =
        '{"server":"example.com","sni":"example.com","password":"secret"}';
    final json = _object(
      DiagnosticsSanitizer.sanitizeJSON(
        input,
        options: const SanitizerOptions(includeServerAddresses: true),
      ),
    );
    expect(json['server'], 'example.com');
    expect(json['sni'], 'example.com');
    expect(json['password'], '<redacted>');
  });

  test('output formatting, scalar input, and invalid input', () {
    expect(
      DiagnosticsSanitizer.sanitizeJSON('{"z":"/tmp/file","a":true}'),
      '{\n  "a" : true,\n  "z" : "/tmp/file"\n}',
    );
    expect(DiagnosticsSanitizer.sanitizeJSON('42'), '42');
    expect(
      () => DiagnosticsSanitizer.sanitizeJSON('not JSON'),
      throwsFormatException,
    );
  });

  test('abbreviates Windows user paths', () {
    final json = _object(
      DiagnosticsSanitizer.sanitizeJSON(
        r'{"a":"C:\\Users\\developer\\App.exe",'
        r'"b":"d:/uSeRs/name/rest/file.txt",'
        r'"c":"C:\\Users\\name","d":"C:\\Users\\\\file"}',
      ),
    );
    expect(json['a'], r'~\App.exe');
    expect(json['b'], r'~\rest\file.txt');
    expect(json['c'], r'C:\Users\name');
    expect(json['d'], r'C:\Users\\file');
  });

  test('secret subtrees do not consume server placeholder numbers', () {
    final json = _object(
      DiagnosticsSanitizer.sanitizeJSON(
        '{"secrets":{"server":"hidden.example"},'
        '"server":"visible.example"}',
      ),
    );
    expect(json['secrets'], '<redacted>');
    expect(json['server'], 'server-1');
  });
}

Map<String, Object?> _object(String text) =>
    jsonDecode(text)! as Map<String, Object?>;
