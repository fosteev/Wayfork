import Foundation
import WayforkCore

// The control socket (F21, docs/design/09-wayforkctl.md): `wayforkctl` reads state and makes
// reversible rule changes through the same `update` path as the popover. A change waits
// for `confirm`; unconfirmed, it is undone at its deadline — also after a crash, via
// `control-pending.json`.

extension AppModel {
    enum ControlRevertReason {
        case requested, deadline, leftover
    }

    // MARK: - Lifecycle

    func startControlServer() {
        // A fresh install has no store directory until the first save.
        try? FileManager.default.createDirectory(
            at: StoreRepository.defaultDirectory(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = ControlPaths.socket().path
        let server = ControlServer(path: path) { [weak self] request in
            guard let self else { return .failure(ControlError(.internal, "shutting down")) }
            return await self.handleControl(request)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            logs.app(.warning, "control socket unavailable: \(error)")
        }
    }

    func stopControlServer() {
        controlServer?.stop()
        controlServer = nil
    }

    /// A pending change left by a run that ended before its deadline was never confirmed:
    /// undo it before anything is applied.
    func revertLeftoverControlChange() async {
        let url = ControlPaths.pending()
        guard let data = try? Data(contentsOf: url) else { return }
        guard let pending = try? Self.controlDecoder.decode(PendingControlChange.self, from: data)
        else {
            try? FileManager.default.removeItem(at: url)
            logs.app(.warning, "control: unreadable \(url.lastPathComponent) removed")
            return
        }
        controlPending = pending
        _ = await revertControlChange(.leftover)
    }

    // MARK: - Dispatch

    func handleControl(_ request: ControlRequest) async -> Result<Data, ControlError> {
        do {
            switch request.method {
            case .status: return ControlWire.encodeResult(controlStatus())
            case .failed: return ControlWire.encodeResult(controlFailed())
            case .listsList: return ControlWire.encodeResult(controlLists())
            case .listsSet: return try await controlSetList(request.params)
            case .rulesList:
                return ControlWire.encodeResult(try controlRules(via: request.params.via))
            case .rulesAdd: return try await controlAddRule(request.params)
            case .rulesRemove: return try await controlRemoveRule(request.params)
            case .logLevelSet: return try await controlSetLogLevel(request.params)
            case .confirm: return try await controlConfirm()
            case .revert: return try await controlRevert()
            case .reconnect: return try controlReconnect(request.params)
            }
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(.internal, "\(error)"))
        }
    }

    // MARK: - Reads

    struct ControlStatusReply: Encodable {
        struct TunnelRow: Encodable {
            var id: UUID
            var name: String
            var kind: String
            var enabled: Bool
            var state: String
        }

        struct GroupRow: Encodable {
            var id: UUID
            var name: String
            var members: [String]
            var using: String?
        }

        var on: Bool
        var engine: String
        var tunnels: [TunnelRow]
        var groups: [GroupRow]
        var rules: Int
        var logLevel: LogLevel
        var planHash: String?
        var lastApplyError: String?
        var pending: ControlPendingInfo?
    }

    func controlStatus() -> ControlStatusReply {
        ControlStatusReply(
            on: desiredOn,
            engine: Self.engineText(status?.engine),
            tunnels: store.tunnels.map { tunnel in
                .init(
                    id: tunnel.id, name: tunnel.name, kind: Self.kindText(tunnel.kind),
                    enabled: tunnel.isEnabled,
                    state: missingSecrets.contains(tunnel.id)
                        ? "secret missing" : Self.stateText(tunnelState(tunnel.id)))
            },
            groups: store.groups.map { group in
                .init(
                    id: group.id, name: group.name,
                    members: group.members.map { store.tunnel(id: $0)?.name ?? $0.uuidString },
                    using: activeMember(of: group)?.name)
            },
            rules: store.rules.count,
            logLevel: store.settings.logLevel,
            planHash: status?.planHash,
            lastApplyError: lastApplyError,
            pending: controlPending.map { ControlPendingInfo($0) })
    }

    struct ControlFailedReply: Encodable {
        struct Row: Encodable {
            var host: String
            var app: String?
            var tries: Int
            var why: String
            var via: String
            var lastSeen: Date
        }

        struct Exit: Encodable {
            var name: String
            var using: String?
            var connections: Int?
            var reached: Int?
            var failed: Int
            var lastFailure: String?
        }

        var since: Date?
        var failed: [Row]
        var exits: [Exit]
    }

    func controlFailed() -> ControlFailedReply {
        ControlFailedReply(
            since: failedSince,
            failed: failedHosts.map { row in
                .init(
                    host: row.host, app: row.processPath, tries: row.count,
                    why: failedReason(row), via: failedVia(row), lastSeen: row.lastSeen)
            },
            exits: exitRows(window: .sinceTurnOn).map { row in
                .init(
                    name: row.name, using: row.usingMember, connections: row.connections,
                    reached: row.reached, failed: row.failed, lastFailure: row.lastFailureText)
            })
    }

    struct ControlListInfo: Encodable {
        var id: UUID
        var name: String
        var target: RuleListTarget
        var via: String
        var enabled: Bool
        var showInMenu: Bool
        var rows: Int
        var priority: Int
        var warning: String?
    }

    func controlLists() -> [ControlListInfo] {
        store.lists.enumerated().map { index, list in
            ControlListInfo(
                id: list.id, name: list.name, target: list.target,
                via: controlExitName(store.resolvedTarget(list.target)), enabled: list.isEnabled,
                showInMenu: list.showInMenu, rows: store.rules(in: list.id).count, priority: index,
                warning: list.isEnabled
                    ? listExitWarning(store.resolvedTarget(list.target)) : "list paused")
        }
    }

    func controlRules(via: String?) throws -> [ControlRuleInfo] {
        let target = try via.map(resolveExit)
        // Keep paused and disabled rows visible, after the active exception tier.
        let ordered = store.lists.flatMap { store.rules(in: $0.id) }
        let exceptions = ordered.filter { rule in
            rule.listID.flatMap { store.list(id: $0)?.isEnabled } == true && rule.isEnabled
                && store.declaredTarget(for: rule) == .exit(.direct)
        }
        let exceptionIDs = Set(exceptions.map(\.id))
        return (exceptions + ordered.filter { !exceptionIDs.contains($0.id) })
            .filter { target == nil || store.target(for: $0) == target }
            .map { rule in
                let list = rule.listID.flatMap { store.list(id: $0) }
                let shadow = ruleIssues[rule.id]?.compactMap { issue -> String? in
                    guard case .shadowed(let id) = issue,
                        let winner = store.rules.first(where: { $0.id == id })
                    else { return nil }
                    let name = winner.listID.flatMap { store.list(id: $0)?.name } ?? "earlier list"
                    return "shadowed by \(name): \(winner.pattern)"
                }.first
                let warning =
                    list?.isEnabled == false
                    ? "list paused"
                    : (!rule.isEnabled
                        ? "row paused" : (listExitWarning(store.target(for: rule)) ?? shadow))
                return ControlRuleInfo(
                    rule, via: controlExitName(store.target(for: rule)), store: store,
                    warning: warning)
            }
    }

    private func controlSetList(_ params: ControlParams) async throws -> Result<Data, ControlError>
    {
        guard let text = params.list, let via = params.via else {
            throw ControlError(.badRequest, "list and via are required")
        }
        let list = try resolveList(text)
        let target: RuleListTarget =
            via.lowercased() == "default"
            ? .everythingElse : .exit(try resolveExit(via))
        guard list.target != target else {
            throw ControlError(.invalid, "list already uses this route")
        }
        return try await commit(
            .setListTarget(id: list.id, from: list.target, to: target),
            description: "route list \(list.name) via \(via)", rule: nil, params: params)
    }

    private func resolveList(_ text: String) throws -> RuleList {
        if let id = UUID(uuidString: text) {
            guard let list = store.list(id: id) else {
                throw ControlError(.notFound, "no list with id \(text)")
            }
            return list
        }
        let matches = store.lists.filter { $0.name.lowercased() == text.lowercased() }
        guard matches.count == 1 else {
            throw ControlError(
                matches.isEmpty ? .notFound : .invalid,
                "list \(text) is missing or ambiguous; use a list id")
        }
        return matches[0]
    }

    // MARK: - Changes

    private func controlAddRule(_ params: ControlParams) async throws -> Result<Data, ControlError>
    {
        guard var input = params.pattern, !input.isEmpty else {
            throw ControlError(.badRequest, "pattern is required")
        }
        guard params.via != nil || params.list != nil else {
            throw ControlError(.badRequest, "--list or --via is required")
        }
        let target = try params.via.map(resolveExit)
        var inferred: RuleMatch?
        if let message = translateFakeIP(&input, match: &inferred) {
            throw ControlError(.invalid, message)
        }
        // F23: an absolute `.app` path is an app rule here (never in the popover); a network
        // narrows app and IP rules only.
        let match = inferred ?? RulePattern.inferControlMatch(input)
        if params.network != nil, !(match == .app || match == .ip) {
            throw ControlError(
                .badRequest,
                "--network applies to app and IP rules only; \(input) is a domain pattern")
        }
        var candidate = store
        let listID: UUID
        if let text = params.list {
            listID = try resolveList(text).id
        } else {
            listID = candidate.ensureList(for: target!)
        }
        let createdList = store.list(id: listID) == nil ? candidate.list(id: listID) : nil
        switch QuickAdd.evaluate(
            input: input, listID: listID, store: candidate, network: params.network, match: match)
        {
        case .invalid(let message):
            throw ControlError(.invalid, message)
        case .add(var rule):
            rule.target = params.list == nil ? nil : target
            return try await commit(
                createdList.map { .batch([.insertList($0), .insertRule(rule, before: nil)]) }
                    ?? .insertRule(rule, before: nil),
                description:
                    "add \(rule.pattern)\(networkSuffix(rule.network)) → \(controlExitName(candidate.target(for: rule)))",
                rule: rule,
                params: params)
        case .update(var rule):
            rule.target = params.list == nil ? nil : target
            guard let current = store.rules.first(where: { $0.id == rule.id }) else {
                throw ControlError(.internal, "rule \(rule.pattern) vanished")
            }
            guard current != rule else {
                throw ControlError(
                    .invalid,
                    "\(rule.pattern) already goes via \(controlExitName(candidate.target(for: rule)))"
                )
            }
            return try await commit(
                .replaceRule(from: current, to: rule),
                description:
                    "route \(rule.pattern)\(networkSuffix(rule.network)) via \(controlExitName(candidate.target(for: rule))) (was \(controlExitName(store.target(for: current))))",
                rule: rule, params: params)
        }
    }

    private func controlRemoveRule(_ params: ControlParams) async throws -> Result<
        Data, ControlError
    > {
        guard let text = params.pattern, !text.isEmpty else {
            throw ControlError(.badRequest, "a pattern or a rule id is required")
        }
        let rule = try findRule(text)
        return try await commit(
            StoreEdit.removal(of: rule, in: store),
            description:
                "remove \(rule.pattern)\(networkSuffix(rule.network)) → \(controlExitName(store.target(for: rule)))",
            rule: rule,
            params: params)
    }

    private func controlSetLogLevel(_ params: ControlParams) async throws -> Result<
        Data, ControlError
    > {
        guard let level = params.level else { throw ControlError(.badRequest, "level is required") }
        let current = store.settings.logLevel
        guard current != level else {
            throw ControlError(.invalid, "log level is already \(level.rawValue)")
        }
        return try await commit(
            .setLogLevel(from: current, to: level),
            description: "log level \(current.rawValue) → \(level.rawValue)", rule: nil,
            params: params)
    }

    private func commit(
        _ edit: StoreEdit, description: String, rule: Rule?, params: ControlParams
    ) async throws -> Result<Data, ControlError> {
        guard !persistenceDisabled else {
            throw ControlError(.internal, "store persistence is disabled")
        }
        var candidate = store
        if let skipped = edit.apply(to: &candidate) { throw ControlError(.invalid, skipped) }
        let info = rule.map {
            ControlRuleInfo($0, via: controlExitName(candidate.target(for: $0)), store: candidate)
        }
        if params.dryRun == true {
            return ControlWire.encodeResult(
                ControlChangeReply(change: description, dryRun: true, rule: info))
        }
        if let pending = controlPending {
            throw ControlError(
                .pendingChange,
                "\"\(pending.description)\" is waiting: run `wayforkctl confirm` or `wayforkctl revert` first"
            )
        }
        let seconds = try ControlDeadline.seconds(params.confirmWithin)
        if let seconds {
            let pending = PendingControlChange(
                edit: edit, description: description,
                deadline: Date().addingTimeInterval(TimeInterval(seconds)))
            do {
                let url = ControlPaths.pending()
                try Self.controlEncoder.encode(pending).write(to: url, options: [.atomic])
                chmod(url.path, 0o600)
            } catch {
                throw ControlError(.internal, "cannot persist rollback: \(error)")
            }
            setControlPending(pending)
            logs.app(
                .info, "control: \(description) — undone in \(seconds) s unless confirmed")
        } else {
            logs.app(.info, "control: \(description)")
        }
        update { $0 = candidate }
        let applyError = await settleApply()
        return ControlWire.encodeResult(
            ControlChangeReply(
                change: description, rule: info, applied: applyError == nil,
                applyError: applyError, pending: controlPending.map { ControlPendingInfo($0) }))
    }

    private func controlConfirm() async throws -> Result<Data, ControlError> {
        guard let pending = controlPending else {
            throw ControlError(.noPendingChange, "nothing to confirm")
        }
        guard controlResolution.begin(.confirm, pending: pending) else {
            throw ControlError(.pendingChange, "pending change is being resolved")
        }
        defer { controlResolution.end(pending) }
        try await persistControlStore()
        guard controlResolution.owns(pending, current: controlPending) else {
            throw ControlError(.pendingChange, "pending change changed during confirmation")
        }
        try clearControlPendingFile()
        setControlPending(nil)
        logs.app(.info, "control: confirmed \"\(pending.description)\"")
        return ControlWire.encodeResult(
            ControlChangeReply(change: "confirmed: \(pending.description)"))
    }

    private func controlRevert() async throws -> Result<Data, ControlError> {
        guard let pending = controlPending else {
            throw ControlError(.noPendingChange, "nothing to revert")
        }
        guard !controlResolution.isBusy else {
            throw ControlError(.pendingChange, "pending change is being resolved")
        }
        let skipped = await revertControlChange(.requested)
        let applyError = await settleApply()
        return ControlWire.encodeResult(
            ControlChangeReply(
                change: "reverted: \(pending.description)", applied: applyError == nil,
                applyError: applyError, skipped: skipped))
    }

    private func controlReconnect(_ params: ControlParams) throws -> Result<Data, ControlError> {
        guard let text = params.tunnel else {
            throw ControlError(.badRequest, "tunnel is required")
        }
        guard case .tunnel(let id) = try resolveExit(text) else {
            throw ControlError(.invalid, "\(text) is not a tunnel")
        }
        guard desiredOn else { throw ControlError(.invalid, "Wayfork is off") }
        reconnect(id)
        return ControlWire.encodeResult(
            ControlChangeReply(change: "reconnect \(store.tunnel(id: id)?.name ?? text)"))
    }

    // MARK: - Pending change

    func setControlPending(_ pending: PendingControlChange?, retryDelay: TimeInterval = 0) {
        controlPending = pending
        controlDeadlineTask?.cancel()
        controlDeadlineTask = nil
        let url = ControlPaths.pending()
        guard let pending else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        controlDeadlineTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(max(retryDelay, pending.deadline.timeIntervalSinceNow)))
            while self?.controlResolution.isBusy == true {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            _ = await self?.revertControlChange(.deadline)
        }
    }

