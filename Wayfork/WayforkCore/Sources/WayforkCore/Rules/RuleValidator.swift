import Foundation

/// Problems the UI shows as chips next to a rule (docs/design/02-ux.md).
public enum RuleIssue: Equatable, Sendable, Hashable {
    /// Same pattern and match as an earlier rule of the same group.
    case duplicate(of: UUID)
    /// Same pattern and match as an active rule in an earlier group (Direct comes first);
    /// never matches.
    case shadowed(by: UUID)
    /// The rule's tunnel is disabled: the rule is inert.
    case tunnelDisabled
    /// The rule's tunnel no longer exists.
    case tunnelMissing
    /// The pattern covers the server host of a tunnel — its own control traffic would
    /// try to go through a tunnel (docs/design/03-routing.md).
    case coversTunnelServer(tunnelName: String)
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
    public static func validate(_ store: Store) -> [UUID: [RuleIssue]] {
        var issues: [UUID: [RuleIssue]] = [:]
        let tunnelsByID = Dictionary(uniqueKeysWithValues: store.tunnels.map { ($0.id, $0) })
        // Group order for shadowing: Direct first, then tunnels in store order.
        var groupOrder: [RuleTarget: Int] = [.direct: 0]
        for (index, tunnel) in store.tunnels.enumerated() {
            groupOrder[.tunnel(tunnel.id)] = index + 1
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

        // Shadowing: an active rule with the same pattern and match in an earlier group.
        var firstActive: [RuleKey: (ruleID: UUID, group: Int)] = [:]
        for rule in store.effectiveRules {
            guard rule.isEnabled, !duplicates.contains(rule.id), isGroupActive(rule.target),
                let group = groupOrder[rule.target]
            else { continue }
            let key = RuleKey(rule, target: nil)
            if let earlier = firstActive[key] {
                if earlier.group < group {
                    issues[rule.id, default: []].append(.shadowed(by: earlier.ruleID))
                }
            } else {
                firstActive[key] = (rule.id, group)
            }
        }

        let serverHosts = store.tunnels.flatMap { tunnel in
            tunnel.kind.serverHosts.compactMap { host -> (String, String)? in
                guard let normalized = try? RulePattern.normalize(host, match: .exact) else {
                    return nil
                }
                return (normalized, tunnel.name)
            }
        }

        for rule in store.rules {
            guard let tunnelID = rule.tunnelID else { continue }  // exceptions: nothing more
            if let tunnel = tunnelsByID[tunnelID] {
                if !tunnel.isEnabled {
                    issues[rule.id, default: []].append(.tunnelDisabled)
                }
            } else {
                issues[rule.id, default: []].append(.tunnelMissing)
            }
            for (host, name) in serverHosts
            where RulePattern.matches(host: host, pattern: rule.pattern, match: rule.match) {
                issues[rule.id, default: []].append(.coversTunnelServer(tunnelName: name))
            }
        }
        return issues

        func isGroupActive(_ target: RuleTarget) -> Bool {
            switch target {
            case .direct: true
            case .tunnel(let id): tunnelsByID[id]?.isEnabled == true
            }
        }
    }

    /// Tunnel rules the routing engine should emit: enabled, tunnel enabled, not shadowed
    /// or duplicated. Grouped by tunnel id, in effective order.
    public static func activeRules(_ store: Store) -> [UUID: [Rule]] {
        var result: [UUID: [Rule]] = [:]
        for rule in activeRulesInOrder(store) {
            if let tunnelID = rule.tunnelID {
                result[tunnelID, default: []].append(rule)
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
                case .coversTunnelServer: false
                }
            }
            return blocking != true
        }
    }

    private struct RuleKey: Hashable {
        let pattern: String
        let match: RuleMatch
        let target: RuleTarget?

        init(_ rule: Rule, target: RuleTarget?) {
            pattern = rule.pattern
            match = rule.match
            self.target = target
        }
    }
}
