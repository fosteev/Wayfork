import Foundation
import WayforkCore

/// Pure state machine of one xray process (the loopback SOCKS side of an XHTTP tunnel):
/// process lifecycle and stdout lines in, `TunnelState` plus side effects out. Simpler than
/// `OpenVPNSessionReducer`: there is no management channel, no routes and no permanent
/// failure, so every exit restarts per backoff — a taken port included
/// (docs/roadmap/xhttp-xray.md, D8).
public struct XraySessionReducer: Sendable, Equatable {
    /// `TunnelState.failed` reason when the process exited and `autoReconnect` is off.
    public static let exitedReason = "xray.exited"
    /// `TunnelState.failed` reason when the session could not start at all.
    public static let startFailedReason = "xray.startFailed"

    /// Log source of a session; `wayforkctl logs --source xray` matches every one.
    public static func source(for id: String) -> String { "xray:\(id)" }

    public struct Context: Sendable, Equatable {
        public var id: String
        public var port: Int

        public init(id: String, port: Int) {
            self.id = id
            self.port = port
        }

        public init(_ runtime: XrayRuntime) {
            self.init(id: runtime.id, port: runtime.port)
        }

        /// The SOCKS inbound, reported as the "interface" of a connected session.
        public var listenAddress: String { "127.0.0.1:\(port)" }
    }

    public enum Input: Sendable, Equatable {
        /// A fresh xray process was spawned for attempt `attempt` (1-based).
        case processStarted(attempt: Int)
        /// A line of the process's stdout or stderr.
        case processLine(String)
        case processExited(ProcessExit)
        /// The session will respawn after `nextIn` seconds.
        case restartScheduled(attempt: Int, nextIn: TimeInterval)
        /// The session will not respawn (`autoReconnect` off).
        case retriesDisabled
    }

    public enum Effect: Sendable, Equatable {
        case log(LogLevel, String)
        /// Emitted once per `processExited`; the session decides on the restart.
        case exited
    }

    public let context: Context
    public private(set) var state: TunnelState
    public private(set) var attempt: Int
    /// The latest error line of the current attempt, shown as the reconnect reason.
    private var lastError: String?
    private var lastReason: String?

    public init(context: Context) {
        self.context = context
        state = .connecting(attempt: 1)
        attempt = 1
    }

    public mutating func handle(_ input: Input, now: Date = Date()) -> [Effect] {
        switch input {
        case .processStarted(let attempt):
            self.attempt = attempt
            lastError = nil
            lastReason = nil
            state = .connecting(attempt: attempt)
            return [.log(.info, "xray started (attempt \(attempt), \(context.listenAddress))")]

        case .processLine(let line):
            let (level, message) = XrayLog.parse(line)
            if level == .error { lastError = message }
            if XrayLog.isStarted(message) {
                state = .connected(since: now, ip: nil, interface: context.listenAddress)
            }
            return [.log(level, message)]

        case .processExited(let exit):
            lastReason = lastError ?? describe(exit)
            return [.log(.warning, "xray exited (\(describe(exit)))"), .exited]

        case .restartScheduled(let attempt, let nextIn):
            self.attempt = attempt
            state = .reconnecting(attempt: attempt, nextIn: nextIn, reason: lastReason)
            return [
                .log(.info, "restarting xray in \(Int(nextIn.rounded())) s (attempt \(attempt))")
            ]

        case .retriesDisabled:
            state = .failed(reason: Self.exitedReason, permanent: false)
            return [.log(.warning, "xray exited; automatic reconnect is off")]
        }
    }

    private func describe(_ exit: ProcessExit) -> String {
        switch exit {
        case .exited(let status): "exit status \(status)"
        case .signaled(let signal): "signal \(signal)"
        }
    }
}

/// xray's own output: `2026/10/30 09:38:51.451616 [Warning] core: Xray 26.10.29 started`,
/// plus unprefixed lines — the version banner, `Failed to start: …` and Go panics.
public enum XrayLog {
    public static func parse(_ line: String) -> (LogLevel, String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.firstIndex(of: "["),
            isTimestamp(trimmed[..<open]),
            let close = trimmed[open...].firstIndex(of: "]"),
            let level = level(trimmed[trimmed.index(after: open)..<close])
        {
            let message = trimmed[trimmed.index(after: close)...]
                .trimmingCharacters(in: .whitespaces)
            return (level, message)
        }
        if trimmed.hasPrefix("Failed to start") || trimmed.hasPrefix("panic:")
            || trimmed.hasPrefix("fatal error:")
        {
            return (.error, trimmed)
        }
        return (.info, trimmed)
    }

    /// `core: Xray <version> started`: the inbound is listening.
    public static func isStarted(_ message: String) -> Bool {
        message.hasPrefix("core: Xray ") && message.hasSuffix(" started")
    }

    /// `YYYY/MM/DD HH:MM:SS[.ffffff] ` — digits, `/`, `:`, `.` and one space.
    private static func isTimestamp(_ text: Substring) -> Bool {
        let stamp = text.trimmingCharacters(in: .whitespaces)
        return stamp.count >= 19 && stamp.contains(" ")
            && stamp.allSatisfy { $0.isNumber || "/:. ".contains($0) }
    }

    private static func level(_ text: Substring) -> LogLevel? {
        switch text.lowercased() {
        case "error": .error
        case "warning": .warning
        case "info": .info
        case "debug": .debug
        default: nil
        }
    }
}
