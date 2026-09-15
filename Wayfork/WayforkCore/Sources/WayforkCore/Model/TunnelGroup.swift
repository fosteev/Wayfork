import Foundation

/// How a group picks the member that carries its traffic (F16).
public enum GroupPolicy: String, Codable, Sendable, CaseIterable {
    /// sing-box `urltest`: the member with the lowest probe latency, with hysteresis.
    case fastest
    /// A `selector` the daemon points at the first member whose probe passes.
    case firstLive
}

/// Several tunnels behind one name (F16, docs/design/01-data-model.md, "Tunnel groups").
/// Shares the UUID space with tunnels: a rule target or `Store.defaultTunnelID` names
/// either.
public struct TunnelGroup: Codable, Sendable, Hashable, Identifiable {
    public static let minimumMembers = 2

    public var id: UUID
    /// Unique among tunnels and groups, 1…40 chars.
    public var name: String
    public var isEnabled: Bool
    /// Tunnel ids in the user's order — never a group, no duplicates, at least two.
    public var members: [UUID]
    public var policy: GroupPolicy
    public var createdAt: Date
    /// F17: a loopback port that sends an app through this group; nil = never turned on.
    public var localProxy: LocalProxy?

    public init(
        id: UUID = UUID(), name: String, isEnabled: Bool = true, members: [UUID],
        policy: GroupPolicy = .fastest, createdAt: Date = Date(), localProxy: LocalProxy? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.members = members
        self.policy = policy
        self.createdAt = createdAt
        self.localProxy = localProxy
    }

    /// sing-box outbound tag: `g-<id>`.
    public var outboundTag: String {
        "\(TunnelGroup.outboundTagPrefix)\(id.uuidString.lowercased())"
    }

    public static let outboundTagPrefix = "g-"

    /// The group id behind an outbound tag; nil for anything else.
    public static func groupID(fromOutboundTag tag: String) -> String? {
        guard tag.hasPrefix(outboundTagPrefix), tag.count > outboundTagPrefix.count else {
            return nil
        }
        return String(tag.dropFirst(outboundTagPrefix.count))
    }

    /// `rules-g-<id>` / `rules-g-<id>-ip`, like a tunnel's.
    public var ruleSetTag: String { "rules-\(outboundTag)" }
    public var ruleSetFileName: String { "\(ruleSetTag).json" }
    public var ipRuleSetTag: String { "\(ruleSetTag)-ip" }
    public var ipRuleSetFileName: String { "\(ipRuleSetTag).json" }
}

/// What a rule can be sent through once the generator has decided what is usable: a
/// tunnel or a group, reduced to what the config and the rule-set files need.
public struct RoutedExit: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var outboundTag: String

    public init(_ tunnel: Tunnel) {
        id = tunnel.id
        name = tunnel.name
        outboundTag = tunnel.outboundTag
    }

    public init(_ group: TunnelGroup) {
        id = group.id
        name = group.name
        outboundTag = group.outboundTag
    }

    public var ruleSetTag: String { "rules-\(outboundTag)" }
    public var ruleSetFileName: String { "\(ruleSetTag).json" }
    public var ipRuleSetTag: String { "\(ruleSetTag)-ip" }
    public var ipRuleSetFileName: String { "\(ipRuleSetTag).json" }
    public var isGroup: Bool { outboundTag.hasPrefix(TunnelGroup.outboundTagPrefix) }
}
