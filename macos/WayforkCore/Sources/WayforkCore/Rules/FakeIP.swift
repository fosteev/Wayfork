import Foundation

/// Fake IPs (`SingBoxConfigGenerator.fakeIPv4Range`) are names in disguise: sing-box hands
/// one out per name it resolves and routes the connection by that name, so a rule on the
/// address itself can never match (docs/design/03-routing.md). The app remembers which name
/// got which address from sing-box's `dns: exchanged A <name>. <ttl> IN A <address>` lines
/// and turns a pasted fake IP into a wildcard rule for the name's domain
/// (docs/design/02-ux.md, "Rules").
public struct FakeIPIndex: Sendable, Equatable {
    public static let range = IPv4Prefix(SingBoxConfigGenerator.fakeIPv4Range)!
    /// Enough for a long session; the index is rebuilt from the log tail at launch anyway.
    static let capacity = 10_000

    private var names: [String: String] = [:]

    public init() {}

    public var count: Int { names.count }

    /// A single address inside the fake range (no subnet).
    public static func isFakeIP(_ text: String) -> Bool {
        guard let prefix = IPv4Prefix(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            prefix.isHost
        else { return false }
        return range.contains(prefix)
    }

    /// Records the name behind a fake IP from a sing-box log line; other lines are ignored.
    /// Returns whether something was recorded.
    @discardableResult
    public mutating func ingest(_ message: String) -> Bool {
        // Cheap pre-check: every relevant line carries an answer inside 198.18.0.0/15.
        guard message.contains(" IN A 198.1") else { return false }
        guard let match = message.firstMatch(of: FakeIPIndex.answer) else { return false }
        let name = String(match.1).lowercased()
        let address = String(match.2)
        guard !name.isEmpty, FakeIPIndex.isFakeIP(address) else { return false }
        if names.count >= FakeIPIndex.capacity { names.removeAll(keepingCapacity: true) }
        names[address] = name
        return true
    }

    public func name(for address: String) -> String? {
        names[address.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// `dns: exchanged A gitlab.example.com. 600 IN A 198.18.0.118` (the prefix may carry
    /// the connection id and ANSI colours; `cached` answers use the same shape).
    nonisolated(unsafe) private static let answer =
        /dns: (?:exchanged|cached) A (\S+?)\.? \d+ IN A (\d{1,3}(?:\.\d{1,3}){3})\b/
}

public enum FakeIP {
    public enum Translation: Sendable, Equatable {
        /// The fake IP belongs to `name`; `pattern` is the rule to use instead.
        case pattern(String, name: String)
        /// A fake IP whose name the app has not seen in the logs.
        case unknown(String)
    }

    /// What a typed fake IP should become; nil when `input` is not a single fake IP.
    public static func translate(_ input: String, index: FakeIPIndex) -> Translation? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FakeIPIndex.isFakeIP(address) else { return nil }
        guard let name = index.name(for: address) else { return .unknown(address) }
        return .pattern(RulePattern.wildcardForSiblings(of: name), name: name)
    }

    public static func message(forUnknown address: String) -> String {
        "\(address) is a fake IP Wayfork issued to a name it has not logged yet — add the domain instead"
    }
}
