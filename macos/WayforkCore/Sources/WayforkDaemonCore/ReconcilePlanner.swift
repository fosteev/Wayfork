import Foundation
import WayforkCore

/// What the daemon currently runs, as far as reconcile cares.
public struct ReconcileState: Sendable, Equatable {
    public var singBoxRunning: Bool
    /// `SingBoxPlan.configHash` of the config on disk (nil = never written).
    public var singBoxConfigHash: String?
    /// Rule-set files on disk: name → contents.
    public var ruleSets: [String: String]
    /// Running (or supervised) OpenVPN processes: tunnel id → `OpenVPNArguments.diffKey`.
    public var openVPN: [String: String]
    /// Supervised xray processes: tunnel id → `XrayRuntime.configHash`.
    public var xray: [String: String]

    public init(
        singBoxRunning: Bool = false,
        singBoxConfigHash: String? = nil,
        ruleSets: [String: String] = [:],
        openVPN: [String: String] = [:],
        xray: [String: String] = [:]
    ) {
        self.singBoxRunning = singBoxRunning
        self.singBoxConfigHash = singBoxConfigHash
        self.ruleSets = ruleSets
        self.openVPN = openVPN
        self.xray = xray
    }
}

public enum SingBoxAction: Sendable, Equatable {
    /// Config and rule-sets unchanged, process running.
    case none
    /// Same config, some rule-set files differ: rewrite `files` in place, no restart.
    case rewriteRuleSets(files: [String])
    /// Write everything, `sing-box check`, start (not running yet).
    case start
    /// Write everything, `sing-box check`, restart the running process.
    case restart
}

/// Steps that turn `ReconcileState` into a `RuntimePlan`
/// (docs/design/00-architecture.md, "Reconcile algorithm").
public struct ReconcileActions: Sendable, Equatable {
    /// Tunnel ids to stop first (removed or changed).
    public var stopOpenVPN: [String]
    /// Tunnel ids to start afterwards (added or changed).
    public var startOpenVPN: [String]
    public var singBox: SingBoxAction
    /// Rule-set files on disk that the plan no longer contains.
    public var staleRuleSets: [String]
    /// xray tunnel ids to stop first (removed or changed), then to start.
    public var stopXray: [String] = []
    public var startXray: [String] = []

    public var isNoOp: Bool {
        stopOpenVPN.isEmpty && startOpenVPN.isEmpty && singBox == .none && staleRuleSets.isEmpty
            && stopXray.isEmpty && startXray.isEmpty
    }
}

public enum ReconcilePlanner {
    public static func plan(from state: ReconcileState, to plan: RuntimePlan) -> ReconcileActions {
        let (stop, start) = diff(
            running: state.openVPN,
            desired: plan.openVPN.map {
                ($0.id, OpenVPNArguments.diffKey(for: $0, logLevel: plan.logLevel))
            })
        let (stopXray, startXray) = diff(
            running: state.xray, desired: plan.xray.map { ($0.id, $0.configHash) })

        let stale = state.ruleSets.keys.filter { plan.singBox.ruleSets[$0] == nil }.sorted()
        let singBox: SingBoxAction
        if !state.singBoxRunning {
            singBox = .start
        } else if state.singBoxConfigHash != plan.singBox.configHash {
            singBox = .restart
        } else {
            let changed = plan.singBox.ruleSets.keys.filter {
                state.ruleSets[$0] != plan.singBox.ruleSets[$0]
            }
            .sorted()
            singBox = changed.isEmpty ? .none : .rewriteRuleSets(files: changed)
        }
        return ReconcileActions(
            stopOpenVPN: stop, startOpenVPN: start, singBox: singBox, staleRuleSets: stale,
            stopXray: stopXray, startXray: startXray)
    }

    /// Processes to stop (gone or key changed, sorted by id) and to start (changed, then
    /// new in plan order).
    private static func diff(running: [String: String], desired: [(id: String, key: String)])
        -> (stop: [String], start: [String])
    {
        let keys = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0.key) })
        var stop: [String] = []
        var start: [String] = []
        for (id, key) in running.sorted(by: { $0.key < $1.key }) {
            switch keys[id] {
            case nil: stop.append(id)
            case key: break
            default:
                stop.append(id)
                start.append(id)
            }
        }
        for entry in desired where running[entry.id] == nil {
            start.append(entry.id)
        }
        return (stop, start)
    }
}
