import Foundation

/// Rate and total strings for the popover (docs/design/02-ux.md, "Traffic rates"):
/// decimal units, at most three significant digits, fixed formatting so the labels do not
/// jitter — `0 B/s`, `85 KB/s`, `1.2 MB/s`, `12 MB/s`; totals the same without `/s`.
public enum TrafficFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Shown while no sample arrived for `staleAfter` seconds.
    public static let stale = "↓ — ↑ —"
    public static let staleAfter: TimeInterval = 3

    public static func bytes(_ count: UInt64) -> String {
        var value = Double(count)
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 {
            return "\(count) B"
        }
        // One decimal below 10 (1.2 MB), none above (12 MB, 123 MB); 9.95 rounds up to 10.
        let text = value < 9.95 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return "\(text) \(units[unit])"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        let clamped = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        return bytes(UInt64(clamped.rounded())) + "/s"
    }

    /// `↓ 1.2 MB/s ↑ 85 KB/s`, or the stale placeholder for nil.
    public static func rateLabel(_ counters: TrafficCounters?) -> String {
        guard let counters else { return stale }
        return "↓ \(rate(counters.downBytesPerSecond)) ↑ \(rate(counters.upBytesPerSecond))"
    }

    /// Tooltip: `Since Turn On: ↓ 1.2 GB ↑ 88 MB · 14 connections`.
    public static func tooltip(_ counters: TrafficCounters) -> String {
        "Since Turn On: ↓ \(bytes(counters.downTotal)) ↑ \(bytes(counters.upTotal)) · "
            + StatusText.count(counters.connections, "connection")
    }

    public static let staleTooltip = "No traffic sample in the last \(Int(staleAfter)) seconds"

    /// Label of the Direct row: exceptions only when a default tunnel takes the rest (F8).
    public static func directRowTitle(hasDefaultTunnel: Bool) -> String {
        hasDefaultTunnel ? "Direct · exceptions" : "Direct"
    }
}
