import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/secrets/secret_store.dart';

import '../app/sample_store.dart';

void main() {
  test('every tunnel kind maps to the secret its plan builder loads', () {
    final cases = <(TunnelKind, SecretKind)>[
      (openVPNTunnel('ovpn', slot: 0).kind, SecretKind.ovpn),
      (vlessTunnel('vless', slot: 1).kind, SecretKind.uuid),
      (
        TunnelKindVMess(
          VMessMeta(
            server: 'vmess.example.net',
            port: 443,
            security: 'auto',
            tlsSecurity: TlsSecurity.tls,
          ),
        ),
        SecretKind.uuid,
      ),
      (
        TunnelKindWireGuard(
          WireGuardMeta(
            addresses: ['10.9.0.2/32'],
            peers: [
              WireGuardPeer(
                host: 'wg.example.net',
                port: 51820,
                publicKey: 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=',
                allowedIPs: ['0.0.0.0/0'],
              ),
            ],
          ),
        ),
        SecretKind.privateKey,
      ),
      (
        TunnelKindShadowsocks(
          ShadowsocksMeta(
            server: 'ss.example.net',
            port: 8388,
            method: 'aes-256-gcm',
          ),
        ),
        SecretKind.password,
      ),
      (
        TunnelKindTrojan(
          TrojanMeta(
            server: 'trojan.example.net',
            port: 443,
            security: TlsSecurity.tls,
          ),
        ),
        SecretKind.password,
      ),
    ];
    for (final (kind, expected) in cases) {
      expect(requiredSecretKind(kind), expected, reason: '$kind');
    }
  });
}
