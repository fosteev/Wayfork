import Foundation
import WayforkCore

/// Level and milestone detection on sing-box's stdout/stderr
/// (docs/design/06-logging.md, "Sources and levels").
public enum SingBoxLog {
    private static let levels: [(token: String, level: LogLevel)] = [
        ("FATAL", .error), ("PANIC", .error), ("ERROR", .error), ("WARN", .warning),
        ("INFO", .info), ("DEBUG", .debug), ("TRACE", .debug),
    ]

    /// `+0300 2026-08-25 12:00:00 INFO inbound/tun[tun-in]: started` → `.info`.
    /// Unknown formats (Go panics, plain text) count as `info`.
    public static func level(of line: String) -> LogLevel {
        // The level token sits near the start; scanning a bounded prefix avoids matching
        // words inside the message itself.
        let prefix = line.prefix(48)
        for token in prefix.split(whereSeparator: \.isWhitespace) {
            var word = Substring(token)
            if let bracket = word.firstIndex(of: "[") { word = word[..<bracket] }
            if let match = levels.first(where: { $0.token == word }) {
                return match.level
            }
        }
        return .info
    }

    /// sing-box logs `sing-box started (0.02s)` once every inbound is up.
    public static func isStartedLine(_ line: String) -> Bool {
        line.contains("sing-box started")
    }

    /// Removes the timestamp prefix that our own `LogLine.ts` already carries.
    public static func message(of line: String) -> String {
        // Format with `timestamp: true`: `<zone> <date> <time> <LEVEL> <message>`.
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count == 5, parts[0].first == "+" || parts[0].first == "-",
            parts[1].count == 10, parts[2].count == 8
        else { return line }
        return String(parts[4])
    }
}
