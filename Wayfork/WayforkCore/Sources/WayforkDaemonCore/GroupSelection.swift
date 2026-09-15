import Foundation
import WayforkCore

/// Which member a *first live* group should point at (F16, docs/design/05-daemon.md,
/// "Group selection"): the first member in the group's order whose latest probe passed.
public enum GroupSelection {
    /// nil when no member's latest probe succeeded — the selector is then left alone.
    public static func wantedMember(order: [String], samples: [String: LatencySample])
        -> String?
    {
        order.first { samples[$0]?.milliseconds != nil }
    }
}
