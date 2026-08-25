import Darwin
import Foundation
import WayforkCore
import WayforkDaemonCore

/// Ordered notifications from the engine and the sessions; the supervisor folds them
/// into `RuntimeStatus`.
enum SupervisorEvent: Sendable {
    case engine(EngineState)
    case tunnel(id: String, state: TunnelState)
    case discoveredDNS(id: String, servers: [String])
}

/// Single owner of every child process. XPC handlers hop onto it; `apply`/`stop`/
/// `reconnect` run one at a time, status queries do not wait for them
/// (docs/design/05-daemon.md, "Supervisor"; docs/design/00-architecture.md, "Reconcile").
actor Supervisor {
    let env: DaemonEnvironment
    let hub: ClientHub
    private let engine: SingBoxEngine
    private let sampler: TrafficSampler
    private let events: AsyncStream<SupervisorEvent>
    private let eventSink: AsyncStream<SupervisorEvent>.Continuation
    private var sessions: [String: OpenVPNSession] = [:]
    private var status = RuntimeStatus.stopped
    private var plan: RuntimePlan?
    private var eventPump: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    private var applyGeneration = 0
    private var binaryVersions: (singBox: String, openVPN: String)?
    /// CDHash of the executable this process was started from, taken once at startup: after
    /// the app bundle is replaced the file at `env.executablePath` is already the *new*
    /// daemon, and hashing it on request made a stale process look up to date.
    private let buildID: String?

    init(env: DaemonEnvironment, hub: ClientHub) {
        self.env = env
        self.hub = hub
        buildID = CodeSignature.uniqueIdentifier(ofExecutableAt: env.executablePath)
        (events, eventSink) = AsyncStream.makeStream(
            of: SupervisorEvent.self, bufferingPolicy: .unbounded)
        sampler = TrafficSampler(hub: hub)
        engine = SingBoxEngine(env: env, hub: hub, events: eventSink, sampler: sampler)
    }

    // MARK: - Startup

    /// Kills leftovers from a previous daemon, wipes `run/`, removes stale routes.
    func bootstrap() async {
        startEventPump()
        await killLeftovers()
        wipeRunDirectory()
        await removeStaleRoutes()
        status = .stopped
        await hub.setStatus(status)
        hub.post(.info, "daemon \(env.version) ready (bundle \(env.bundlePath))")
        if env.teamID == nil {
            hub.post(.error, "WayforkTeamID is not set: this build rejects every client")
        }
    }

    private func killLeftovers() async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: env.runDirectory)) ?? []
        for name in names where RunLayout.isPIDFile(name) {
            guard let text = try? String(contentsOfFile: env.runPath(name), encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
            else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(
                decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard path.hasPrefix(env.binDirectory + "/") else { continue }
            hub.post(.warning, "killing leftover \(name) pid \(pid) (\(path))")
            kill(pid, SIGTERM)
            for _ in 0..<30 where kill(pid, 0) == 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    private func wipeRunDirectory() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: env.runDirectory)) ?? []
        for name in names where RunLayout.isTransient(name) {
            unlink(env.runPath(name))
        }
    }

    private func removeStaleRoutes() async {
        for unit in InterfaceName.openVPNUnits {
            let interface = "utun\(unit)"
            guard if_nametoindex(interface) != 0 else { continue }
            _ = await RouteHelper.deleteScopedDefault(interface: interface)
        }
    }

    private func startEventPump() {
        guard eventPump == nil else { return }
        let events = events
        eventPump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: SupervisorEvent) async {
        switch event {
        case .engine(let state):
            status.engine = state
        case .tunnel(let id, let state):
            guard sessions[id] != nil else { return }
            status.tunnels[id] = state
        case .discoveredDNS(let id, let servers):
            guard sessions[id] != nil else { return }
            status.discoveredDNS[id] = servers
        }
        await hub.setStatus(status)
    }

    // MARK: - XPC entry points

    func info() async -> DaemonInfo {
        if binaryVersions == nil {
            binaryVersions = (
                await binaryVersion(env.singBoxPath, name: "sing-box", arguments: ["version"]),
                await binaryVersion(env.openVPNPath, name: "openvpn", arguments: ["--version"])
            )
        }
        return DaemonInfo(
            version: env.version, bundlePath: env.bundlePath,
            buildID: buildID,
            singBoxVersion: binaryVersions?.singBox ?? "",
            openVPNVersion: binaryVersions?.openVPN ?? "")
    }

    func currentStatus() -> RuntimeStatus {
        status
    }

    func apply(_ plan: RuntimePlan) async -> ApplyResult {
        do {
            try PlanValidator.validate(plan)
        } catch {
            return .failure(error)
        }
        applyGeneration += 1
        let generation = applyGeneration
        return await serialized {
            // A newer plan is already queued: latest wins, this one is a no-op.
            let latest = await self.applyGeneration
            guard generation == latest else { return .success }
            return await self.performApply(plan)
        }
    }

    func stop() async -> ApplyResult {
        applyGeneration += 1
        return await serialized {
            await self.performStop()
            return .success
        }
    }

    func reconnect(tunnelID: String) async -> ApplyResult {
        await serialized {
            guard let session = await self.sessions[tunnelID] else {
                return .failure(.tunnelNotFound(id: tunnelID))
            }
            await session.reconnect()
            return .success
        }
    }

    func diagnostics() async -> DaemonDiagnostics {
        var tails = await hub.tails(200)
        let daemonTail = tails.removeValue(forKey: "daemon") ?? []
        var listing: [String] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: env.runDirectory)) ?? []
        for name in names.sorted() {
            let attributes = try? FileManager.default.attributesOfItem(atPath: env.runPath(name))
            let size = (attributes?[.size] as? Int) ?? 0
            let mode = (attributes?[.posixPermissions] as? Int) ?? 0
            listing.append(String(format: "%@ %o %d", name, mode, size))
        }
        var routes = "$ route -n get default\n" + (await RouteHelper.defaultRouteDescription())
        routes += "\n\n$ route -n get -inet 1.1.1.1\n"
        routes += (await RouteHelper.routeDescription(forAddress: "1.1.1.1"))
        if let table = try? await CommandRunner.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]) {
            routes +=
                "\n\n$ netstat -rn -f inet\n" + table.lines.prefix(200).joined(separator: "\n")
        }
        return DaemonDiagnostics(
            daemonLogTail: daemonTail, childLogTails: tails, runDirectoryListing: listing,
            routes: routes)
    }

    // MARK: - Reconcile

    private func performApply(_ plan: RuntimePlan) async -> ApplyResult {
        for (path, name) in [(env.singBoxPath, "sing-box"), (env.openVPNPath, "openvpn")] {
            do {
                try BinaryValidator.validate(path: path, name: name, teamID: env.teamID)
            } catch {
                hub.post(.error, "refusing to run untrusted binary \(path)")
                return .failure(error)
            }
        }
        let current = ReconcileState(
            singBoxRunning: await engine.isRunning,
            singBoxConfigHash: await engine.configHash,
            ruleSets: await engine.ruleSets,
            openVPN: await sessionKeys())
        let actions = ReconcilePlanner.plan(from: current, to: plan)
        hub.post(
            .info,
            "apply: sing-box \(actions.singBox), stop \(actions.stopOpenVPN.count), start \(actions.startOpenVPN.count) tunnel(s)"
        )

        await stopSessions(actions.stopOpenVPN)
        await engine.deleteRuleSets(actions.staleRuleSets)

        var failure: DaemonError?
        do {
            switch actions.singBox {
            case .none:
                break
            case .rewriteRuleSets(let files):
                try await engine.writeRuleSets(
                    plan.singBox.ruleSets.filter { files.contains($0.key) })
                hub.post(.info, "rule-sets updated in place (\(files.count) file(s))")
            case .start, .restart:
                try await engine.writeRuleSets(plan.singBox.ruleSets)
                try await engine.check(config: plan.singBox.config, hash: plan.singBox.configHash)
                if actions.singBox == .restart {
                    await engine.stop()
                }
                try await engine.start()
            }
        } catch {
            failure = error
            hub.post(.error, "sing-box: \(error)")
        }

        for runtime in plan.openVPN where actions.startOpenVPN.contains(runtime.id) {
            let session = OpenVPNSession(
                runtime: runtime, logLevel: plan.logLevel, autoReconnect: plan.autoReconnect,
                env: env, hub: hub, events: eventSink)
            sessions[runtime.id] = session
            status.tunnels[runtime.id] = .connecting(attempt: 1)
            do {
                try await session.start()
            } catch {
                status.tunnels[runtime.id] = .failed(reason: "ovpn.startFailed", permanent: true)
                hub.post(.error, "openvpn \(runtime.id): \(error)")
            }
        }
        for session in sessions.values {
            await session.setAutoReconnect(plan.autoReconnect)
        }

        self.plan = plan
        status.planHash = plan.planHash
        await hub.setStatus(status)
        if let failure {
            return .failure(failure)
        }
        return .success
    }

    private func performStop() async {
        hub.post(.info, "stop requested")
        await engine.stop()
        await sampler.reset()
        await stopSessions(Array(sessions.keys))
        wipeRunDirectory()
        plan = nil
        status = .stopped
        await hub.setStatus(status)
        hub.post(.info, "stopped")
    }

    private func stopSessions(_ ids: [String]) async {
        let stopping = ids.compactMap { sessions.removeValue(forKey: $0) }
        for id in ids {
            status.tunnels[id] = nil
            status.discoveredDNS[id] = nil
        }
        await withTaskGroup(of: Void.self) { group in
            for session in stopping {
                group.addTask { await session.stop() }
            }
        }
    }

    private func sessionKeys() async -> [String: String] {
        var keys: [String: String] = [:]
        for (id, session) in sessions {
            keys[id] = session.diffKey
        }
        return keys
    }

    /// Runs `body` after every previously enqueued operation has finished.
    private func serialized(_ body: @escaping @Sendable () async -> ApplyResult) async
        -> ApplyResult
    {
        let previous = queue
        let task = Task<ApplyResult, Never> {
            await previous?.value
            return await body()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func binaryVersion(_ path: String, name: String, arguments: [String]) async -> String {
        do {
            try BinaryValidator.validate(path: path, name: name, teamID: env.teamID)
        } catch {
            return "untrusted"
        }
        guard let result = try? await CommandRunner.run(path, arguments, timeout: .seconds(5)),
            let first = result.lines.first
        else { return "unavailable" }
        // "sing-box version 1.13.19" / "OpenVPN 2.7.6 aarch64-apple-darwin […]"
        let words = first.split(separator: " ")
        return words.first { $0.first?.isNumber == true }.map(String.init) ?? first
    }
}
