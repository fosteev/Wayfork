import Foundation
import WayforkCore

/// Connections that could not be established, aggregated by site + app from sing-box's own
/// log lines (F19, docs/design/05-daemon.md, "Failed connections"). sing-box tells one
/// connection's story under one id (`[3921 5004ms]`): the destination, the sniffed
/// domain, the process, the chosen outbound and — when it fails — an `ERROR` line. The
/// tracker joins those by id and keeps one row per `(host, processPath)`.
public struct FailedConnections: Sendable, Equatable {
    /// Ids remembered for the join; the oldest are forgotten first.
    public static let idCapacity = 2000

    private struct Pending: Sendable, Equatable {
        var host: String?
        var processPath: String?
        var exit: String?
    }

    private struct LastFailure: Sendable, Equatable {
        var reason: FailureReason
        var at: Date
    }

    private var pending: [String: Pending] = [:]
    private var pendingOrder: [String] = []
    private var rows: [String: FailedHost] = [:]

    // MARK: - Counters by exit (F20)

    /// Connections opened per exit, once per connection id, at the match/`using` line.
    private var openedCounts: [String: Int] = [:]
    /// Connections that failed per exit, at the `ERROR` line (blocked excluded).
    private var failedCounts: [String: Int] = [:]
    /// `=> reject` / `=> predefined` on the block list; always attributed to `direct`.
    private var blockedCount = 0
    private var lastFailureByExit: [String: LastFailure] = [:]
    /// Whether a `match`/`using` line has been seen since the last `clear()` — while
    /// false, `opened` stays nil for every exit (log detail *Problems*).
    private var sawMatchLine = false

    public init() {}

    /// Cheap pre-filter for the engine's relay: lines that can never matter are skipped
    /// before an actor hop.
    public static func isInteresting(_ message: String) -> Bool {
        guard message.first == "[" else { return false }
        return message.contains("connection to ") || message.contains("found process path")
            || message.contains(" => ") || message.contains("sniffed")
            || message.contains("dns: exchange ")
            || message.contains("using ")
    }

    /// Feeds one line (the message after the timestamp, i.e. `SingBoxLog.message(of:)`,
    /// with the level still in front or not — both shapes are accepted).
    public mutating func ingest(_ line: String, level: LogLevel, at date: Date = Date()) {
        guard let (id, rest) = Self.split(line) else { return }
        if let host = Self.value(after: "inbound connection to ", in: rest)
            ?? Self.value(after: "inbound packet connection to ", in: rest)
        {
            remember(id) { $0.host = Self.stripPort(host) }
        } else if let domain = Self.value(after: "domain: ", in: rest), rest.contains("sniffed") {
            remember(id) { $0.host = domain }
        } else if let path = Self.value(after: "found process path: ", in: rest) {
            remember(id) { $0.processPath = path }
        } else if let name = Self.value(after: "dns: exchange ", in: rest) {
            remember(id) { $0.host = name.split(separator: " ").first.map(String.init) }
        } else if let target = Self.value(after: " => ", in: rest)
            ?? Self.value(after: "using ", in: rest)
        {
            if target == "reject", rest.contains("rule_set=\(SingBoxConfigGenerator.blockListTag)")
            {
                sawMatchLine = true
                record(id, reason: .blocked, exitOverride: "", at: date)
            } else if target == "predefined",
                rest.contains("rule_set=\(SingBoxConfigGenerator.blockListTag)")
            {
                sawMatchLine = true
                record(id, reason: .blocked, exitOverride: "", at: date)
            } else if rest.contains("router:") {
                sawMatchLine = true
                let exit = Self.exitID(fromOutboundTag: target)
                // Opened counts once per connection id, at the first match/`using` line.
                if pending[id]?.exit == nil { openedCounts[exit, default: 0] += 1 }
                remember(id) { $0.exit = exit }
            }
        } else if level == .error,
            let failure = Self.value(after: "open connection to ", in: rest)
                ?? Self.value(after: "open packet connection to ", in: rest)
        {
            // `host:443: dial tcp 203.0.113.9:443: i/o timeout` — host:port up to the first
            // `: `, the error after it.
            let hostPort: String
            let error: String
            if let cut = failure.range(of: ": ") {
                hostPort = String(failure[..<cut.lowerBound])
                error = String(failure[cut.upperBound...])
            } else {
                hostPort = failure
                error = ""
            }
            remember(id) { if $0.host == nil { $0.host = Self.stripPort(hostPort) } }
            record(id, reason: Self.classify(error, exit: pending[id]?.exit), at: date)
        }
    }

