import Foundation

/// Global state shown in the menu bar, derived in the app from the daemon status
/// (docs/design/00-architecture.md, "State machines").
public enum GlobalState: Sendable, Hashable {
    case off
    case starting
    case on
    /// sing-box runs but at least one enabled OpenVPN tunnel is not connected.
    case degraded(failingTunnelIDs: [UUID])
    case stopping
    /// sing-box failed to start or crashed repeatedly; `reason` is a catalogue code.
    case error(reason: String)

    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }

    /// The routing engine is up (traffic is being routed).
    public var isRunning: Bool {
        switch self {
        case .on, .degraded: true
        default: false
        }
    }

    public var isOff: Bool { self == .off }
}

/// What the app is currently doing on the user's behalf; overrides the daemon status
/// while an operation is in flight.
public enum AppTransition: Sendable, Hashable {
    case starting(since: Date)
    case stopping
}

public enum GlobalStateDerivation {
    /// `starting` gives up waiting for every tunnel after this long and shows `degraded`.
    public static let startingTimeout: TimeInterval = 30

    public static func derive(
        store: Store, status: RuntimeStatus?, transition: AppTransition?, now: Date = Date()
    ) -> GlobalState {
        if case .stopping = transition { return .stopping }
        guard let status else {
            return transition == nil ? .off : .starting
        }
        switch status.engine {
        case .failed(let reason):
            return .error(reason: reason)
        case .stopped:
            return transition == nil ? .off : .starting
        case .starting:
            return .starting
        case .running:
            let (failing, waiting) = classify(store: store, status: status)
            if failing.isEmpty && waiting.isEmpty { return .on }
            if case .starting(let since) = transition, failing.isEmpty,
                now.timeIntervalSince(since) < startingTimeout
            {
                return .starting
            }
            return .degraded(failingTunnelIDs: failing + waiting)
        }
    }

    /// Enabled OpenVPN tunnels that are failing (failed / reconnecting) and those still on
    /// their first connection attempt, both in store order.
    private static func classify(store: Store, status: RuntimeStatus) -> (
        failing: [UUID], waiting: [UUID]
    ) {
        var failing: [UUID] = []
        var waiting: [UUID] = []
        for tunnel in store.tunnels where tunnel.isEnabled && tunnel.kind.isOpenVPN {
            guard let state = status.tunnels[tunnel.id.uuidString.lowercased()] else { continue }
            switch state {
            case .connected, .disabled:
                continue
            case .connecting:
                waiting.append(tunnel.id)
            case .reconnecting, .failed:
                failing.append(tunnel.id)
            }
        }
        return (failing, waiting)
    }
}
