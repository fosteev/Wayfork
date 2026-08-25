import Foundation

/// One `remote` line of an OpenVPN profile, kept for display only.
public struct Remote: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    /// `udp` or `tcp` (OpenVPN's `proto`, normalized: `udp4` → `udp`, `tcp-client` → `tcp`).
    public var proto: String

    public init(host: String, port: Int, proto: String) {
        self.host = host
        self.port = port
        self.proto = proto
    }
}

/// Resolver used for the domains routed through an OpenVPN tunnel.
public enum TunnelDNS: Codable, Sendable, Hashable {
    /// `discoveredDNS` if the server pushed any, otherwise `1.1.1.1` through the tunnel.
    case auto
    case custom(servers: [String])
}

/// OpenVPN tunnel metadata. The sanitized config body itself lives in Keychain.
public struct OpenVPNMeta: Codable, Sendable, Hashable {
    public var remotes: [Remote]
    public var needsCredentials: Bool
    public var needsKeyPassphrase: Bool
    public var dns: TunnelDNS
    public var discoveredDNS: [String]
    /// SHA-256 (hex) of the sanitized config body.
    public var configHash: String

    public init(
        remotes: [Remote],
        needsCredentials: Bool,
        needsKeyPassphrase: Bool,
        dns: TunnelDNS = .auto,
        discoveredDNS: [String] = [],
        configHash: String
    ) {
        self.remotes = remotes
        self.needsCredentials = needsCredentials
        self.needsKeyPassphrase = needsKeyPassphrase
        self.dns = dns
        self.discoveredDNS = discoveredDNS
        self.configHash = configHash
    }
}

public enum VLESSSecurity: String, Codable, Sendable, CaseIterable {
    case none
    case tls
    case reality
}

public enum VLESSTransport: Codable, Sendable, Hashable {
    case tcp
    case ws(path: String, host: String?)
    case grpc(serviceName: String)
}

/// VLESS tunnel metadata. The UUID lives in Keychain.
public struct VLESSMeta: Codable, Sendable, Hashable {
    public var server: String
    public var port: Int
    /// `xtls-rprx-vision` or nil.
    public var flow: String?
    public var security: VLESSSecurity
    public var sni: String?
    /// uTLS fingerprint: `chrome`, `firefox`, `safari`, …
    public var fingerprint: String?
    public var alpn: [String]
    public var realityPublicKey: String?
    public var realityShortID: String?
    public var transport: VLESSTransport
    public var allowInsecure: Bool

    public init(
        server: String,
        port: Int,
        flow: String? = nil,
        security: VLESSSecurity,
        sni: String? = nil,
        fingerprint: String? = nil,
        alpn: [String] = [],
        realityPublicKey: String? = nil,
        realityShortID: String? = nil,
        transport: VLESSTransport = .tcp,
        allowInsecure: Bool = false
    ) {
        self.server = server
        self.port = port
        self.flow = flow
        self.security = security
        self.sni = sni
        self.fingerprint = fingerprint
        self.alpn = alpn
        self.realityPublicKey = realityPublicKey
        self.realityShortID = realityShortID
        self.transport = transport
        self.allowInsecure = allowInsecure
    }
}

/// Encoded as `{"openVPN": {…meta…}}` / `{"vless": {…meta…}}` (docs/design/01-data-model.md).
public enum TunnelKind: Sendable, Hashable {
    case openVPN(OpenVPNMeta)
    case vless(VLESSMeta)

    public var isOpenVPN: Bool {
        if case .openVPN = self { return true }
        return false
    }

    public var openVPN: OpenVPNMeta? {
        if case .openVPN(let meta) = self { return meta }
        return nil
    }

    public var vless: VLESSMeta? {
        if case .vless(let meta) = self { return meta }
        return nil
    }

    /// Server host(s) this tunnel connects to; used to warn about rules covering them.
    public var serverHosts: [String] {
        switch self {
        case .openVPN(let meta): meta.remotes.map(\.host)
        case .vless(let meta): [meta.server]
        }
    }
}

extension TunnelKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case openVPN, vless
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let meta = try c.decodeIfPresent(OpenVPNMeta.self, forKey: .openVPN) {
            self = .openVPN(meta)
        } else if let meta = try c.decodeIfPresent(VLESSMeta.self, forKey: .vless) {
            self = .vless(meta)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "tunnel kind must be one of: openVPN, vless"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openVPN(let meta): try c.encode(meta, forKey: .openVPN)
        case .vless(let meta): try c.encode(meta, forKey: .vless)
        }
    }
}

public struct Tunnel: Codable, Sendable, Hashable, Identifiable {
    /// Maximum number of tunnels; also the number of OpenVPN interface slots.
    public static let maxSlots = 32
    public static let nameMaxLength = 40
    /// `utun` unit of the first OpenVPN tunnel slot; sing-box itself owns `utun100`.
    public static let firstOpenVPNInterfaceUnit = 101

    public var id: UUID
    /// Unique, 1…40 characters.
    public var name: String
    public var isEnabled: Bool
    /// 0…31, unique and stable for the tunnel's lifetime.
    public var slot: Int
    public var kind: TunnelKind
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        slot: Int,
        kind: TunnelKind,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.slot = slot
        self.kind = kind
        self.createdAt = createdAt
    }

    /// sing-box outbound tag: `t-<id>`.
    public var outboundTag: String { "t-\(id.uuidString.lowercased())" }

    /// sing-box rule-set tag: `rules-t-<id>`; the file is `<tag>.json`.
    public var ruleSetTag: String { "rules-\(outboundTag)" }

    public var ruleSetFileName: String { "\(ruleSetTag).json" }

    /// `utun<101 + slot>` for OpenVPN tunnels; VLESS tunnels have no interface.
    public var interfaceName: String? {
        guard kind.isOpenVPN else { return nil }
        return "utun\(Tunnel.firstOpenVPNInterfaceUnit + slot)"
    }
}
