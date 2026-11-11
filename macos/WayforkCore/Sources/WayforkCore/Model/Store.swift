import Foundation

/// Everything the app persists in `store.json`. No secrets (docs/design/01-data-model.md).
public struct Store: Codable, Sendable, Hashable {
    /// 2 since F10: `"match": "app"` rules; the data of schema 1 is unchanged. F16's
    /// `groups` and `groupID` rules are additive without a bump (the F13 forward-only
    /// stance, docs/design/01-data-model.md): a build that predates them reports the
    /// store as corrupt, which only a downgrade can cause. 3 since F23: `Rule.network`;
    /// older data is unchanged. 4 introduces ordered lists and inherited/pinned rows.
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var tunnels: [Tunnel]
    public var lists: [RuleList]
    public var rules: [Rule]
    public var settings: Settings
    /// F8: the tunnel that takes everything no rule matched; nil keeps unmatched traffic
    /// direct. See `effectiveDefaultTunnel`.
    public var defaultTunnelID: UUID?
    /// F16: groups of tunnels; a rule or `defaultTunnelID` may name one.
    public var groups: [TunnelGroup]

    public init(
        schemaVersion: Int = Store.currentSchemaVersion,
        tunnels: [Tunnel] = [],
        rules: [Rule] = [],
        settings: Settings = Settings(),
        defaultTunnelID: UUID? = nil,
        groups: [TunnelGroup] = [],
        lists: [RuleList]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tunnels = tunnels
        self.rules = rules
        self.settings = settings
        self.defaultTunnelID = defaultTunnelID
        self.groups = groups
        self.lists = lists ?? []
        if lists == nil && !rules.isEmpty { self = LegacyListMigration.migrate(self) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tunnels, lists, rules, settings, defaultTunnelID, groups
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw StoreCodec.Error.newerSchema(
                found: schemaVersion, supported: Self.currentSchemaVersion)
        }
        tunnels = try c.decode([Tunnel].self, forKey: .tunnels)
        rules = try c.decode([Rule].self, forKey: .rules)
        settings = try c.decode(Settings.self, forKey: .settings)
        defaultTunnelID = try c.decodeIfPresent(UUID.self, forKey: .defaultTunnelID)
        groups = try c.decodeIfPresent([TunnelGroup].self, forKey: .groups) ?? []
        if schemaVersion >= 4 {
            lists = try c.decode([RuleList].self, forKey: .lists)
            try validateMembership()
        } else {
            lists = []
        }
    }

    /// `groups` is written only when there are any, so a store (and every golden
    /// `input.json`) without groups is byte-identical to one written before F16.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(tunnels, forKey: .tunnels)
        try c.encode(lists, forKey: .lists)
        try c.encode(rules, forKey: .rules)
        try c.encode(settings, forKey: .settings)
        try c.encodeIfPresent(defaultTunnelID, forKey: .defaultTunnelID)
        if !groups.isEmpty { try c.encode(groups, forKey: .groups) }
    }

    public static let empty = Store()

    public func tunnel(id: UUID) -> Tunnel? {
        tunnels.first { $0.id == id }
    }

    public func group(id: UUID) -> TunnelGroup? {
        groups.first { $0.id == id }
    }

    /// The name of a tunnel or group, whichever `id` is.
    public func exitName(id: UUID) -> String? {
        tunnel(id: id)?.name ?? group(id: id)?.name
    }

    /// Rules of one group of tunnels (F16) in their list order.
    public func rules(forGroup groupID: UUID) -> [Rule] {
        rules(for: .group(groupID))
    }

    /// The enabled tunnels among a group's members, in the group's order.
    public func enabledMembers(of group: TunnelGroup) -> [Tunnel] {
        group.members.compactMap { id in tunnels.first { $0.id == id && $0.isEnabled } }
    }

    /// Rules of one group (a tunnel or Direct) in their list order.
    public func rules(for target: RuleTarget) -> [Rule] {
        rules.filter { self.target(for: $0) == target }
    }

    /// Rules of one tunnel in their list order.
    public func rules(for tunnelID: UUID) -> [Rule] {
        rules(for: .tunnel(tunnelID))
    }

    /// Direct rules (F8 exceptions) in list order.
    public var exceptions: [Rule] { rules(for: .direct) }

    /// Frozen schema-3 section order, used only by migration suppression analysis.
    var legacyEffectiveRules: [Rule] {
        var ordered = rules.filter { $0.target == .direct }
        for tunnel in tunnels {
            ordered.append(contentsOf: rules.filter { $0.target == .tunnel(tunnel.id) })
        }
        for group in groups {
            ordered.append(contentsOf: rules.filter { $0.target == .group(group.id) })
        }
        let known = Set(tunnels.map(\.id)).union(groups.map(\.id))
        ordered.append(
            contentsOf: rules.filter { rule in
                guard let exitID = rule.exitID else { return false }
                return !known.contains(exitID)
            })
        return ordered
    }

    public var effectiveRules: [Rule] {
        let ordered = lists.flatMap { list in rules.filter { $0.listID == list.id } }
        return ordered.filter { declaredTarget(for: $0) == .exit(.direct) }
            + ordered.filter { declaredTarget(for: $0) != .exit(.direct) }
    }

    /// Where "everything else" goes (F8, F16): a tunnel or a group, when it exists and is
    /// enabled (a group also needs an enabled member). nil means direct.
    public var effectiveDefaultExit: DefaultExit? {
        guard let id = defaultTunnelID else { return nil }
        if let tunnel = tunnel(id: id) {
            return tunnel.isEnabled ? .tunnel(tunnel) : nil
        }
        if let group = group(id: id), group.isEnabled, !enabledMembers(of: group).isEmpty {
            return .group(group)
        }
        return nil
    }

    /// The default tunnel when it exists and is enabled; nil means unmatched traffic goes
    /// direct. A default without its secret is dropped later by `RuntimePlanBuilder`.
    public var effectiveDefaultTunnel: Tunnel? {
        guard let id = defaultTunnelID, let tunnel = tunnel(id: id), tunnel.isEnabled else {
            return nil
        }
        return tunnel
    }

    /// Lowest free slot for a new tunnel, or nil when all `Tunnel.maxSlots` are taken.
    /// `excluding` lists slots claimed by tunnels not yet appended (a batch import).
    public func nextFreeSlot(excluding: [Int] = []) -> Int? {
        let used = Set(tunnels.map(\.slot)).union(excluding)
        return (0..<Tunnel.maxSlots).first { !used.contains($0) }
    }

    /// Slots still free for new tunnels.
    public var freeSlotCount: Int { max(0, Tunnel.maxSlots - tunnels.count) }

    /// Tunnel and group names share one namespace, compared case-insensitively.
    public func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespaces).lowercased()
        return !tunnels.contains { $0.id != id && $0.name.lowercased() == candidate }
            && !groups.contains { $0.id != id && $0.name.lowercased() == candidate }
    }
}

