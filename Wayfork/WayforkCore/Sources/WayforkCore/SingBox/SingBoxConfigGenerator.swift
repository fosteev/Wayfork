import Foundation

/// Generates `sing-box.json` and the rule-set files from the store
/// (docs/design/03-routing.md). Pure function of its input; the output is deterministic.
public enum SingBoxConfigGenerator {
    public struct Input: Sendable {
        public var store: Store
        /// VLESS UUID per tunnel id (from Keychain). Enabled VLESS tunnels without an entry
        /// are left out of the config — they cannot connect without their secret.
        public var vlessUUIDs: [UUID: String]
        /// Absolute path of the bundled `openvpn`, matched by `process_path` so that the
        /// tunnels' own control traffic always goes direct.
        public var openVPNBinaryPath: String

        public init(store: Store, vlessUUIDs: [UUID: String], openVPNBinaryPath: String) {
            self.store = store
            self.vlessUUIDs = vlessUUIDs
            self.openVPNBinaryPath = openVPNBinaryPath
        }
    }

    public struct Output: Sendable, Equatable {
        /// `sing-box.json`
        public var config: String
        /// `rules-t-<id>.json` → contents, one per routed tunnel.
        public var ruleSets: [String: String]
        /// Tunnels that made it into the config, in store order.
        public var routedTunnels: [Tunnel]
    }

    public static let tunInterface = "utun100"
    public static let fakeIPv4Range = "198.18.0.0/15"
    public static let fakeIPv6Range = "fc00::/18"
    /// Resolver for `.auto` OpenVPN tunnels before the server pushed anything.
    public static let fallbackTunnelDNS = "1.1.1.1"

    public static func generate(_ input: Input) -> Output {
        let store = input.store
        let routed = store.tunnels.filter { tunnel in
            guard tunnel.isEnabled else { return false }
            switch tunnel.kind {
            case .openVPN: return true
            case .vless: return input.vlessUUIDs[tunnel.id] != nil
            }
        }
        let activeRules = RuleValidator.activeRules(store)

        var dnsServers: [[String: Any]] = [directDNSServer(store.settings.directDNS)]
        var outbounds: [[String: Any]] = [["type": "direct", "tag": "direct"]]
        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["process_path": [input.openVPNBinaryPath], "outbound": "direct"],
        ]
        var ruleSetRefs: [[String: Any]] = []

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
            }
            routeRules.append(["rule_set": tunnel.ruleSetTag, "outbound": tunnel.outboundTag])
            ruleSetRefs.append([
                "type": "local",
                "tag": tunnel.ruleSetTag,
                "format": "source",
                "path": tunnel.ruleSetFileName,
            ])
        }
        routeRules.append(["ip_is_private": true, "outbound": "direct"])

        dnsServers.append([
            "type": "fakeip",
            "tag": "fakeip",
            "inet4_range": fakeIPv4Range,
            "inet6_range": fakeIPv6Range,
        ])

        var dns: [String: Any] = [
            "servers": dnsServers,
            "final": "dns-direct",
            "independent_cache": true,
        ]
        if !routed.isEmpty {
            dns["rules"] = [
                [
                    "rule_set": routed.map(\.ruleSetTag),
                    "query_type": ["A", "AAAA"],
                    "server": "fakeip",
                ] as [String: Any]
            ]
        }

        var route: [String: Any] = [
            "rules": routeRules,
            "final": "direct",
            "auto_detect_interface": true,
            "default_domain_resolver": "dns-direct",
            "find_process": true,
        ]
        if !ruleSetRefs.isEmpty {
            route["rule_set"] = ruleSetRefs
        }

        let config: [String: Any] = [
            "log": ["level": store.settings.logLevel.singBoxLevel, "timestamp": true],
            "dns": dns,
            "inbounds": [tunInbound()],
            "outbounds": outbounds,
            "route": route,
            "experimental": [
                "cache_file": ["enabled": true, "path": "cache.db", "store_fakeip": true]
            ],
        ]

        return Output(
            config: JSONText.render(config),
            ruleSets: RuleSetGenerator.generate(tunnels: routed, activeRules: activeRules),
            routedTunnels: routed)
    }

    // MARK: - Pieces

    static func directDNSServer(_ directDNS: DirectDNS) -> [String: Any] {
        switch directDNS {
        case .system:
            return ["type": "local", "tag": "dns-direct"]
        case .custom(let servers):
            // sing-box has no fallback list: only the first server is used (the UI says so).
            guard let first = servers.first else {
                return ["type": "local", "tag": "dns-direct"]
            }
            return ["type": "udp", "tag": "dns-direct", "server": first, "detour": "direct"]
        }
    }

    static func resolver(for meta: OpenVPNMeta) -> String {
        switch meta.dns {
        case .custom(let servers):
            return servers.first ?? fallbackTunnelDNS
        case .auto:
            return meta.discoveredDNS.first ?? fallbackTunnelDNS
        }
    }

    static func tunInbound() -> [String: Any] {
        [
            "type": "tun",
            "tag": "tun-in",
            "interface_name": tunInterface,
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "mtu": 1500,
            "auto_route": true,
            "strict_route": false,
            "route_exclude_address": [
                "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
                "169.254.0.0/16", "224.0.0.0/4", "fe80::/10", "ff00::/8",
            ],
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
        if meta.security != .none {
            var tls: [String: Any] = [
                "enabled": true,
                "server_name": meta.sni ?? meta.server,
                "insecure": meta.allowInsecure,
            ]
            if !meta.alpn.isEmpty {
                tls["alpn"] = meta.alpn
            }
            if let fingerprint = meta.fingerprint {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            if meta.security == .reality {
                tls["reality"] = [
                    "enabled": true,
                    "public_key": meta.realityPublicKey ?? "",
                    "short_id": meta.realityShortID ?? "",
                ]
            }
            outbound["tls"] = tls
        }
        switch meta.transport {
        case .tcp:
            break
        case .ws(let path, let host):
            var transport: [String: Any] = ["type": "ws", "path": path]
            if let host {
                transport["headers"] = ["Host": host]
            }
            outbound["transport"] = transport
        case .grpc(let serviceName):
            outbound["transport"] = ["type": "grpc", "service_name": serviceName]
        }
        return outbound
    }
}
