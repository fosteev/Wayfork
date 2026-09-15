import Foundation

/// Desired runtime state, computed by the app and reconciled by the daemon
/// (docs/design/00-architecture.md, "Runtime plan").
public struct RuntimePlan: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    /// Upper bounds enforced by the daemon before anything is written or spawned.
    public static let maxTunnels = Tunnel.maxSlots
    public static let maxConfigBytes = 1_048_576

    public var version: Int
    public var singBox: SingBoxPlan
    /// One entry per enabled OpenVPN tunnel. VLESS tunnels only exist inside the sing-box config.
    public var openVPN: [OpenVPNRuntime]
    /// `Settings.autoReconnect`: whether the daemon restarts an OpenVPN process after a
    /// transient failure. Not part of any hash; takes effect on the next failure.
    public var autoReconnect: Bool
    /// `Settings.logLevel`: sets `openvpn --verb`. Part of the OpenVPN diff key, so a change
    /// restarts every OpenVPN process (sing-box restarts anyway: `log.level` is in the config).
    public var logLevel: LogLevel
    /// Make Wayfork the system resolver while sing-box runs (F12, docs/design/05-daemon.md).
    public var overrideSystemDNS: Bool

    public init(
        version: Int = RuntimePlan.currentVersion,
        singBox: SingBoxPlan,
        openVPN: [OpenVPNRuntime],
        autoReconnect: Bool = true,
        logLevel: LogLevel = .info,
        overrideSystemDNS: Bool = true
    ) {
        self.version = version
        self.singBox = singBox
        self.openVPN = openVPN
        self.autoReconnect = autoReconnect
        self.logLevel = logLevel
        self.overrideSystemDNS = overrideSystemDNS
    }

    private enum CodingKeys: String, CodingKey {
        case version, singBox, openVPN, autoReconnect, logLevel, overrideSystemDNS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        singBox = try c.decode(SingBoxPlan.self, forKey: .singBox)
        openVPN = try c.decode([OpenVPNRuntime].self, forKey: .openVPN)
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        overrideSystemDNS = try c.decodeIfPresent(Bool.self, forKey: .overrideSystemDNS) ?? true
    }

    /// Ids of the tunnels the config routes: every routed tunnel has a `rules-t-<id>.json`
    /// (docs/design/03-routing.md, "Rule-set files"), so the daemon needs no separate list
    /// to know whom to probe (F14).
    public var routedTunnelIDs: [String] {
        routedIDs(prefix: "rules-t-")
    }

    /// Ids of the groups the config routes, from their `rules-g-<id>.json` files (F16).
    public var routedGroupIDs: [String] {
        routedIDs(prefix: "rules-g-")
    }

    private func routedIDs(prefix: String) -> [String] {
        singBox.ruleSets.keys.compactMap { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".json"), !name.hasSuffix("-ip.json")
            else { return nil }
            return String(name.dropFirst(prefix.count).dropLast(".json".count))
        }
        .sorted()
    }

    /// Hash over everything the daemon acts on; reported back as `RuntimeStatus.planHash`.
    public var planHash: String {
        var parts = [singBox.configHash]
        parts.append(
            contentsOf: singBox.ruleSets.keys.sorted().map {
                "\($0)=\(Hashing.sha256Hex(singBox.ruleSets[$0] ?? ""))"
            })
        parts.append(contentsOf: openVPN.map { "\($0.id)=\($0.configHash)" })
        parts.append("overrideSystemDNS=\(overrideSystemDNS)")
        return Hashing.sha256Hex(parts.joined(separator: "\n"))
    }
}

public struct SingBoxPlan: Codable, Sendable, Hashable {
    /// `sing-box.json` contents.
    public var config: String
    /// `rules-t-<id>.json` file name → contents.
    public var ruleSets: [String: String]
    /// Hash of `config` alone; rule-set changes do not affect it, so the daemon can tell a
    /// hot-reloadable change from one that needs a restart.
    public var configHash: String

