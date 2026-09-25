import Foundation

/// Strings of the Connections view (F20, docs/design/02-ux.md, "Connections by exit").
public enum ExitsText {
    public static let header = "Connections by exit"
    public static let totalLabel = "All exits"
    public static let blockedLabel = "Blocked by your list"
    public static let notCountedAsFailures = "not counted as failures"
    public static let problemsHint = "Connections and the rate need log detail Normal — change it"
    public static let footerTitle = "Connections"
    public static let footerShortcut = "⇧⌘L"

    public enum RateClass { case ok, warn, bad }

    /// `since 14:31 · click an exit to see what failed through it`.
    public static func hint(since: Date?) -> String {
        let tail = "click an exit to see what failed through it"
        guard let since else { return tail }
        return "since \(FailedText.clock(since)) · \(tail)"
    }

    /// `using Home` under a group's name.
    public static func using(_ memberName: String) -> String { "using \(memberName)" }

    /// `no answer · 12 min ago`; nil when the exit has not failed (in the chosen window).
    public static func lastFailure(_ stats: ExitStats, exitName: String?, now: Date) -> String? {
        guard let reason = stats.lastFailure, let at = stats.lastFailedAt else { return nil }
        return
            "\(FailedText.reason(reason, exitName: exitName)) · \(FailedText.lastSeen(at, now: now))"
    }

    /// `0%` / `0.2%` / `100%`.
    public static func rate(_ value: Double) -> String {
        let percent = value * 100
        if percent <= 0 { return "0%" }
        if percent >= 100 { return "100%" }
        return String(format: "%.1f%%", percent)
    }

    /// Grey ≤ 1 %, amber ≤ 5 %, red above.
    public static func rateClass(_ value: Double) -> RateClass {
        if value > 0.05 { return .bad }
        if value > 0.01 { return .warn }
        return .ok
    }

    /// The collapsed table when nothing has gone through any exit yet.
    public static func empty(since: Date?) -> String {
        guard let since else { return "No connections yet." }
        return "No connections since \(FailedText.clock(since)) yet."
    }
}
