import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/vless/vless_uri_parser.dart';

import '../fixtures.dart';

const vlessUUID = '00000000-0000-4000-8000-000000000001';

void main() {
  test('parses supported VLESS links', () {
    final reality = VLESSURIParser.parse(
      'vless://${vlessUUID.toUpperCase()}@example.com:443?encryption=none&'
      'flow=xtls-rprx-vision&security=reality&sni=example.com&fp=chrome&'
      'pbk=public-key&sid=short-id&type=tcp#Reality',
    );
    expect(reality.uuid, vlessUUID);
    expect(reality.name, 'Reality');
    expect(reality.meta.flow, 'xtls-rprx-vision');
    expect(reality.meta.security, VLESSSecurity.reality);
    expect(reality.meta.realityPublicKey, 'public-key');

    final ws = VLESSURIParser.parse(
      'vless://$vlessUUID@example.com:8443?security=tls&type=ws&'
      'path=%2Fsocket%3Fx%3D1&host=example.com&alpn=h2%2C%20http%2F1.1&'
      'allowInsecure=true#%20Web%20Socket%20',
    );
    expect(ws.name, 'Web Socket');
    expect(ws.meta.sni, 'example.com');
    expect(ws.meta.alpn, ['h2', 'http/1.1']);
    expect(
      ws.meta.transport,
      const VLESSTransportWS(path: '/socket?x=1', host: 'example.com'),
    );
    expect(ws.meta.allowInsecure, isTrue);

    final grpc = VLESSURIParser.parse(
      'vless://$vlessUUID@example.com:443?security=tls&type=grpc&'
      'serviceName=wayfork&insecure=1#gRPC',
    );
    expect(
      grpc.meta.transport,
      const VLESSTransportGRPC(serviceName: 'wayfork'),
    );
    expect(grpc.meta.sni, 'example.com');
    expect(grpc.meta.allowInsecure, isTrue);

    final plain = VLESSURIParser.parse(
      'VLESS://$vlessUUID@example.com:80?fp=first&fp=last#A+B',
    );
    expect(plain.meta.security, VLESSSecurity.none);
    expect(plain.meta.sni, isNull);
    expect(plain.meta.fingerprint, 'last');
    expect(plain.name, 'A+B');

    final ipv6 = VLESSURIParser.parse(
      'vless://$vlessUUID@[2001:db8::1]:443?security=tls#IPv6',
    );
    expect(ipv6.meta.server, '2001:db8::1');
    expect(ipv6.meta.sni, '2001:db8::1');
  });

  test('rejects unsupported transports', () {
    for (final transport in [
      'kcp',
      'http',
      'h2',
      'httpupgrade',
      'xhttp',
      'quic',
      'splithttp',
      'other',
    ]) {
      expect(
        () => VLESSURIParser.parse(
          'vless://$vlessUUID@example.com:443?type=$transport',
        ),
        throwsA(
          VLESSImportException(
            VLESSImportError.unsupported,
            'Transport "$transport" is not supported yet.',
          ),
        ),
      );
    }
  });

  test('rejects invalid options', () {
    _expectError(
      'vless://$vlessUUID@example.com:443?encryption=aes',
      VLESSImportError.invalid,
      'encryption must be none',
    );
    _expectError(
      'vless://$vlessUUID@example.com:443?security=unknown',
      VLESSImportError.invalid,
      'security must be none, tls, or reality',
    );
    _expectError(
      'vless://$vlessUUID@example.com:443?security=tls&flow=legacy',
      VLESSImportError.unsupported,
      'Flow "legacy" is not supported yet.',
    );
    _expectError(
      'vless://$vlessUUID@example.com:443?flow=xtls-rprx-vision',
      VLESSImportError.invalid,
      'flow requires TLS/REALITY over TCP',
    );
    _expectError(
      'vless://$vlessUUID@example.com:443?security=tls&type=ws&'
          'flow=xtls-rprx-vision',
      VLESSImportError.invalid,
      'flow requires TLS/REALITY over TCP',
    );
    _expectError(
      'vless://$vlessUUID@example.com:443?security=reality',
      VLESSImportError.invalid,
      'REALITY requires pbk',
    );
    _expectError(
      'vless://$vlessUUID@example.com:443?security=reality&pbk=public-key&'
          'type=grpc',
      VLESSImportError.unsupported,
      'REALITY over ws/grpc is not supported',
    );
    _expectError(
      'vless://$vlessUUID@example.com:443?headerType=http',
      VLESSImportError.unsupported,
      'headerType "http" is not supported yet.',
    );
  });

  test('fixture links parse as recorded', () {
    final document =
        jsonDecode(Fixtures.text('vless/links.json')) as Map<String, Object?>;
    final accepted = document['accepted']! as List<Object?>;
    expect(accepted, isNotEmpty);
    for (final item in accepted) {
      final link = item! as Map<String, Object?>;
      final expected = link['expected']! as Map<String, Object?>;
      final parsed = VLESSURIParser.parse(link['uri']! as String);
      expect(parsed.uuid, expected['uuid'], reason: link['name']! as String);
      expect(parsed.name, expected['name'], reason: link['name']! as String);
      expect(
        parsed.meta,
        VLESSMeta.fromJson(expected['meta']! as Map<String, Object?>),
        reason: link['name']! as String,
      );
    }
  });

  test('fixture links are rejected', () {
    final document =
        jsonDecode(Fixtures.text('vless/links.json')) as Map<String, Object?>;
    final rejected = document['rejected']! as List<Object?>;
    expect(rejected, isNotEmpty);
    for (final uri in rejected.cast<String>()) {
      expect(
        () => VLESSURIParser.parse(uri),
        throwsA(isA<VLESSImportException>()),
        reason: uri,
      );
    }
  });

  test('sharing URI round-trips and uses stable order', () {
    final cases = [
      VLESSMeta(server: 'example.com', port: 80, security: VLESSSecurity.none),
      VLESSMeta(
        server: 'example.com',
        port: 443,
        security: VLESSSecurity.tls,
        sni: 'example.com',
        fingerprint: 'chrome',
        alpn: const ['h2', 'http/1.1'],
        transport: const VLESSTransportWS(path: '/socket', host: 'example.com'),
        allowInsecure: true,
      ),
      VLESSMeta(
        server: 'example.com',
        port: 443,
        security: VLESSSecurity.tls,
        sni: 'example.com',
        transport: const VLESSTransportGRPC(serviceName: 'wayfork'),
      ),
      VLESSMeta(
        server: '2001:db8::1',
        port: 443,
        flow: 'xtls-rprx-vision',
        security: VLESSSecurity.reality,
        sni: 'example.com',
        fingerprint: 'chrome',
        realityPublicKey: 'public-key',
        realityShortID: 'short-id',
      ),
    ];
    for (final meta in cases) {
      expect(
        VLESSURIParser.parse(
          VLESSURIParser.uri(meta, vlessUUID, 'Wayfork Test'),
        ),
        VLESSImportResult(uuid: vlessUUID, meta: meta, name: 'Wayfork Test'),
      );
    }
    expect(
      VLESSURIParser.uri(cases[1], '<uuid>', 'A B'),
      'vless://<uuid>@example.com:443?encryption=none&security=tls&'
      'sni=example.com&fp=chrome&alpn=h2%2Chttp%2F1.1&type=ws&'
      'path=%2Fsocket&host=example.com&allowInsecure=1#A%20B',
    );
  });

  test('fragment falls back and name is truncated', () {
    final fallback = VLESSURIParser.parse(
      'vless://$vlessUUID@example.com:443#%20',
    );
    expect(fallback.name, 'example.com');
    final longName = List.filled(41, 'é').join();
    final result = VLESSURIParser.parse(
      VLESSURIParser.uri(
        VLESSMeta(
          server: 'example.com',
          port: 443,
          security: VLESSSecurity.none,
        ),
        vlessUUID,
        longName,
      ),
    );
    expect(result.name, List.filled(40, 'é').join());
  });
}

void _expectError(String uri, VLESSImportError kind, String message) {
  expect(
    () => VLESSURIParser.parse(uri),
    throwsA(VLESSImportException(kind, message)),
  );
}
