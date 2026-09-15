import Foundation

/// Strings of the *Can't reach* pane and the popover line (F19, docs/design/02-ux.md,
/// "Can't reach").
public enum FailedText {
    /// How far back the popover line looks.
    public static let recentWindow: TimeInterval = 300

    /// The reason in the user's words; `exitName` names the tunnel for *‹tunnel› is down*.
    public static func reason(_ reason: FailureReason, exitName: String?) -> String {
        switch reason {
        case .noAnswer: "no answer"
        case .refused: "refused"
        case .reset: "reset"
        case .noSuchName: "no such name"
        case .blocked: "blocked by your list"
        case .tunnelDown: "\(exitName ?? "the tunnel") is down"
        case .other: "failed"
        }
    }

    /// The raw error for the tooltip of *failed*; nil for the classified reasons.
    public static func detail(_ reason: FailureReason) -> String? {
        if case .other(let text) = reason { return text.isEmpty ? nil : text }
        return nil
    }

    /// `×14`.
    public static func tries(_ count: Int) -> String { "×\(count)" }

    /// `12 s ago` / `3 min ago` / `14:02` (older than an hour).
    public static func lastSeen(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
    }

    /// `4 sites since 14:31 — click a row to see its log lines`.
    public static func header(count: Int, since: Date?, appsUnknown: Bool) -> String {
        var text = "\(StatusText.count(count, "site"))"
        if let since { text += " since \(clock(since))" }
        text +=
            appsUnknown
            ? " — which app needs log detail Normal" : " — click a row to see its log lines"
        return text
    }

    /// The collapsed strip when nothing failed.
    public static func empty(since: Date?) -> String {
        guard let since else { return "Every site your apps tried could be reached." }
        return "Every site your apps tried since \(clock(since)) could be reached."
    }

    /// `Showing lines for cdn.example.net · 14 tries, all no answer · went direct`.
    public static func showing(host: String, tries: Int, reason: String, via: String) -> String {
        "Showing lines for \(host) · \(tries == 1 ? "1 try" : "\(tries) tries"), all \(reason) · went \(via)"
    }

    /// `3 sites can't be reached`.
    public static func popoverLine(count: Int) -> String {
        "\(StatusText.count(count, "site")) can't be reached"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
