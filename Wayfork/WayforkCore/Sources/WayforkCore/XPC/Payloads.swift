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

/// The daemon's hold on the system resolver (F12, docs/design/05-daemon.md, "System
/// resolver override").
public enum ResolverOverrideState: Codable, Sendable, Hashable {
    case off
    /// The primary service's DNS points at the TUN.
    case active(service: String)
    /// Written, but a manual entry in System Settings takes precedence.
    case shadowed(manual: [String])
    case failed(reason: String)
}

public struct RuntimeStatus: Codable, Sendable, Hashable {
    public var engine: EngineState
    /// By tunnel id (OpenVPN tunnels only).
    public var tunnels: [String: TunnelState]
    /// `RuntimePlan.planHash` of the last applied plan.
    public var planHash: String?
    /// Last `dhcp-option DNS` values pushed by each OpenVPN server, by tunnel id.
    public var discoveredDNS: [String: [String]]
    /// F12: whether the system resolver currently points at the TUN.
    public var resolverOverride: ResolverOverrideState

    public init(
        engine: EngineState = .stopped,
        tunnels: [String: TunnelState] = [:],
        planHash: String? = nil,
        discoveredDNS: [String: [String]] = [:],
        resolverOverride: ResolverOverrideState = .off
    ) {
        self.engine = engine
        self.tunnels = tunnels
        self.planHash = planHash
        self.discoveredDNS = discoveredDNS
        self.resolverOverride = resolverOverride
    }

    private enum CodingKeys: String, CodingKey {
        case engine, tunnels, planHash, discoveredDNS, resolverOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(EngineState.self, forKey: .engine)
        tunnels = try c.decode([String: TunnelState].self, forKey: .tunnels)
        planHash = try c.decodeIfPresent(String.self, forKey: .planHash)
        discoveredDNS =
            try c.decodeIfPresent([String: [String]].self, forKey: .discoveredDNS) ?? [:]
        resolverOverride =
            try c.decodeIfPresent(ResolverOverrideState.self, forKey: .resolverOverride) ?? .off
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

/// Traffic figures of one exit — a tunnel or Direct (F9). Rates cover
/// `TrafficSnapshot.interval`; totals run since Turn On.
public struct TrafficCounters: Codable, Sendable, Hashable {
    /// How long a UDP flow may keep sending without a single byte back before it counts as
    /// one-way (H3, docs/design/05-daemon.md "Traffic sampling").
    public static let oneWayUDPGrace: TimeInterval = 10

    public var downBytesPerSecond: Double
    public var upBytesPerSecond: Double
    public var downTotal: UInt64
    public var upTotal: UInt64
    /// Connections open at sample time.
    public var connections: Int
    /// UDP connections that sent but received nothing for `oneWayUDPGrace` — the signature
    /// of a tunnel server dropping UDP (H3). An aggregate count; no hosts or addresses.
    public var oneWayUDPFlows: Int

    public init(
        downBytesPerSecond: Double = 0, upBytesPerSecond: Double = 0, downTotal: UInt64 = 0,
        upTotal: UInt64 = 0, connections: Int = 0, oneWayUDPFlows: Int = 0
    ) {
        self.downBytesPerSecond = downBytesPerSecond
        self.upBytesPerSecond = upBytesPerSecond
        self.downTotal = downTotal
        self.upTotal = upTotal
        self.connections = connections
        self.oneWayUDPFlows = oneWayUDPFlows
    }

    private enum CodingKeys: String, CodingKey {
        case downBytesPerSecond, upBytesPerSecond, downTotal, upTotal, connections
        case oneWayUDPFlows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downBytesPerSecond = try c.decode(Double.self, forKey: .downBytesPerSecond)
        upBytesPerSecond = try c.decode(Double.self, forKey: .upBytesPerSecond)
        downTotal = try c.decode(UInt64.self, forKey: .downTotal)
        upTotal = try c.decode(UInt64.self, forKey: .upTotal)
        connections = try c.decode(Int.self, forKey: .connections)
        // Additive field: a payload from a build that predates it reads as zero.
        oneWayUDPFlows = try c.decodeIfPresent(Int.self, forKey: .oneWayUDPFlows) ?? 0
    }

    public static let zero = TrafficCounters()

    /// Nothing moved during the sampled interval.
    public var isIdle: Bool { downBytesPerSecond == 0 && upBytesPerSecond == 0 }
}

/// One traffic sample, pushed by the daemon once a second while sing-box runs
/// (docs/design/05-daemon.md, "Traffic sampling").
public struct TrafficSnapshot: Codable, Sendable, Hashable {
    public var sampledAt: Date
    /// Seconds covered by the rates (time since the previous sample).
    public var interval: TimeInterval
    /// By tunnel id (OpenVPN and VLESS alike). A tunnel that carried nothing since Turn On
    /// is absent; `counters(forTunnel:)` reads that as zero.
    public var tunnels: [String: TrafficCounters]
    /// Everything that bypasses the tunnels.
    public var direct: TrafficCounters

    public init(
        sampledAt: Date, interval: TimeInterval, tunnels: [String: TrafficCounters],
        direct: TrafficCounters
    ) {
        self.sampledAt = sampledAt
        self.interval = interval
        self.tunnels = tunnels
        self.direct = direct
    }

    public func counters(forTunnel id: String) -> TrafficCounters {
        tunnels[id] ?? .zero
    }
}
