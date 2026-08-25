import Foundation

/// Desired runtime state, computed by the app and reconciled by the daemon
/// (docs/design/00-architecture.md, "Runtime plan").
public struct RuntimePlan: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    /// Upper bounds enforced by the daemon before anything is written or spawned.
    public static let maxTunnels = Tunnel.maxSlots
    public static let maxConfigBytes = 1_048_576

    public var version: Int
    public var singBox: SingBoxPlan
    /// One entry per enabled OpenVPN tunnel. VLESS tunnels only exist inside the sing-box config.
    public var openVPN: [OpenVPNRuntime]

    public init(
        version: Int = RuntimePlan.currentVersion, singBox: SingBoxPlan, openVPN: [OpenVPNRuntime]
    ) {
        self.version = version
        self.singBox = singBox
        self.openVPN = openVPN
    }

    /// Hash over everything the daemon acts on; reported back as `RuntimeStatus.planHash`.
    public var planHash: String {
        var parts = [singBox.configHash]
        parts.append(
            contentsOf: singBox.ruleSets.keys.sorted().map {
                "\($0)=\(Hashing.sha256Hex(singBox.ruleSets[$0] ?? ""))"
            })
        parts.append(contentsOf: openVPN.map { "\($0.id)=\($0.configHash)" })
        return Hashing.sha256Hex(parts.joined(separator: "\n"))
    }
}

public struct SingBoxPlan: Codable, Sendable, Hashable {
    /// `sing-box.json` contents.
    public var config: String
    /// `rules-t-<id>.json` file name → contents.
    public var ruleSets: [String: String]
    /// Hash of `config` alone; rule-set changes do not affect it, so the daemon can tell a
    /// hot-reloadable change from one that needs a restart.
    public var configHash: String

    public init(config: String, ruleSets: [String: String]) {
        self.config = config
        self.ruleSets = ruleSets
        configHash = Hashing.sha256Hex(config)
    }
}

public struct OpenVPNRuntime: Codable, Sendable, Hashable, Identifiable {
    /// Tunnel id (`Tunnel.id.uuidString.lowercased()`).
    public var id: String
    /// `utun101`…
    public var interface: String
    /// Sanitized `.ovpn` body with inline certs/keys.
    public var config: String
    public var credentials: Credentials?
    public var keyPassphrase: String?
    /// Hash of `config` + credentials + passphrase: any change restarts the process.
    public var configHash: String

    public init(
        id: String,
        interface: String,
        config: String,
        credentials: Credentials? = nil,
        keyPassphrase: String? = nil
    ) {
        self.id = id
        self.interface = interface
        self.config = config
        self.credentials = credentials
        self.keyPassphrase = keyPassphrase
        configHash = Hashing.sha256Hex(
            [
                config,
                credentials?.username ?? "",
                credentials?.password ?? "",
                keyPassphrase ?? "",
            ].joined(separator: "\u{0}"))
    }
}
