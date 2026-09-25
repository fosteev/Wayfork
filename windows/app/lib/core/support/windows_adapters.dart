import 'dart:ffi';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:ffi/ffi.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:win32/win32.dart';

/// One IPv4 address of an adapter with its on-link prefix length.
final class AdapterAddress {
  const AdapterAddress(this.address, this.prefixLength);

  /// Host-order IPv4 address.
  final int address;
  final int prefixLength;

  IPv4Prefix get prefix => IPv4Prefix(address, prefixLength);

  @override
  bool operator ==(Object other) =>
      other is AdapterAddress &&
      address == other.address &&
      prefixLength == other.prefixLength;

  @override
  int get hashCode => Object.hash(address, prefixLength);
}

/// What the app needs from one `IP_ADAPTER_ADDRESSES` entry (IPv4 only).
final class WindowsAdapter {
  const WindowsAdapter({
    required this.adapterName,
    required this.friendlyName,
    required this.ifIndex,
    required this.ifType,
    required this.isUp,
    required this.ipv4Metric,
    this.addresses = const [],
    this.dnsServers = const [],
    this.gateways = const [],
  });

  /// `IF_TYPE_SOFTWARE_LOOPBACK`.
  static const ifTypeLoopback = 24;

  /// `IF_TYPE_PROP_VIRTUAL` — wintun and dco adapters report this.
  static const ifTypePropVirtual = 53;

  /// `IF_TYPE_TUNNEL`.
  static const ifTypeTunnel = 131;

  /// The adapter GUID, `{…}`, which keys the Tcpip registry entries.
  final String adapterName;

  /// The name shown in Network Connections (`Ethernet`, `Wayfork-1`).
  final String friendlyName;
  final int ifIndex;
  final int ifType;
  final bool isUp;
  final int ipv4Metric;
  final List<AdapterAddress> addresses;

  /// IPv4 resolvers, dotted, in configuration order.
  final List<String> dnsServers;

  /// IPv4 default gateways, dotted.
  final List<String> gateways;

  /// Our own adapters: the sing-box TUN `Wayfork` and the OpenVPN `Wayfork-N`.
  bool get isWayfork =>
      friendlyName == 'Wayfork' || friendlyName.startsWith('Wayfork-');

  bool get isLoopback => ifType == ifTypeLoopback;
  bool get isTunnel => ifType == ifTypeTunnel;

  @override
  bool operator ==(Object other) =>
      other is WindowsAdapter &&
      adapterName == other.adapterName &&
      friendlyName == other.friendlyName &&
      ifIndex == other.ifIndex &&
      ifType == other.ifType &&
      isUp == other.isUp &&
      ipv4Metric == other.ipv4Metric &&
      const ListEquality<AdapterAddress>().equals(addresses, other.addresses) &&
      const ListEquality<String>().equals(dnsServers, other.dnsServers) &&
      const ListEquality<String>().equals(gateways, other.gateways);

  @override
  int get hashCode => Object.hash(
    adapterName,
    friendlyName,
    ifIndex,
    ifType,
    isUp,
    ipv4Metric,
    const ListEquality<AdapterAddress>().hash(addresses),
    const ListEquality<String>().hash(dnsServers),
    const ListEquality<String>().hash(gateways),
  );

  @override
  String toString() =>
      'WindowsAdapter($friendlyName, $adapterName, up: $isUp, type: $ifType, '
      'metric: $ipv4Metric, dns: $dnsServers, gateways: $gateways)';
}

/// How an adapter's resolvers were configured, from the Tcpip registry.
final class AdapterResolverConfig {
  const AdapterResolverConfig({
    this.manualServers = const [],
    this.dhcpServers = const [],
  });

  /// `NameServer`: resolvers entered by hand (empty when DHCP-assigned).
  final List<String> manualServers;

  /// `DhcpNameServer`: what DHCP supplied.
  final List<String> dhcpServers;
}

/// Adapter enumeration through the IP Helper API (`GetAdaptersAddresses`) and
/// the Tcpip interface registry (docs/design/08-windows.md, "Resolver
/// override"). Everything returns empty off Windows so the pure halves can be
/// exercised on any platform.
abstract final class WindowsAdapters {
  static const _tcpipInterfaces =
      r'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces';

  /// Every adapter with its IPv4 addresses, resolvers and gateways; empty when
  /// the lookup fails.
  static List<WindowsAdapter> enumerate() {
    if (!Platform.isWindows) return const [];
    final size = calloc<Uint32>();
    Pointer<IP_ADAPTER_ADDRESSES_LH> buffer = nullptr;
    try {
      size.value = 16 * 1024;
      final flags = GET_ADAPTERS_ADDRESSES_FLAGS(
        GAA_FLAG_SKIP_ANYCAST |
            GAA_FLAG_SKIP_MULTICAST |
            GAA_FLAG_INCLUDE_GATEWAYS,
      );
      for (var attempt = 0; attempt < 4; attempt++) {
        if (buffer != nullptr) calloc.free(buffer);
        buffer = calloc<Uint8>(size.value).cast();
        final result = GetAdaptersAddresses(AF_INET, flags, buffer, size);
        if (result == ERROR_BUFFER_OVERFLOW) continue;
        if (result != 0) return const [];
        return _walk(buffer);
      }
      return const [];
    } finally {
      if (buffer != nullptr) calloc.free(buffer);
      calloc.free(size);
    }
  }

