import Foundation
import WayforkCore

/// Ring of the domains that took the default route, fed from every `/connections` sample
/// (docs/design/05-daemon.md, "Recent hosts"). Keyed by host: the newest sighting and the
/// last known process win; the oldest entry goes when the ring is full.
public struct RecentHosts: Sendable, Equatable {
    /// Names that are always direct by the built-in exceptions; never worth a rule.
    static let localSuffixes = [".local", ".lan", ".internal", ".home.arpa", ".localhost"]

    private var entries: [String: RecentHost] = [:]

    public init() {}

    /// Records the connections whose exit is the default route (`defaultExit`, the tunnel
    /// id behind `route.final` or nil for direct) and whose destination is a name.
    public mutating func ingest(
        _ connections: [ClashConnection], defaultExit: TrafficAccumulator.Exit, at now: Date
    ) {
        for connection in connections {
            guard TrafficAccumulator.Exit(chains: connection.chains) == defaultExit else {
                continue
            }
            let host = connection.host.lowercased()
            guard Self.isListable(host) else { continue }
            let exit: String
            switch defaultExit {
            case .direct: exit = "direct"
            case .tunnel(let id): exit = id
            }
            entries[host] = RecentHost(
                host: host,
                processPath: connection.processPath.isEmpty
                    ? entries[host]?.processPath : connection.processPath,
                exit: exit, lastSeen: now)
        }
        if entries.count > RecentHost.capacity {
            let doomed = entries.values.sorted { $0.lastSeen < $1.lastSeen }
                .prefix(entries.count - RecentHost.capacity)
            for entry in doomed { entries.removeValue(forKey: entry.host) }
        }
    }

    /// Newest first.
    public var snapshot: [RecentHost] {
        entries.values.sorted { ($0.lastSeen, $0.host) > ($1.lastSeen, $1.host) }
    }

    /// sing-box restarted or Turn Off: the list starts over.
    public mutating func clear() {
        entries = [:]
    }

    /// A domain, not an address, and not a local name.
    static func isListable(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains("."), host != "localhost" else { return false }
        guard host.rangeOfCharacter(from: Self.digitsAndDots.inverted) != nil else {
            return false  // IPv4 literal
        }
        guard !host.contains(":") else { return false }  // IPv6 literal
        return !localSuffixes.contains { host.hasSuffix($0) }
    }

    private static let digitsAndDots = CharacterSet(charactersIn: "0123456789.")
}
