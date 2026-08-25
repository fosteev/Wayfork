import Foundation

/// Everything the app persists in `store.json`. No secrets (docs/design/01-data-model.md).
public struct Store: Codable, Sendable, Hashable {
    /// 2 since F10: `"match": "app"` rules; the data of schema 1 is unchanged.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var tunnels: [Tunnel]
    public var rules: [Rule]
    public var settings: Settings
    /// F8: the tunnel that takes everything no rule matched; nil keeps unmatched traffic
    /// direct. See `effectiveDefaultTunnel`.
    public var defaultTunnelID: UUID?

    public init(
        schemaVersion: Int = Store.currentSchemaVersion,
        tunnels: [Tunnel] = [],
        rules: [Rule] = [],
        settings: Settings = Settings(),
        defaultTunnelID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tunnels = tunnels
        self.rules = rules
        self.settings = settings
        self.defaultTunnelID = defaultTunnelID
    }

    public static let empty = Store()

    public func tunnel(id: UUID) -> Tunnel? {
        tunnels.first { $0.id == id }
    }

    /// Rules of one group (a tunnel or Direct) in their list order.
    public func rules(for target: RuleTarget) -> [Rule] {
        rules.filter { $0.target == target }
    }

    /// Rules of one tunnel in their list order.
    public func rules(for tunnelID: UUID) -> [Rule] {
        rules(for: .tunnel(tunnelID))
    }

    /// Direct rules (F8 exceptions) in list order.
    public var exceptions: [Rule] { rules(for: .direct) }

    /// Rules in matching order: the Direct group first (exceptions always win), then tunnels
    /// in store order, each group's rules in list order. Rules pointing at a tunnel that no
    /// longer exists come last, in list order.
    public var effectiveRules: [Rule] {
        var ordered = exceptions
        for tunnel in tunnels {
            ordered.append(contentsOf: rules(for: tunnel.id))
        }
        let known = Set(tunnels.map(\.id))
        ordered.append(
            contentsOf: rules.filter { rule in
                guard let tunnelID = rule.tunnelID else { return false }
                return !known.contains(tunnelID)
            })
        return ordered
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
    public func nextFreeSlot() -> Int? {
        let used = Set(tunnels.map(\.slot))
        return (0..<Tunnel.maxSlots).first { !used.contains($0) }
    }

    /// Tunnel names are compared case-insensitively for uniqueness.
    public func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespaces).lowercased()
        return !tunnels.contains { $0.id != id && $0.name.lowercased() == candidate }
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
        StoreMigration(fromVersion: 1) { _ in }
    ]

    public static func encode(_ store: Store) throws -> Data {
        try JSONCoding.prettyEncoder.encode(store)
    }

    public static func decode(_ data: Data) throws -> Store {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidDocument
        }
        var version = object["schemaVersion"] as? Int ?? 1
        if version > Store.currentSchemaVersion {
            throw Error.newerSchema(found: version, supported: Store.currentSchemaVersion)
        }
        while version < Store.currentSchemaVersion {
            guard let migration = migrations.first(where: { $0.fromVersion == version }) else {
                throw Error.invalidDocument
            }
            try migration.apply(&object)
            version += 1
            object["schemaVersion"] = version
        }
        let migrated = try JSONSerialization.data(withJSONObject: object)
        return try JSONCoding.decoder.decode(Store.self, from: migrated)
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
