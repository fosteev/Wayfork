import Foundation

/// How a rule pattern is matched against a hostname (docs/design/01-data-model.md).
public enum RuleMatch: String, Codable, Sendable, CaseIterable {
    /// `example.com` covers `example.com` and every subdomain.
    case suffix
    /// `api.example.com` covers exactly that host.
    case exact
    /// `*.cdn.example.com`: `*` stands for one or more characters, dots included.
    case wildcard
}

/// `pattern → tunnel`. Rules are ordered within their tunnel; see `Store.effectiveRules`.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Normalized by `RulePattern.normalize`: lowercase, punycode, no trailing dot.
    public var pattern: String
    public var match: RuleMatch
    public var tunnelID: UUID
    public var isEnabled: Bool
    public var note: String?

    public init(
        id: UUID = UUID(),
        pattern: String,
        match: RuleMatch = .suffix,
        tunnelID: UUID,
        isEnabled: Bool = true,
        note: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.match = match
        self.tunnelID = tunnelID
        self.isEnabled = isEnabled
        self.note = note
    }
}
