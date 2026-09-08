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

/// WireGuard tunnel metadata. Private and preshared keys live in Keychain.
public struct WireGuardMeta: Codable, Sendable, Hashable {
    public var addresses: [String]
    public var peers: [WireGuardPeer]
    public var mtu: Int?
    public var dns: TunnelDNS
    public var discoveredDNS: [String]

    public init(
        addresses: [String],
        peers: [WireGuardPeer],
        mtu: Int? = nil,
        dns: TunnelDNS = .auto,
        discoveredDNS: [String] = []
    ) {
        self.addresses = addresses
        self.peers = peers
        self.mtu = mtu
        self.dns = dns
        self.discoveredDNS = discoveredDNS
    }
}

public struct WireGuardPeer: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var publicKey: String
    public var hasPresharedKey: Bool
    public var allowedIPs: [String]
    public var keepalive: Int?

    public init(
        host: String,
        port: Int,
        publicKey: String,
        hasPresharedKey: Bool = false,
        allowedIPs: [String],
        keepalive: Int? = nil
    ) {
        self.host = host
        self.port = port
        self.publicKey = publicKey
        self.hasPresharedKey = hasPresharedKey
        self.allowedIPs = allowedIPs
        self.keepalive = keepalive
    }
}

/// TLS layer of a proxy tunnel (VLESS, Trojan, VMess). Encoded by case name, so renaming
/// the type from `VLESSSecurity` changed no stored JSON.
public enum TLSSecurity: String, Codable, Sendable, CaseIterable {
    case none
    case tls
    case reality
}

/// Stream transport shared by the proxy kinds; `case` names and payloads are the stored form.
public enum ProxyTransport: Codable, Sendable, Hashable {
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
    public var security: TLSSecurity
    public var sni: String?
    /// uTLS fingerprint: `chrome`, `firefox`, `safari`, …
    public var fingerprint: String?
    public var alpn: [String]
    public var realityPublicKey: String?
    public var realityShortID: String?
    public var transport: ProxyTransport
    public var allowInsecure: Bool

