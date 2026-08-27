import 'package:collection/collection.dart';
import 'package:wayfork/core/json_text.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/model/tunnel.dart';
import 'package:wayfork/core/platform.dart';
import 'package:wayfork/core/rules/rule_validator.dart';
import 'package:wayfork/core/singbox/constants.dart';
import 'package:wayfork/core/singbox/rule_set_generator.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

export 'package:wayfork/core/singbox/constants.dart';

/// Everything consumed by the deterministic sing-box generator.
final class SingBoxInput {
  SingBoxInput({
    required this.store,
    required Map<String, String> vlessUUIDs,
    required this.openVPNBinaryPath,
    Map<String, List<String>> resolvedServerAddresses = const {},
    List<String> systemDNSServers = const [],
    List<String> networkResolvers = const [],
    this.platform = WayforkPlatform.windows,
  }) : vlessUUIDs = Map.unmodifiable(
         vlessUUIDs.map((key, value) => MapEntry(key.toLowerCase(), value)),
       ),
       resolvedServerAddresses = Map.unmodifiable(
         resolvedServerAddresses.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       ),
       systemDNSServers = List.unmodifiable(systemDNSServers),
       networkResolvers = List.unmodifiable(networkResolvers);

  factory SingBoxInput.fromJson(
    Map<String, Object?> json, {
    WayforkPlatform platform = WayforkPlatform.windows,
  }) => SingBoxInput(
    store: Store.fromJson(_map(json['store'], 'store')),
    vlessUUIDs: _stringMap(json['vlessUUIDs'], 'vlessUUIDs'),
    openVPNBinaryPath: _string(json, 'openVPNBinaryPath'),
    resolvedServerAddresses: _stringListMap(
      json['resolvedServerAddresses'],
      'resolvedServerAddresses',
    ),
    systemDNSServers: _stringList(json['systemDNSServers'], 'systemDNSServers'),
    networkResolvers: _stringList(json['networkResolvers'], 'networkResolvers'),
    platform: platform,
  );

  final Store store;

  /// VLESS UUID by lowercase tunnel id. Tunnels without one are not routed.
  final Map<String, String> vlessUUIDs;

  /// The executable path is matched so OpenVPN control traffic stays direct.
  final String openVPNBinaryPath;

  /// Resolved OpenVPN server addresses by lowercase host name.
  final Map<String, List<String>> resolvedServerAddresses;

  /// Effective system resolvers that must enter the TUN for DNS hijacking.
  final List<String> systemDNSServers;

  /// DHCP resolvers used explicitly for direct DNS to avoid an override loop.
  final List<String> networkResolvers;

  /// Platform-specific interface names and application path matching.
  final WayforkPlatform platform;

  Map<String, Object?> toJson() => {
    'store': store.toJson(),
    'vlessUUIDs': vlessUUIDs,
    'openVPNBinaryPath': openVPNBinaryPath,
    'resolvedServerAddresses': resolvedServerAddresses,
    'systemDNSServers': systemDNSServers,
    'networkResolvers': networkResolvers,
  };
}

final class SingBoxOutput {
  SingBoxOutput({
    required this.config,
    required Map<String, String> ruleSets,
    required List<Tunnel> routedTunnels,
    required this.defaultTunnel,
  }) : ruleSets = Map.unmodifiable(ruleSets),
       routedTunnels = List.unmodifiable(routedTunnels);

  final String config;
  final Map<String, String> ruleSets;
  final List<Tunnel> routedTunnels;
  final Tunnel? defaultTunnel;

  @override
  bool operator ==(Object other) =>
      other is SingBoxOutput &&
      config == other.config &&
      const MapEquality<String, String>().equals(ruleSets, other.ruleSets) &&
      const ListEquality<Tunnel>().equals(routedTunnels, other.routedTunnels) &&
      defaultTunnel == other.defaultTunnel;

  @override
  int get hashCode => Object.hash(
    config,
    const MapEquality<String, String>().hash(ruleSets),
    const ListEquality<Tunnel>().hash(routedTunnels),
    defaultTunnel,
  );
}

/// Generates `sing-box.json` and rule-set files as a pure, deterministic
/// function of its input.
abstract final class SingBoxConfigGenerator {
  static const tunHostAddress = SingBoxConstants.tunHostAddress;
  static const tunAddress = SingBoxConstants.tunAddress;
  static const resolverAddress = SingBoxConstants.resolverAddress;
  static const resolverProbeName = SingBoxConstants.resolverProbeName;
  static const fakeIPv4Range = SingBoxConstants.fakeIPv4Range;
  static const lanRanges = SingBoxConstants.lanRanges;
  static const fallbackTunnelDNS = SingBoxConstants.fallbackTunnelDNS;
  static const defaultTunnelDoTServer = SingBoxConstants.defaultTunnelDoTServer;
  static const ddrDiscoveryName = SingBoxConstants.ddrDiscoveryName;

