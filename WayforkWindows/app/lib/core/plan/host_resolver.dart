import 'dart:io';

import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/singbox/constants.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

/// Resolves OpenVPN server names for direct route rules. DNS lookup is
/// blocking below the Dart API, so callers should keep it off latency-sensitive
/// UI paths.
abstract final class HostResolver {
  /// Non-literal remotes of enabled OpenVPN tunnels, lowercase and unique in
  /// store order.
  static List<String> openVPNHosts(Store store) {
    final hosts = <String>[];
    for (final tunnel in store.tunnels.where((tunnel) => tunnel.isEnabled)) {
      final meta = tunnel.kind.openVPN;
      if (meta == null) continue;
      for (final remote in meta.remotes) {
        if (IPv4Prefix.parse(remote.host) != null) continue;
        final host = remote.host.toLowerCase();
        if (host.isNotEmpty && !hosts.contains(host)) hosts.add(host);
      }
    }
    return hosts;
  }

  /// IPv4 addresses per host, sorted and unique. Failed hosts are omitted and
  /// lookup errors never escape.
  static Future<Map<String, List<String>>> resolveIPv4(
    Iterable<String> hosts,
  ) async {
    final result = <String, List<String>>{};
    final fakeRange = IPv4Prefix.parse(SingBoxConstants.fakeIPv4Range)!;
    for (final host in hosts) {
      try {
        final addresses =
            (await InternetAddress.lookup(host, type: InternetAddressType.IPv4))
                .map((address) => address.address)
                .where((address) {
                  final prefix = IPv4Prefix.parse(address);
                  // A lookup while Wayfork is already On may receive Wayfork's
                  // own fake-IP answer, not a usable OpenVPN server address.
                  return prefix != null && !fakeRange.contains(prefix);
                })
                .toSet()
                .toList()
              ..sort();
        if (addresses.isNotEmpty) result[host] = addresses;
      } on Object {
        // Resolution is best-effort; the generator still matches the hostname.
      }
    }
    return result;
  }
}
