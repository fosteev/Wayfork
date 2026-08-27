import 'package:collection/collection.dart';

/// Pure snapshot logic shared by plan construction and tests.
///
/// Windows adapter enumeration (`GetAdaptersAddresses`) belongs to a later
/// milestone; this file deliberately contains no platform API calls.
final class SystemDnsSnapshot {
  SystemDnsSnapshot(
    List<String> servers,
    this.router, {
    this.primaryService,
    List<String> manualServers = const [],
    List<String> networkServers = const [],
  }) : servers = List.unmodifiable(servers),
       manualServers = List.unmodifiable(manualServers),
       networkServers = List.unmodifiable(networkServers);

  /// IPv4 system resolvers, unique and in configuration order.
  final List<String> servers;

  /// The IPv4 default gateway, if any.
  final String? router;

  final String? primaryService;

  /// Manually entered resolvers. While On, the daemon replaces this entry.
  final List<String> manualServers;

  /// DHCP resolvers untouched by the override and usable by `dns-direct`.
  final List<String> networkServers;

  /// The override alone is effective while enabled; manual entries are
  /// replaced and restored later just like DHCP entries.
  List<String> effectiveServers(String? overrideAddress) =>
      overrideAddress == null ? [...servers] : [overrideAddress];

  /// Effective resolvers that may be routed into the TUN. The gateway is never
  /// carved out because a TUN host route for it breaks every outbound dial.
  List<String> routable({String? overrideAddress}) => effectiveServers(
    overrideAddress,
  ).where((server) => server != router).toList();

  /// Effective resolvers that cannot be routed because they are the gateway.
  List<String> unroutable({String? overrideAddress}) => effectiveServers(
    overrideAddress,
  ).where((server) => server == router).toList();

  @override
  bool operator ==(Object other) =>
      other is SystemDnsSnapshot &&
      const ListEquality<String>().equals(servers, other.servers) &&
      router == other.router &&
      primaryService == other.primaryService &&
      const ListEquality<String>().equals(manualServers, other.manualServers) &&
      const ListEquality<String>().equals(networkServers, other.networkServers);

  @override
  int get hashCode => Object.hash(
    const ListEquality<String>().hash(servers),
    router,
    primaryService,
    const ListEquality<String>().hash(manualServers),
    const ListEquality<String>().hash(networkServers),
  );
}
