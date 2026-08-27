import 'ipv4_prefix.dart';

/// One of the machine's own IPv4 networks.
///
/// Enumeration through the Windows IP Helper API is implemented in a later milestone.
final class LocalNetwork {
  const LocalNetwork(this.interface, this.prefix);

  final String interface;
  final IPv4Prefix prefix;

  @override
  bool operator ==(Object other) =>
      other is LocalNetwork &&
      interface == other.interface &&
      prefix == other.prefix;

  @override
  int get hashCode => Object.hash(interface, prefix);
}
