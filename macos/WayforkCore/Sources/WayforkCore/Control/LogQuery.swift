import Foundation

/// `wayforkctl logs` filters (docs/design/09-wayforkctl.md § logs): source, level threshold,
/// case-insensitive substrings, a start time and a tail length. Pure; the CLI only finds the
/// files.
public struct LogQuery: Sendable, Hashable {
    /// Empty: every source. `openvpn` stands for every `openvpn:<id>`.
    public var sources: [String]
    /// Lines at this level or more severe.
    public var level: LogLevel
    /// Every one must occur in the message, case-insensitively.
    public var grep: [String]
    public var since: Date?
    /// The last `tail` matching lines; 0 means no cap.
    public var tail: Int

    public static let defaultTail = 100

    public init(
        sources: [String] = [],
        level: LogLevel = .debug,
        grep: [String] = [],
        since: Date? = nil,
        tail: Int = LogQuery.defaultTail
    ) {
        self.sources = sources
        self.level = level
        self.grep = grep
        self.since = since
        self.tail = tail
    }

    public func matches(_ line: LogLine) -> Bool {
        guard line.level <= level else { return false }
        if let since, line.ts < since { return false }
        if !sources.isEmpty, !sources.contains(where: { Self.source(line.source, matches: $0) }) {
            return false
        }
        return grep.allSatisfy { line.message.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Filters every stream, merges them by timestamp (stable for equal stamps) and keeps
    /// the tail.
    public func run(_ streams: [[LogLine]]) -> [LogLine] {
        var merged: [(index: Int, line: LogLine)] = []
        for stream in streams {
            for line in stream where matches(line) {
                merged.append((merged.count, line))
            }
        }
        merged.sort { ($0.line.ts, $0.index) < ($1.line.ts, $1.index) }
        let lines = merged.map(\.line)
        guard tail > 0, lines.count > tail else { return lines }
        return Array(lines.suffix(tail))
    }

    static func source(_ source: String, matches filter: String) -> Bool {
        let filter = filter.lowercased()
        let source = source.lowercased()
        return source == filter || (filter == "openvpn" && source.hasPrefix("openvpn:"))
    }

    /// `90s`, `15m`, `2h`, `1d` before `now`, or an ISO-8601 timestamp (with or without
    /// fractional seconds). Nil when the text is neither.
    public static func parseSince(_ text: String, now: Date = Date()) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let unit = text.last, let amount = Double(text.dropLast()), amount >= 0 {
            let seconds: Double? =
                switch unit {
                case "s": 1
                case "m": 60
                case "h": 3600
                case "d": 86_400
                default: nil
                }
            if let seconds { return now.addingTimeInterval(-amount * seconds) }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Reads `runtime.log` / `wayfork.log` and, when needed, their rotated siblings, newest file
/// first, stopping as soon as older files cannot contribute.
public enum LogArchive {
    /// Lines of `<name>.log` and `<name>-<stamp>.log` in `directory`, oldest first, that
    /// match `query` — enough of them for `query.tail` (every one when `tail` is 0).
    public static func lines(directory: URL, name: String, query: LogQuery) -> [LogLine] {
        var files = AppLogFile.rotatedFiles(directory: directory, name: name)
        files.append(directory.appendingPathComponent("\(name).log"))
        var chunks: [[LogLine]] = []
        var count = 0
        for file in files.reversed() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parsed = text.split(separator: "\n").compactMap { LogLineFormat.parse(String($0)) }
            let matching = parsed.filter(query.matches)
            chunks.append(matching)
            count += matching.count
            if let since = query.since, let first = parsed.first, first.ts < since { break }
            if query.since == nil, query.tail > 0, count >= query.tail { break }
        }
        return chunks.reversed().flatMap { $0 }
    }
}

/// Replaces configured server addresses in log messages with `server-N` placeholders
/// (numbered in store order). Only exact, whole-token matches: a host inside a longer name
/// or an address inside a longer one stays as it is.
public struct LogRedactor: Sendable {
    private let replacements: [(needle: String, placeholder: String)]

    public init(servers: [String]) {
        var seen: [String: String] = [:]
        var ordered: [(String, String)] = []
        for server in servers {
            let key = server.lowercased()
            guard !key.isEmpty, seen[key] == nil else { continue }
            let placeholder = "server-\(seen.count + 1)"
            seen[key] = placeholder
            ordered.append((key, placeholder))
        }
        // Longest first, so `a.example.com` is replaced before `example.com` could be.
        replacements = ordered.sorted { $0.0.count > $1.0.count }
    }

    /// The addresses of every tunnel's servers, in store order.
    public init(store: Store) {
        self.init(servers: store.tunnels.flatMap(\.kind.serverHosts))
    }

    public var isEmpty: Bool { replacements.isEmpty }

    /// The redacted message and how many addresses were replaced.
    public func redact(_ message: String) -> (String, Int) {
        guard !replacements.isEmpty else { return (message, 0) }
        var result = message
        var count = 0
        for (needle, placeholder) in replacements {
            var searchStart = result.startIndex
            while let range = result.range(
                of: needle, options: .caseInsensitive, range: searchStart..<result.endIndex)
            {
                if Self.isBoundary(result, before: range.lowerBound)
                    && Self.isBoundary(result, after: range.upperBound)
                {
                    let offset = result.distance(from: result.startIndex, to: range.lowerBound)
                    result.replaceSubrange(range, with: placeholder)
                    count += 1
                    searchStart = result.index(
                        result.startIndex, offsetBy: offset + placeholder.count)
                } else {
                    searchStart = range.upperBound
                }
            }
        }
        return (result, count)
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "-"
            || character == "_"
    }

    private static func isBoundary(_ text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        return !isTokenCharacter(text[text.index(before: index)])
    }

    private static func isBoundary(_ text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text[index]
        // A trailing dot ends a sentence, not a name: `server.example.com.` still matches.
        if next == "." {
            let afterDot = text.index(after: index)
            return afterDot == text.endIndex || !isTokenCharacter(text[afterDot])
        }
        return !isTokenCharacter(next)
    }
}
