import Foundation
import WayforkCore

/// Pure state machine of one OpenVPN tunnel: management events and process lifecycle in,
/// `TunnelState` plus side effects out. The daemon's `OpenVPNSession` owns the process,
/// socket and timers and feeds this reducer (docs/design/04-tunnels.md, "Management
/// protocol handling"; docs/design/00-architecture.md, "State machines").
public struct OpenVPNSessionReducer: Sendable, Equatable {
    public struct Context: Sendable, Equatable {
        public var id: String
        public var interface: String
        public var credentials: Credentials?
        public var keyPassphrase: String?

        public init(
            id: String, interface: String, credentials: Credentials? = nil,
            keyPassphrase: String? = nil
        ) {
            self.id = id
            self.interface = interface
            self.credentials = credentials
            self.keyPassphrase = keyPassphrase
        }

        public init(_ runtime: OpenVPNRuntime) {
            self.init(
                id: runtime.id, interface: runtime.interface, credentials: runtime.credentials,
                keyPassphrase: runtime.keyPassphrase)
        }
    }

    public enum Input: Sendable, Equatable {
        /// A fresh openvpn process was spawned for attempt `attempt` (1-based).
        case processStarted(attempt: Int)
        case managementConnected
        case management(ManagementEvent)
        case managementClosed
        /// A line of the process's own stdout/stderr. Forwarded to the log only until the
        /// management socket is up (openvpn then prints every line on both channels).
        case processLine(String)
        case processExited(ProcessExit)
        /// The session will respawn after `nextIn` seconds.
        case restartScheduled(attempt: Int, nextIn: TimeInterval)
        /// The session will not respawn (`autoReconnect` off).
        case retriesDisabled
    }

    public enum ExitDisposition: Sendable, Equatable {
        /// Do not restart until the plan changes.
        case permanent(OpenVPNFailure)
        /// Restart per backoff policy.
        case transient(reason: String)
    }

    public enum Effect: Sendable, Equatable {
        /// Write to the management socket. May contain secrets: never log it.
        case send(String)
        case log(LogLevel, String)
        case addScopedRoute(interface: String)
        case deleteScopedRoute(interface: String)
        /// `dhcp-option DNS` servers from the latest `PUSH_REPLY` (possibly empty).
        case discoveredDNS([String])
        /// Emitted once per `processExited`.
        case exited(ExitDisposition)
    }

    public let context: Context
    public private(set) var state: TunnelState
    public private(set) var attempt: Int
    private var managementUp = false
    private var routeAdded = false
    private var permanentFailure: OpenVPNFailure?
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
            managementUp = false
            routeAdded = false
            permanentFailure = nil
            lastReason = nil
            state = .connecting(attempt: attempt)
            return [.log(.info, "openvpn started (attempt \(attempt), \(context.interface))")]

        case .managementConnected:
            managementUp = true
            return [
                .send(ManagementCommand.stateOn), .send(ManagementCommand.logOn),
                .send(ManagementCommand.bytecount), .send(ManagementCommand.holdRelease),
                .log(.debug, "management interface connected"),
            ]

        case .management(let event):
            return handle(event, now: now)

        case .managementClosed:
            managementUp = false
            return []

        case .processLine(let line):
            let (flags, message) = OpenVPNOutput.parse(line)
            var effects: [Effect] = []
            if !managementUp {
                effects.append(.log(ManagementProtocol.level(forLogFlags: flags), message))
            }
            if flags.contains("F"), permanentFailure == nil,
                let reason = OpenVPNFailure.permanentReason(forFatal: message)
            {
                effects.append(contentsOf: fail(reason, detail: message))
            }
            effects.append(contentsOf: checkOpenedInterface(message))
            return effects

        case .processExited(let exit):
            managementUp = false
            var effects: [Effect] = []
            if routeAdded {
                routeAdded = false
                effects.append(.deleteScopedRoute(interface: context.interface))
            }
            if let failure = permanentFailure {
                effects.append(
                    .log(
                        .error,
                        "openvpn exited (\(describe(exit))); not retrying: \(failure.rawValue)"))
                effects.append(.exited(.permanent(failure)))
            } else {
                let reason = lastReason ?? describe(exit)
                effects.append(.log(.warning, "openvpn exited (\(describe(exit)))"))
                effects.append(.exited(.transient(reason: reason)))
            }
            return effects

        case .restartScheduled(let attempt, let nextIn):
            self.attempt = attempt
            state = .reconnecting(attempt: attempt, nextIn: nextIn, reason: lastReason)
            return [
                .log(.info, "restarting openvpn in \(Int(nextIn.rounded())) s (attempt \(attempt))")
            ]

