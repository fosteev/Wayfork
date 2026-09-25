import Darwin
import Foundation
import WayforkCore
import WayforkDaemonCore

/// One OpenVPN tunnel: the process, its management socket, restarts with backoff. All
/// decisions live in `OpenVPNSessionReducer`; this actor only performs the effects
/// (docs/design/04-tunnels.md, "Runtime (daemon)").
actor OpenVPNSession {
    static let stopTimeout: Duration = .seconds(5)

    let runtime: OpenVPNRuntime
    let diffKey: String
    private let logLevel: LogLevel
    private let env: DaemonEnvironment
    private let hub: ClientHub
    private let events: AsyncStream<SupervisorEvent>.Continuation
    private let inputs: AsyncStream<(Int, OpenVPNSessionReducer.Input)>
    private let feed: AsyncStream<(Int, OpenVPNSessionReducer.Input)>.Continuation

    private var reducer: OpenVPNSessionReducer
    private var backoff = BackoffPolicy()
    private var autoReconnect: Bool
    private var process: ManagedProcess?
    private var management: UnixSocketLineClient?
    private var generation = 0
    private var stopping = false
    private var restartTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    /// Set by `reconnect()` while the old process is being torn down.
    private var manualRestart = false

    init(
        runtime: OpenVPNRuntime, logLevel: LogLevel, autoReconnect: Bool,
        env: DaemonEnvironment, hub: ClientHub, events: AsyncStream<SupervisorEvent>.Continuation
    ) {
        self.runtime = runtime
        self.logLevel = logLevel
        self.autoReconnect = autoReconnect
        self.env = env
        self.hub = hub
        self.events = events
        diffKey = OpenVPNArguments.diffKey(for: runtime, logLevel: logLevel)
        reducer = OpenVPNSessionReducer(context: .init(runtime))
        (inputs, feed) = AsyncStream.makeStream(
            of: (Int, OpenVPNSessionReducer.Input).self, bufferingPolicy: .unbounded)
    }

    var id: String { runtime.id }
    var state: TunnelState { reducer.state }
    private var source: String { "openvpn:\(runtime.id)" }

    // MARK: - Lifecycle

    /// Writes the config and spawns the first attempt. Throws only for problems that no
    /// retry would fix (untrusted binary, unwritable run directory).
    func start() async throws(DaemonError) {
        try BinaryValidator.validate(path: env.openVPNPath, name: "openvpn", teamID: env.teamID)
        do {
            try AtomicFile.write(
                runtime.config, to: env.runPath(RunLayout.openVPNConfig(runtime.id)))
        } catch {
            throw .internalError(message: "cannot write OpenVPN config: \(error)")
        }
        stopping = false
        startPump()
        spawn(attempt: backoff.nextAttempt)
    }

    func stop() async {
        stopping = true
        restartTask?.cancel()
        restartTask = nil
        connectTask?.cancel()
        connectTask = nil
        if let process {
            hub.post(.info, "stopping openvpn (pid \(process.pid))", source: source)
            try? management?.send(ManagementCommand.signalTerm)
            _ = await process.terminate(timeout: OpenVPNSession.stopTimeout)
        }
        feed.finish()
        await pump?.value
        pump = nil
        for name in [
            RunLayout.openVPNConfig(runtime.id), RunLayout.managementSocket(runtime.id),
            RunLayout.openVPNPID(runtime.id),
        ] {
            unlink(env.runPath(name))
        }
    }

    /// User-initiated: kill the current attempt, reset backoff, start again right away —
    /// also for permanently failed tunnels and with `autoReconnect` off.
    func reconnect() async {
        guard !stopping else { return }
        restartTask?.cancel()
        restartTask = nil
        backoff.reset()
        hub.post(.info, "reconnect requested", source: source)
        guard let process else {
            spawn(attempt: 1)
            return
        }
        // The exit lands in the pump after `terminate` returns; the pump respawns.
        manualRestart = true
        try? management?.send(ManagementCommand.signalTerm)
        _ = await process.terminate(timeout: OpenVPNSession.stopTimeout)
    }

    func setAutoReconnect(_ enabled: Bool) {
        autoReconnect = enabled
    }

    // MARK: - Process

    private func spawn(attempt: Int) {
        generation += 1
        let generation = generation
        let feed = feed
        let socketPath = env.runPath(RunLayout.managementSocket(runtime.id))
        unlink(socketPath)
        let spawned: ManagedProcess
        do {
            spawned = try ManagedProcess(
                spec: ProcessSpec(
                    executable: env.openVPNPath,
                    arguments: OpenVPNArguments.arguments(
                        for: runtime, runDirectory: env.runDirectory, logLevel: logLevel),
                    workingDirectory: env.runDirectory),
                handlers: ProcessEventHandlers(
                    onLine: { _, line in feed.yield((generation, .processLine(line))) },
                    onExit: { exit in feed.yield((generation, .processExited(exit))) }))
        } catch {
            hub.post(.error, "posix_spawn failed: \(error)", source: source)
            feed.yield((generation, .processExited(.exited(status: -1))))
            return
        }
        process = spawned
        try? AtomicFile.write("\(spawned.pid)\n", to: env.runPath(RunLayout.openVPNPID(runtime.id)))
        feed.yield((generation, .processStarted(attempt: attempt)))
        connectTask = Task { [weak self] in
            await self?.connectManagement(path: socketPath, generation: generation)
        }
    }

    private func connectManagement(path: String, generation: Int) async {
        let feed = feed
        let handlers = UnixSocketLineClientHandlers(
            onLine: { line in feed.yield((generation, .management(ManagementProtocol.parse(line))))
            },
            onClose: { _ in feed.yield((generation, .managementClosed)) })
        do {
            let client = try await UnixSocketLineClient.connect(path: path, handlers: handlers)
            guard generation == self.generation, process != nil else {
                client.close()
                return
            }
            management = client
            feed.yield((generation, .managementConnected))
        } catch {
            guard generation == self.generation, let process else { return }
            hub.post(.error, "management socket unavailable: \(error)", source: source)
            process.signal(SIGTERM)
        }
    }

    // MARK: - Reducer pump

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            for await (generation, input) in inputs {
                await self.handle(input, generation: generation)
            }
        }
    }

    private func handle(_ input: OpenVPNSessionReducer.Input, generation: Int) async {
        guard generation == self.generation else { return }
        let before = reducer.state
        let effects = reducer.handle(input)
        for effect in effects {
            await perform(effect)
        }
        if reducer.state != before {
            events.yield(.tunnel(id: runtime.id, state: reducer.state))
        }
    }

    private func perform(_ effect: OpenVPNSessionReducer.Effect) async {
        switch effect {
        case .send(let command):
            do {
                try management?.send(command)
            } catch {
                hub.post(.warning, "management write failed: \(error)", source: source)
            }
        case .log(let level, let message):
            hub.post(level, message, source: source)
        case .addScopedRoute(let interface):
            if let error = await RouteHelper.addScopedDefault(interface: interface) {
                hub.post(.warning, "route add failed: \(error)", source: source)
            }
        case .deleteScopedRoute(let interface):
            if let error = await RouteHelper.deleteScopedDefault(interface: interface) {
                hub.post(.debug, "route delete: \(error)", source: source)
            }
        case .discoveredDNS(let servers):
            events.yield(.discoveredDNS(id: runtime.id, servers: servers))
        case .exited(let disposition):
            let uptime = process.map { Date().timeIntervalSince($0.startedAt) } ?? 0
            management?.close()
            management = nil
            process = nil
            unlink(env.runPath(RunLayout.openVPNPID(runtime.id)))
            guard !stopping else { return }
            if manualRestart {
                manualRestart = false
                spawn(attempt: 1)
                return
            }
            switch disposition {
            case .permanent:
                break
            case .transient:
                guard autoReconnect else {
                    _ = reducer.handle(.retriesDisabled)
                    return
                }
                let delay = backoff.nextDelay(afterUptime: .seconds(uptime))
                let attempt = backoff.nextAttempt
                let seconds = TimeInterval(delay.components.seconds)
                _ = reducer.handle(.restartScheduled(attempt: attempt, nextIn: seconds))
                restartTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    await self?.respawnAfterBackoff(attempt: attempt)
                }
            }
        }
    }

    private func respawnAfterBackoff(attempt: Int) {
        guard !stopping, process == nil else { return }
        spawn(attempt: attempt)
    }
}
