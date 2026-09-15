import Foundation

/// Which of the daemon's recent hosts (F15) the app shows: within the window, not hidden
/// for the session, and not already covered by an active domain rule — the daemon cannot
/// tell a rule that points at the default tunnel from no rule at all.
public enum RecentFilter {
    public static func visible(
        _ hosts: [RecentHost], sampledAt: Date, window: TimeInterval, hidden: Set<String>,
        store: Store
    ) -> [RecentHost] {
        let cutoff = sampledAt.addingTimeInterval(-window)
        let rules = store.rules.filter { $0.isEnabled && !$0.isApp && $0.match != .ip }
        return hosts.filter { entry in
            entry.lastSeen >= cutoff && !hidden.contains(entry.host)
                && !rules.contains {
                    RulePattern.matches(host: entry.host, pattern: $0.pattern, match: $0.match)
                }
        }
    }
}
