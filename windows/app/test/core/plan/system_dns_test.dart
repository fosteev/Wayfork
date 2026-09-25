import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/plan/system_dns.dart';

void main() {
  test('gateway resolver is never routed into the TUN', () {
    final home = SystemDnsSnapshot(['192.168.31.1', '8.8.8.8'], '192.168.31.1');
    expect(home.routable(), ['8.8.8.8']);
    expect(home.unroutable(), ['192.168.31.1']);

    final pihole = SystemDnsSnapshot(['192.168.31.5'], '192.168.31.1');
    expect(pihole.routable(), ['192.168.31.5']);
    expect(pihole.unroutable(), isEmpty);

    final offline = SystemDnsSnapshot([], null);
    expect(offline.routable(), isEmpty);
    expect(offline.unroutable(), isEmpty);
  });

  test('override replaces system and manual resolvers', () {
    const tun = '172.19.0.1';
    final dhcp = SystemDnsSnapshot(['192.168.31.1'], '192.168.31.1');
    expect(dhcp.effectiveServers(tun), [tun]);
    expect(dhcp.routable(overrideAddress: tun), [tun]);
    expect(dhcp.unroutable(overrideAddress: tun), isEmpty);
    expect(dhcp.effectiveServers(null), ['192.168.31.1']);

    final manual = SystemDnsSnapshot(
      ['8.8.8.8'],
      '192.168.31.1',
      primaryService: 'wifi',
      manualServers: ['8.8.8.8'],
    );
    expect(manual.effectiveServers(tun), [tun]);
    expect(manual.effectiveServers(null), ['8.8.8.8']);

    final manualGateway = SystemDnsSnapshot(
      ['192.168.31.1'],
      '192.168.31.1',
      manualServers: ['192.168.31.1'],
    );
    expect(manualGateway.routable(overrideAddress: tun), [tun]);
    expect(manualGateway.unroutable(), ['192.168.31.1']);
  });

  test('network resolvers stay separate from effective resolvers', () {
    const tun = '172.19.0.2';
    final on = SystemDnsSnapshot(
      [tun],
      '192.168.31.1',
      manualServers: [tun],
      networkServers: ['192.168.31.1'],
    );
    expect(on.effectiveServers(tun), [tun]);
    expect(on.networkServers, ['192.168.31.1']);
    expect(SystemDnsSnapshot([], null).networkServers, isEmpty);
  });
}