/// The default exit (F8) once resolved against the store.
public enum DefaultExit: Sendable, Hashable {
    case tunnel(Tunnel)
    case group(TunnelGroup)

    public var id: UUID {
        switch self {
        case .tunnel(let tunnel): tunnel.id
        case .group(let group): group.id
        }
    }

    public var name: String {
        switch self {
        case .tunnel(let tunnel): tunnel.name
        case .group(let group): group.name
        }
    }
}

/// A JSON-level transformation applied to a `store.json` written by an older schema.
public struct StoreMigration: Sendable {
    public let fromVersion: Int
    public let apply: @Sendable (inout [String: Any]) throws -> Void

    public init(fromVersion: Int, apply: @escaping @Sendable (inout [String: Any]) throws -> Void) {
        self.fromVersion = fromVersion
        self.apply = apply
    }
}

/// Encoding/decoding of `store.json` with schema migrations.
public enum StoreCodec {
    public enum Error: Swift.Error, Equatable {
        /// Written by a newer Wayfork; refuse to load rather than lose data.
        case newerSchema(found: Int, supported: Int)
        case invalidDocument
    }

    /// Migrations in order; each bumps `schemaVersion` by one.
    static let migrations: [StoreMigration] = [
        // 1 → 2 (F10): nothing to rewrite — the bump only makes builds that do not know
        // `"match": "app"` refuse the file instead of failing on the first app rule.
        StoreMigration(fromVersion: 1) { _ in },
        // 2 → 3 (F23): nothing to rewrite — a build that predates `network` would send both
        // transports wherever a narrowed rule points, so it must refuse the file.
        StoreMigration(fromVersion: 2) { _ in },
    ]

    public static func encode(_ store: Store) throws -> Data {
        try store.validateMembership()
        return try JSONCoding.prettyEncoder.encode(store)
    }

    public static func decode(_ data: Data) throws -> Store {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidDocument
        }
        var version = object["schemaVersion"] as? Int ?? 1
        if version > Store.currentSchemaVersion {
            throw Error.newerSchema(found: version, supported: Store.currentSchemaVersion)
        }
        while version < min(Store.currentSchemaVersion, 3) {
            guard let migration = migrations.first(where: { $0.fromVersion == version }) else {
                throw Error.invalidDocument
            }
            try migration.apply(&object)
            version += 1
            object["schemaVersion"] = version
        }
        let migrated = try JSONSerialization.data(withJSONObject: object)
        var store = try JSONCoding.decoder.decode(Store.self, from: migrated)
        if version < 4 { store = LegacyListMigration.migrate(store) }
        try store.validateMembership()
        return store
    }
}

/// Shared JSON configuration: ISO 8601 dates, stable key order.
public enum JSONCoding {
    public static var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var compactEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