    /// Applies the pending change's inverse. Returns why (part of) it was skipped.
    @discardableResult
    func revertControlChange(_ reason: ControlRevertReason) async -> String? {
        guard let pending = controlPending else { return nil }
        guard controlResolution.begin(.revert, pending: pending) else {
            return "pending change is being resolved"
        }
        defer { controlResolution.end(pending) }
        var skipped: String?
        update { skipped = pending.edit.inverse.apply(to: &$0) }
        do {
            // Keep the journal until the inverse is durable. A crash in this interval
            // retries the guarded inverse; it cannot leave the forward change permanent.
            try await persistControlStore()
            guard controlResolution.owns(pending, current: controlPending) else {
                throw ControlError(.pendingChange, "pending change changed during rollback")
            }
            try clearControlPendingFile()
        } catch {
            let message = "cannot finish rollback: \(error); pending journal retained"
            logs.app(.error, message)
            if controlPending == pending { setControlPending(pending, retryDelay: 5) }
            return message
        }
        setControlPending(nil)
        let why =
            switch reason {
            case .requested: "revert requested"
            case .deadline: "not confirmed in time"
            case .leftover: "the app quit before it was confirmed"
            }
        logs.app(
            .warning,
            "control: reverted \"\(pending.description)\" (\(why))"
                + (skipped.map { "; skipped: \($0)" } ?? ""))
        if reason != .requested {
            notifier.post(
                id: "control-revert", title: "Wayfork undid a change",
                body: "\(pending.description) was made from the command line and not confirmed.")
        }
        return skipped
    }

