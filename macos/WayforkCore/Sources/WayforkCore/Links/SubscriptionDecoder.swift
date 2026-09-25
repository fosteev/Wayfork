import Foundation

/// One line of a subscription body after decoding: a link the parser accepted, or a line it
/// did not, with the reason the sheet shows next to it. Line numbers are 1-based and count
/// lines of the decoded text.
public enum SubscriptionEntry: Sendable, Equatable {
    case link(ProxyLink, line: Int, uri: String)
    case skipped(line: Int, reason: String)
}

/// Turns a fetched subscription body into links (docs/design/04-tunnels.md,
/// "Subscriptions"). Pure: no network, no store; `SubscriptionFetcher` brings the body.
public enum SubscriptionDecoder {
    static let schemes = ["vless://", "ss://", "trojan://", "vmess://"]

    /// Plain link lines win; otherwise the whole body is tried as base64 of such lines.
    /// Anything else (YAML, JSON, HTML) is refused. Lines the link parser refuses are
    /// reported per line, never fatal.
    public static func decode(_ body: String) throws -> [SubscriptionEntry] {
        let text = normalized(body)
        guard !text.isEmpty else { throw ProxyLinkError.invalid("subscription is empty") }

        let lines: [String]
        if containsLinkLine(text) {
            lines = text.components(separatedBy: "\n")
        } else if let decoded = decodeBase64Body(text), containsLinkLine(decoded) {
            lines = decoded.components(separatedBy: "\n")
        } else {
            throw ProxyLinkError.invalid("not a list of links")
        }

        var entries: [SubscriptionEntry] = []
        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let number = offset + 1
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            guard let schemeEnd = line.range(of: "://") else {
                entries.append(.skipped(line: number, reason: "not a link"))
                continue
            }
            let scheme = line[..<schemeEnd.upperBound].lowercased()
            guard schemes.contains(scheme) else {
                entries.append(.skipped(line: number, reason: "unsupported scheme \(scheme)"))
                continue
            }
            do {
                entries.append(.link(try ProxyLinkParser.parse(line), line: number, uri: line))
            } catch ProxyLinkError.invalid(let reason) {
                entries.append(.skipped(line: number, reason: reason))
            } catch ProxyLinkError.unsupported(let reason) {
                entries.append(.skipped(line: number, reason: reason))
            }
        }
        return entries
    }

    /// Whether a subscription-looking URL was pasted where a link was expected.
    public static func isURL(_ text: String) -> Bool {
        let lowercased = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://")
    }

    private static func normalized(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsLinkLine(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let lowercased = line.trimmingCharacters(in: .whitespaces).lowercased()
            return schemes.contains { lowercased.hasPrefix($0) }
        }
    }

    /// Standard or URL-safe alphabet, padding optional, whitespace anywhere (exporters wrap
    /// the base64 at 76 columns).
    private static func decodeBase64Body(_ text: String) -> String? {
        var compact = ""
        compact.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            switch scalar {
            case "-": compact.append("+")
            case "_": compact.append("/")
            case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "=":
                compact.unicodeScalars.append(scalar)
            default: return nil
            }
        }
        let unpadded = compact.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard !unpadded.isEmpty, unpadded.count % 4 != 1 else { return nil }
        let padded = unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        return normalized(decoded)
    }
}

extension ProxyLink {
    /// The tunnel kind this link imports as.
    public var tunnelKind: TunnelKind {
        switch self {
        case .vless(let result): .vless(result.meta)
        case .shadowsocks(let result): .shadowsocks(result.meta)
        case .trojan(let result): .trojan(result.meta)
        case .vmess(let result): .vmess(result.meta)
        }
    }

    /// The name from the link's fragment (or `ps`), possibly empty.
    public var name: String {
        switch self {
        case .vless(let result): result.name
        case .shadowsocks(let result): result.name
        case .trojan(let result): result.name
        case .vmess(let result): result.name
        }
    }

    public var server: String {
        switch self {
        case .vless(let result): result.meta.server
        case .shadowsocks(let result): result.meta.server
        case .trojan(let result): result.meta.server
        case .vmess(let result): result.meta.server
        }
    }

    public var port: Int {
        switch self {
        case .vless(let result): result.meta.port
        case .shadowsocks(let result): result.meta.port
        case .trojan(let result): result.meta.port
        case .vmess(let result): result.meta.port
        }
    }
}