    /// `route.final` of the config — `direct` or the default tunnel's `t-<id>` (F8) — which
    /// is where a flow no rule matched ends up (F15 lists exactly those). nil when the
    /// config is not the generator's shape.
    public var routeFinal: String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
            let route = root["route"] as? [String: Any]
        else { return nil }
        return route["final"] as? String
    }

    /// Paths of the `binary` local rule-sets the config references — the bundled block
    /// list (F18) and nothing else in the generator's shape.
    public var binaryRuleSetPaths: [String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
            let route = root["route"] as? [String: Any],
            let ruleSets = route["rule_set"] as? [[String: Any]]
        else { return [] }
        return ruleSets.compactMap { ruleSet in
            guard ruleSet["type"] as? String == "local", ruleSet["format"] as? String == "binary"
            else { return nil }
            return ruleSet["path"] as? String
        }
    }

    /// Whether the config carries the block list's rule-set (F18).
    public var hasBlockList: Bool { !binaryRuleSetPaths.isEmpty }

    /// The local proxy inbounds of the config (F17): tag, listen address and port of every
    /// `mixed` inbound, in config order. Empty when the config is not the generator's shape.
    public var localProxyInbounds: [LocalProxyInbound] {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
            let inbounds = root["inbounds"] as? [[String: Any]]
        else { return [] }
        return inbounds.compactMap { inbound in
            guard inbound["type"] as? String == "mixed", let tag = inbound["tag"] as? String
            else { return nil }
            return LocalProxyInbound(
                tag: tag, listen: inbound["listen"] as? String ?? "",
                port: inbound["listen_port"] as? Int ?? 0)
        }
    }

    /// The group outbounds of the config by group id (F16): the policy behind each
    /// (`selector` = *first live*, `urltest` = *fastest*) and the member tunnel ids in the
    /// group's order. Empty when the config is not the generator's shape.
    public var groupOutbounds: [String: GroupOutbound] {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
            let outbounds = root["outbounds"] as? [[String: Any]]
        else { return [:] }
        var result: [String: GroupOutbound] = [:]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String,
                let id = TunnelGroup.groupID(fromOutboundTag: tag),
                let type = outbound["type"] as? String,
                let policy = GroupOutbound.Policy(rawValue: type)
            else { continue }
            let members = (outbound["outbounds"] as? [String] ?? [])
                .compactMap(Tunnel.tunnelID(fromOutboundTag:))
            result[id] = GroupOutbound(policy: policy, members: members)
        }
        return result
    }

    public init(config: String, ruleSets: [String: String]) {
        self.config = config
        self.ruleSets = ruleSets
        configHash = Hashing.sha256Hex(config)
    }
}

/// One `mixed` inbound as the daemon sees it in the config (F17).
public struct LocalProxyInbound: Sendable, Hashable {
    public var tag: String
    public var listen: String
    public var port: Int

    public init(tag: String, listen: String, port: Int) {
        self.tag = tag
        self.listen = listen
        self.port = port
    }

    /// `t-<id>` / `g-<id>` the inbound feeds, per its tag; nil for a foreign tag.
    public var outboundTag: String? { LocalProxy.outboundTag(fromInboundTag: tag) }

    /// The tunnel or group id behind the tag; nil for a foreign tag.
    public var exitID: String? {
        guard let outboundTag else { return nil }
        return Tunnel.tunnelID(fromOutboundTag: outboundTag)
            ?? TunnelGroup.groupID(fromOutboundTag: outboundTag)
    }
}

/// One group outbound as the daemon sees it in the config (F16).
public struct GroupOutbound: Sendable, Hashable {
    public enum Policy: String, Sendable {
        /// The daemon points it at the first member whose probe passes.
        case selector
        /// sing-box picks the lowest delay itself.
        case urltest
    }

    public var policy: Policy
    /// Member tunnel ids in the group's order (usable members only — the generator left
    /// the others out).
    public var members: [String]

    public init(policy: Policy, members: [String]) {
        self.policy = policy
        self.members = members
    }
}

public struct OpenVPNRuntime: Codable, Sendable, Hashable, Identifiable {
    /// Tunnel id (`Tunnel.id.uuidString.lowercased()`).
    public var id: String
    /// `utun101`…
    public var interface: String
    /// Sanitized `.ovpn` body with inline certs/keys.
    public var config: String
    public var credentials: Credentials?
    public var keyPassphrase: String?
    /// Hash of `config` + credentials + passphrase: any change restarts the process.
    public var configHash: String

    public init(
        id: String,
        interface: String,
        config: String,
        credentials: Credentials? = nil,
        keyPassphrase: String? = nil
    ) {
        self.id = id
        self.interface = interface
        self.config = config
        self.credentials = credentials
        self.keyPassphrase = keyPassphrase
        configHash = Hashing.sha256Hex(
            [
                config,
                credentials?.username ?? "",
                credentials?.password ?? "",
                keyPassphrase ?? "",
            ].joined(separator: "\u{0}"))
    }
}
