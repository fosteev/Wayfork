import Foundation
import WayforkCore

/// Level and milestone detection on sing-box's stdout/stderr
/// (docs/design/06-logging.md, "Sources and levels").
public enum SingBoxLog {
    private static let levels: [(token: String, level: LogLevel)] = [
        ("FATAL", .error), ("PANIC", .error), ("ERROR", .error), ("WARN", .warning),
        ("INFO", .info), ("DEBUG", .debug), ("TRACE", .debug),
    ]

    /// The connection id sing-box prints is ANSI-coloured (`\e[38;5;147m3216874115\e[0m`);
    /// this is the one place that strips it, so every consumer (the app's Logs window,
    /// `runtime.log`, `FailedConnections`, `BlockCounter`) sees plain text.
    private static let ansiEscape = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

    private static func stripANSI(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return ansiEscape.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    /// `+0300 2026-08-25 12:00:00 INFO inbound/tun[tun-in]: started` → `.info`.
    /// Unknown formats (Go panics, plain text) count as `info`.
    public static func level(of line: String) -> LogLevel {
        // The level token sits near the start; scanning a bounded prefix avoids matching
        // words inside the message itself.
        let prefix = stripANSI(line).prefix(48)
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

    /// The inbound whose port another program holds, from sing-box's start failure
    /// (`… initialize inbound/mixed[proxy-t-<id>]: listen tcp 127.0.0.1:1081: bind: address
    /// already in use`); nil for any other line (F17).
    public static func inboundBindFailure(_ line: String) -> String? {
        guard line.contains("address already in use"), let open = line.range(of: "inbound/"),
            let bracket = line[open.upperBound...].firstIndex(of: "["),
            let close = line[bracket...].firstIndex(of: "]")
        else { return nil }
        let tag = line[line.index(after: bracket)..<close]
        return tag.isEmpty ? nil : String(tag)
    }

    /// Removes the timestamp prefix that our own `LogLine.ts` already carries, and strips
    /// the ANSI colour codes sing-box wraps the connection id in.
    public static func message(of line: String) -> String {
        let stripped = stripANSI(line)
        // Format with `timestamp: true`: `<zone> <date> <time> <LEVEL> <message>`.
        let parts = stripped.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count == 5, parts[0].first == "+" || parts[0].first == "-",
            parts[1].count == 10, parts[2].count == 8
        else { return stripped }
        return String(parts[4])
    }
}
