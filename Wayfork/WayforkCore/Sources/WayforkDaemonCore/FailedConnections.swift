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

    private var pending: [String: Pending] = [:]
    private var pendingOrder: [String] = []
    private var rows: [String: FailedHost] = [:]

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
                record(id, reason: .blocked, exitOverride: "", at: date)
            } else if target == "predefined",
                rest.contains("rule_set=\(SingBoxConfigGenerator.blockListTag)")
            {
                record(id, reason: .blocked, exitOverride: "", at: date)
            } else if rest.contains("router:") {
                remember(id) { $0.exit = Self.exitID(fromOutboundTag: target) }
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

    public mutating func clear() {
        pending.removeAll()
        pendingOrder.removeAll()
        rows.removeAll()
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
