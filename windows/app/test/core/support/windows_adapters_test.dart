import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/plan/system_dns.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/local_networks.dart';
import 'package:wayfork/core/support/windows_adapters.dart';

int ip(String dotted) => IPv4Prefix.parse(dotted)!.address;

const ethernet = WindowsAdapter(
  adapterName: '{11111111-1111-1111-1111-111111111111}',
  friendlyName: 'Ethernet',
  ifIndex: 5,
  ifType: 6,
  isUp: true,
  ipv4Metric: 25,
  addresses: [AdapterAddress(0xC0A81FCB, 24)], // 192.168.31.203/24
  dnsServers: ['192.168.31.1', '1.1.1.1'],
  gateways: ['192.168.31.1'],
);

const wifi = WindowsAdapter(
  adapterName: '{22222222-2222-2222-2222-222222222222}',
  friendlyName: 'Wi-Fi',
  ifIndex: 7,
  ifType: 71,
  isUp: true,
  ipv4Metric: 35,
  addresses: [AdapterAddress(0x0A000105, 16), AdapterAddress(0xA9FE0102, 16)],
  dnsServers: ['10.0.0.1'],
  gateways: ['10.0.0.1'],
);

const tun = WindowsAdapter(
  adapterName: '{33333333-3333-3333-3333-333333333333}',
  friendlyName: 'Wayfork',
  ifIndex: 9,
  ifType: WindowsAdapter.ifTypePropVirtual,
  isUp: true,
  ipv4Metric: 0,
  addresses: [AdapterAddress(0xAC130001, 30)],
  dnsServers: ['172.19.0.2'],
  gateways: [],
);

const dco = WindowsAdapter(
  adapterName: '{44444444-4444-4444-4444-444444444444}',
  friendlyName: 'Wayfork-2',
  ifIndex: 11,
  ifType: WindowsAdapter.ifTypePropVirtual,
  isUp: true,
  ipv4Metric: 25,
  addresses: [AdapterAddress(0x0A080006, 24)],
  dnsServers: ['10.8.0.1'],
  gateways: ['10.8.0.1'],
);

const loopback = WindowsAdapter(
  adapterName: '{55555555-5555-5555-5555-555555555555}',
  friendlyName: 'Loopback Pseudo-Interface 1',
  ifIndex: 1,
  ifType: WindowsAdapter.ifTypeLoopback,
  isUp: true,
  ipv4Metric: 75,
  addresses: [AdapterAddress(0x7F000001, 8)],
);

const disconnected = WindowsAdapter(
  adapterName: '{66666666-6666-6666-6666-666666666666}',
  friendlyName: 'Ethernet 2',
  ifIndex: 13,
  ifType: 6,
  isUp: false,
  ipv4Metric: 25,
  addresses: [AdapterAddress(0xC0A80105, 24)],
  gateways: ['192.168.1.1'],
);

void main() {
  test('local networks skip loopback, link-local, host routes and Wayfork', () {
    final networks = LocalNetwork.fromAdapters(const [
      ethernet,
      wifi,
      tun,
      dco,
      loopback,
      disconnected,
      WindowsAdapter(
        adapterName: '{7}',
        friendlyName: 'PPP',
        ifIndex: 15,
        ifType: 23,
        isUp: true,
        ipv4Metric: 50,
        addresses: [AdapterAddress(0x0A0A0A0A, 32)],
      ),
      // The same subnet twice is reported once.
      WindowsAdapter(
        adapterName: '{8}',
        friendlyName: 'Ethernet',
        ifIndex: 5,
        ifType: 6,
        isUp: true,
        ipv4Metric: 25,
        addresses: [AdapterAddress(0xC0A81F05, 24)],
      ),
    ]);
    expect(networks, [
      LocalNetwork('Ethernet', IPv4Prefix.parse('192.168.31.0/24')!),
      LocalNetwork('Wi-Fi', IPv4Prefix.parse('10.0.0.0/16')!),
    ]);
    expect(networks.first.toString(), 'Ethernet 192.168.31.0/24');
  });

  test('the primary adapter is the physical one with the lowest metric', () {
    expect(
      SystemDns.primaryAdapter(const [tun, dco, wifi, ethernet, disconnected]),
      ethernet,
    );
    expect(SystemDns.primaryAdapter(const [tun, dco, loopback]), isNull);
    expect(SystemDns.primaryAdapter(const [wifi, disconnected]), wifi);
  });

  test('snapshot follows the primary adapter and its DHCP/manual split', () {
    final dhcp = SystemDns.fromAdapters(
      const [tun, dco, wifi, ethernet],
      resolverConfig: (name) {
        expect(name, ethernet.adapterName);
        return const AdapterResolverConfig(
          dhcpServers: ['192.168.31.1', '1.1.1.1'],
        );
      },
    );
    expect(dhcp.servers, ['192.168.31.1', '1.1.1.1']);
    expect(dhcp.router, '192.168.31.1');
    expect(dhcp.primaryService, 'Ethernet');
    expect(dhcp.manualServers, isEmpty);
    expect(dhcp.networkServers, ['192.168.31.1', '1.1.1.1']);
    expect(dhcp.routable(), ['1.1.1.1']);
    expect(dhcp.unroutable(), ['192.168.31.1']);

    final manual = SystemDns.fromAdapters(
      const [ethernet],
      resolverConfig: (_) => const AdapterResolverConfig(
        manualServers: ['1.1.1.1', '9.9.9.9'],
        dhcpServers: ['192.168.31.1'],
      ),
    );
    expect(manual.manualServers, ['1.1.1.1']);
    expect(manual.networkServers, isEmpty);

    final none = SystemDns.fromAdapters(const [tun, dco, loopback]);
    expect(none.servers, isEmpty);
    expect(none.router, isNull);
    expect(none.primaryService, isNull);

    // A registry key that cannot exist has no resolvers on either platform.
    expect(WindowsAdapters.readResolverConfig('{x}').manualServers, isEmpty);
    expect(WindowsAdapters.readResolverConfig('{x}').dhcpServers, isEmpty);
    if (Platform.isWindows) {
      // On Windows the live lookups reach Win32; a CI runner always has at
      // least the loopback adapter, and none of them may throw.
      expect(WindowsAdapters.enumerate(), isNotEmpty);
      LocalNetwork.current();
      SystemDns.snapshot();
    } else {
      // Elsewhere they return nothing rather than failing.
      expect(WindowsAdapters.enumerate(), isEmpty);
      expect(LocalNetwork.current(), isEmpty);
      expect(SystemDns.snapshot().servers, isEmpty);
    }
  });
}
