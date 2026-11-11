import Foundation

/// Problems the UI shows as chips next to a rule (docs/design/02-ux.md).
public enum RuleIssue: Equatable, Sendable, Hashable {
    /// Same pattern and match as an earlier rule of the same group.
    case duplicate(of: UUID)
    /// Same pattern and match as an active rule in an earlier group (Direct comes first);
    /// never matches.
    case shadowed(by: UUID)
    /// The rule's tunnel (or group, F16) is disabled — for a group also: has no enabled
    /// member — so the rule is inert.
    case tunnelDisabled
    /// The rule's tunnel or group no longer exists.
    case tunnelMissing
    /// Enabled exit has no usable secret (or no member with one).
    case missingSecret
    /// The pattern covers the server host of a tunnel — its own control traffic would
    /// try to go through a tunnel (docs/design/03-routing.md).
    case coversTunnelServer(tunnelName: String)
    /// An IP rule overlaps one of the Mac's own networks (F11): the LAN devices in the range
    /// go through the tunnel while Wayfork is on.
    case coversLocalNetwork(interface: String, network: String)
}

/// Why `Store.defaultTunnelID` is not taking "everything else" right now (F8).
public enum DefaultTunnelIssue: Equatable, Sendable, Hashable {
    /// The id points at no tunnel.
    case missing
    case disabled
    /// The tunnel has no config body / UUID in Keychain, so the plan leaves it out.
    case missingSecret
}

public enum RuleValidator {
    /// Issues per rule id. Rules without problems are absent from the result.
    /// `localNetworks` (the app passes `LocalNetwork.current()`) feeds `coversLocalNetwork`.
    public static func validate(
        _ store: Store, localNetworks: [LocalNetwork] = [], routedExitIDs: Set<UUID>? = nil
    )
        -> [UUID: [RuleIssue]]
    {
        var issues: [UUID: [RuleIssue]] = [:]
        let candidates = resolvedCandidates(store, routedExitIDs: routedExitIDs)
        var seen: [String: UUID] = [:]
        var earlier: [ResolvedRule] = []
        for row in candidates {
            let rule = row.rule
            let key =
                "\(row.listID)|\(rule.match.rawValue)|\(rule.pattern)|\(rule.network?.rawValue ?? "both")"
            if let first = seen[key] {
                issues[rule.id, default: []].append(.duplicate(of: first))
                continue
            }
            seen[key] = rule.id
            if let first = earlier.first(where: {
                $0.rule.pattern == rule.pattern && $0.rule.match == rule.match
                    && ($0.rule.network == nil || $0.rule.network == rule.network)
            }) {
                issues[rule.id, default: []].append(.shadowed(by: first.rule.id))
            } else {
                earlier.append(row)
            }
        }
        // Tunnel servers: names are matched by domain rules, IP literals by IP rules.
        var serverNames: [(host: String, tunnel: String)] = []
        var serverAddresses: [(address: IPv4Prefix, tunnel: String)] = []
        for tunnel in store.tunnels {
            for host in tunnel.kind.serverHosts {
                if let address = IPv4Prefix(host) {
                    serverAddresses.append((address, tunnel.name))
                } else if let normalized = try? RulePattern.normalize(host, match: .exact) {
                    serverNames.append((normalized, tunnel.name))
                }
            }
        }

        for rule in store.rules {
            // Direct rows need no exit availability or server/LAN warnings.
            guard let target = store.target(for: rule), let exitID = target.exitID else { continue }
            if let tunnel = store.tunnel(id: exitID) {
                if !tunnel.isEnabled {
                    issues[rule.id, default: []].append(.tunnelDisabled)
                }
            } else if let group = store.group(id: exitID) {
                if !group.isEnabled || store.enabledMembers(of: group).isEmpty {
                    issues[rule.id, default: []].append(.tunnelDisabled)
                }
            } else {
                issues[rule.id, default: []].append(.tunnelMissing)
            }
            if let routedExitIDs, !routedExitIDs.contains(exitID),
                issues[rule.id]?.contains(.tunnelDisabled) != true,
                issues[rule.id]?.contains(.tunnelMissing) != true
            {
                issues[rule.id, default: []].append(.missingSecret)
            }
            if rule.isIP {
                guard let range = IPv4Prefix(rule.pattern) else { continue }
                for server in serverAddresses where range.contains(server.address) {
                    issues[rule.id, default: []].append(
                        .coversTunnelServer(tunnelName: server.tunnel))
                }
                for network in localNetworks where range.overlaps(network.prefix) {
                    issues[rule.id, default: []].append(
                        .coversLocalNetwork(
                            interface: network.interface, network: network.prefix.description))
                }
            } else {
                for server in serverNames
                where RulePattern.matches(
                    host: server.host, pattern: rule.pattern, match: rule.match)
                {
                    issues[rule.id, default: []].append(
                        .coversTunnelServer(tunnelName: server.tunnel))
                }
            }
        }
        return issues

    }

