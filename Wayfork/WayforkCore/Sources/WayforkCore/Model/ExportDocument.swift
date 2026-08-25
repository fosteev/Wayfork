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

    public init(
        ovpn: String? = nil,
        credentials: Credentials? = nil,
        keyPassphrase: String? = nil,
        uuid: String? = nil
    ) {
        self.ovpn = ovpn
        self.credentials = credentials
        self.keyPassphrase = keyPassphrase
        self.uuid = uuid
    }

    public static let none = TunnelSecrets()

    public var isEmpty: Bool {
        ovpn == nil && credentials == nil && keyPassphrase == nil && uuid == nil
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

    public init(tunnel: Tunnel, secrets: TunnelSecrets = .none) {
        id = tunnel.id
        name = tunnel.name
        isEnabled = tunnel.isEnabled
        createdAt = tunnel.createdAt
        kind = tunnel.kind
        self.secrets = secrets
    }
}

/// `wayfork-export.json` (F7, docs/design/01-data-model.md).
public struct ExportDocument: Codable, Sendable, Hashable {
    public static let formatName = "wayfork-export"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var includesSecrets: Bool
    public var tunnels: [ExportedTunnel]
    public var rules: [Rule]
    public var settings: Settings

    public init(
        exportedAt: Date = Date(),
        includesSecrets: Bool,
        tunnels: [ExportedTunnel],
        rules: [Rule],
        settings: Settings
    ) {
        format = ExportDocument.formatName
        version = ExportDocument.currentVersion
        self.exportedAt = exportedAt
        self.includesSecrets = includesSecrets
        self.tunnels = tunnels
        self.rules = rules
        self.settings = settings
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