    private func clearControlPendingFile() throws {
        let url = ControlPaths.pending()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    /// `direct`, a tunnel or group id, or a name (case-insensitive, tunnels first).
    func resolveExit(_ text: String) throws -> RuleTarget {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "direct" { return .direct }
        if let id = UUID(uuidString: trimmed) {
            if store.tunnel(id: id) != nil { return .tunnel(id) }
            if store.group(id: id) != nil { return .group(id) }
        }
        let name = trimmed.lowercased()
        let tunnels = store.tunnels.filter { $0.name.lowercased() == name }
        let groups = store.groups.filter { $0.name.lowercased() == name }
        switch (tunnels.count, groups.count) {
        case (1, 0): return .tunnel(tunnels[0].id)
        case (0, 1): return .group(groups[0].id)
        case (0, 0):
            let names = store.tunnels.map(\.name) + store.groups.map(\.name)
            throw ControlError(
                .notFound,
                "no tunnel or group named \(trimmed); known: \(names.joined(separator: ", ")), direct"
            )
        default:
            throw ControlError(.invalid, "\(trimmed) names more than one exit; use its id")
        }
    }

    /// A rule by id, or by pattern as typed or normalized.
    private func findRule(_ text: String) throws -> Rule {
        if let id = UUID(uuidString: text), let rule = store.rules.first(where: { $0.id == id }) {
            return rule
        }
        var candidates = [text.lowercased()]
        if let normalized = try? RulePattern.normalize(text, match: RulePattern.inferMatch(text)) {
            candidates.append(normalized)
        }
        let matches = store.rules.filter { candidates.contains($0.pattern.lowercased()) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw ControlError(.notFound, "no rule for \(text)")
        default:
            throw ControlError(
                .invalid,
                "\(text) matches \(matches.count) rules; use an id: "
                    + matches.map(\.id.uuidString).joined(separator: ", "))
        }
    }

    private func networkSuffix(_ network: RuleNetwork?) -> String {
        network.map { " (\($0.rawValue.uppercased()) only)" } ?? ""
    }

    private func controlExitName(_ target: RuleTarget?) -> String {
        target?.exitID.flatMap { store.exitName(id: $0) } ?? "direct"
    }

    private static func engineText(_ engine: EngineState?) -> String {
        switch engine {
        case nil: "unknown"
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .failed(let reason): "failed: \(reason)"
        }
    }

    private static func stateText(_ state: TunnelState?) -> String {
        switch state {
        case nil: "unknown"
        case .disabled: "disabled"
        case .connecting(let attempt): "connecting (attempt \(attempt))"
        case .connected: "connected"
        case .reconnecting(let attempt, _, let reason):
            "reconnecting (attempt \(attempt))" + (reason.map { ": \($0)" } ?? "")
        case .failed(let reason, _): "failed: \(reason)"
        }
    }

    private static func kindText(_ kind: TunnelKind) -> String {
        switch kind {
        case .openVPN: "openvpn"
        case .vless: "vless"
        case .wireGuard: "wireguard"
        case .shadowsocks: "shadowsocks"
        case .trojan: "trojan"
        case .vmess: "vmess"
        }
    }

    private static let controlEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let controlDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
