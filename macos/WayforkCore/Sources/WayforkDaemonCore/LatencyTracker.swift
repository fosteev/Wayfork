import Foundation
import WayforkCore

/// Per-tunnel probe history behind the daemon's `LatencyProber` (docs/design/05-daemon.md,
/// "Tunnel latency"): pure bookkeeping, so the rounds themselves stay a thin loop.
public struct LatencyTracker: Sendable, Equatable {
    public enum Transition: Sendable, Equatable {
        case becameUnreachable(tunnel: String, failures: Int)
        case recovered(tunnel: String, milliseconds: Int)
    }

    public private(set) var samples: [String: LatencySample] = [:]

    public init() {}

    /// Records one probe; returns the state change it caused, if any.
    @discardableResult
    public mutating func record(
        tunnel: String, milliseconds: Int?, at now: Date
    ) -> Transition? {
        var sample = samples[tunnel] ?? LatencySample()
        let wasUnreachable = sample.unreachable
        sample.history.append(milliseconds)
        if sample.history.count > LatencyProbe.historyLength {
            sample.history.removeFirst(sample.history.count - LatencyProbe.historyLength)
        }
        sample.milliseconds = milliseconds
        if let milliseconds {
            sample.failedInARow = 0
            sample.lastSuccess = now
        } else {
            sample.failedInARow += 1
        }
        sample.unreachable = sample.failedInARow >= LatencyProbe.failureThreshold
        samples[tunnel] = sample
        if sample.unreachable, !wasUnreachable {
            return .becameUnreachable(tunnel: tunnel, failures: sample.failedInARow)
        }
        if wasUnreachable, let milliseconds {
            return .recovered(tunnel: tunnel, milliseconds: milliseconds)
        }
        return nil
    }

    /// Retry / reconnect from the card: the streak starts over so the next round decides.
    public mutating func resetStreak(tunnel: String) {
        guard var sample = samples[tunnel] else { return }
        sample.failedInARow = 0
        sample.unreachable = false
        samples[tunnel] = sample
    }

    /// Drops tunnels that left the plan.
    public mutating func retain(tunnels: Set<String>) {
        samples = samples.filter { tunnels.contains($0.key) }
    }

    /// sing-box restarted or Turn Off: histories start over.
    public mutating func clear() {
        samples = [:]
    }
}
