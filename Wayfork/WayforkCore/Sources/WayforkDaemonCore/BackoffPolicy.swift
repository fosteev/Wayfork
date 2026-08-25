import Foundation

/// Restart backoff for a supervised process (docs/design/05-daemon.md, "Supervisor").
public struct BackoffPolicy: Sendable, Equatable {
    public static let delays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32),
        .seconds(60),
    ]
    /// Uptime after which a process counts as stable and the attempt counter resets.
    public static let stableUptime: Duration = .seconds(60)

    /// Consecutive failed attempts so far (0 = never failed, or stable since).
    public private(set) var failures = 0

    public init() {}

    /// Registers an exit after `uptime` and returns the delay before the next start.
    /// A process that ran for `stableUptime` or longer restarts from the first delay.
    public mutating func nextDelay(afterUptime uptime: Duration) -> Duration {
        if uptime >= Self.stableUptime { failures = 0 }
        failures += 1
        return Self.delays[min(failures, Self.delays.count) - 1]
    }

    /// The attempt number the next start will carry (`connecting(attempt:)`).
    public var nextAttempt: Int { failures + 1 }

    public mutating func reset() {
        failures = 0
    }
}

/// "3 exits within 60 s" detection for sing-box.
public struct CrashCounter: Sendable, Equatable {
    public let limit: Int
    public let window: TimeInterval
    private var exits: [Date] = []

    public init(limit: Int = 3, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Records an exit; returns true when `limit` exits happened within `window`.
    public mutating func recordExit(at date: Date = Date()) -> Bool {
        exits.append(date)
        exits.removeAll { date.timeIntervalSince($0) > window }
        return exits.count >= limit
    }

    public mutating func reset() {
        exits.removeAll()
    }
}
