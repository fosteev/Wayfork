import 'package:wayfork/core/support/ipv4_prefix.dart';
import 'package:wayfork/core/support/windows_adapters.dart';

/// One of the machine's own IPv4 networks — the "covers your LAN" check of IP
/// rules (F11).
final class LocalNetwork {
  const LocalNetwork(this.interface, this.prefix);

  /// The adapter's friendly name (`Ethernet`, `Wi-Fi`).
  final String interface;
  final IPv4Prefix prefix;

  /// The networks of every adapter that is up, not loopback, not a tunnel and
  /// not one of Wayfork's own, with a real subnet (no point-to-point /32, no
  /// link-local). Empty when the lookup fails or off Windows.
  static List<LocalNetwork> current() =>
      fromAdapters(WindowsAdapters.enumerate());

  /// The pure half of [current].
  static List<LocalNetwork> fromAdapters(List<WindowsAdapter> adapters) {
    final result = <LocalNetwork>[];
    for (final adapter in adapters) {
      if (!adapter.isUp ||
          adapter.isLoopback ||
          adapter.isTunnel ||
          adapter.isWayfork) {
        continue;
      }
      for (final address in adapter.addresses) {
        final bits = address.prefixLength;
        if (bits <= 0 || bits >= 32) continue;
        if (address.address >> 16 == 0xA9FE) continue; // 169.254.0.0/16
        final network = LocalNetwork(adapter.friendlyName, address.prefix);
        if (!result.contains(network)) result.add(network);
      }
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is LocalNetwork &&
      interface == other.interface &&
      prefix == other.prefix;

  @override
  int get hashCode => Object.hash(interface, prefix);

  @override
  String toString() => '$interface ${prefix.canonical}';
}
