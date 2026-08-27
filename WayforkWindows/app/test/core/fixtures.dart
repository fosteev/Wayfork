import 'dart:io';

import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';

abstract final class Fixtures {
  static final Directory root = () {
    final directory = Directory('../../fixtures').absolute;
    if (!directory.existsSync()) {
      throw StateError(
        'Shared fixtures directory does not exist at ${directory.path}; '
        'run tests from WayforkWindows/app.',
      );
    }
    return directory;
  }();

  static String text(String relative) =>
      File('${root.path}/$relative').readAsStringSync();

  static const workID = '00000000-0000-4000-8000-000000000001';
  static const homeID = '00000000-0000-4000-8000-000000000002';
  static final date = DateTime.utc(2026, 8, 25, 12);

  static final work = Tunnel(
    id: workID,
    name: 'Work',
    slot: 0,
    kind: TunnelKindOpenVPN(
      OpenVPNMeta(
        remotes: [
          const Remote(host: 'vpn.example.org', port: 1194, proto: 'udp'),
        ],
        needsCredentials: true,
        needsKeyPassphrase: false,
        discoveredDNS: const ['10.8.0.1'],
        configHash: 'abc',
      ),
    ),
    createdAt: date,
  );

  static final home = Tunnel(
    id: homeID,
    name: 'Home',
    slot: 1,
    kind: TunnelKindVLESS(
      VLESSMeta(
        server: 'home.example.net',
        port: 443,
        flow: 'xtls-rprx-vision',
        security: VLESSSecurity.reality,
        sni: 'www.apple.com',
        fingerprint: 'chrome',
        realityPublicKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
        realityShortID: '0123abcd',
      ),
    ),
    createdAt: date,
  );

  static Store store({List<Rule> rules = const []}) =>
      Store(tunnels: [work, home], rules: rules);
}