    public init(
        server: String,
        port: Int,
        flow: String? = nil,
        security: TLSSecurity,
        sni: String? = nil,
        fingerprint: String? = nil,
        alpn: [String] = [],
        realityPublicKey: String? = nil,
        realityShortID: String? = nil,
        transport: ProxyTransport = .tcp,
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

/// Shadowsocks tunnel metadata. The password lives in Keychain.
public struct ShadowsocksMeta: Codable, Sendable, Hashable {
    public var server: String
    public var port: Int
    public var method: String

    public init(server: String, port: Int, method: String) {
        self.server = server
        self.port = port
        self.method = method
    }
}

/// Trojan tunnel metadata. The password lives in Keychain.
public struct TrojanMeta: Codable, Sendable, Hashable {
    public var server: String
    public var port: Int
    public var security: TLSSecurity
    public var sni: String?
    public var fingerprint: String?
    public var alpn: [String]
    public var realityPublicKey: String?
    public var realityShortID: String?
    public var transport: ProxyTransport
    public var allowInsecure: Bool

    public init(
        server: String,
        port: Int,
        security: TLSSecurity,
        sni: String? = nil,
        fingerprint: String? = nil,
        alpn: [String] = [],
        realityPublicKey: String? = nil,
        realityShortID: String? = nil,
        transport: ProxyTransport = .tcp,
        allowInsecure: Bool = false
    ) {
        self.server = server
        self.port = port
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

/// VMess tunnel metadata. The UUID lives in Keychain.
public struct VMessMeta: Codable, Sendable, Hashable {
    public var server: String
    public var port: Int
    public var security: String
    public var tlsSecurity: TLSSecurity
    public var sni: String?
    public var fingerprint: String?
    public var alpn: [String]
    public var realityPublicKey: String?
    public var realityShortID: String?
    public var transport: ProxyTransport
    public var allowInsecure: Bool

    public init(
        server: String,
        port: Int,
        security: String,
        tlsSecurity: TLSSecurity,
        sni: String? = nil,
        fingerprint: String? = nil,
        alpn: [String] = [],
        realityPublicKey: String? = nil,
        realityShortID: String? = nil,
        transport: ProxyTransport = .tcp,
        allowInsecure: Bool = false
    ) {
        self.server = server
        self.port = port
        self.security = security
        self.tlsSecurity = tlsSecurity
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
    case wireGuard(WireGuardMeta)
    case shadowsocks(ShadowsocksMeta)
    case trojan(TrojanMeta)
    case vmess(VMessMeta)

    public var isOpenVPN: Bool {
        if case .openVPN = self { return true }
        return false
    }

    public var hasOwnResolver: Bool {
        switch self {
        case .openVPN, .wireGuard: true
        case .vless, .shadowsocks, .trojan, .vmess: false
        }
    }

    public var openVPN: OpenVPNMeta? {
        if case .openVPN(let meta) = self { return meta }
        return nil
    }

    public var vless: VLESSMeta? {
        if case .vless(let meta) = self { return meta }
        return nil
    }

    public var wireGuard: WireGuardMeta? {
        if case .wireGuard(let meta) = self { return meta }
        return nil
    }

    public var shadowsocks: ShadowsocksMeta? {
        if case .shadowsocks(let meta) = self { return meta }
        return nil
    }

    public var trojan: TrojanMeta? {
        if case .trojan(let meta) = self { return meta }
        return nil
    }

    public var vmess: VMessMeta? {
        if case .vmess(let meta) = self { return meta }
        return nil
    }

    /// Server host(s) this tunnel connects to; used to warn about rules covering them.
    public var serverHosts: [String] {
        switch self {
        case .openVPN(let meta): meta.remotes.map(\.host)
        case .vless(let meta): [meta.server]
        case .wireGuard(let meta): meta.peers.map(\.host)
        case .shadowsocks(let meta): [meta.server]
        case .trojan(let meta): [meta.server]
        case .vmess(let meta): [meta.server]
        }
    }
}

extension TunnelKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case openVPN, vless, wireGuard, shadowsocks, trojan, vmess
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let meta = try c.decodeIfPresent(OpenVPNMeta.self, forKey: .openVPN) {
            self = .openVPN(meta)
        } else if let meta = try c.decodeIfPresent(VLESSMeta.self, forKey: .vless) {
            self = .vless(meta)
        } else if let meta = try c.decodeIfPresent(WireGuardMeta.self, forKey: .wireGuard) {
            self = .wireGuard(meta)
        } else if let meta = try c.decodeIfPresent(ShadowsocksMeta.self, forKey: .shadowsocks) {
            self = .shadowsocks(meta)
        } else if let meta = try c.decodeIfPresent(TrojanMeta.self, forKey: .trojan) {
            self = .trojan(meta)
        } else if let meta = try c.decodeIfPresent(VMessMeta.self, forKey: .vmess) {
            self = .vmess(meta)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "tunnel kind must be one of: openVPN, vless, wireGuard, shadowsocks, trojan, vmess"
                ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openVPN(let meta): try c.encode(meta, forKey: .openVPN)
        case .vless(let meta): try c.encode(meta, forKey: .vless)
        case .wireGuard(let meta): try c.encode(meta, forKey: .wireGuard)
        case .shadowsocks(let meta): try c.encode(meta, forKey: .shadowsocks)
        case .trojan(let meta): try c.encode(meta, forKey: .trojan)
        case .vmess(let meta): try c.encode(meta, forKey: .vmess)
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
    public var outboundTag: String { "\(Tunnel.outboundTagPrefix)\(id.uuidString.lowercased())" }

    public static let outboundTagPrefix = "t-"

    /// The tunnel id behind an outbound tag; nil for `direct`, `block` and other outbounds.
    public static func tunnelID(fromOutboundTag tag: String) -> String? {
        guard tag.hasPrefix(outboundTagPrefix), tag.count > outboundTagPrefix.count else {
            return nil
        }
        return String(tag.dropFirst(outboundTagPrefix.count))
    }

    /// sing-box rule-set tag: `rules-t-<id>`; the file is `<tag>.json`.
    public var ruleSetTag: String { "rules-\(outboundTag)" }

    public var ruleSetFileName: String { "\(ruleSetTag).json" }

    /// F11: the tunnel's IP rules, `rules-t-<id>-ip`; referenced by route rules only.
    public var ipRuleSetTag: String { "\(ruleSetTag)-ip" }

    public var ipRuleSetFileName: String { "\(ipRuleSetTag).json" }

    /// `utun<101 + slot>` for OpenVPN tunnels; native tunnels have no system interface.
    public var interfaceName: String? {
        guard kind.isOpenVPN else { return nil }
        return "utun\(Tunnel.firstOpenVPNInterfaceUnit + slot)"
    }
}