  static SingBoxOutput generate(SingBoxInput input) {
    final store = input.store;
    final routed = store.tunnels.where((tunnel) {
      if (!tunnel.isEnabled) return false;
      return switch (tunnel.kind) {
        TunnelKindOpenVPN() => true,
        TunnelKindVLESS() => input.vlessUUIDs.containsKey(tunnel.id),
      };
    }).toList();
    final activeRules = RuleValidator.activeRules(store);
    final exceptions = RuleValidator.activeExceptions(store);
    final wantedDefault = store.effectiveDefaultTunnel;
    final defaultTunnel = wantedDefault == null
        ? null
        : routed.where((tunnel) => tunnel.id == wantedDefault.id).firstOrNull;

    final dnsServers = <Map<String, Object?>>[
      directDNSServer(
        store.settings.directDNS,
        networkResolvers: input.networkResolvers,
      ),
    ];
    final outbounds = <Map<String, Object?>>[
      {'type': 'direct', 'tag': 'direct'},
    ];
    // Direct exceptions come first so they beat tunnel sets and the default.
    final routeRules = <Map<String, Object?>>[
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
    ];
    if (input.systemDNSServers.isNotEmpty) {
      // Refuse cached DDR upgrades before any rule can route them elsewhere.
      routeRules.add({
        'ip_cidr': input.systemDNSServers
            .map((server) => '$server/32')
            .toList(),
        'port': [443, 853],
        'action': 'reject',
      });
    }
    routeRules.add({
      'process_path': [input.openVPNBinaryPath],
      'outbound': 'direct',
    });

    // A process match can miss the first UDP flow, so OpenVPN servers are also
    // forced direct by address and name to prevent tunnel-in-tunnel routing.
    final servers = openVPNServers(
      routed,
      resolved: input.resolvedServerAddresses,
    );
    final serverRule = serverRouteRule(servers);
    if (serverRule != null) routeRules.add(serverRule);
    routeRules.add({
      'rule_set': [RuleSetGenerator.directTag, RuleSetGenerator.directIPTag],
      'outbound': 'direct',
    });
    final ruleSetRefs = <Map<String, Object?>>[
      localRuleSet(
        tag: RuleSetGenerator.directTag,
        path: RuleSetGenerator.directFileName,
      ),
      localRuleSet(
        tag: RuleSetGenerator.directIPTag,
        path: RuleSetGenerator.directIPFileName,
      ),
    ];

    for (final tunnel in routed) {
      switch (tunnel.kind) {
        case TunnelKindOpenVPN(:final meta):
          final dnsTag = 'dns-${tunnel.outboundTag}';
          dnsServers.add({
            'type': 'udp',
            'tag': dnsTag,
            'server': resolverFor(meta),
            'detour': tunnel.outboundTag,
          });
          outbounds.add({
            'type': 'direct',
            'tag': tunnel.outboundTag,
            'bind_interface': input.platform.openVPNInterface(tunnel.slot),
            'domain_resolver': {'server': dnsTag, 'strategy': 'ipv4_only'},
          });
        case TunnelKindVLESS(:final meta):
          outbounds.add(
            vlessOutbound(
              meta,
              tag: tunnel.outboundTag,
              uuid: input.vlessUUIDs[tunnel.id] ?? '',
            ),
          );
      }
      routeRules.add({
        'rule_set': [tunnel.ruleSetTag, tunnel.ipRuleSetTag],
        'outbound': tunnel.outboundTag,
      });
      ruleSetRefs.add(
        localRuleSet(tag: tunnel.ruleSetTag, path: tunnel.ruleSetFileName),
      );
      ruleSetRefs.add(
        localRuleSet(tag: tunnel.ipRuleSetTag, path: tunnel.ipRuleSetFileName),
      );
    }
    routeRules.add({'ip_is_private': true, 'outbound': 'direct'});

    // Tunnel IP rules inside LAN ranges must enter the TUN. Direct IP rules do
    // not need carving because either path is already direct.
    final carved = <IPv4Prefix>[];
    for (final tunnel in routed) {
      for (final rule in activeRules[tunnel.id] ?? const []) {
        if (!rule.isIP) continue;
        final prefix = IPv4Prefix.parse(rule.pattern);
        if (prefix != null) carved.add(prefix);
      }
    }
    // LAN-hosted system resolvers must enter the TUN for hijack-dns. Public
    // resolvers are not excluded, so carving them is a no-op.
    for (final server in input.systemDNSServers) {
      final prefix = IPv4Prefix.parse(server);
      if (prefix?.isHost == true) carved.add(prefix!);
    }

    dnsServers.add({
      'type': 'fakeip',
      'tag': 'fakeip',
      'inet4_range': fakeIPv4Range,
    });
    final dnsRules = <Map<String, Object?>>[
      {
        'domain': [resolverProbeName],
        'action': 'predefined',
        'rcode': 'NOERROR',
        'answer': ['$resolverProbeName. 0 IN A $resolverAddress'],
      },
      {
        'domain': [ddrDiscoveryName],
        'action': 'reject',
      },
      {'rule_set': RuleSetGenerator.directTag, 'server': 'dns-direct'},
    ];
    if (servers.hosts.isNotEmpty) {
      dnsRules.add({'domain': servers.hosts, 'server': 'dns-direct'});
    }
    if (routed.isNotEmpty) {
      dnsRules.add({
        'rule_set': routed.map((tunnel) => tunnel.ruleSetTag).toList(),
        'query_type': ['A', 'AAAA'],
        'server': 'fakeip',
      });
    }

    var dnsFinal = 'dns-direct';
    if (defaultTunnel != null) {
      dnsRules.add({
        'query_type': ['A', 'AAAA'],
        'server': 'fakeip',
      });
      final tag = 'dns-${defaultTunnel.outboundTag}';
      if (!defaultTunnel.kind.isOpenVPN) {
        dnsServers.add({
          'type': 'tls',
          'tag': tag,
          'server': defaultTunnelDoTServer,
          'detour': defaultTunnel.outboundTag,
        });
      }
      dnsFinal = tag;
    }

    final dns = <String, Object?>{
      'servers': dnsServers,
      'rules': dnsRules,
      'final': dnsFinal,
      // The TUN and tunnels are IPv4-only; suppressing AAAA avoids unusable
      // IPv6 answers after the TUN owns the IPv6 default route.
      'strategy': 'ipv4_only',
      'independent_cache': true,
      // Preserve real-answer name mappings for flows with no SNI or Host.
      'reverse_mapping': true,
    };
    final route = <String, Object?>{
      'rules': routeRules,
      'rule_set': ruleSetRefs,
      // A missing default fails closed by construction instead of leaking.
      'final': defaultTunnel?.outboundTag ?? 'direct',
      'auto_detect_interface': true,
      'default_domain_resolver': 'dns-direct',
      'find_process': true,
    };
    final config = <String, Object?>{
      'log': {'level': store.settings.logLevel.singBoxLevel, 'timestamp': true},
      'dns': dns,
      'inbounds': [tunInbound(carving: carved, platform: input.platform)],
      'outbounds': outbounds,
      'route': route,
      'experimental': {
        'cache_file': {
          'enabled': true,
          'path': 'cache.db',
          'store_fakeip': true,
        },
      },
    };

    return SingBoxOutput(
      config: '${JsonText.render(config)}\n',
      ruleSets: RuleSetGenerator.generate(
        tunnels: routed,
        activeRules: activeRules,
        exceptions: exceptions,
        platform: input.platform,
      ),
      routedTunnels: routed,
      defaultTunnel: defaultTunnel,
    );
  }

