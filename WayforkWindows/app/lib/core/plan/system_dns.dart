import 'package:collection/collection.dart';
import 'package:wayfork/core/support/windows_adapters.dart';

/// The system resolvers as the plan builder sees them: the resolvers, default
/// gateway and DHCP/manual split of the *primary* adapter — the one the
/// default route leaves through (the Windows counterpart of
/// `State:/Network/Global/DNS` + `PrimaryService` on macOS).
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

/// Builds [SystemDnsSnapshot] from the adapters (docs/design/08-windows.md,
/// "Resolver override"). The primary adapter is the physical one that is up,
/// has an IPv4 default gateway and the lowest interface metric; Wayfork's own
/// adapters never qualify, so a snapshot taken while On still describes the
/// underlying network. With NRPT the per-adapter resolvers are never rewritten,
/// so `manualServers` are informational and `networkServers` (DHCP) feed
/// `dns-direct` exactly as on macOS.
abstract final class SystemDns {
  /// Empty without a network; IPv6 resolvers are left out (the TUN is
  /// IPv4-only).
  static SystemDnsSnapshot snapshot() => fromAdapters(
    WindowsAdapters.enumerate(),
    resolverConfig: WindowsAdapters.readResolverConfig,
  );

  /// The pure half of [snapshot]; [resolverConfig] reads the Tcpip registry
  /// entries of an adapter by its GUID.
  static SystemDnsSnapshot fromAdapters(
    List<WindowsAdapter> adapters, {
    AdapterResolverConfig Function(String adapterName)? resolverConfig,
  }) {
    final primary = primaryAdapter(adapters);
    if (primary == null) return SystemDnsSnapshot(const [], null);
    final config =
        resolverConfig?.call(primary.adapterName) ??
        const AdapterResolverConfig();
    final servers = primary.dnsServers;
    final manual = config.manualServers.isEmpty
        ? const <String>[]
        : servers.where(config.manualServers.contains).toList();
    // DHCP entries count only while they are in effect: a manual entry
    // replaces them in the adapter's list.
    final network = config.manualServers.isEmpty
        ? servers.where(config.dhcpServers.contains).toList()
        : const <String>[];
    return SystemDnsSnapshot(
      servers,
      primary.gateways.firstOrNull,
      primaryService: primary.friendlyName,
      manualServers: manual,
      networkServers: network,
    );
  }

  /// The adapter carrying the system default route, by lowest interface
  /// metric; null when no physical adapter has a gateway.
  static WindowsAdapter? primaryAdapter(List<WindowsAdapter> adapters) {
    WindowsAdapter? best;
    for (final adapter in adapters) {
      if (!adapter.isUp ||
          adapter.isLoopback ||
          adapter.isTunnel ||
          adapter.isWayfork ||
          adapter.gateways.isEmpty) {
        continue;
      }
      if (best == null || adapter.ipv4Metric < best.ipv4Metric) best = adapter;
    }
    return best;
  }
}