  /// `NameServer` / `DhcpNameServer` of the adapter's Tcpip interface key.
  static AdapterResolverConfig readResolverConfig(String adapterName) {
    if (!Platform.isWindows) return const AdapterResolverConfig();
    final subKey = '$_tcpipInterfaces\\$adapterName';
    return AdapterResolverConfig(
      manualServers: _splitServers(_readString(subKey, 'NameServer')),
      dhcpServers: _splitServers(_readString(subKey, 'DhcpNameServer')),
    );
  }

  static List<WindowsAdapter> _walk(Pointer<IP_ADAPTER_ADDRESSES_LH> first) {
    final adapters = <WindowsAdapter>[];
    var pointer = first;
    while (pointer != nullptr) {
      final entry = pointer.ref;
      final addresses = <AdapterAddress>[];
      var unicast = entry.FirstUnicastAddress;
      while (unicast != nullptr) {
        final address = _ipv4(unicast.ref.Address);
        if (address != null) {
          addresses.add(
            AdapterAddress(address, unicast.ref.OnLinkPrefixLength),
          );
        }
        unicast = unicast.ref.Next;
      }
      final dnsServers = <String>[];
      var dns = entry.FirstDnsServerAddress;
      while (dns != nullptr) {
        final address = _ipv4(dns.ref.Address);
        if (address != null) {
          final dotted = _dotted(address);
          if (!dnsServers.contains(dotted)) dnsServers.add(dotted);
        }
        dns = dns.ref.Next;
      }
      final gateways = <String>[];
      var gateway = entry.FirstGatewayAddress;
      while (gateway != nullptr) {
        final address = _ipv4(gateway.ref.Address);
        if (address != null) {
          final dotted = _dotted(address);
          if (!gateways.contains(dotted)) gateways.add(dotted);
        }
        gateway = gateway.ref.Next;
      }
      adapters.add(
        WindowsAdapter(
          adapterName: entry.AdapterName.toDartString(),
          friendlyName: entry.FriendlyName.toDartString(),
          ifIndex: entry.Anonymous1.Anonymous.IfIndex,
          ifType: entry.IfType,
          isUp: entry.OperStatus == IfOperStatusUp,
          ipv4Metric: entry.Ipv4Metric,
          addresses: addresses,
          dnsServers: dnsServers,
          gateways: gateways,
        ),
      );
      pointer = entry.Next;
    }
    return adapters;
  }

  /// The host-order IPv4 address of a `SOCKET_ADDRESS`, null for other
  /// families.
  static int? _ipv4(SOCKET_ADDRESS socketAddress) {
    final sockaddr = socketAddress.lpSockaddr;
    if (sockaddr == nullptr || socketAddress.iSockaddrLength < 8) return null;
    if (sockaddr.ref.sa_family != AF_INET) return null;
    // sockaddr_in: family(2) port(2) addr(4) — the address is network order.
    final bytes = sockaddr.cast<Uint8>();
    return (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
  }

  static String _dotted(int address) =>
      '${(address >> 24) & 0xFF}.${(address >> 16) & 0xFF}.'
      '${(address >> 8) & 0xFF}.${address & 0xFF}';

  static String? _readString(String subKey, String value) {
    final keyName = subKey.toPcwstr();
    final valueName = value.toPcwstr();
    final size = calloc<Uint32>();
    try {
      var result = RegGetValue(
        HKEY_LOCAL_MACHINE,
        keyName,
        valueName,
        RRF_RT_REG_SZ,
        null,
        null,
        size,
      );
      if (result != 0 || size.value == 0) return null;
      final data = calloc<Uint8>(size.value + 2);
      try {
        result = RegGetValue(
          HKEY_LOCAL_MACHINE,
          keyName,
          valueName,
          RRF_RT_REG_SZ,
          null,
          data,
          size,
        );
        if (result != 0) return null;
        return data.cast<Utf16>().toDartString();
      } finally {
        calloc.free(data);
      }
    } finally {
      calloc.free(size);
      free(valueName);
      free(keyName);
    }
  }

  /// `NameServer` is comma- or space-separated; `DhcpNameServer` space-
  /// separated. IPv4 only, unique, in order.
  static List<String> _splitServers(String? text) {
    if (text == null) return const [];
    final servers = <String>[];
    for (final part in text.split(RegExp(r'[,\s]+'))) {
      if (part.isEmpty) continue;
      final prefix = IPv4Prefix.parse(part);
      if (prefix == null || !prefix.isHost) continue;
      if (!servers.contains(part)) servers.add(part);
    }
    return servers;
  }
}
