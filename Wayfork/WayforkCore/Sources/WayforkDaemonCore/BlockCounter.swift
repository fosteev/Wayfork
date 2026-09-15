import Foundation
import WayforkCore

/// `Blocked N today` (F18, docs/design/05-daemon.md, "Block list"): counts sing-box's own
/// log lines for the `block-ads` rule — a `reject` from the route rule or a `predefined`
/// answer from the DNS rule — since local midnight. In memory only; lost with the daemon.
public struct BlockCounter: Sendable, Equatable {
    private var count = 0
    private var day: Date?

    public init() {}

    /// Whether `line` reports one blocked flow or lookup. sing-box prints a rule match as
    /// `match[N] <rule> => <action>`, the rule-set item as `rule_set=<tag>` (inside
    /// `logical(and)[…]` when exceptions exist).
    public static func isBlockedLine(_ line: String) -> Bool {
        line.contains("rule_set=\(SingBoxConfigGenerator.blockListTag)")
            && (line.contains("=> reject") || line.contains("=> predefined"))
    }

    public mutating func record(at date: Date = Date(), calendar: Calendar = .current) {
        rollOver(at: date, calendar: calendar)
        count += 1
    }

    /// The count for the day `date` is in; zero once midnight has passed.
    public mutating func value(at date: Date = Date(), calendar: Calendar = .current) -> Int {
        rollOver(at: date, calendar: calendar)
        return count
    }

    public mutating func reset() {
        count = 0
        day = nil
    }

    private mutating func rollOver(at date: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: date)
        if day != today {
            day = today
            count = 0
        }
    }
}