        case .retriesDisabled:
            state = .failed(reason: OpenVPNFailure.exited.rawValue, permanent: false)
            return [.log(.warning, "openvpn exited; automatic reconnect is off")]
        }
    }

    private mutating func handle(_ event: ManagementEvent, now: Date) -> [Effect] {
        switch event {
        case .state(let s):
            return handleState(s, now: now)

        case .log(let flags, let message):
            var effects: [Effect] = [.log(ManagementProtocol.level(forLogFlags: flags), message)]
            if let servers = ManagementProtocol.pushedDNS(fromLogMessage: message) {
                effects.append(.discoveredDNS(servers))
            }
            effects.append(contentsOf: checkOpenedInterface(message))
            return effects

        case .passwordNeeded(let kind):
            guard permanentFailure == nil else { return [] }
            switch kind {
            case "Auth":
                guard let credentials = context.credentials else {
                    return fail(.needsCredentials)
                }
                return [
                    .send(ManagementCommand.username(kind: kind, credentials.username)),
                    .send(ManagementCommand.password(kind: kind, credentials.password)),
                ]
            case "Private Key":
                guard let passphrase = context.keyPassphrase else {
                    return fail(.needsKeyPassphrase)
                }
                return [.send(ManagementCommand.password(kind: kind, passphrase))]
            default:
                return fail(.unsupportedPrompt, detail: "server asked for '\(kind)'")
            }

        case .passwordVerificationFailed(let kind):
            guard permanentFailure == nil else { return [] }
            switch kind {
            case "Auth": return fail(.authFailed)
            case "Private Key": return fail(.keyPassphrase)
            default: return fail(.unsupportedPrompt, detail: "verification failed for '\(kind)'")
            }

        case .fatal(let message):
            if let reason = OpenVPNFailure.permanentReason(forFatal: message) {
                return fail(reason, detail: message)
            }
            lastReason = message
            return [.log(.error, message)]

        case .error(let message):
            return [.log(.warning, "management: \(message)")]

        case .hold:
            // `--management-hold` is persistent: after every soft restart (server_poll,
            // ping-restart, SIGUSR1) openvpn hibernates again until the next `hold release`.
            return [.send(ManagementCommand.holdRelease), .log(.debug, "hold released")]

        case .info, .success, .other:
            return []

        case .bytecount:
            return []
        }
    }

    private mutating func handleState(_ s: ManagementState, now: Date) -> [Effect] {
        switch s.name {
        case "CONNECTED":
            state = .connected(since: now, ip: s.tunnelIP, interface: context.interface)
            var effects: [Effect] = [
                .log(.info, "connected (\(s.tunnelIP ?? "no ip") on \(context.interface))")
            ]
            if !routeAdded {
                routeAdded = true
                effects.append(.addScopedRoute(interface: context.interface))
            }
            return effects

        case "RECONNECTING":
            lastReason = s.description.isEmpty ? nil : s.description
            var effects: [Effect] = []
            if routeAdded {
                routeAdded = false
                effects.append(.deleteScopedRoute(interface: context.interface))
            }
            if permanentFailure == nil {
                state = .reconnecting(attempt: attempt, nextIn: 0, reason: lastReason)
            }
            effects.append(.log(.warning, "reconnecting: \(s.description)"))
            return effects

        case "EXITING":
            if !s.description.isEmpty { lastReason = s.description }
            return [.log(.info, "exiting: \(s.description)")]

        default:
            if permanentFailure == nil, !state.isConnected {
                state = .connecting(attempt: attempt)
            }
            return [
                .log(
                    .debug, "state \(s.name) \(s.description)".trimmingCharacters(in: .whitespaces))
            ]
        }
    }

    /// `Opened utun device utunN`: the unit must be the planned one, or sing-box binds the
    /// tunnel outbound to an interface that does not exist.
    private mutating func checkOpenedInterface(_ message: String) -> [Effect] {
        guard permanentFailure == nil,
            let opened = OpenVPNOutput.openedInterface(in: message), opened != context.interface
        else { return [] }
        return fail(
            .configError,
            detail: "openvpn opened \(opened) instead of \(context.interface)")
    }

    private mutating func fail(_ reason: OpenVPNFailure, detail: String? = nil) -> [Effect] {
        permanentFailure = reason
        state = .failed(reason: reason.rawValue, permanent: true)
        var effects: [Effect] = [
            .log(.error, "tunnel failed: \(reason.rawValue)" + (detail.map { " — \($0)" } ?? ""))
        ]
        if managementUp {
            effects.append(.send(ManagementCommand.signalTerm))
        }
        return effects
    }

    private func describe(_ exit: ProcessExit) -> String {
        switch exit {
        case .exited(let status): "exit status \(status)"
        case .signaled(let signal): "signal \(signal)"
        }
    }
}
