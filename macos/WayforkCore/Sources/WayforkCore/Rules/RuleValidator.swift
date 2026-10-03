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
    public static func validate(_ store: Store, localNetworks: [LocalNetwork] = [])
        -> [UUID: [RuleIssue]]
    {
        var issues: [UUID: [RuleIssue]] = [:]
        let tunnelsByID = Dictionary(uniqueKeysWithValues: store.tunnels.map { ($0.id, $0) })
        let groupsByID = Dictionary(uniqueKeysWithValues: store.groups.map { ($0.id, $0) })
        // Section order for shadowing: Direct first, then tunnels, then groups (F16), each
        // in store order.
        var groupOrder: [RuleTarget: Int] = [.direct: 0]
        for (index, tunnel) in store.tunnels.enumerated() {
            groupOrder[.tunnel(tunnel.id)] = index + 1
        }
        for (index, group) in store.groups.enumerated() {
            groupOrder[.group(group.id)] = store.tunnels.count + index + 1
        }

        // Duplicates within one group: the first occurrence in list order wins.
        var seen: [RuleKey: UUID] = [:]
        var duplicates: Set<UUID> = []
        for rule in store.rules {
            let key = RuleKey(rule, target: rule.target)
            if let first = seen[key] {
                issues[rule.id, default: []].append(.duplicate(of: first))
                duplicates.insert(rule.id)
            } else {
                seen[key] = rule.id
            }
        }

        // Shadowing: an active rule is shadowed by an earlier one in the effective order
        // with the same pattern and match whose network covers its own (F23). The order is
        // a rank — Direct both 0, Direct narrowed 1, exit narrowed 2, exit both 3 — then the
        // section order; without narrowed rules that is the plain section order.
        struct Candidate {
            let ruleID: UUID
            let network: RuleNetwork?
            let order: [Int]
        }
        var active: [PatternKey: [Candidate]] = [:]
        for rule in store.effectiveRules {
            guard rule.isEnabled, !duplicates.contains(rule.id), isGroupActive(rule.target),
                let group = groupOrder[rule.target]
            else { continue }
            let rank =
                switch (rule.isException, rule.network != nil) {
                case (true, false): 0
                case (true, true): 1
                case (false, true): 2
                case (false, false): 3
                }
            active[PatternKey(rule), default: []].append(
                Candidate(ruleID: rule.id, network: rule.network, order: [rank, group]))
        }
        for candidates in active.values {
            for candidate in candidates {
                let earlier = candidates.first { other in
                    other.ruleID != candidate.ruleID
                        && other.order.lexicographicallyPrecedes(candidate.order)
                        && (other.network == nil || other.network == candidate.network)
                }
                if let earlier {
                    issues[candidate.ruleID, default: []].append(.shadowed(by: earlier.ruleID))
                }
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
            guard let exitID = rule.exitID else { continue }  // exceptions: nothing more
            if let tunnel = tunnelsByID[exitID] {
                if !tunnel.isEnabled {
                    issues[rule.id, default: []].append(.tunnelDisabled)
                }
            } else if let group = groupsByID[exitID] {
                if !group.isEnabled || store.enabledMembers(of: group).isEmpty {
                    issues[rule.id, default: []].append(.tunnelDisabled)
                }
            } else {
                issues[rule.id, default: []].append(.tunnelMissing)
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

        func isGroupActive(_ target: RuleTarget) -> Bool {
            switch target {
            case .direct: true
            case .tunnel(let id): tunnelsByID[id]?.isEnabled == true
            case .group(let id):
                groupsByID[id].map { $0.isEnabled && !store.enabledMembers(of: $0).isEmpty }
                    == true
            }
        }
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
        guard let tunnel = store.tunnel(id: id) else { return .missing }
        guard tunnel.isEnabled else { return .disabled }
        return missingSecrets.contains(id) ? .missingSecret : nil
    }

    private static func activeRulesInOrder(_ store: Store) -> [Rule] {
        let issues = validate(store)
        return store.effectiveRules.filter { rule in
            guard rule.isEnabled else { return false }
            let blocking = issues[rule.id]?.contains { issue in
                switch issue {
                case .duplicate, .shadowed, .tunnelDisabled, .tunnelMissing: true
                case .coversTunnelServer, .coversLocalNetwork: false
                }
            }
            return blocking != true
        }
    }

    private struct RuleKey: Hashable {
        let pattern: String
        let match: RuleMatch
        let network: RuleNetwork?
        let target: RuleTarget

        init(_ rule: Rule, target: RuleTarget) {
            pattern = rule.pattern
            match = rule.match
            network = rule.network
            self.target = target
        }
    }

    private struct PatternKey: Hashable {
        let pattern: String
        let match: RuleMatch

        init(_ rule: Rule) {
            pattern = rule.pattern
            match = rule.match
        }
    }
}
