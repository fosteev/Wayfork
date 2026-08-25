import Foundation

/// How a rule pattern is matched (docs/design/01-data-model.md): against a hostname for
/// the domain kinds, against the connecting process for `app`.
public enum RuleMatch: String, Codable, Sendable, CaseIterable {
    /// `example.com` covers `example.com` and every subdomain.
    case suffix
    /// `api.example.com` covers exactly that host.
    case exact
    /// `*.cdn.example.com`: `*` stands for one or more characters, dots included.
    case wildcard
    /// F10: the pattern is an absolute `.app` bundle path; every process inside the bundle
    /// (helpers included) matches, whatever it talks to.
    case app

    /// The kinds a hostname pattern can take — what the match popup offers.
    public static let domainCases: [RuleMatch] = [.suffix, .exact, .wildcard]

    public var isApp: Bool { self == .app }
}

/// Where a rule sends its traffic (F8): a tunnel, or `direct` for an exception.
public enum RuleTarget: Sendable, Hashable {
    case tunnel(UUID)
    case direct

    public var tunnelID: UUID? {
        if case .tunnel(let id) = self { return id }
        return nil
    }

    public var isDirect: Bool { self == .direct }
}

/// `pattern → target`. Rules are ordered within their group; see `Store.effectiveRules`.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Normalized by `RulePattern.normalize`: lowercase, punycode, no trailing dot for
    /// domains; an absolute bundle path for `match == .app`.
    public var pattern: String
    public var match: RuleMatch
    public var target: RuleTarget
    public var isEnabled: Bool
    public var note: String?

    /// The tunnel this rule routes to; nil for an exception.
    public var tunnelID: UUID? { target.tunnelID }
    /// A Direct rule: carves the pattern out of the default tunnel or a broader rule.
    public var isException: Bool { target.isDirect }
    /// An application rule (F10).
    public var isApp: Bool { match.isApp }

    public init(
        id: UUID = UUID(),
        pattern: String,
        match: RuleMatch = .suffix,
        target: RuleTarget,
        isEnabled: Bool = true,
        note: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.match = match
        self.target = target
        self.isEnabled = isEnabled
        self.note = note
    }

    public init(
        id: UUID = UUID(),
        pattern: String,
        match: RuleMatch = .suffix,
        tunnelID: UUID,
        isEnabled: Bool = true,
        note: String? = nil
    ) {
        self.init(
            id: id, pattern: pattern, match: match, target: .tunnel(tunnelID),
            isEnabled: isEnabled, note: note)
    }

    // MARK: - JSON (schema 1; `"match": "app"` needs schema 2)

    // A tunnel rule carries `tunnelID`; an exception carries `"target": "direct"` and no
    // `tunnelID`. A rule with neither is invalid (docs/design/01-data-model.md, F8).

    private enum CodingKeys: String, CodingKey {
        case id, pattern, match, tunnelID, target, isEnabled, note
    }

    private static let directTargetName = "direct"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        pattern = try container.decode(String.self, forKey: .pattern)
        match = try container.decode(RuleMatch.self, forKey: .match)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        let targetName = try container.decodeIfPresent(String.self, forKey: .target)
        if let targetName {
            guard targetName == Rule.directTargetName else {
                throw DecodingError.dataCorruptedError(
                    forKey: .target, in: container,
                    debugDescription: "unknown rule target \"\(targetName)\"")
            }
            target = .direct
        } else if let tunnelID = try container.decodeIfPresent(UUID.self, forKey: .tunnelID) {
            target = .tunnel(tunnelID)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .tunnelID, in: container,
                debugDescription: "rule needs a tunnelID or target: direct")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(match, forKey: .match)
        switch target {
        case .tunnel(let tunnelID):
            try container.encode(tunnelID, forKey: .tunnelID)
        case .direct:
            try container.encode(Rule.directTargetName, forKey: .target)
        }
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
