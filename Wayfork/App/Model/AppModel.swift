import AppKit
import Foundation
import Observation
import WayforkCore

/// Single owner of the app state: store, runtime status, helper state and the derived global
/// state (docs/design/00-architecture.md, "Concurrency"; docs/design/02-ux.md).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum SettingsSection: String, CaseIterable, Identifiable {
        case tunnels, rules, general
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Field to focus when Settings › Tunnels opens on a tunnel (✎ from a failure).
    enum TunnelField: Hashable {
        case name, username, password, keyPassphrase, config, url
    }

    // MARK: - State

    private(set) var store: Store = .empty
    private(set) var status: RuntimeStatus?
    private(set) var transition: AppTransition?
    /// The user wants routing on; survives daemon restarts until the user turns it off.
    private(set) var desiredOn = false
    private(set) var helperState: HelperInstaller.State = .notInstalled
    /// Shown instead of the summary while waiting for the helper approval.
    private(set) var helperMessage: String?
    private(set) var daemonInfo: DaemonInfo?
    /// Latest traffic sample (F9); nil while off and when no sample arrived for
    /// `TrafficFormat.staleAfter` seconds, so the popover shows `—` instead of stale figures.
    private(set) var traffic: TrafficSnapshot?
    /// Tunnels whose OpenVPN body / VLESS UUID is not in Keychain (imported without secrets).
    private(set) var missingSecrets: Set<UUID> = []
    private(set) var iconPulse = false
    /// Set when `store.json` was written by a newer version: never overwrite it.
    private(set) var persistenceDisabled = false

    // MARK: - Navigation

    var settingsSection: SettingsSection = .tunnels
    var expandedTunnelID: UUID?
    var pendingFocus: TunnelField?
    /// Source to preselect when the Logs window opens ("Show Log").
    var logsPreselectedSource: String?
    /// Last tunnel used by quick add.
    var quickAddTarget: RuleTarget?
    /// Set by the scenes; `openWindow` is only reachable from views.
    var windowOpener: ((String) -> Void)?

    static let settingsWindowID = "settings"
    static let logsWindowID = "logs"

    // MARK: - Collaborators

    let logs = LogCenter()
    let secrets: any SecretStore
    private let repository: StoreRepository
    private let client = DaemonClient()
    private let helper = HelperInstaller()
    private let notifier = Notifier()

    private var applyTask: Task<Void, Never>?
    private var startingTimeoutTask: Task<Void, Never>?
    private var pulseTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var trafficStaleTask: Task<Void, Never>?
    private(set) var lastPlan: RuntimePlan?
    private var bootstrapped = false

    init(
        secrets: any SecretStore = KeychainSecretStore(),
        repository: StoreRepository = StoreRepository(
            directory: StoreRepository.defaultDirectory())
    ) {
        self.secrets = secrets
        self.repository = repository
        client.onStatus = { [weak self] status in self?.handleStatus(status) }
        client.onLogLines = { [weak self] lines in self?.logs.receive(lines) }
        client.onTraffic = { [weak self] snapshot in self?.handleTraffic(snapshot) }
        client.onInterruption = { [weak self] in self?.handleDaemonInterruption() }
        client.onInvalidation = { [weak self] in self?.handleDaemonInvalidation() }
    }

    // MARK: - Derived

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? WayforkCore.version
    }

    var bundlePath: String {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }

    /// CDHash of the daemon inside this bundle; the running daemon must report the same one.
    var daemonBuildID: String? {
        CodeSignature.uniqueIdentifier(ofExecutableAt: bundlePath + "/Contents/MacOS/WayforkDaemon")
    }

    private func matchesThisBuild(_ info: DaemonInfo) -> Bool {
        info.version == appVersion && info.bundlePath == bundlePath
            && info.buildID == daemonBuildID
    }

    var globalState: GlobalState {
        GlobalStateDerivation.derive(store: store, status: status, transition: transition)
    }

    var summary: String {
        helperMessage
            ?? StatusText.summary(
                state: globalState, store: store, status: status, missingSecrets: missingSecrets)
    }

    var menuBarIconName: String {
        switch globalState {
        case .off: "MenuBarOff"
        case .starting, .stopping: iconPulse ? "MenuBarOn" : "MenuBarOff"
        case .on: "MenuBarOn"
        case .degraded: "MenuBarDegraded"
        case .error: "MenuBarError"
        }
    }

    var settings: Settings { store.settings }

    var ruleIssues: [UUID: [RuleIssue]] {
        RuleValidator.validate(store, localNetworks: localNetworks)
    }

    /// The Mac's own networks for the "covers your LAN" chip (F11), looked up at most every
    /// 10 s — `ruleIssues` is evaluated per row render.
    @ObservationIgnored private var localNetworksCache: (at: Date, networks: [LocalNetwork])?
    private var localNetworks: [LocalNetwork] {
        if let cache = localNetworksCache, Date().timeIntervalSince(cache.at) < 10 {
            return cache.networks
        }
        let networks = LocalNetwork.current()
        localNetworksCache = (Date(), networks)
        return networks
    }

    func tunnelState(_ id: UUID) -> TunnelState? {
        status?.tunnels[id.uuidString.lowercased()]
    }

    /// Traffic figures of a tunnel; nil when there is no fresh sample (shown as `—`).
    func trafficCounters(for tunnel: Tunnel) -> TrafficCounters? {
        traffic?.counters(forTunnel: tunnel.id.uuidString.lowercased())
    }

    var directTraffic: TrafficCounters? { traffic?.direct }

    func ruleCount(for tunnelID: UUID) -> Int {
        store.rules(for: tunnelID).count
    }

    func ruleCount(for target: RuleTarget) -> Int {
        store.rules(for: target).count
    }

    func card(for tunnel: Tunnel) -> TunnelPresentation {
        StatusText.card(
            tunnel: tunnel, state: tunnelState(tunnel.id), global: globalState,
            ruleCount: ruleCount(for: tunnel.id), missingSecret: missingSecrets.contains(tunnel.id),
            isDefault: effectiveDefaultTunnel?.id == tunnel.id)
    }

    func rowSummary(for tunnel: Tunnel) -> (text: String, glyph: StatusGlyph, isError: Bool) {
        StatusText.rowSummary(
            tunnel: tunnel, state: tunnelState(tunnel.id), global: globalState,
            missingSecret: missingSecrets.contains(tunnel.id),
            isDefault: effectiveDefaultTunnel?.id == tunnel.id)
    }

    // MARK: - Default tunnel (F8)

    /// The tunnel actually taking "everything else": set, enabled and with its secret.
    var effectiveDefaultTunnel: Tunnel? {
        StatusText.effectiveDefaultTunnel(store, missingSecrets: missingSecrets)
    }

    var defaultTunnelIssue: DefaultTunnelIssue? {
        RuleValidator.defaultTunnelIssue(store, missingSecrets: missingSecrets)
    }

    func isDefaultTunnel(_ id: UUID) -> Bool {
        store.defaultTunnelID == id
    }

    /// Only one tunnel can be the default; nil clears it. A change restarts the routing
    /// engine (`route.final` changes), which the apply pipeline handles.
    func setDefaultTunnel(_ id: UUID?) {
        guard store.defaultTunnelID != id else { return }
        update { $0.defaultTunnelID = id }
        if let id {
            logs.app(.info, "default tunnel: \(tunnelName(id))")
        } else {
            logs.app(.info, "default tunnel cleared")
        }
    }

    /// Hint under the "Route everything else" toggle (docs/design/02-ux.md, "Tunnels").
    func defaultTunnelHint(for tunnel: Tunnel) -> (text: String, isWarning: Bool) {
        guard isDefaultTunnel(tunnel.id) else {
            return ("Domains without a rule use this tunnel instead of going direct.", false)
        }
        switch defaultTunnelIssue {
        case .disabled:
            return ("Disabled — everything else goes direct.", true)
        case .missingSecret:
            let what = tunnel.kind.isOpenVPN ? "Config" : "UUID"
            return ("\(what) missing — everything else goes direct.", true)
        case .missing, .none:
            return (
                "Domains without a rule use this tunnel; add exceptions in Rules › Direct. While it is down, unmatched traffic is blocked.",
                false
            )
        }
    }

    /// Header hint of the Direct group in Settings › Rules.
    var directGroupHint: String {
        if let tunnel = effectiveDefaultTunnel {
            return "Everything else goes through \(tunnel.name); these domains stay direct"
        }
        return "Overrides tunnel rules; everything unmatched already goes direct"
    }

    /// Discovered DNS for an OpenVPN tunnel (live status first, then the stored value).
    func discoveredDNS(for tunnel: Tunnel) -> [String] {
        if let live = status?.discoveredDNS[tunnel.id.uuidString.lowercased()], !live.isEmpty {
            return live
        }
        return tunnel.kind.openVPN?.discoveredDNS ?? []
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        logs.app(.info, "Wayfork \(appVersion) starting")
        do {
            let result = try await repository.load()
            store = result.store
            if let backup = result.corruptBackup {
                logs.app(.error, "store.json was unreadable; backup at \(backup.path)")
                if Alerts.show(
                    title: "Settings were reset",
                    message:
                        "Settings file was unreadable and has been reset. A backup is at \(backup.path).",
                    buttons: ["OK", "Reveal in Finder"]) == 1
                {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                }
            }
        } catch StoreRepository.Error.newerSchema(let found, let supported) {
            persistenceDisabled = true
            logs.app(.error, "store.json schema \(found) is newer than supported \(supported)")
            Alerts.show(
                title: "Settings from a newer Wayfork",
                message:
                    "The settings file was written by a newer Wayfork (schema \(found); this version supports \(supported)). Wayfork will not modify it; update the app to use these settings.",
                style: .critical)
        } catch {
            logs.app(.error, "cannot load store: \(error)")
        }
        try? secrets.removeOrphans(keeping: store)
        seedFromDirectory()
        recomputeMissingSecrets()
        logs.minimumLevel = store.settings.logLevel
        logs.prune(retentionDays: store.settings.logRetentionDays)
        scheduleDailyPrune()
        syncLaunchAtLogin()
        refreshHelperState()
        if helperState == .enabled {
            await attachToRunningDaemon()
        }
        if store.settings.connectOnLaunch, !desiredOn {
            await turnOn()
        }
    }

    /// App (re)launch while the daemon may still be routing: reattach and mirror its state.
    private func attachToRunningDaemon() async {
        do {
            try await ensureConnected()
            if status?.engine.isRunning == true || status?.engine == .starting {
                desiredOn = true
                logs.app(.info, "reattached to a running helper")
            }
        } catch {
            logs.app(.warning, "helper not reachable at launch: \(error.localizedDescription)")
            client.disconnect()
        }
    }

    private func scheduleDailyPrune() {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard let self, !Task.isCancelled else { return }
                logs.prune(retentionDays: store.settings.logRetentionDays)
            }
        }
    }

    // MARK: - On / off

    func toggle() {
        Task {
            if desiredOn { await turnOff() } else { await turnOn() }
        }
    }

    func turnOn() async {
        guard !desiredOn, transition == nil else { return }
        logs.app(.info, "Turn On requested")
        desiredOn = true
        setTransition(.starting(since: Date()))
        do {
            try await ensureHelperApproved()
            try await ensureConnected()
            await applyNow()
            startStartingTimeout()
        } catch is CancellationError {
            desiredOn = false
            setTransition(nil)
        } catch {
            logs.app(.error, "Turn On failed: \(error.localizedDescription)")
            desiredOn = false
            setTransition(nil)
            reportHelperError(error)
        }
    }

    func turnOff() async {
        logs.app(.info, "Turn Off requested")
        desiredOn = false
        applyTask?.cancel()
        startingTimeoutTask?.cancel()
        helperMessage = nil
        setTransition(.stopping)
        if client.isConnected {
            do {
                let result = try await client.stop()
                if !result.ok, let error = result.error {
                    logs.app(.error, "stop failed: \(error)")
                }
                status = try await client.getStatus()
            } catch {
                logs.app(.error, "stop failed: \(error.localizedDescription)")
                status = nil
            }
        } else {
            status = nil
        }
        clearTraffic()
        setTransition(nil)
    }

    /// Quit: stop everything, flush the store.
    func shutdown() async {
        if desiredOn || status?.engine.isRunning == true {
            await turnOff()
        }
        if !persistenceDisabled {
            try? await repository.flush()
        }
    }

    func reconnect(_ tunnelID: UUID) {
        guard client.isConnected else { return }
        logs.app(.info, "reconnect requested for \(store.tunnel(id: tunnelID)?.name ?? "?")")
        Task {
            do {
                let result = try await client.reconnect(tunnelID: tunnelID)
                if !result.ok, let error = result.error {
                    logs.app(.warning, "reconnect: \(error)")
                }
            } catch {
                logs.app(.error, "reconnect failed: \(error.localizedDescription)")
            }
        }
    }

    private func setTransition(_ new: AppTransition?) {
        transition = new
        pulseTask?.cancel()
        pulseTask = nil
        iconPulse = false
        guard new != nil else { return }
        pulseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                iconPulse.toggle()
            }
        }
    }

    private func startStartingTimeout() {
        startingTimeoutTask?.cancel()
        startingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(GlobalStateDerivation.startingTimeout))
            guard let self, !Task.isCancelled else { return }
            if case .starting = transition {
                setTransition(nil)
            }
        }
    }

    // MARK: - Helper

    func refreshHelperState() {
        helperState = helper.state
    }

    /// Registers the daemon if needed and waits for the one-time approval
    /// (docs/design/02-ux.md, "First run and helper approval").
    private func ensureHelperApproved() async throws {
        refreshHelperState()
        if helperState == .enabled { return }
        if helperState == .notInstalled || helperState == .notFound {
            try helper.register()
            refreshHelperState()
        }
        guard helperState != .enabled else { return }
        guard helperState == .requiresApproval else {
            throw AppError.helper("The helper could not be registered (\(helperState)).")
        }
        logs.app(.info, "helper requires approval in System Settings")
        let choice = Alerts.show(
            title: "Allow Wayfork to run in the background",
            message:
                "Wayfork needs a helper with system privileges to create the tunnel interface. Open System Settings → Login Items and enable Wayfork under \"Allow in the Background\". Wayfork continues automatically once it's enabled.",
            buttons: ["Open System Settings", "Cancel"], style: .informational)
        guard choice == 0 else { throw CancellationError() }
        HelperInstaller.openLoginItems()
        helperMessage = "Waiting for approval in System Settings…"
        defer { helperMessage = nil }
        let approved = await helper.waitUntilEnabled()
        refreshHelperState()
        guard approved, desiredOn else { throw CancellationError() }
        logs.app(.info, "helper approved")
    }

    /// Connects, checks version/bundle path, re-registers on mismatch, then attaches the
    /// status/log streams.
    private func ensureConnected() async throws {
        client.connect()
        var info = try await client.getInfo()
        if !matchesThisBuild(info) {
            logs.app(
                .info,
                "helper \(info.version) (\(info.buildID?.prefix(8) ?? "unsigned")) at \(info.bundlePath) does not match app \(appVersion) (\(daemonBuildID?.prefix(8) ?? "unsigned")) at \(bundlePath); reinstalling"
            )
            client.disconnect()
            try await helper.reinstall()
            refreshHelperState()
            if helperState != .enabled {
                try await ensureHelperApproved()
            }
            client.connect()
            info = try await client.getInfo()
            if !matchesThisBuild(info) {
                throw AppError.helper(
                    "The helper still reports version \(info.version) (\(info.buildID?.prefix(8) ?? "unsigned")) at \(info.bundlePath)."
                )
            }
        }
        daemonInfo = info
        logs.app(.info, "helper \(info.version) connected")
        status = try await client.getStatus()
        _ = try await client.subscribe()
    }

    func installHelper() async {
        do {
            try await ensureHelperApproved()
            try await ensureConnected()
        } catch is CancellationError {
        } catch {
            reportHelperError(error)
        }
        refreshHelperState()
    }

    func reinstallHelper() async {
        logs.app(.info, "reinstalling helper")
        let wasOn = desiredOn
        if wasOn { await turnOff() }
        client.disconnect()
        do {
            try await helper.reinstall()
        } catch {
            reportHelperError(error)
        }
        refreshHelperState()
        if wasOn { await turnOn() }
    }

    private func reportHelperError(_ error: any Error) {
        if let failure = error as? DaemonClient.Failure {
            let choice = Alerts.show(
                title: "Can't reach the Wayfork helper",
                message: failure.localizedDescription,
                buttons: ["OK", "Reinstall Helper"])
            if choice == 1 { Task { await reinstallHelper() } }
            return
        }
        Alerts.show(title: "Helper error", message: error.localizedDescription)
    }

    private func handleDaemonInterruption() {
        guard client.isConnected else { return }
        logs.app(.warning, "helper connection interrupted")
        daemonInfo = nil
        status = nil
        clearTraffic()
        guard desiredOn else { return }
        Task {
            do {
                try await ensureConnected()
                await applyNow()
            } catch {
                logs.app(.error, "reattach failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleDaemonInvalidation() {
        logs.app(.warning, "helper connection lost")
        daemonInfo = nil
        status = nil
        clearTraffic()
        refreshHelperState()
        if desiredOn {
            desiredOn = false
            setTransition(nil)
            if helperState != .enabled {
                notify(
                    id: "helper", title: "Wayfork helper disabled",
                    body: "Routing stopped because the helper was disabled in System Settings.")
            }
        }
    }

    // MARK: - Status

    private func handleStatus(_ new: RuntimeStatus) {
        let old = status
        status = new
        syncDiscoveredDNS(new)
        if !new.engine.isRunning { clearTraffic() }
        if case .starting = transition, globalState != .starting {
            startingTimeoutTask?.cancel()
            setTransition(nil)
        }
        if desiredOn, transition == nil, new.engine == .stopped, old?.engine != .stopped {
            // The daemon stopped on its own (restart after crash): reflect it.
            logs.app(.warning, "helper reports stopped")
        }
        for (id, state) in new.tunnels {
            guard case .failed(let reason, true) = state, old?.tunnels[id] != state else {
                continue
            }
            let name = UUID(uuidString: id).flatMap { store.tunnel(id: $0)?.name } ?? id
            logs.app(.error, "tunnel \(name) failed: \(reason)")
            notify(
                id: "tunnel-\(id)", title: "\(name) failed",
                body: StatusText.failureMessage(code: reason))
        }
        if case .failed(let reason) = new.engine, old?.engine != new.engine {
            logs.app(.error, "routing engine failed: \(reason)")
            notify(
                id: "engine", title: "Routing engine failed",
                body: StatusText.failureMessage(code: reason))
        }
    }

    // MARK: - Traffic (F9)

    private func handleTraffic(_ snapshot: TrafficSnapshot) {
        guard desiredOn, status?.engine.isRunning == true else { return }
        traffic = snapshot
        trafficStaleTask?.cancel()
        trafficStaleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TrafficFormat.staleAfter))
            guard let self, !Task.isCancelled else { return }
            traffic = nil
        }
    }

    private func clearTraffic() {
        trafficStaleTask?.cancel()
        trafficStaleTask = nil
        traffic = nil
    }

    private func syncDiscoveredDNS(_ status: RuntimeStatus) {
        for (key, servers) in status.discoveredDNS {
            guard let id = UUID(uuidString: key),
                let index = store.tunnels.firstIndex(where: { $0.id == id }),
                case .openVPN(var meta) = store.tunnels[index].kind, meta.discoveredDNS != servers
            else { continue }
            meta.discoveredDNS = servers
            logs.app(
                .info, "\(store.tunnels[index].name) pushed DNS \(servers.joined(separator: ", "))")
            update { $0.tunnels[index].kind = .openVPN(meta) }
        }
    }

    private func notify(id: String, title: String, body: String) {
        guard store.settings.notifyOnTunnelFailure else { return }
        notifier.post(id: id, title: title, body: body)
    }

    // MARK: - Store changes and apply

    /// Every store mutation goes through here: persist (debounced) and re-apply while on.
    func update(_ mutate: (inout Store) -> Void) {
        var changed = store
        mutate(&changed)
        guard changed != store else { return }
        let tunnelsChanged = changed.tunnels != store.tunnels
        store = changed
        if !persistenceDisabled {
            Task { await repository.save(changed) }
        }
        if tunnelsChanged { recomputeMissingSecrets() }
        logs.minimumLevel = changed.settings.logLevel
        secretsChanged()
    }

    /// Call after Keychain writes too: they change the plan without touching the store.
    func secretsChanged() {
        guard desiredOn else { return }
        scheduleApply()
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.applyNow()
        }
    }

    /// Store → plan → `apply` (docs/design/00-architecture.md, "Runtime plan").
    func applyNow() async {
        guard desiredOn, client.isConnected else { return }
        let planSecrets: PlanSecrets
        do {
            planSecrets = try PlanSecrets.load(for: store, from: secrets)
        } catch {
            logs.app(.error, "cannot read secrets: \(error)")
            Alerts.show(title: "Keychain error", message: "Cannot read tunnel secrets: \(error)")
            return
        }
        let result = RuntimePlanBuilder.build(
            store: store, secrets: planSecrets, bundlePath: bundlePath)
        for warning in result.warnings {
            if case .missingSecret(let id) = warning {
                logs.app(.warning, "\(store.tunnel(id: id)?.name ?? "?") skipped: secret missing")
            }
        }
        lastPlan = result.plan
        let openVPN = result.plan.openVPN.count
        let vless = result.routedTunnels.count - openVPN
        logs.app(
            .info,
            "apply: plan \(result.plan.planHash.prefix(8)) (\(openVPN) openvpn, \(vless) vless, \(StatusText.activeRuleCount(store)) rules)"
        )
        do {
            let reply = try await client.apply(result.plan)
            if !reply.ok, let error = reply.error {
                handleApplyError(error)
            }
        } catch {
            logs.app(.error, "apply failed: \(error.localizedDescription)")
            reportHelperError(error)
        }
    }

    private func handleApplyError(_ error: DaemonError) {
        logs.app(.error, "apply rejected: \(error)")
        switch error {
        case .configInvalid(let output):
            let first = output.split(separator: "\n").first.map(String.init) ?? "unknown error"
            if Alerts.show(
                title: "Routing config rejected",
                message:
                    "Routing config rejected: \(first)\n\nThis should not happen with generated configs; please export diagnostics and report it.",
                buttons: ["OK", "Export Diagnostics…"]) == 1
            {
                Task { await exportDiagnostics(includeServerAddresses: false) }
            }
        case .startFailed:
            if Alerts.show(
                title: "Routing engine failed to start",
                message: "Routing engine failed to start. Another VPN may be active.",
                buttons: ["OK", "Show Log"]) == 1
            {
                openLogs(source: "sing-box")
            }
        case .binaryUntrusted(let path):
            Alerts.show(
                title: "Bundled binary rejected",
                message: "The helper refused to run \(path): signature validation failed.",
                style: .critical)
        case .planInvalid(let reason):
            Alerts.show(title: "Plan rejected", message: reason)
        case .tunnelNotFound, .notRunning, .internalError:
            Alerts.show(title: "Helper error", message: "\(error)")
        }
    }

    // MARK: - Secrets bookkeeping

    func recomputeMissingSecrets() {
        var missing: Set<UUID> = []
        for tunnel in store.tunnels {
            let key: SecretKey = tunnel.kind.isOpenVPN ? .ovpn(tunnel.id) : .uuid(tunnel.id)
            if (try? secrets.read(key)) ?? nil == nil {
                missing.insert(tunnel.id)
            }
        }
        missingSecrets = missing
    }

    // MARK: - Settings

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        let before = store.settings
        update { mutate(&$0.settings) }
        let after = store.settings
        if before.launchAtLogin != after.launchAtLogin {
            do {
                try HelperInstaller.setLaunchAtLogin(after.launchAtLogin)
            } catch {
                logs.app(.error, "launch at login: \(error.localizedDescription)")
                Alerts.show(title: "Launch at login", message: error.localizedDescription)
                update { $0.settings.launchAtLogin = HelperInstaller.launchAtLoginEnabled }
            }
        }
        if before.logRetentionDays != after.logRetentionDays {
            logs.prune(retentionDays: after.logRetentionDays)
        }
    }

    private func syncLaunchAtLogin() {
        let actual = HelperInstaller.launchAtLoginEnabled
        if store.settings.launchAtLogin != actual {
            update { $0.settings.launchAtLogin = actual }
        }
    }

    // MARK: - Windows

    func openSettings(section: SettingsSection, tunnel: UUID? = nil, focus: TunnelField? = nil) {
        settingsSection = section
        if let tunnel {
            expandedTunnelID = tunnel
            pendingFocus = focus
        }
        NSApp.activate(ignoringOtherApps: true)
        windowOpener?(AppModel.settingsWindowID)
    }

    func openLogs(source: String? = nil) {
        logsPreselectedSource = source
        NSApp.activate(ignoringOtherApps: true)
        windowOpener?(AppModel.logsWindowID)
    }

    /// Where the ✎ on a failed card leads.
    func perform(_ action: FailureAction, tunnel: Tunnel) {
        switch action {
        case .editCredentials: openSettings(section: .tunnels, tunnel: tunnel.id, focus: .username)
        case .editKeyPassphrase:
            openSettings(section: .tunnels, tunnel: tunnel.id, focus: .keyPassphrase)
        case .replaceConfig:
            openSettings(
                section: .tunnels, tunnel: tunnel.id, focus: tunnel.kind.isOpenVPN ? .config : .url)
        case .showLog: openLogs(source: "openvpn:\(tunnel.id.uuidString.lowercased())")
        case .exportDiagnostics: Task { await exportDiagnostics(includeServerAddresses: false) }
        case .openSystemSettings: HelperInstaller.openLoginItems()
        case .reinstallHelper: Task { await reinstallHelper() }
        }
    }

    // MARK: - Diagnostics

    func exportDiagnostics(includeServerAddresses: Bool) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsExporter.suggestedFileName()
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return }
        var daemon: DaemonDiagnostics?
        if client.isConnected {
            daemon = try? await client.collectDiagnostics()
        }
        let input = DiagnosticsExporter.Input(
            store: store, plan: lastPlan ?? buildPlanForDiagnostics(), daemon: daemon,
            daemonInfo: daemonInfo, helperState: "\(helperState)", appVersion: appVersion,
            logDirectory: LogCenter.directory, includeServerAddresses: includeServerAddresses)
        do {
            try await DiagnosticsExporter.export(input, to: url)
            logs.app(.info, "diagnostics exported to \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            logs.app(.error, "diagnostics export failed: \(error)")
            Alerts.show(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func buildPlanForDiagnostics() -> RuntimePlan? {
        guard let planSecrets = try? PlanSecrets.load(for: store, from: secrets) else { return nil }
        return RuntimePlanBuilder.build(store: store, secrets: planSecrets, bundlePath: bundlePath)
            .plan
    }
}

enum AppError: Error, LocalizedError {
    case helper(String)
    case importFailed(String)
    case limit(String)

    var errorDescription: String? {
        switch self {
        case .helper(let message), .importFailed(let message), .limit(let message): message
        }
    }
}

/// Modal alerts for flows that run outside any window (menu bar app).
@MainActor
enum Alerts {
    /// Returns the index of the pressed button.
    @discardableResult
    static func show(
        title: String, message: String, buttons: [String] = ["OK"],
        style: NSAlert.Style = .warning
    ) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func confirm(title: String, message: String, destructive: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: destructive)
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
