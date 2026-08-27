abstract final class SingBoxConstants {
  static const tunHostAddress = '172.19.0.1';
  static const tunAddress = '$tunHostAddress/30';

  /// The system resolver while On: the other address of the TUN's /30. A
  /// neighbour address reaches the TUN, unlike its own interface address.
  static const resolverAddress = '172.19.0.2';

  /// A predefined, TTL-zero answer used to prove the system resolver reaches
  /// the TUN after the DNS override is installed.
  static const resolverProbeName = 'probe.wayfork.internal';

  static const fakeIPv4Range = '198.18.0.0/15';

  /// LAN, CGNAT, link-local and multicast ranges kept out of the TUN.
  static const lanRanges = [
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '100.64.0.0/10',
    '169.254.0.0/16',
    '224.0.0.0/4',
  ];

  /// Resolver for automatic OpenVPN DNS before the server pushes one.
  static const fallbackTunnelDNS = '1.1.1.1';

  /// DoT resolver used when the default tunnel is VLESS.
  static const defaultTunnelDoTServer = '1.1.1.1';

  /// The DDR special-use name mDNSResponder queries to upgrade to DoH/DoT.
  static const ddrDiscoveryName = '_dns.resolver.arpa';
}
