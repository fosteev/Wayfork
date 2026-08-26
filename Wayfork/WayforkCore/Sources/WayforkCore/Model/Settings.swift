import Foundation

/// Log verbosity. Ordered by verbosity: `error < warning < info < debug`.
public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case error
    case warning
    case info
    case debug

    private var rank: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .info: 2
        case .debug: 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    /// `openvpn --verb` value for this level (docs/design/06-logging.md).
    public var openVPNVerbosity: Int {
        switch self {
        case .debug: 4
        case .info: 3
        case .warning, .error: 1
        }
    }

    /// sing-box `log.level`; capped at `info` unless debug is requested explicitly.
    public var singBoxLevel: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .warning: "warn"
        case .error: "error"
        }
    }
}

/// Resolver used for traffic that no rule matched.
public enum DirectDNS: Codable, Sendable, Hashable {
    case system
    case custom(servers: [String])
}

/// User preferences (F6). Every field has a default so that a `store.json` written by an
/// older version, or with keys removed, still loads.
public struct Settings: Codable, Sendable, Hashable {
    public var launchAtLogin: Bool
    public var connectOnLaunch: Bool
    public var autoReconnect: Bool
    public var notifyOnTunnelFailure: Bool
    public var directDNS: DirectDNS
    /// Wayfork is the system resolver while On (F12, docs/design/03-routing.md).
    public var overrideSystemDNS: Bool
    public var logLevel: LogLevel
    public var logRetentionDays: Int

    public init(
        launchAtLogin: Bool = false,
        connectOnLaunch: Bool = false,
        autoReconnect: Bool = true,
        notifyOnTunnelFailure: Bool = true,
        directDNS: DirectDNS = .system,
        overrideSystemDNS: Bool = true,
        logLevel: LogLevel = .info,
        logRetentionDays: Int = 7
    ) {
        self.launchAtLogin = launchAtLogin
        self.connectOnLaunch = connectOnLaunch
        self.autoReconnect = autoReconnect
        self.notifyOnTunnelFailure = notifyOnTunnelFailure
        self.directDNS = directDNS
        self.overrideSystemDNS = overrideSystemDNS
        self.logLevel = logLevel
        self.logRetentionDays = logRetentionDays
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, connectOnLaunch, autoReconnect, notifyOnTunnelFailure
        case directDNS, overrideSystemDNS, logLevel, logRetentionDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        launchAtLogin =
            try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        connectOnLaunch =
            try c.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? defaults.connectOnLaunch
        autoReconnect =
            try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? defaults.autoReconnect
        notifyOnTunnelFailure =
            try c.decodeIfPresent(Bool.self, forKey: .notifyOnTunnelFailure)
            ?? defaults.notifyOnTunnelFailure
        directDNS = try c.decodeIfPresent(DirectDNS.self, forKey: .directDNS) ?? defaults.directDNS
        overrideSystemDNS =
            try c.decodeIfPresent(Bool.self, forKey: .overrideSystemDNS)
            ?? defaults.overrideSystemDNS
        logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? defaults.logLevel
        logRetentionDays =
            try c.decodeIfPresent(Int.self, forKey: .logRetentionDays) ?? defaults.logRetentionDays
    }
}