    /// Tunnel and group rules the routing engine should emit: enabled, exit enabled, not
    /// shadowed or duplicated. Keyed by the tunnel or group id, in effective order.
    public static func activeRules(_ store: Store) -> [UUID: [Rule]] {
        var result: [UUID: [Rule]] = [:]
        for rule in activeRulesInOrder(store) {
            if let exitID = rule.exitID {
                result[exitID, default: []].append(rule)
            }
        }
        return result
    }

    /// Direct rules the routing engine should emit (`rules-direct.json`), in list order.
    public static func activeExceptions(_ store: Store) -> [Rule] {
        activeRulesInOrder(store).filter(\.isException)
    }

    /// Why the default tunnel is not in effect, or nil when it is (or none is set).
    public static func defaultTunnelIssue(_ store: Store, missingSecrets: Set<UUID> = [])
        -> DefaultTunnelIssue?
    {
        guard let id = store.defaultTunnelID else { return nil }
        if let tunnel = store.tunnel(id: id) {
            guard tunnel.isEnabled else { return .disabled }
            return missingSecrets.contains(id) ? .missingSecret : nil
        }
        if let group = store.group(id: id) {
            let members = store.enabledMembers(of: group)
            guard group.isEnabled, !members.isEmpty else { return .disabled }
            return members.allSatisfy { missingSecrets.contains($0.id) } ? .missingSecret : nil
        }
        return .missing
    }

    public static func activeRulesInOrder(_ store: Store) -> [Rule] {
        resolvedRules(store).map { row in
            var rule = row.rule
            rule.target = row.target
            return rule
        }
    }

    /// The common precedence projection. Runtime callers pass the exits with available secrets.
    public static func resolvedRules(_ store: Store, routedExitIDs: Set<UUID>? = nil)
        -> [ResolvedRule]
    {
        let rows = resolvedCandidates(store, routedExitIDs: routedExitIDs)
        var seen: Set<String> = []
        var active: [ResolvedRule] = []
        for row in rows {
            let rule = row.rule
            let key =
                "\(row.listID)|\(rule.match.rawValue)|\(rule.pattern)|\(rule.network?.rawValue ?? "both")"
            guard seen.insert(key).inserted else { continue }
            guard
                !active.contains(where: {
                    $0.rule.pattern == rule.pattern && $0.rule.match == rule.match
                        && ($0.rule.network == nil || $0.rule.network == rule.network)
                })
            else { continue }
            active.append(row)
        }
        return active
    }

    public static func availableExitIDs(_ store: Store, missingSecrets: Set<UUID> = []) -> Set<UUID>
    {
        let enabled = Set(
            store.tunnels.filter { $0.isEnabled && !missingSecrets.contains($0.id) }.map(\.id))
        return enabled.union(
            store.groups.filter {
                $0.isEnabled && $0.members.contains(where: enabled.contains)
            }.map(\.id))
    }

    private static func resolvedCandidates(_ store: Store, routedExitIDs: Set<UUID>? = nil)
        -> [ResolvedRule]
    {
        let available = routedExitIDs ?? availableExitIDs(store)
        var rows: [ResolvedRule] = []
        for list in store.lists where list.isEnabled {
            for rule in store.rules(in: list.id) where rule.isEnabled {
                let binding = rule.target.map(RuleListTarget.exit) ?? list.target
                let target: RuleTarget
                switch binding {
                case .exit(let exit): target = exit
                case .everythingElse:
                    if let id = store.defaultTunnelID, available.contains(id) {
                        target = store.tunnel(id: id) != nil ? .tunnel(id) : .group(id)
                    } else {
                        target = .direct
                    }
                }
                guard target.exitID.map(available.contains) ?? true else { continue }
                rows.append(
                    ResolvedRule(
                        rule: rule, listID: list.id, target: target,
                        isException: binding == .exit(.direct)))
            }
        }
        return rows.filter(\.isException) + rows.filter { !$0.isException }
    }
}

public struct ResolvedRule: Sendable, Hashable {
    public var rule: Rule
    public var listID: UUID
    public var target: RuleTarget
    public var isException: Bool
    public var outboundTag: String {
        switch target {
        case .direct: "direct"
        case .tunnel(let id): "t-" + id.uuidString.lowercased()
        case .group(let id): "g-" + id.uuidString.lowercased()
        }
    }
    public var tag: String { "rules-r-" + rule.id.uuidString.lowercased() }
    public var fileName: String { tag + ".json" }
}