    /// Rows newest first, at most `FailedHost.capacity`.
    public var snapshot: [FailedHost] {
        rows.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Per-exit counters since the last `clear()` (F20), keyed by exit id (`direct`, a
    /// tunnel id, a group id).
    public var exits: [String: ExitStats] {
        var ids = Set(openedCounts.keys).union(failedCounts.keys).union(lastFailureByExit.keys)
        if blockedCount > 0 { ids.insert("direct") }
        var result: [String: ExitStats] = [:]
        for id in ids {
            var stats = ExitStats(opened: sawMatchLine ? (openedCounts[id] ?? 0) : nil)
            stats.failed = failedCounts[id] ?? 0
            if id == "direct" { stats.blocked = blockedCount }
            if let last = lastFailureByExit[id] {
                stats.lastFailure = last.reason
                stats.lastFailedAt = last.at
            }
            result[id] = stats
        }
        return result
    }

    public mutating func clear() {
        pending.removeAll()
        pendingOrder.removeAll()
        rows.removeAll()
        openedCounts.removeAll()
        failedCounts.removeAll()
        blockedCount = 0
        lastFailureByExit.removeAll()
        sawMatchLine = false
    }

    // MARK: - Pieces

    /// `[3921 5004ms] inbound/tun[tun-in]: …` → (`3921`, the rest); the level token in
    /// front (`ERROR [3921 …`) is skipped.
    static func split(_ line: String) -> (String, String)? {
        guard let open = line.firstIndex(of: "["), line[..<open].count <= 8,
            let close = line[open...].firstIndex(of: "]")
        else { return nil }
        let inside = line[line.index(after: open)..<close]
        guard let id = inside.split(separator: " ").first, id.allSatisfy(\.isNumber) else {
            return nil
        }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (String(id), rest)
    }

    static func value(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `host:443` → `host`; an IPv6 literal keeps its brackets' contents.
    static func stripPort(_ hostPort: String) -> String {
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            return String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
        }
        guard let colon = hostPort.lastIndex(of: ":"),
            hostPort[..<colon].contains(".") || !hostPort[..<colon].contains(":")
        else { return hostPort }
        return String(hostPort[..<colon])
    }

    static func exitID(fromOutboundTag tag: String) -> String {
        Tunnel.tunnelID(fromOutboundTag: tag) ?? TunnelGroup.groupID(fromOutboundTag: tag) ?? tag
    }

    static func classify(_ error: String, exit: String?) -> FailureReason {
        let text = error.lowercased()
        if text.contains("i/o timeout") || text.contains("timeout") { return .noAnswer }
        if text.contains("connection refused") { return .refused }
        if text.contains("connection reset") { return .reset }
        if text.contains("no such host") || text.contains("nxdomain") || text.contains("lookup") {
            return .noSuchName
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return exit == nil || exit == "direct" ? .other(error) : .tunnelDown
        }
        return .other(error)
    }

    private mutating func remember(_ id: String, _ mutate: (inout Pending) -> Void) {
        if pending[id] == nil {
            pending[id] = Pending()
            pendingOrder.append(id)
            if pendingOrder.count > Self.idCapacity {
                let oldest = pendingOrder.removeFirst()
                pending[oldest] = nil
            }
        }
        mutate(&pending[id]!)
    }

    private mutating func record(
        _ id: String, reason: FailureReason, exitOverride: String? = nil, at date: Date
    ) {
        guard let info = pending[id], let host = info.host else { return }
        let exit = exitOverride ?? info.exit ?? "direct"
        if reason == .blocked {
            blockedCount += 1
        } else {
            failedCounts[exit, default: 0] += 1
            lastFailureByExit[exit] = LastFailure(reason: reason, at: date)
        }
        let key = "\(host)|\(info.processPath ?? "")"
        if var row = rows[key] {
            row.count += 1
            row.lastSeen = date
            row.reason = reason
            row.exit = exit
            rows[key] = row
        } else {
            rows[key] = FailedHost(
                host: host, processPath: info.processPath, exit: exit, reason: reason,
                lastSeen: date)
            if rows.count > FailedHost.capacity,
                let oldest = rows.min(by: { $0.value.lastSeen < $1.value.lastSeen })
            {
                rows[oldest.key] = nil
            }
        }
        // One failure per connection: the id is done.
        pending[id] = nil
    }
}
