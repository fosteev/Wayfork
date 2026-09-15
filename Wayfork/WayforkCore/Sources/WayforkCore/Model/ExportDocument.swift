import Foundation

/// OpenVPN username/password. Crosses into the daemon over XPC; never written to disk.
public struct Credentials: Codable, Sendable, Hashable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Secrets of one tunnel as they appear in an export file; nil when not included.
public struct TunnelSecrets: Codable, Sendable, Hashable {
    public var ovpn: String?
    public var credentials: Credentials?
    public var keyPassphrase: String?
    public var uuid: String?
    public var password: String?
    public var privateKey: String?
    public var presharedKey: String?

    public init(
        ovpn: String? = nil,
        credentials: Credentials? = nil,
        keyPassphrase: String? = nil,
        uuid: String? = nil,
        password: String? = nil,
        privateKey: String? = nil,
        presharedKey: String? = nil
    ) {
        self.ovpn = ovpn
        self.credentials = credentials
        self.keyPassphrase = keyPassphrase
        self.uuid = uuid
        self.password = password
        self.privateKey = privateKey
        self.presharedKey = presharedKey
    }

    public static let none = TunnelSecrets()

    public var isEmpty: Bool {
        ovpn == nil && credentials == nil && keyPassphrase == nil && uuid == nil
            && password == nil && privateKey == nil && presharedKey == nil
    }
}

/// A tunnel inside `wayfork-export.json`. `slot` is intentionally absent: slots are
/// re-assigned on import.
public struct ExportedTunnel: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var kind: TunnelKind
    public var secrets: TunnelSecrets
    /// F17; absent in files written before it.
    public var localProxy: LocalProxy?

    public init(tunnel: Tunnel, secrets: TunnelSecrets = .none) {
        id = tunnel.id
        name = tunnel.name
        isEnabled = tunnel.isEnabled
        createdAt = tunnel.createdAt
        kind = tunnel.kind
        self.secrets = secrets
        localProxy = tunnel.localProxy
    }
}

/// `wayfork-export.json` (F7, docs/design/01-data-model.md).
public struct ExportDocument: Codable, Sendable, Hashable {
    public static let formatName = "wayfork-export"
    /// 2 since F10 (app rules); version 1 files import unchanged. F16's `groups` and
    /// `groupID` rules are additive (a pre-F16 build skips such rules as "tunnel not found").
    public static let currentVersion = 2

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var includesSecrets: Bool
    public var tunnels: [ExportedTunnel]
    public var rules: [Rule]
    public var settings: Settings
    /// F8; absent in files written before it existed.
    public var defaultTunnelID: UUID?
    /// F16; absent in files written before it existed.
    public var groups: [TunnelGroup]

    public init(
        exportedAt: Date = Date(),
        includesSecrets: Bool,
        tunnels: [ExportedTunnel],
        rules: [Rule],
        settings: Settings,
        defaultTunnelID: UUID? = nil,
        groups: [TunnelGroup] = []
    ) {
        format = ExportDocument.formatName
        version = ExportDocument.currentVersion
        self.exportedAt = exportedAt
        self.includesSecrets = includesSecrets
        self.tunnels = tunnels
        self.rules = rules
        self.settings = settings
        self.defaultTunnelID = defaultTunnelID
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, includesSecrets, tunnels, rules, settings
        case defaultTunnelID, groups
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        includesSecrets = try c.decode(Bool.self, forKey: .includesSecrets)
        tunnels = try c.decode([ExportedTunnel].self, forKey: .tunnels)
        rules = try c.decode([Rule].self, forKey: .rules)
        settings = try c.decode(Settings.self, forKey: .settings)
        defaultTunnelID = try c.decodeIfPresent(UUID.self, forKey: .defaultTunnelID)
        groups = try c.decodeIfPresent([TunnelGroup].self, forKey: .groups) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encode(includesSecrets, forKey: .includesSecrets)
        try c.encode(tunnels, forKey: .tunnels)
        try c.encode(rules, forKey: .rules)
        try c.encode(settings, forKey: .settings)
        try c.encodeIfPresent(defaultTunnelID, forKey: .defaultTunnelID)
        if !groups.isEmpty { try c.encode(groups, forKey: .groups) }
    }

    public enum Error: Swift.Error, Equatable {
        case unknownFormat(String)
        case newerVersion(Int)
    }

    public static func decode(_ data: Data) throws -> ExportDocument {
        let document = try JSONCoding.decoder.decode(ExportDocument.self, from: data)
        guard document.format == formatName else { throw Error.unknownFormat(document.format) }
        guard document.version <= currentVersion else { throw Error.newerVersion(document.version) }
        return document
    }

    public func encode() throws -> Data {
        try JSONCoding.prettyEncoder.encode(self)
    }
}
