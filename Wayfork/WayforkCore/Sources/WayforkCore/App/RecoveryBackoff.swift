import Foundation

/// How long the app waits before re-applying after the routing engine failed (H2,
/// docs/design/05-daemon.md, "Engine failure recovery"). `failed` is terminal for the
/// daemon, so recovery is the app's job: it keeps trying for as long as the user wants
/// routing on, slowing down but never giving up — the cause is usually another VPN or an
/// adapter that comes back on its own.
public struct RecoveryBackoff: Sendable, Equatable {
    /// Delay before attempt 1, 2, 3 …; the last one repeats.
    public static let delays: [Duration] = [
        .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300),
    ]

    /// Failures in the current streak (0 = the engine is up, or was never seen failing).
    public private(set) var failures = 0

    public init() {}

    /// Registers one more failure and returns how long to wait before re-applying.
    public mutating func nextDelay() -> Duration {
        failures += 1
        return Self.delays[min(failures, Self.delays.count) - 1]
    }

    /// A streak is running: the failure has been reported and retries are under way.
    public var isRecovering: Bool { failures > 0 }

    public mutating func reset() {
        failures = 0
    }
}
