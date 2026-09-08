import Foundation

public struct WireGuardSecrets: Codable, Sendable, Equatable {
    public var privateKey: String
    public var presharedKey: String?

    public init(privateKey: String, presharedKey: String? = nil) {
        self.privateKey = privateKey
        self.presharedKey = presharedKey
    }
}

/// Generates `sing-box.json` and the rule-set files from the store
/// (docs/design/03-routing.md). Pure function of its input; the output is deterministic.
public enum SingBoxConfigGenerator {
    public struct Input: Sendable {
        public var store: Store
        /// VLESS UUID per tunnel id (from Keychain). Enabled VLESS tunnels without an entry
        /// are left out of the config — they cannot connect without their secret.
        public var vlessUUIDs: [UUID: String]
        /// WireGuard keys per tunnel id. Enabled tunnels without an entry are left out.
        public var wireGuardKeys: [UUID: WireGuardSecrets]
        /// Shadowsocks and Trojan passwords per tunnel id.
        public var passwords: [UUID: String]
        /// VMess UUID per tunnel id.
        public var vmessUUIDs: [UUID: String]
        /// Absolute path of the bundled `openvpn`, matched by `process_path` so that the
        /// tunnels' own control traffic always goes direct.
        public var openVPNBinaryPath: String
        /// IPv4 addresses of OpenVPN and WireGuard server hostnames (lowercased host →
        /// addresses), resolved by the caller (`HostResolver`). OpenVPN server addresses
        /// also enter the `ip_cidr` half of the direct rule; WireGuard peer addresses do not.
        public var resolvedServerAddresses: [String: [String]]
        /// IPv4 addresses of the system resolvers (`SystemDNS.Snapshot.routable`). Those
        /// inside the LAN ranges are carved out of `route_exclude_address` so that the system
        /// resolver's queries enter the TUN and `hijack-dns` sees them. Must never contain the
        /// default gateway: a host route for the gateway through the TUN makes it unreachable
        /// from the physical interface and every outbound dial fails with "network is
        /// unreachable" (2026-08-26).
        public var systemDNSServers: [String]
        /// IPv4 resolvers the network supplied (DHCP; `SystemDNS.Snapshot.networkServers`).
        /// With `directDNS = .system` the first one becomes `dns-direct` explicitly: sing-box's
        /// `local` transport asks DHCP for them itself and, when that times out, falls back
        /// to the system resolver — which is sing-box under the F12 override, a loop that
        /// left every direct name unresolvable (2026-08-26). Empty → `local` as before.
        public var networkResolvers: [String]

        public init(
            store: Store, vlessUUIDs: [UUID: String],
            wireGuardKeys: [UUID: WireGuardSecrets] = [:], passwords: [UUID: String] = [:],
            vmessUUIDs: [UUID: String] = [:], openVPNBinaryPath: String,
            resolvedServerAddresses: [String: [String]] = [:], systemDNSServers: [String] = [],
            networkResolvers: [String] = []
        ) {
            self.store = store
            self.vlessUUIDs = vlessUUIDs
            self.wireGuardKeys = wireGuardKeys
            self.passwords = passwords
            self.vmessUUIDs = vmessUUIDs
            self.openVPNBinaryPath = openVPNBinaryPath
            self.resolvedServerAddresses = resolvedServerAddresses
            self.systemDNSServers = systemDNSServers
            self.networkResolvers = networkResolvers
        }
    }

    public struct Output: Sendable, Equatable {
        /// `sing-box.json`
        public var config: String
        /// Rule-set file name → contents: `rules-t-<id>.json` and `rules-t-<id>-ip.json` per
        /// routed tunnel plus `rules-direct.json` / `rules-direct-ip.json`.
        public var ruleSets: [String: String]
        /// Tunnels that made it into the config, in store order.
        public var routedTunnels: [Tunnel]
        /// The tunnel behind `route.final` (F8), when the store's default is routed.
        public var defaultTunnel: Tunnel?
    }