  /// OpenVPN remotes split into address CIDRs and lowercased hostnames,
  /// unique in store order. Resolved addresses are sorted beside each name.
  static ({List<String> addresses, List<String> hosts}) openVPNServers(
    List<Tunnel> routed, {
    Map<String, List<String>> resolved = const {},
  }) {
    final addresses = <String>[];
    final hosts = <String>[];
    void addAddress(String literal) {
      final prefix = IPv4Prefix.parse(literal);
      if (prefix == null) return;
      final cidr = prefix.toString();
      if (!addresses.contains(cidr)) addresses.add(cidr);
    }

    for (final tunnel in routed) {
      final meta = tunnel.kind.openVPN;
      if (meta == null) continue;
      for (final remote in meta.remotes) {
        if (IPv4Prefix.parse(remote.host) != null) {
          addAddress(remote.host);
          continue;
        }
        final host = remote.host.toLowerCase();
        if (host.isEmpty || hosts.contains(host)) continue;
        hosts.add(host);
        final resolvedAddresses = [...?resolved[host]]..sort();
        for (final address in resolvedAddresses) {
          addAddress(address);
        }
      }
    }
    return (addresses: addresses, hosts: hosts);
  }

  static Map<String, Object?>? serverRouteRule(
    ({List<String> addresses, List<String> hosts}) servers,
  ) {
    final rule = <String, Object?>{
      'outbound': 'direct',
      if (servers.hosts.isNotEmpty) 'domain': servers.hosts,
      if (servers.addresses.isNotEmpty) 'ip_cidr': servers.addresses,
    };
    return rule.length > 1 ? rule : null;
  }

