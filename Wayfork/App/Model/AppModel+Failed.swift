import Foundation
import WayforkCore

// Can't reach (F19, docs/design/06-logging.md, "Logs window"): the daemon's rows of
// connections that could not be established, minus what the user dismissed.

extension AppModel {
    /// Rows for the pane, newest first; empty while off.
    var failedHosts: [FailedHost] {
        guard globalState.isRunning, let traffic else { return [] }
        return traffic.failedHosts.filter { !hiddenFailedHosts.contains($0.id) }
    }

    /// Rows younger than `FailedText.recentWindow`, for the popover line.
    var recentFailedCount: Int {
        guard let traffic else { return 0 }
        let cutoff = traffic.sampledAt.addingTimeInterval(-FailedText.recentWindow)
        return failedHosts.filter { $0.lastSeen >= cutoff }.count
    }

    /// When the current engine run started — the pane's `since`.
    var failedSince: Date? {
        if case .running(let since) = status?.engine { return since }
        return nil
    }

    /// The reason in the user's words for one row.
    func failedReason(_ row: FailedHost) -> String {
        let exitName = UUID(uuidString: row.exit).flatMap { store.exitName(id: $0) }
        return FailedText.reason(row.reason, exitName: exitName)
    }

    /// `direct`, the tunnel or group name, or `—` for a blocked lookup.
    func failedVia(_ row: FailedHost) -> String {
        if row.exit.isEmpty { return "—" }
        if row.exit == "direct" { return "direct" }
        return UUID(uuidString: row.exit).flatMap { store.exitName(id: $0) } ?? row.exit
    }

    func hideFailed(_ row: FailedHost) {
        hiddenFailedHosts.insert(row.id)
    }

    /// *Route via* on a row: a suffix rule for the registrable domain, like Recent.
    @discardableResult
    func routeFailed(_ row: FailedHost, via target: RuleTarget) -> String? {
        let pattern = RulePattern.registrableDomain(of: row.host)
        if let message = addRule(pattern: pattern, match: .suffix, target: target) {
            return message
        }
        hideFailed(row)
        return nil
    }

    /// *Never block* on a row whose reason is the list.
    func neverBlockFailed(_ row: FailedHost) {
        let host = row.host.hasSuffix(".") ? String(row.host.dropLast()) : row.host
        if addBlockException(host) == nil { hideFailed(row) }
    }

    /// Whether a row can become a domain rule: a name that reached an outbound (an
    /// address or a blocked lookup cannot).
    func canRouteFailed(_ row: FailedHost) -> Bool {
        !row.exit.isEmpty && row.host.contains(where: \.isLetter)
    }
}
