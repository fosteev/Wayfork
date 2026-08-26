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
    /// An `ip` rule whose pattern is not an IPv4 address or subnet (F11).
    case invalidIP
    /// A domain rule whose pattern is an IPv4 address — the UI points at the IP match (F11).
    case looksLikeIP
    /// An `ip` rule inside a reserved range (loopback, link-local, multicast, Wayfork's own
    /// fake-IP and TUN ranges) or `/0` (F11).
    case reservedRange
}

/// Normalization, validation and matching of rule patterns (docs/design/01-data-model.md).
public enum RulePattern {
    public static let maxLength = 253
    public static let maxLabelLength = 63

    /// `wildcard` if the input contains `*`, `ip` if it is an IPv4 address or subnet,
    /// otherwise `suffix` — what the UI picks while typing.
    public static func inferMatch(_ raw: String) -> RuleMatch {
        if raw.contains("*") { return .wildcard }
        return ipPrefix(fromInput: raw) != nil ? .ip : .suffix
    }

    /// Ranges an IP rule may not lie inside (F11): unroutable ones plus Wayfork's own. A
    /// wider rule that overlaps one is emitted minus the reserved part.
    public static let reservedRanges: [IPv4Prefix] = [
        "0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
        SingBoxConfigGenerator.fakeIPv4Range, SingBoxConfigGenerator.tunAddress,
    ].compactMap { IPv4Prefix($0) }

    /// The address or subnet in the input, if it is one: `10.8.0.0/24`, `10.8.0.5`,
    /// `http://10.8.0.5:8080/x` (URL parts stripped); nil for anything else.
    public static func ipPrefix(fromInput raw: String) -> IPv4Prefix? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = IPv4Prefix(trimmed) { return prefix }
        // `10.8.0.0/33` is a bad CIDR, not the address `10.8.0.0` with a path.
        if trimmed.contains("/"), !trimmed.contains("://") { return nil }
        return IPv4Prefix(stripURLParts(trimmed))
    }

    /// Turns user input into the stored form: URL parts stripped, lowercased, NFC, IDNA
    /// labels converted to punycode, trailing dot removed. For `app`, a bundle path: a
    /// `file://` URL becomes a path, trailing slashes go, case is kept (F10). For `ip`, the
    /// canonical address or CIDR with host bits cleared (F11). Throws `RulePatternError`.
    public static func normalize(_ raw: String, match: RuleMatch) throws -> String {
        if match == .app { return try normalizeAppPath(raw) }
        if match == .ip { return try normalizeIP(raw) }
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
        case .app, .ip:
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
            // Digits only: an IPv4 address (there is a match kind for those) or a typo.
            throw labels.count == 4 ? RulePatternError.looksLikeIP : .invalidHostname(s)
        }
        let result = labels.joined(separator: ".")
        guard result.count <= maxLength else { throw RulePatternError.tooLong }
        return result
    }

    /// Does `host` (already normalized) fall under the pattern? Never for an `app` or `ip`
    /// rule — those match processes and addresses, not names.
    public static func matches(host: String, pattern: String, match: RuleMatch) -> Bool {
        switch match {
        case .exact:
            return host == pattern
        case .suffix:
            return host == pattern || host.hasSuffix("." + pattern)
        case .wildcard:
            guard let regex = try? Regex(wildcardRegex(pattern)) else { return false }
            return host.wholeMatch(of: regex) != nil
        case .app, .ip:
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

    /// The wildcard covering a host's siblings: `*.example.com` for `gitlab.example.com`.
    /// A two-label host is returned as is (a suffix rule covers it and its subdomains), and
    /// so is a host right under a public second-level suffix (`foo.co.uk`), where dropping
    /// the label would cover half the internet.
    public static func wildcardForSiblings(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 3 else { return host.lowercased() }
        let parent = Array(labels.dropFirst())
        if parent.count == 2, parent[1].count == 2, publicSecondLevelLabels.contains(parent[0]) {
            return host.lowercased()
        }
        return "*." + parent.joined(separator: ".")
    }

    /// Second-level labels that act as public suffixes under two-letter TLDs (`co.uk`,
    /// `com.au`, `ac.jp`); enough for `wildcardForSiblings` without a suffix list.
    static let publicSecondLevelLabels: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "gob", "mil", "info",
    ]

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

    private static func normalizeIP(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RulePatternError.empty }
        guard let prefix = ipPrefix(fromInput: trimmed) else { throw RulePatternError.invalidIP }
        guard prefix.bits > 0, !reservedRanges.contains(where: { $0.contains(prefix) }) else {
            throw RulePatternError.reservedRange
        }
        return prefix.canonical
    }

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
