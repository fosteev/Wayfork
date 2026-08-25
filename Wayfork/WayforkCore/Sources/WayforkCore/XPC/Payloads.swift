import Foundation

// Codable payloads exchanged over XPC as JSON `Data` (docs/design/05-daemon.md).

public struct DaemonInfo: Codable, Sendable, Hashable {
    public var version: String
    public var bundlePath: String
    /// CDHash of the running daemon executable (`CodeSignature.uniqueIdentifier`); nil for
    /// unsigned builds. Optional so that an older daemon still decodes.
    public var buildID: String?
    public var singBoxVersion: String
    public var openVPNVersion: String

    public init(
        version: String, bundlePath: String, buildID: String? = nil, singBoxVersion: String,
        openVPNVersion: String
    ) {
        self.version = version
        self.bundlePath = bundlePath
        self.buildID = buildID
        self.singBoxVersion = singBoxVersion
        self.openVPNVersion = openVPNVersion
    }
}

public enum EngineState: Codable, Sendable, Hashable {
    case stopped
    case starting
    case running(since: Date)
    case failed(reason: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// State of one OpenVPN tunnel, owned by the daemon.
public enum TunnelState: Codable, Sendable, Hashable {
    case disabled
    case connecting(attempt: Int)
    case connected(since: Date, ip: String?, interface: String)
    case reconnecting(attempt: Int, nextIn: TimeInterval, reason: String?)
    case failed(reason: String, permanent: Bool)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public struct RuntimeStatus: Codable, Sendable, Hashable {
    public var engine: EngineState
    /// By tunnel id (OpenVPN tunnels only).
    public var tunnels: [String: TunnelState]
    /// `RuntimePlan.planHash` of the last applied plan.
    public var planHash: String?
    /// Last `dhcp-option DNS` values pushed by each OpenVPN server, by tunnel id.
    public var discoveredDNS: [String: [String]]

    public init(
        engine: EngineState = .stopped,
        tunnels: [String: TunnelState] = [:],
        planHash: String? = nil,
        discoveredDNS: [String: [String]] = [:]
    ) {
        self.engine = engine
        self.tunnels = tunnels
        self.planHash = planHash
        self.discoveredDNS = discoveredDNS
    }

    public static let stopped = RuntimeStatus()
}

public struct LogLine: Codable, Sendable, Hashable {
    public var ts: Date
    /// `daemon`, `sing-box`, `openvpn:<tunnel id>`.
    public var source: String
    public var level: LogLevel
    public var message: String

    public init(ts: Date = Date(), source: String, level: LogLevel, message: String) {
        self.ts = ts
        self.source = source
        self.level = level
        self.message = message
    }
}

/// Errors the daemon reports back; codes follow the catalogue in docs/design/02-ux.md.
public enum DaemonError: Error, Codable, Sendable, Hashable {
    /// A bundled binary failed signature validation; nothing was started.
    case binaryUntrusted(path: String)
    /// The plan violated a limit (interface range, tunnel count, config size).
    case planInvalid(reason: String)
    /// `sing-box check` rejected the generated config (`singbox.configInvalid`).
    case configInvalid(output: String)
    /// sing-box exited early or crashed repeatedly (`singbox.startFailed`).
    case startFailed(logTail: [String])
    case tunnelNotFound(id: String)
    case notRunning
    case internalError(message: String)
}

public struct ApplyResult: Codable, Sendable, Hashable {
    public var ok: Bool
    public var error: DaemonError?

    public init(ok: Bool, error: DaemonError? = nil) {
        self.ok = ok
        self.error = error
    }

    public static let success = ApplyResult(ok: true)

    public static func failure(_ error: DaemonError) -> ApplyResult {
        ApplyResult(ok: false, error: error)
    }
}

/// Root-side material for "Export Diagnostics" (docs/design/06-logging.md).
public struct DaemonDiagnostics: Codable, Sendable, Hashable {
    public var daemonLogTail: [String]
    /// `sing-box`, `openvpn-<id>` → last lines of the raw log.
    public var childLogTails: [String: [String]]
    public var runDirectoryListing: [String]
    public var routes: String

    public init(
        daemonLogTail: [String],
        childLogTails: [String: [String]],
        runDirectoryListing: [String],
        routes: String
    ) {
        self.daemonLogTail = daemonLogTail
        self.childLogTails = childLogTails
        self.runDirectoryListing = runDirectoryListing
        self.routes = routes
    }
}

/// JSON codec used on both ends of the XPC connection.
public enum XPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONCoding.compactEncoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONCoding.decoder.decode(type, from: data)
    }
}
