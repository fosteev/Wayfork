import Foundation

/// Colour band of a latency figure (docs/design/02-ux.md, "Variant C": green ≤ 100 ms,
/// amber ≤ 300 ms, red above).
public enum LatencyBand: Sendable, Hashable {
    case good, fair, poor

    public init(milliseconds: Int) {
        switch milliseconds {
        case ...100: self = .good
        case ...300: self = .fair
        default: self = .poor
        }
    }
}

/// Strings for the latency figure and its tooltip (F14).
public enum LatencyFormat {
    /// `62 ms`.
    public static func label(_ milliseconds: Int) -> String { "\(milliseconds) ms" }

    /// `Measured through the tunnel every 10 s · last 2 min: min 58, max 71 ms`.
    public static func tooltip(_ sample: LatencySample) -> String {
        var text = "Measured through the tunnel every \(Int(LatencyProbe.interval)) s"
        let values = sample.history.compactMap { $0 }
        if let low = values.min(), let high = values.max() {
            let window = Int(LatencyProbe.interval) * LatencyProbe.historyLength / 60
            text += " · last \(window) min: min \(low), max \(high) ms"
        }
        return text
    }

    /// `No answer through the tunnel for 2 min` — since the last success, or since the
    /// first failed probe when there never was one.
    public static func unreachableDetail(_ sample: LatencySample, now: Date) -> String {
        let seconds: Int
        if let last = sample.lastSuccess {
            seconds = max(0, Int(now.timeIntervalSince(last)))
        } else {
            seconds = sample.failedInARow * Int(LatencyProbe.interval)
        }
        return "No answer through the tunnel for \(duration(seconds))"
    }

    /// `30 s`, `2 min`, `1 h 05 min`.
    public static func duration(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) s"
        case ..<3600: "\(seconds / 60) min"
        default: String(format: "%d h %02d min", seconds / 3600, seconds % 3600 / 60)
        }
    }
}
