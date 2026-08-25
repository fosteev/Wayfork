import Foundation

/// Problems the UI shows as chips next to a rule (docs/design/02-ux.md).
public enum RuleIssue: Equatable, Sendable, Hashable {
    /// Same pattern and match as an earlier rule of the same tunnel.
    case duplicate(of: UUID)
    /// Same pattern and match as an active rule under an earlier tunnel; never matches.
    case shadowed(by: UUID)
    /// The rule's tunnel is disabled: the rule is inert.
    case tunnelDisabled
    /// The rule's tunnel no longer exists.
    case tunnelMissing
    /// The pattern covers the server host of a tunnel — its own control traffic would
    /// try to go through a tunnel (docs/design/03-routing.md).
    case coversTunnelServer(tunnelName: String)
}

public enum RuleValidator {
    /// Issues per rule id. Rules without problems are absent from the result.
    public static func validate(_ store: Store) -> [UUID: [RuleIssue]] {
        var issues: [UUID: [RuleIssue]] = [:]
        let tunnelsByID = Dictionary(uniqueKeysWithValues: store.tunnels.map { ($0.id, $0) })
        let tunnelOrder = Dictionary(
            uniqueKeysWithValues: store.tunnels.enumerated().map { ($1.id, $0) })

        // Duplicates within one tunnel: the first occurrence in list order wins.
        var seen: [RuleKey: UUID] = [:]
        var duplicates: Set<UUID> = []
        for rule in store.rules {
            let key = RuleKey(rule, tunnelID: rule.tunnelID)
            if let first = seen[key] {
                issues[rule.id, default: []].append(.duplicate(of: first))
                duplicates.insert(rule.id)
            } else {
                seen[key] = rule.id
            }
        }

        // Shadowing: an active rule with the same pattern and match under an earlier tunnel.
        var firstActive: [RuleKey: (ruleID: UUID, tunnelIndex: Int)] = [:]
        for rule in store.effectiveRules {
            guard rule.isEnabled, !duplicates.contains(rule.id),
                let tunnel = tunnelsByID[rule.tunnelID], tunnel.isEnabled,
                let index = tunnelOrder[rule.tunnelID]
            else { continue }
            let key = RuleKey(rule, tunnelID: nil)
            if let earlier = firstActive[key] {
                if earlier.tunnelIndex < index {
                    issues[rule.id, default: []].append(.shadowed(by: earlier.ruleID))
                }
            } else {
                firstActive[key] = (rule.id, index)
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
            if let tunnel = tunnelsByID[rule.tunnelID] {
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
    }

    /// Rules the routing engine should emit: enabled, tunnel enabled, not shadowed or
    /// duplicated. Grouped by tunnel id, in effective order.
    public static func activeRules(_ store: Store) -> [UUID: [Rule]] {
        let issues = validate(store)
        var result: [UUID: [Rule]] = [:]
        for rule in store.effectiveRules where rule.isEnabled {
            let blocking = issues[rule.id]?.contains { issue in
                switch issue {
                case .duplicate, .shadowed, .tunnelDisabled, .tunnelMissing: true
                case .coversTunnelServer: false
                }
            }
            if blocking != true {
                result[rule.tunnelID, default: []].append(rule)
            }
        }
        return result
    }

    private struct RuleKey: Hashable {
        let pattern: String
        let match: RuleMatch
        let tunnelID: UUID?

        init(_ rule: Rule, tunnelID: UUID?) {
            pattern = rule.pattern
            match = rule.match
            self.tunnelID = tunnelID
        }
    }
}