    public static let tunInterface = "utun100"
    public static let tunHostAddress = "172.19.0.1"
    public static let tunAddress = tunHostAddress + "/30"
    /// The system resolver while On (F12): the *other* address of the TUN's /30. The TUN's
    /// own address never works for this — mDNSResponder treats an address that belongs to a
    /// local interface as loopback and its queries never enter the TUN (2026-08-26: only
    /// applications with their own resolvers got answers), whereas a neighbour address is
    /// routed through `utun100` like any other and `hijack-dns` answers it.
    public static let resolverAddress = "172.19.0.2"
    /// A name sing-box answers by itself (`predefined`, TTL 0): the daemon resolves it
    /// through the system resolver right after the override to prove that mDNSResponder
    /// reaches the TUN, and backs the override out when it does not.
    public static let resolverProbeName = "probe.wayfork.internal"
    public static let fakeIPv4Range = "198.18.0.0/15"
    /// LAN, CGNAT, link-local and multicast: kept out of the TUN entirely.
    static let lanRanges = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
        "169.254.0.0/16", "224.0.0.0/4",
    ]
    /// Resolver for `.auto` OpenVPN tunnels before the server pushed anything.
    public static let fallbackTunnelDNS = "1.1.1.1"
    /// DoT resolver used as `dns.final` when the default tunnel is VLESS (detoured through it).
    public static let defaultTunnelDoTServer = "1.1.1.1"
    /// The DDR special-use name (RFC 9462) mDNSResponder queries to upgrade to DoH/DoT.
    public static let ddrDiscoveryName = "_dns.resolver.arpa"

    public static func generate(_ input: Input) -> Output {
        let store = input.store
        let routed = store.tunnels.filter { tunnel in
            guard tunnel.isEnabled else { return false }
            switch tunnel.kind {
            case .openVPN: return true
            case .vless: return input.vlessUUIDs[tunnel.id] != nil
            case .wireGuard: return input.wireGuardKeys[tunnel.id] != nil
            case .shadowsocks, .trojan: return input.passwords[tunnel.id] != nil
            case .vmess: return input.vmessUUIDs[tunnel.id] != nil
            }
        }
        let activeRules = RuleValidator.activeRules(store)
        let exceptions = RuleValidator.activeExceptions(store)
        let defaultTunnel = store.effectiveDefaultTunnel.flatMap { wanted in
            routed.first { $0.id == wanted.id }
        }

        var dnsServers: [[String: Any]] = [
            directDNSServer(store.settings.directDNS, networkResolvers: input.networkResolvers)
        ]
        var outbounds: [[String: Any]] = [["type": "direct", "tag": "direct"]]
        var endpoints: [[String: Any]] = []
        // Exceptions (plus the built-in local names) come first so that they beat both the
        // tunnel rule-sets and the default tunnel; the file always exists, so adding an
        // exception is a rule-set rewrite, never a restart.
        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        if !input.systemDNSServers.isEmpty {
            // DDR (RFC 9462): mDNSResponder asks the system resolver for `_dns.resolver.arpa`
            // and, when the advertised DoH/DoT endpoint's certificate covers the resolver's
            // address, moves every query to 443/853 — past `hijack-dns`, real addresses
            // again (2026-08-26, 1.1.1.1: DoH3 over UDP 443). The DNS rule below refuses
            // the discovery; this rule cuts an upgrade cached before Wayfork started, so
            // mDNSResponder falls back to plain 53. Never matches sing-box's own DoT
            // upstream: outbound dials do not pass through route rules.
            routeRules.append([
                "ip_cidr": input.systemDNSServers.map { "\($0)/32" },
                "port": [443, 853],
                "action": "reject",
            ])
        }
        routeRules.append(["process_path": [input.openVPNBinaryPath], "outbound": "direct"])
        // The OpenVPN servers themselves always go direct, by address and by name: the
        // process match above is best effort (seen to miss the very first UDP flow after
        // start), and a control channel routed into another tunnel is a tunnel-in-tunnel.
        let servers = openVPNServers(routed, resolved: input.resolvedServerAddresses)
        if let rule = serverRouteRule(servers) {
            routeRules.append(rule)
        }
        routeRules.append([
            "rule_set": [RuleSetGenerator.directTag, RuleSetGenerator.directIPTag],
            "outbound": "direct",
        ])
        var ruleSetRefs: [[String: Any]] = [
            localRuleSet(tag: RuleSetGenerator.directTag, path: RuleSetGenerator.directFileName),
            localRuleSet(
                tag: RuleSetGenerator.directIPTag, path: RuleSetGenerator.directIPFileName),
        ]

        for tunnel in routed {
            switch tunnel.kind {
            case .openVPN(let meta):
                let dnsTag = "dns-\(tunnel.outboundTag)"
                dnsServers.append([
                    "type": "udp",
                    "tag": dnsTag,
                    "server": resolver(for: meta),
                    "detour": tunnel.outboundTag,
                ])
                outbounds.append([
                    "type": "direct",
                    "tag": tunnel.outboundTag,
                    "bind_interface": tunnel.interfaceName ?? "",
                    "domain_resolver": ["server": dnsTag, "strategy": "ipv4_only"],
                ])
            case .vless(let meta):
                outbounds.append(
                    vlessOutbound(
                        meta, tag: tunnel.outboundTag, uuid: input.vlessUUIDs[tunnel.id] ?? ""))
            case .wireGuard(let meta):
                let dnsTag = "dns-\(tunnel.outboundTag)"
                dnsServers.append([
                    "type": "udp",
                    "tag": dnsTag,
                    "server": resolver(for: meta),
                    "detour": tunnel.outboundTag,
                ])
                if let keys = input.wireGuardKeys[tunnel.id] {
                    endpoints.append(
                        wireGuardEndpoint(
                            meta, tag: tunnel.outboundTag, secrets: keys,
                            resolved: input.resolvedServerAddresses))
                }
            case .shadowsocks(let meta):
                outbounds.append(
                    shadowsocksOutbound(
                        meta, tag: tunnel.outboundTag, password: input.passwords[tunnel.id] ?? ""))
            case .trojan(let meta):
                outbounds.append(
                    trojanOutbound(
                        meta, tag: tunnel.outboundTag, password: input.passwords[tunnel.id] ?? ""))
            case .vmess(let meta):
                outbounds.append(
                    vmessOutbound(
                        meta, tag: tunnel.outboundTag, uuid: input.vmessUUIDs[tunnel.id] ?? ""))
            }
            routeRules.append([
                "rule_set": [tunnel.ruleSetTag, tunnel.ipRuleSetTag],
                "outbound": tunnel.outboundTag,
            ])
            ruleSetRefs.append(localRuleSet(tag: tunnel.ruleSetTag, path: tunnel.ruleSetFileName))
            ruleSetRefs.append(
                localRuleSet(tag: tunnel.ipRuleSetTag, path: tunnel.ipRuleSetFileName))
        }
        routeRules.append(["ip_is_private": true, "outbound": "direct"])

        // F11: a tunnel IP rule inside the LAN ranges must enter the TUN, so its range is
        // carved out of the exclusion list. Direct IP rules stay excluded — direct either way.
        var carved = routed.flatMap { tunnel in
            (activeRules[tunnel.id] ?? []).filter(\.isIP).compactMap { IPv4Prefix($0.pattern) }
        }
        // The system resolvers must enter the TUN for `hijack-dns` to see their queries, and a
        // LAN-hosted resolver sits inside the excluded ranges (03-routing.md, "Notes on
        // specific choices"). Public resolvers are not excluded to begin with: no-op. The
        // caller leaves out the default gateway (see `Input.systemDNSServers`).
        carved += input.systemDNSServers.compactMap { IPv4Prefix($0) }.filter(\.isHost)

        dnsServers.append([
            "type": "fakeip",
            "tag": "fakeip",
            "inet4_range": fakeIPv4Range,
        ])

        var dnsRules: [[String: Any]] = [
            // F12: the daemon's proof that the system resolver reaches the TUN.
            [
                "domain": [resolverProbeName],
                "action": "predefined",
                "rcode": "NOERROR",
                "answer": ["\(resolverProbeName). 0 IN A \(resolverAddress)"],
            ],
            // No designated (encrypted) resolver, ever: see the DDR route rule above.
            ["domain": [ddrDiscoveryName], "action": "reject"],
            ["rule_set": RuleSetGenerator.directTag, "server": "dns-direct"],
        ]
        let directDNSHosts = uniqueHosts(
            servers.hosts + wireGuardPeerHosts(routed))
        if !directDNSHosts.isEmpty {
            // OpenVPN remotes and WireGuard peers must resolve to real addresses, never
            // fake IPs. Only OpenVPN's control flow also gets a direct route rule above.
            dnsRules.append(["domain": directDNSHosts, "server": "dns-direct"])
        }
        if !routed.isEmpty {
            dnsRules.append([
                "rule_set": routed.map(\.ruleSetTag),
                "query_type": ["A", "AAAA"],
                "server": "fakeip",
            ])
        }
        // F8: with a default tunnel every remaining A/AAAA gets a fake IP so that the default
        // outbound dials by domain (VLESS resolves server-side, OpenVPN through its own
        // resolver); other query types go to the default tunnel's resolver.
        var dnsFinal = "dns-direct"
        if let defaultTunnel {
            dnsRules.append(["query_type": ["A", "AAAA"], "server": "fakeip"])
            let tag = "dns-\(defaultTunnel.outboundTag)"
            if !defaultTunnel.kind.hasOwnResolver {
                dnsServers.append([
                    "type": "tls",
                    "tag": tag,
                    "server": defaultTunnelDoTServer,
                    "detour": defaultTunnel.outboundTag,
                ])
            }
            dnsFinal = tag
        }
        var dns: [String: Any] = [
            "servers": dnsServers,
            "rules": dnsRules,
            "final": dnsFinal,
            // AAAA answers are suppressed while Wayfork is on: the TUN owns the IPv6 default
            // route, so on an IPv4-only network every AAAA the system resolver hands out
            // would end in "no route to host" inside sing-box. Tunnels are IPv4-only anyway.
            "strategy": "ipv4_only",
            "independent_cache": true,
        ]
        if defaultTunnel != nil {
            // Remember which name a real answer was for, so that domain rules also match
            // flows that carry no SNI/Host (SSH to a Direct-listed host, 2026-08-26): the
            // exceptions get real IPs from `dns-direct`, and without this only sniffing
            // would keep such a flow out of the default tunnel. Without a default tunnel
            // the mapping cannot change where a flow goes (`route.final` is `direct`) and
            // a poisoned ISP answer would only mislabel raw-IP flows, so it is omitted
            // (H4, docs/design/03-routing.md).
            dns["reverse_mapping"] = true
        }

        let route: [String: Any] = [
            "rules": routeRules,
            "rule_set": ruleSetRefs,
            // F8: unmatched traffic takes the default tunnel; when it is down the dials fail
            // instead of leaking direct (kill switch by construction).
            "final": defaultTunnel?.outboundTag ?? "direct",
            "auto_detect_interface": true,
            "default_domain_resolver": "dns-direct",
            "find_process": true,
        ]

        var config: [String: Any] = [
            "log": ["level": store.settings.logLevel.singBoxLevel, "timestamp": true],
            "dns": dns,
            "inbounds": [tunInbound(carving: carved)],
            "outbounds": outbounds,
            "route": route,
            "experimental": [
                "cache_file": ["enabled": true, "path": "cache.db", "store_fakeip": true]
            ],
        ]
        if !endpoints.isEmpty {
            config["endpoints"] = endpoints
        }

        return Output(
            config: JSONText.render(config),
            ruleSets: RuleSetGenerator.generate(
                tunnels: routed, activeRules: activeRules, exceptions: exceptions),
            routedTunnels: routed,
            defaultTunnel: defaultTunnel)
    }

    // MARK: - Pieces

    /// `remote` hosts of the routed OpenVPN tunnels, split into IPv4 literals (as /32) and
    /// names; unique, in store order. A name's `resolved` addresses (sorted) join the
    /// literals right after it.
    static func openVPNServers(_ routed: [Tunnel], resolved: [String: [String]] = [:])
        -> (addresses: [String], hosts: [String])
    {
        var addresses: [String] = []
        var hosts: [String] = []
        func addAddress(_ literal: String) {
            guard let prefix = IPv4Prefix(literal) else { return }
            let cidr = prefix.description
            if !addresses.contains(cidr) { addresses.append(cidr) }
        }
        for tunnel in routed {
            guard case .openVPN(let meta) = tunnel.kind else { continue }
            for remote in meta.remotes {
                if IPv4Prefix(remote.host) != nil {
                    addAddress(remote.host)
                } else {
                    let host = remote.host.lowercased()
                    guard !host.isEmpty, !hosts.contains(host) else { continue }
                    hosts.append(host)
                    for address in (resolved[host] ?? []).sorted() { addAddress(address) }
                }
            }
        }
        return (addresses, hosts)
    }

    static func serverRouteRule(_ servers: (addresses: [String], hosts: [String]))
        -> [String: Any]?
    {
        var rule: [String: Any] = ["outbound": "direct"]
        if !servers.hosts.isEmpty { rule["domain"] = servers.hosts }
        if !servers.addresses.isEmpty { rule["ip_cidr"] = servers.addresses }
        return rule.count > 1 ? rule : nil
    }

    static func directDNSServer(_ directDNS: DirectDNS, networkResolvers: [String] = [])
        -> [String: Any]
    {
        switch directDNS {
        case .system:
            // The network's own resolver, named explicitly (see `Input.networkResolvers`);
            // sing-box dials it from the physical interface, so a LAN address is fine.
            guard let first = networkResolvers.first else {
                return ["type": "local", "tag": "dns-direct"]
            }
            return udpDNSServer(first)
        case .custom(let servers):
            // sing-box has no fallback list: only the first server is used (the UI says so).
            guard let first = servers.first else {
                return ["type": "local", "tag": "dns-direct"]
            }
            return udpDNSServer(first)
        }
    }

    /// `dns-direct` as a plain UDP server. No `detour: direct`: sing-box 1.13 refuses to
    /// start with it ("detour to an empty direct outbound makes no sense", 2026-08-26); the
    /// default dialer already leaves through the physical interface (`auto_detect_interface`).
    static func udpDNSServer(_ server: String) -> [String: Any] {
        ["type": "udp", "tag": "dns-direct", "server": server]
    }

    static func resolver(for meta: OpenVPNMeta) -> String {
        resolver(dns: meta.dns, discoveredDNS: meta.discoveredDNS)
    }

    static func resolver(for meta: WireGuardMeta) -> String {
        resolver(dns: meta.dns, discoveredDNS: meta.discoveredDNS)
    }

    private static func resolver(dns: TunnelDNS, discoveredDNS: [String]) -> String {
        switch dns {
        case .custom(let servers):
            return servers.first ?? fallbackTunnelDNS
        case .auto:
            return discoveredDNS.first ?? fallbackTunnelDNS
        }
    }

    static func wireGuardEndpoint(
        _ meta: WireGuardMeta, tag: String, secrets: WireGuardSecrets,
        resolved: [String: [String]] = [:]
    ) -> [String: Any] {
        var everyPeerIsLiteral = true
        let peers = meta.peers.map { peer -> [String: Any] in
            let hostIsLiteral = isIPv4Literal(peer.host)
            let address: String
            if hostIsLiteral {
                address = peer.host
            } else if let first =
                (resolved[peer.host] ?? resolved[peer.host.lowercased()])?.first,
                isIPv4Literal(first)
            {
                address = first
            } else {
                address = peer.host
                everyPeerIsLiteral = false
            }
            var result: [String: Any] = [
                "address": address,
                "port": peer.port,
                "public_key": peer.publicKey,
                "allowed_ips": peer.allowedIPs,
            ]
            if peer.hasPresharedKey, let presharedKey = secrets.presharedKey {
                result["pre_shared_key"] = presharedKey
            }
            if let keepalive = peer.keepalive {
                result["persistent_keepalive_interval"] = keepalive
            }
            return result
        }
        var endpoint: [String: Any] = [
            "type": "wireguard",
            "tag": tag,
            "system": false,
            "address": meta.addresses,
            "private_key": secrets.privateKey,
            "domain_resolver":
                everyPeerIsLiteral
                ? ["server": "dns-\(tag)", "strategy": "ipv4_only"] : "dns-direct",
            "peers": peers,
        ]
        if let mtu = meta.mtu { endpoint["mtu"] = mtu }
        return endpoint
    }

    private static func wireGuardPeerHosts(_ routed: [Tunnel]) -> [String] {
        routed.flatMap { tunnel -> [String] in
            guard case .wireGuard(let meta) = tunnel.kind else { return [] }
            return meta.peers.compactMap { peer in
                isIPv4Literal(peer.host) ? nil : peer.host.lowercased()
            }
        }
    }

    private static func uniqueHosts(_ hosts: [String]) -> [String] {
        var result: [String] = []
        for host in hosts where !host.isEmpty && !result.contains(host) { result.append(host) }
        return result
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        !host.contains("/") && IPv4Prefix(host)?.isHost == true
    }

    /// `route_exclude_address` for the TUN inbound: `lanRanges` with the TUN's own subnet
    /// carved out. sing-tun subtracts the excluded ranges from the auto-route split ranges,
    /// and on Darwin a point-to-point utun only gets a host route for its own address. If an
    /// exclusion covered the TUN subnet, the replies of the system stack's TCP redirect
    /// (addressed to the TUN's next address, 172.19.0.2) would leave through the physical
    /// interface and every TCP connection would hang while UDP kept working (2026-08-25).
    public static func routeExcludeAddresses(carving carved: [IPv4Prefix] = []) -> [String] {
        let holes = [IPv4Prefix(tunAddress)].compactMap { $0 } + carved
        return lanRanges.flatMap { text -> [String] in
            guard let range = IPv4Prefix(text) else { return [text] }
            return range.subtracting(all: holes).map(\.description)
        }
    }

    static func localRuleSet(tag: String, path: String) -> [String: Any] {
        ["type": "local", "tag": tag, "format": "source", "path": path]
    }

    /// IPv4-only on purpose: an `inet6` address here makes `auto_route` install an IPv6
    /// default route, which makes the host look dual-stack to every application even on an
    /// IPv4-only network (docs/design/03-routing.md, "Notes on specific choices").
    static func tunInbound(carving carved: [IPv4Prefix] = []) -> [String: Any] {
        [
            "type": "tun",
            "tag": "tun-in",
            "interface_name": tunInterface,
            "address": [tunAddress],
            "mtu": 1500,
            "auto_route": true,
            "strict_route": false,
            "route_exclude_address": routeExcludeAddresses(carving: carved),
            "stack": "system",
        ]
    }

    /// docs/design/04-tunnels.md, "sing-box outbound mapping".
    static func vlessOutbound(_ meta: VLESSMeta, tag: String, uuid: String) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": tag,
            "server": meta.server,
            "server_port": meta.port,
            "uuid": uuid,
        ]
        if let flow = meta.flow {
            outbound["flow"] = flow
        }
        if let tls = tlsBlock(
            security: meta.security, server: meta.server, sni: meta.sni,
            fingerprint: meta.fingerprint, alpn: meta.alpn,
            realityPublicKey: meta.realityPublicKey, realityShortID: meta.realityShortID,
            allowInsecure: meta.allowInsecure)
        {
            outbound["tls"] = tls
        }
        if let transport = transportBlock(meta.transport) {
            outbound["transport"] = transport
        }
        return outbound
    }

    static func shadowsocksOutbound(
        _ meta: ShadowsocksMeta, tag: String, password: String
    ) -> [String: Any] {
        [
            "type": "shadowsocks",
            "tag": tag,
            "server": meta.server,
            "server_port": meta.port,
            "method": meta.method,
            "password": password,
        ]
    }

    static func trojanOutbound(
        _ meta: TrojanMeta, tag: String, password: String
    ) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "trojan",
            "tag": tag,
            "server": meta.server,
            "server_port": meta.port,
            "password": password,
        ]
        if let tls = tlsBlock(
            security: meta.security, server: meta.server, sni: meta.sni,
            fingerprint: meta.fingerprint, alpn: meta.alpn,
            realityPublicKey: meta.realityPublicKey, realityShortID: meta.realityShortID,
            allowInsecure: meta.allowInsecure)
        {
            outbound["tls"] = tls
        }
        if let transport = transportBlock(meta.transport) {
            outbound["transport"] = transport
        }
        return outbound
    }

    static func vmessOutbound(_ meta: VMessMeta, tag: String, uuid: String) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "vmess",
            "tag": tag,
            "server": meta.server,
            "server_port": meta.port,
            "uuid": uuid,
            "security": meta.security,
            "alter_id": 0,
        ]
        if let tls = tlsBlock(
            security: meta.tlsSecurity, server: meta.server, sni: meta.sni,
            fingerprint: meta.fingerprint, alpn: meta.alpn,
            realityPublicKey: meta.realityPublicKey, realityShortID: meta.realityShortID,
            allowInsecure: meta.allowInsecure)
        {
            outbound["tls"] = tls
        }
        if let transport = transportBlock(meta.transport) {
            outbound["transport"] = transport
        }
        return outbound
    }

    /// The `tls` block shared by VLESS, Trojan and VMess (docs/design/04-tunnels.md,
    /// "Shared TLS and transport"). nil when the tunnel carries no TLS layer.
    static func tlsBlock(
        security: TLSSecurity, server: String, sni: String?, fingerprint: String?,
        alpn: [String], realityPublicKey: String?, realityShortID: String?,
        allowInsecure: Bool
    ) -> [String: Any]? {
        guard security != .none else { return nil }
        var tls: [String: Any] = [
            "enabled": true,
            "server_name": sni ?? server,
            "insecure": allowInsecure,
        ]
        if !alpn.isEmpty {
            tls["alpn"] = alpn
        }
        if let fingerprint {
            tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        if security == .reality {
            // sing-box refuses REALITY without uTLS ("uTLS is required by reality client"),
            // so the parsers default the fingerprint to `chrome` when the link omits `fp`.
            tls["reality"] = [
                "enabled": true,
                "public_key": realityPublicKey ?? "",
                "short_id": realityShortID ?? "",
            ]
        }
        return tls
    }

    /// The `transport` block shared by VLESS, Trojan and VMess; nil for plain TCP.
    static func transportBlock(_ transport: ProxyTransport) -> [String: Any]? {
        switch transport {
        case .tcp:
            return nil
        case .ws(let path, let host):
            var block: [String: Any] = ["type": "ws", "path": path]
            if let host {
                block["headers"] = ["Host": host]
            }
            return block
        case .grpc(let serviceName):
            return ["type": "grpc", "service_name": serviceName]
        }
    }
}
