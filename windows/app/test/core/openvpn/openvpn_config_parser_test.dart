import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/export_document.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/openvpn/openvpn_config_parser.dart';
import 'package:wayfork/core/support/hashing.dart';

import '../fixtures.dart';

void main() {
  test('imports full inline profile', () {
    final source = Fixtures.text('ovpn/full-inline.ovpn');
    final expected = Fixtures.text('ovpn/full-inline.expected.ovpn');
    final result = OpenVPNConfigParser.parseWith(source, (_) => null);
    expect(result.sanitizedConfig, expected);
    expect(result.strippedDirectives, [
      'dev',
      'redirect-gateway',
      'dhcp-option',
      'up',
      'script-security',
      'verb',
    ]);
    expect(result.meta.remotes, const [
      Remote(host: 'vpn.example.org', port: 443, proto: 'udp'),
      Remote(host: 'vpn.example.org', port: 8443, proto: 'tcp'),
    ]);
    expect(result.meta.needsCredentials, isTrue);
    expect(result.meta.needsKeyPassphrase, isFalse);
    expect(result.meta.dns, const TunnelDNSAuto());
    expect(result.meta.discoveredDNS, isEmpty);
    expect(result.meta.configHash, Hashing.sha256Hex(expected));
    expect(result.credentials, isNull);
  });

  test('inlines referenced files and reads credentials', () {
    final files = <String, Uint8List>{
      'ca.crt': _data(
        '-----BEGIN CERTIFICATE-----\nPLACEHOLDER\n-----END CERTIFICATE-----\n',
      ),
      'client.key': _data(
        '-----BEGIN PRIVATE KEY-----\nPLACEHOLDER\n-----END PRIVATE KEY-----\n',
      ),
      'ta.key': _data(
        '-----BEGIN OpenVPN Static key V1-----\nPLACEHOLDER\n'
        '-----END OpenVPN Static key V1-----\n',
      ),
      'creds.txt': _data(' alice \n secret \n'),
    };
    const source =
        'remote vpn.example.org\n'
        'ca ca.crt\n'
        'key client.key\n'
        'tls-auth ta.key 1\n'
        'auth-user-pass creds.txt\n';
    final result = OpenVPNConfigParser.parseWith(source, (name) => files[name]);
    expect(
      result.sanitizedConfig,
      'remote vpn.example.org\n'
      '<ca>\n'
      '-----BEGIN CERTIFICATE-----\n'
      'PLACEHOLDER\n'
      '-----END CERTIFICATE-----\n'
      '</ca>\n'
      '<key>\n'
      '-----BEGIN PRIVATE KEY-----\n'
      'PLACEHOLDER\n'
      '-----END PRIVATE KEY-----\n'
      '</key>\n'
      '<tls-auth>\n'
      '-----BEGIN OpenVPN Static key V1-----\n'
      'PLACEHOLDER\n'
      '-----END OpenVPN Static key V1-----\n'
      '</tls-auth>\n'
      'key-direction 1\n'
      'auth-user-pass\n',
    );
    expect(
      result.credentials,
      const Credentials(username: 'alice', password: 'secret'),
    );
    expect(result.meta.needsCredentials, isTrue);
    expect(result.meta.needsKeyPassphrase, isFalse);
  });

  test('resolves files relative to base directory', () {
    final directory = Directory.systemTemp.createTempSync(
      'wayfork-ovpn-parser-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/ca.crt').writeAsStringSync('PLACEHOLDER\n');
    final result = OpenVPNConfigParser.parse(
      'remote vpn.example.org\nca ca.crt\n',
      baseDirectory: directory,
    );
    expect(
      result.sanitizedConfig,
      'remote vpn.example.org\n<ca>\nPLACEHOLDER\n</ca>\n',
    );
  });

  test('existing key direction suppresses generated direction', () {
    const source =
        'remote vpn.example.org\ntls-auth ta.key 1\nkey-direction 0\n';
    final result = OpenVPNConfigParser.parseWith(
      source,
      (name) => name == 'ta.key' ? _data('PLACEHOLDER\n') : null,
    );
    expect(result.sanitizedConfig, isNot(contains('key-direction 1')));
    expect(result.sanitizedConfig, contains('key-direction 0\n'));
  });

  test('reports all missing files', () {
    const source =
        'remote vpn.example.org\n'
        'ca ca.crt\n'
        'key client.key\n'
        'auth-user-pass creds.txt\n'
        'ca ca.crt\n';
    expect(
      () => OpenVPNConfigParser.parseWith(source, (_) => null),
      throwsA(
        const OpenVPNImportException.missingFiles([
          'ca.crt',
          'client.key',
          'creds.txt',
        ]),
      ),
    );
  });

  test('detects encrypted inline key', () {
    const source =
        'remote vpn.example.org\n'
        '<key>\n'
        '-----BEGIN ENCRYPTED PRIVATE KEY-----\n'
        'PLACEHOLDER\n'
        '-----END ENCRYPTED PRIVATE KEY-----\n'
        '</key>\n';
    expect(
      OpenVPNConfigParser.parseWith(
        source,
        (_) => null,
      ).meta.needsKeyPassphrase,
      isTrue,
    );
  });

  test('encodes PKCS12 and uses askpass as passphrase signal', () {
    final bundle = Uint8List.fromList(List.filled(60, 0x41));
    const source = 'remote vpn.example.org\npkcs12 client.p12\naskpass\n';
    final result = OpenVPNConfigParser.parseWith(
      source,
      (name) => name == 'client.p12' ? bundle : null,
    );
    final bodyLines = result.sanitizedConfig.split('\n').skip(2).toList()
      ..removeLast();
    bodyLines.removeLast();
    expect(result.strippedDirectives, ['askpass']);
    expect(result.meta.needsKeyPassphrase, isTrue);
    expect(bodyLines.map((line) => line.length), [64, 16]);
  });

  test('rejects TAP devices and profiles without a remote', () {
    expect(
      () => OpenVPNConfigParser.parseWith(
        'remote vpn.example.org\ndev tap\n',
        (_) => null,
      ),
      throwsA(const OpenVPNImportException.unsupported('dev tap')),
    );
    expect(
      () => OpenVPNConfigParser.parseWith('client\n', (_) => null),
      throwsA(const OpenVPNImportException.noRemote()),
    );
  });

  test('rejects unterminated blocks and unbalanced quotes', () {
    expect(
      () => OpenVPNConfigParser.parseWith(
        'remote vpn.example.org\n<ca>\nPLACEHOLDER\n',
        (_) => null,
      ),
      throwsA(
        const OpenVPNImportException.malformed(
          2,
          'unterminated inline block <ca>',
        ),
      ),
    );
    expect(
      () => OpenVPNConfigParser.parseWith(
        'remote "vpn.example.org\n',
        (_) => null,
      ),
      throwsA(const OpenVPNImportException.malformed(1, 'unbalanced quotes')),
    );
  });

  test('processes connection blocks', () {
    const source =
        'proto tcp4-client\n'
        '<connection>\n'
        '  remote vpn.example.org 443\n'
        '  route 10.0.0.1\n'
        '  management-hold\n'
        '</connection>\n'
        'remote vpn.example.org\n';
    final result = OpenVPNConfigParser.parseWith(source, (_) => null);
    expect(
      result.sanitizedConfig,
      'proto tcp4-client\n'
      '<connection>\n'
      'remote vpn.example.org 443\n'
      '</connection>\n'
      'remote vpn.example.org\n',
    );
    expect(result.strippedDirectives, ['route', 'management-hold']);
    expect(result.meta.remotes, const [
      Remote(host: 'vpn.example.org', port: 443, proto: 'tcp'),
      Remote(host: 'vpn.example.org', port: 1194, proto: 'tcp'),
    ]);
  });

  test('sanitized profile is stable on round trip', () {
    final imported = OpenVPNConfigParser.parseWith(
      Fixtures.text('ovpn/full-inline.ovpn'),
      (_) => null,
    );
    final reparsed = OpenVPNConfigParser.parseWith(
      imported.sanitizedConfig,
      (_) => null,
    );
    expect(reparsed.sanitizedConfig, imported.sanitizedConfig);
  });

  test('strips compression and Windows-only directives', () {
    const source =
        'remote vpn.example.org\n'
        'comp-lzo no\n'
        'compress lz4-v2\n'
        'windows-driver wintun\n'
        'ip-win32 dynamic\n';
    final result = OpenVPNConfigParser.parseWith(source, (_) => null);
    expect(result.sanitizedConfig, 'remote vpn.example.org\n');
    expect(result.strippedDirectives, [
      'comp-lzo',
      'compress',
      'windows-driver',
      'ip-win32',
    ]);
  });
}

Uint8List _data(String value) => Uint8List.fromList(utf8.encode(value));