  static Map<String, Object?> directDNSServer(
    DirectDNS directDNS, {
    List<String> networkResolvers = const [],
  }) => switch (directDNS) {
    DirectDNSSystem() =>
      networkResolvers.isEmpty
          ? {'type': 'local', 'tag': 'dns-direct'}
          : udpDNSServer(networkResolvers.first),
    DirectDNSCustom(:final servers) =>
      servers.isEmpty
          ? {'type': 'local', 'tag': 'dns-direct'}
          : udpDNSServer(servers.first),
  };

  /// No `detour: direct`: sing-box rejects a detour to an empty direct
  /// outbound, and auto interface detection already uses the physical link.
  static Map<String, Object?> udpDNSServer(String server) => {
    'type': 'udp',
    'tag': 'dns-direct',
    'server': server,
  };

  static String resolverFor(OpenVPNMeta meta) => switch (meta.dns) {
    TunnelDNSCustom(:final servers) => servers.firstOrNull ?? fallbackTunnelDNS,
    TunnelDNSAuto() => meta.discoveredDNS.firstOrNull ?? fallbackTunnelDNS,
  };

  /// Exclusions are carved around the TUN subnet because otherwise redirected
  /// TCP replies to the neighbour address leave through the physical interface.
  static List<String> routeExcludeAddresses({
    List<IPv4Prefix> carving = const [],
  }) {
    final holes = <IPv4Prefix>[?IPv4Prefix.parse(tunAddress), ...carving];
    return [
      for (final text in lanRanges)
        ...(IPv4Prefix.parse(text)?.subtractingAll(holes) ?? const []).map(
          (prefix) => prefix.toString(),
        ),
    ];
  }

  static Map<String, Object?> localRuleSet({
    required String tag,
    required String path,
  }) => {'type': 'local', 'tag': tag, 'format': 'source', 'path': path};

  /// IPv4-only: an IPv6 TUN address would make an IPv4-only host appear
  /// dual-stack and install an unusable IPv6 default route.
  static Map<String, Object?> tunInbound({
    List<IPv4Prefix> carving = const [],
    WayforkPlatform platform = WayforkPlatform.windows,
  }) => {
    'type': 'tun',
    'tag': 'tun-in',
    'interface_name': platform.tunInterface,
    'address': [tunAddress],
    'mtu': 1500,
    'auto_route': true,
    'strict_route': false,
    'route_exclude_address': routeExcludeAddresses(carving: carving),
    'stack': 'system',
  };

  /// Maps the stored VLESS transport and TLS metadata to a sing-box outbound.
  static Map<String, Object?> vlessOutbound(
    VLESSMeta meta, {
    required String tag,
    required String uuid,
  }) {
    final outbound = <String, Object?>{
      'type': 'vless',
      'tag': tag,
      'server': meta.server,
      'server_port': meta.port,
      'uuid': uuid,
      if (meta.flow != null) 'flow': meta.flow,
    };
    if (meta.security != VLESSSecurity.none) {
      final tls = <String, Object?>{
        'enabled': true,
        'server_name': meta.sni ?? meta.server,
        'insecure': meta.allowInsecure,
        if (meta.alpn.isNotEmpty) 'alpn': meta.alpn,
        if (meta.fingerprint != null)
          'utls': {'enabled': true, 'fingerprint': meta.fingerprint},
      };
      if (meta.security == VLESSSecurity.reality) {
        tls['reality'] = {
          'enabled': true,
          'public_key': meta.realityPublicKey ?? '',
          'short_id': meta.realityShortID ?? '',
        };
      }
      outbound['tls'] = tls;
    }
    switch (meta.transport) {
      case VLESSTransportTCP():
        break;
      case VLESSTransportWS(:final path, :final host):
        outbound['transport'] = <String, Object?>{
          'type': 'ws',
          'path': path,
          if (host != null) 'headers': <String, Object?>{'Host': host},
        };
      case VLESSTransportGRPC(:final serviceName):
        outbound['transport'] = {'type': 'grpc', 'service_name': serviceName};
    }
    return outbound;
  }
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

List<String> _stringList(Object? value, String name) {
  if (value is! List<Object?>) throw FormatException('$name must be an array');
  return value.map((item) {
    if (item is String) return item;
    throw FormatException('$name entries must be strings');
  }).toList();
}

Map<String, String> _stringMap(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be an object');
  }
  return value.map((key, item) {
    if (item is! String) throw FormatException('$name.$key must be a string');
    return MapEntry(key.toLowerCase(), item);
  });
}

Map<String, List<String>> _stringListMap(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be an object');
  }
  return value.map(
    (key, item) => MapEntry(key, _stringList(item, '$name.$key')),
  );
}
