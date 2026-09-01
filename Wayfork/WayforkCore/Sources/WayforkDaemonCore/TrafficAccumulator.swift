import Foundation
import WayforkCore

/// Turns the cumulative per-connection counters of consecutive `/connections` samples into
/// per-exit rates and running totals (docs/design/05-daemon.md, "Traffic sampling").
///
/// A connection seen in two consecutive samples contributes `now − previous`; one seen for
/// the first time contributes its full count; one that disappeared contributes nothing (at
/// most a second of a closing connection's bytes is lost). Totals accumulate until `reset`;
/// `restartConnections` forgets the per-connection map for a sing-box restart but keeps
/// the totals.
public struct TrafficAccumulator: Sendable {
    /// Where a connection left: a tunnel (by id) or everything else.
    public enum Exit: Hashable, Sendable {
        case tunnel(String)
        case direct

        /// The first tunnel outbound in the chain wins; `direct`, `block` and DNS outbounds
        /// count as Direct.
        public init(chains: [String]) {
            if let id = chains.lazy.compactMap(Tunnel.tunnelID(fromOutboundTag:)).first {
                self = .tunnel(id)
            } else {
                self = .direct
            }
        }
    }

    private struct Bytes: Sendable {
        var down: UInt64 = 0
        var up: UInt64 = 0

        mutating func add(_ other: Bytes) {
            down &+= other.down
            up &+= other.up
        }
    }

    private struct Seen: Sendable {
        var exit: Exit
        var download: UInt64
        var upload: UInt64
        /// When this connection id was first sampled; the dead-UDP age runs from here (H3).
        var firstSeenAt: Date
    }

    private var totals: [Exit: Bytes] = [:]
    private var previous: [String: Seen] = [:]
    private var lastSampledAt: Date?

    public init() {}

    /// sing-box (re)started at `date`: connection ids and counters start over, totals stay.
    public mutating func restartConnections(at date: Date) {
        previous.removeAll()
        lastSampledAt = date
    }

    /// Turn Off: everything back to zero.
    public mutating func reset() {
        totals.removeAll()
        previous.removeAll()
        lastSampledAt = nil
    }

    public mutating func ingest(_ connections: [ClashConnection], at now: Date) -> TrafficSnapshot {
        let interval = max(0, lastSampledAt.map { now.timeIntervalSince($0) } ?? 0)
        var deltas: [Exit: Bytes] = [:]
        var open: [Exit: Int] = [:]
        var oneWayUDP: [Exit: Int] = [:]
        var current: [String: Seen] = [:]
        for connection in connections {
            let exit = Exit(chains: connection.chains)
            var delta = Bytes(down: connection.download, up: connection.upload)
            var firstSeenAt = now
            if let seen = previous[connection.id], seen.exit == exit {
                // Counters only grow; a smaller value means the id was reused.
                if connection.download >= seen.download, connection.upload >= seen.upload {
                    delta = Bytes(
                        down: connection.download - seen.download,
                        up: connection.upload - seen.upload)
                    firstSeenAt = seen.firstSeenAt
                }
            }
            deltas[exit, default: Bytes()].add(delta)
            open[exit, default: 0] += 1
            // Sent for `oneWayUDPGrace` with nothing back: a one-way UDP flow (H3).
            if connection.network == "udp", connection.upload > 0, connection.download == 0,
                now.timeIntervalSince(firstSeenAt) >= TrafficCounters.oneWayUDPGrace
            {
                oneWayUDP[exit, default: 0] += 1
            }
            current[connection.id] = Seen(
                exit: exit, download: connection.download, upload: connection.upload,
                firstSeenAt: firstSeenAt)
        }
        for (exit, delta) in deltas {
            totals[exit, default: Bytes()].add(delta)
        }
        previous = current
        lastSampledAt = now

        func counters(_ exit: Exit) -> TrafficCounters {
            let total = totals[exit] ?? Bytes()
            let delta = deltas[exit] ?? Bytes()
            return TrafficCounters(
                downBytesPerSecond: interval > 0 ? Double(delta.down) / interval : 0,
                upBytesPerSecond: interval > 0 ? Double(delta.up) / interval : 0,
                downTotal: total.down, upTotal: total.up, connections: open[exit] ?? 0,
                oneWayUDPFlows: oneWayUDP[exit] ?? 0)
        }
        var tunnels: [String: TrafficCounters] = [:]
        for case .tunnel(let id) in Set(totals.keys).union(open.keys) {
            tunnels[id] = counters(.tunnel(id))
        }
        return TrafficSnapshot(
            sampledAt: now, interval: interval, tunnels: tunnels, direct: counters(.direct))
    }
}
