import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';

Tunnel openVPNTunnel(
  String name, {
  required int slot,
  bool enabled = true,
  String? id,
}) => Tunnel(
  id: id,
  name: name,
  isEnabled: enabled,
  slot: slot,
  kind: TunnelKindOpenVPN(
    OpenVPNMeta(
      remotes: const [
        Remote(host: 'vpn.example.com', port: 1194, proto: 'udp'),
      ],
      needsCredentials: true,
      needsKeyPassphrase: false,
      configHash: 'abc',
    ),
  ),
);

Tunnel vlessTunnel(
  String name, {
  required int slot,
  bool enabled = true,
  String? id,
}) => Tunnel(
  id: id,
  name: name,
  isEnabled: enabled,
  slot: slot,
  kind: TunnelKindVLESS(
    VLESSMeta(
      server: 'host.example.com',
      port: 443,
      flow: 'xtls-rprx-vision',
      security: VLESSSecurity.reality,
      sni: 'cdn.example.com',
      fingerprint: 'chrome',
    ),
  ),
);

/// The three-tunnel store of the macOS AppLogicTests: Work (OpenVPN), Home
/// (VLESS), Lab (OpenVPN) with six rules, one of them disabled.
final class SampleStore {
  SampleStore._(this.store, this.work, this.home, this.lab);

  factory SampleStore() {
    final work = openVPNTunnel('Work', slot: 0);
    final home = vlessTunnel('Home', slot: 1);
    final lab = openVPNTunnel('Lab', slot: 2);
    final store = Store(
      tunnels: [work, home, lab],
      rules: [
        Rule.tunnel(pattern: 'example.com', tunnelID: work.id),
        Rule.tunnel(
          pattern: 'api.internal.example.com',
          match: RuleMatch.exact,
          tunnelID: work.id,
        ),
        Rule.tunnel(
          pattern: 'old.example.com',
          match: RuleMatch.exact,
          tunnelID: work.id,
          isEnabled: false,
        ),
        Rule.tunnel(
          pattern: '*.cdn.example.com',
          match: RuleMatch.wildcard,
          tunnelID: home.id,
        ),
        Rule.tunnel(pattern: 'news.example.org', tunnelID: home.id),
        Rule.tunnel(pattern: 'docs.example.net', tunnelID: lab.id),
      ],
    );
    return SampleStore._(store, work, home, lab);
  }

  final Store store;
  final Tunnel work;
  final Tunnel home;
  final Tunnel lab;
}
