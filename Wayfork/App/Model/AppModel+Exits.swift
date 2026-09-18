import Foundation
import WayforkCore

// Connections by exit (F20, docs/design/06-logging.md, "Logs window › Connections
// view"): the daemon only ever sends cumulative counters since Turn On
// (`TrafficSnapshot.exits`), so the app keeps a short ring of samples to answer *Last 5
// min* and a baseline to answer *Reset* — both windows read the same cumulative wire
// data, never a fresh protocol round trip.

extension AppModel {
    /// `Since Turn On` (from the daemon's counters, offset by the last `Reset`) or `Last 5
    /// min` (subtracted from the ring).
    enum ExitsWindow: String, CaseIterable {
        case sinceTurnOn = "Since Turn On"
        case last5Min = "Last 5 min"
    }

    /// One row of the Connections table.
    struct ExitRow: Identifiable {
        enum Kind: Equatable { case tunnel, group, direct, blocked }

        let id: String
        let kind: Kind
        let name: String
        let isDefault: Bool
        /// `using <member>` under a group's name.
        let usingMember: String?
        /// nil renders `—` (log detail *Problems*, or the blocked row).
        let connections: Int?
        let reached: Int?
        let failed: Int
        let rate: Double?
        let lastFailureText: String?
        let isError: Bool
    }

    struct ExitsTotals {
        let connections: Int
        let reached: Int
        let failed: Int
        let rate: Double?
    }

    private static let ringWindow: TimeInterval = FailedText.recentWindow

    /// Rows for the table, in the fixed order: tunnels in the popover's order, groups
    /// after their members, *Not via any tunnel*, then the dimmed *Blocked by your list*
    /// row last.
    func exitRows(window: ExitsWindow) -> [ExitRow] {
        guard globalState.isRunning else { return [] }
        var rows: [ExitRow] = []
        for tunnel in store.tunnels.filter(\.isEnabled) {
            let id = tunnel.id.uuidString.lowercased()
            rows.append(
                exitRow(
                    id: id, kind: .tunnel, name: tunnel.name,
                    isDefault: card(for: tunnel).isDefault,
                    usingMember: nil, window: window))
        }
        for group in store.groups.filter(\.isEnabled) {
            let id = group.id.uuidString.lowercased()
            let usingMember = traffic?.groups[id]?.activeMember
                .flatMap { memberID in UUID(uuidString: memberID).flatMap(store.exitName(id:)) }
            rows.append(
                exitRow(
                    id: id, kind: .group, name: group.name,
                    isDefault: groupCard(for: group).isDefault,
                    usingMember: usingMember, window: window))
        }
        rows.append(
            exitRow(
                id: "direct", kind: .direct, name: "Not via any tunnel", isDefault: false,
                usingMember: nil, window: window))
        let blockedStats = effectiveStats(for: "direct", window: window)
        rows.append(
            ExitRow(
                id: "blocked", kind: .blocked, name: "Blocked by your list", isDefault: false,
                usingMember: nil, connections: nil, reached: nil, failed: blockedStats.blocked,
                rate: nil, lastFailureText: nil, isError: false))
        return rows
    }

    /// The bottom total row, blocked excluded.
    func exitsTotals(window: ExitsWindow) -> ExitsTotals {
        let rows = exitRows(window: window).filter { $0.kind != .blocked }
        let connections = rows.compactMap(\.connections).reduce(0, +)
        let reached = rows.compactMap(\.reached).reduce(0, +)
        let failed = rows.reduce(0) { $0 + $1.failed }
        let anyOpenedKnown = rows.contains { $0.connections != nil }
        return ExitsTotals(
            connections: connections, reached: reached, failed: failed,
            rate: anyOpenedKnown && connections > 0
                ? min(1, Double(failed) / Double(connections)) : nil)
    }

    /// Whether `opened` is unavailable — sing-box's log level is above *Normal*: no match
    /// line has been seen since the last `clear()`, or nothing has been seen yet and the
    /// setting says the lines will not come (the F19 pane's check).
    var exitsNeedNormalLogLevel: Bool {
        if let traffic, !traffic.exits.isEmpty {
            return traffic.exits.values.allSatisfy { $0.opened == nil }
        }
        return settings.logLevel != .info && settings.logLevel != .debug
    }

