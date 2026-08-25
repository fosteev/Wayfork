import Foundation

/// `rule.invalid` reasons (docs/design/02-ux.md, error catalogue).
public enum RulePatternError: Error, Equatable, Sendable {
    case empty
    /// Not a valid hostname; the payload is the offending label.
    case invalidHostname(String)
    case tooLong
    /// `*` in a `suffix` / `exact` rule.
    case wildcardNotAllowed
    /// A `wildcard` rule without `*`.
    case wildcardRequired
    /// An `app` rule whose pattern is not an absolute path ending in `.app` (F10).
    case notAnAppBundle
}

/// Normalization, validation and matching of rule patterns (docs/design/01-data-model.md).
public enum RulePattern {
    public static let maxLength = 253
    public static let maxLabelLength = 63

    /// `wildcard` if the input contains `*`, otherwise `suffix` — what the UI picks while typing.
    public static func inferMatch(_ raw: String) -> RuleMatch {
        raw.contains("*") ? .wildcard : .suffix
    }

    /// Turns user input into the stored form: URL parts stripped, lowercased, NFC, IDNA
    /// labels converted to punycode, trailing dot removed. For `app`, a bundle path: a
    /// `file://` URL becomes a path, trailing slashes go, case is kept (F10). Throws
    /// `RulePatternError`.
    public static func normalize(_ raw: String, match: RuleMatch) throws -> String {
        if match == .app { return try normalizeAppPath(raw) }
        var s = stripURLParts(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        s = s.lowercased().precomposedStringWithCanonicalMapping
        while s.hasSuffix(".") {
            s.removeLast()
        }
        while s.hasPrefix(".") {
            s.removeFirst()
        }
        guard !s.isEmpty else { throw RulePatternError.empty }

        let hasWildcard = s.contains("*")
        switch match {
        case .suffix, .exact:
            if hasWildcard { throw RulePatternError.wildcardNotAllowed }
        case .wildcard:
            if !hasWildcard { throw RulePatternError.wildcardRequired }
        case .app:
            preconditionFailure("handled above")
        }

        var labels: [String] = []
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let ascii = Punycode.toASCII(String(label)) else {
                throw RulePatternError.invalidHostname(String(label))
            }
            try validate(label: ascii, original: String(label))
            labels.append(ascii)
        }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            // Looks like an IPv4 address; IP rules are a Later feature.
            throw RulePatternError.invalidHostname(s)
        }
        let result = labels.joined(separator: ".")
        guard result.count <= maxLength else { throw RulePatternError.tooLong }
        return result
    }

    /// Does `host` (already normalized) fall under the pattern? Never for an `app` rule —
    /// those match processes, not names.
    public static func matches(host: String, pattern: String, match: RuleMatch) -> Bool {
        switch match {
        case .exact:
            return host == pattern
        case .suffix:
            return host == pattern || host.hasSuffix("." + pattern)
        case .wildcard:
            guard let regex = try? Regex(wildcardRegex(pattern)) else { return false }
            return host.wholeMatch(of: regex) != nil
        case .app:
            return false
        }
    }

    /// Regular expression emitted for an app rule (F10): `^` + escaped bundle path + `/`,
    /// so every executable inside the bundle matches and `Foo.app 2` does not.
    public static func appPathRegex(_ path: String) -> String {
        "^" + escapeRegex(path) + "/"
    }

    /// The last path component without `.app` — a display name when the bundle is gone.
    public static func appName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Regular expression emitted for a wildcard pattern, e.g. `^.+\.cdn\.example\.com$`.
    public static func wildcardRegex(_ pattern: String) -> String {
        var out = "^"
        for ch in pattern {
            switch ch {
            case "*": out += ".+"
            case ".": out += "\\."
            case "-": out += "-"
            default: out.append(ch)
            }
        }
        return out + "$"
    }

    // MARK: - Helpers

    private static func normalizeAppPath(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("file://") {
            guard let url = URL(string: s), url.isFileURL else {
                throw RulePatternError.notAnAppBundle
            }
            s = url.path
        }
        while s.count > 1, s.hasSuffix("/") {
            s.removeLast()
        }
        guard !s.isEmpty else { throw RulePatternError.empty }
        guard s.hasPrefix("/"), s.count > 4, s.lowercased().hasSuffix(".app"),
            !s.contains("/../"), !s.contains("/./")
        else { throw RulePatternError.notAnAppBundle }
        return s
    }

    /// Escapes every character that RE2 (and ICU) treat specially.
    static func escapeRegex(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\.+*?()|[]{}^$".contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    /// `https://user@host:443/path?q#f` → `host`. Also handles bare `host:443/path`.
    static func stripURLParts(_ input: String) -> String {
        var s = input
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        if let end = s.firstIndex(where: { "/?#".contains($0) }) {
            s = String(s[..<end])
        }
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber),
            !s.contains("[")
        {
            s = String(s[..<colon])
        }
        return s
    }

    private static func validate(label: String, original: String) throws {
        guard !label.isEmpty, label.count <= maxLabelLength else {
            throw RulePatternError.invalidHostname(original)
        }
        for scalar in label.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9", "-", "*": continue
            default: throw RulePatternError.invalidHostname(original)
            }
        }
        if label.hasPrefix("-") || label.hasSuffix("-") {
            throw RulePatternError.invalidHostname(original)
        }
    }
}