    /// When the window in `.sinceTurnOn` started: the last `Reset`, or Turn On.
    var exitsSince: Date? {
        exitsResetAt ?? failedSince
    }

    /// F19 rows that went through one exit, for the expanded section under a row.
    func failedHosts(forExit id: String) -> [FailedHost] {
        let exit = id == "blocked" ? "" : id
        return failedHosts.filter { $0.exit == exit }
    }

    /// *Reset* on the Connections view: the counters read zero from here on, in
    /// `.sinceTurnOn`; `.last5Min` is unaffected (it is already a short window).
    func resetExits() {
        exitsBaseline = traffic?.exits ?? [:]
        exitsResetAt = Date()
    }

    /// Whether a tunnel's or group's exit failed at least once in the last 5 minutes —
    /// the popover card's *Details* link.
    func exitHasRecentFailures(id: UUID) -> Bool {
        effectiveStats(for: id.uuidString.lowercased(), window: .last5Min).failed > 0
    }

    // MARK: - Sampling

    /// Fed from every traffic snapshot; trimmed to a bit over `ringWindow`.
    func recordExitsSample(_ snapshot: TrafficSnapshot) {
        exitsRing.append((snapshot.sampledAt, snapshot.exits))
        let cutoff = snapshot.sampledAt.addingTimeInterval(-Self.ringWindow * 1.2)
        while exitsRing.count > 1, exitsRing[1].0 < cutoff {
            exitsRing.removeFirst()
        }
    }

    /// Turn On: the daemon's counters start over, so does the app's tracking of them.
    func resetExitsTracking() {
        exitsRing.removeAll()
        exitsBaseline = nil
        exitsResetAt = nil
    }

    // MARK: - Pieces

    private func exitRow(
        id: String, kind: ExitRow.Kind, name: String, isDefault: Bool, usingMember: String?,
        window: ExitsWindow
    ) -> ExitRow {
        let stats = effectiveStats(for: id, window: window)
        let connections = stats.opened
        let reached = connections.map { max(0, $0 - stats.failed) }
        // Clamped: an error without its match line (log detail switched mid-run) can put
        // failed above opened.
        let rate = connections.flatMap { $0 > 0 ? min(1, Double(stats.failed) / Double($0)) : 0 }
        let exitName = UUID(uuidString: id).flatMap(store.exitName(id:)) ?? name
        let lastFailureText = ExitsText.lastFailure(
            stats, exitName: exitName, now: traffic?.sampledAt ?? Date())
        return ExitRow(
            id: id, kind: kind, name: name, isDefault: isDefault, usingMember: usingMember,
            connections: connections, reached: reached, failed: stats.failed, rate: rate,
            lastFailureText: lastFailureText, isError: stats.failed > 0)
    }

    /// The counters for one exit under the chosen window: `.sinceTurnOn` offset by the
    /// last `Reset`, `.last5Min` subtracted from the ring.
    private func effectiveStats(for id: String, window: ExitsWindow) -> ExitStats {
        let current = traffic?.exits[id] ?? ExitStats()
        switch window {
        case .sinceTurnOn:
            guard let baseline = exitsBaseline?[id] else { return current }
            return ExitStats(
                opened: subtract(current.opened, baseline.opened),
                failed: max(0, current.failed - baseline.failed),
                blocked: max(0, current.blocked - baseline.blocked),
                lastFailure: current.lastFailure, lastFailedAt: current.lastFailedAt)
        case .last5Min:
            guard let now = traffic?.sampledAt else { return current }
            let cutoff = now.addingTimeInterval(-Self.ringWindow)
            let old = exitsRing.first { $0.0 >= cutoff }?.1[id] ?? exitsRing.first?.1[id]
            guard let old else { return current }
            let recentFailure =
                current.lastFailedAt.map { $0 >= cutoff } ?? false
            return ExitStats(
                opened: subtract(current.opened, old.opened),
                failed: max(0, current.failed - old.failed),
                blocked: max(0, current.blocked - old.blocked),
                lastFailure: recentFailure ? current.lastFailure : nil,
                lastFailedAt: recentFailure ? current.lastFailedAt : nil)
        }
    }

    private func subtract(_ current: Int?, _ baseline: Int?) -> Int? {
        guard let current else { return nil }
        return max(0, current - (baseline ?? 0))
    }
}
