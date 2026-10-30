import Darwin
import Foundation
import WayforkCore
import WayforkDaemonCore

/// One XHTTP tunnel's xray process: a loopback SOCKS inbound that sing-box's `t-<id>`
/// outbound dials. Restarts with backoff on every exit; no management socket, no routes.
/// Decisions live in `XraySessionReducer`; this actor performs the effects
/// (docs/roadmap/xhttp-xray.md, D7–D8).
actor XraySession {
    static let stopTimeout: Duration = .seconds(5)

    let runtime: XrayRuntime
    /// What `ReconcilePlanner` compares: any config change restarts the process.
    nonisolated var diffKey: String { runtime.configHash }
    private let env: DaemonEnvironment
    private let hub: ClientHub
    private let events: AsyncStream<SupervisorEvent>.Continuation
    private let inputs: AsyncStream<(Int, XraySessionReducer.Input)>
    private let feed: AsyncStream<(Int, XraySessionReducer.Input)>.Continuation

    private var reducer: XraySessionReducer
    private var backoff = BackoffPolicy()
    private var autoReconnect: Bool
    private var process: ManagedProcess?
    private var generation = 0
    private var stopping = false
    private var restartTask: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    /// Set by `reconnect()` while the old process is being torn down.
    private var manualRestart = false

    init(
        runtime: XrayRuntime, autoReconnect: Bool, env: DaemonEnvironment, hub: ClientHub,
        events: AsyncStream<SupervisorEvent>.Continuation
    ) {
        self.runtime = runtime
        self.autoReconnect = autoReconnect
        self.env = env
        self.hub = hub
        self.events = events
        reducer = XraySessionReducer(context: .init(runtime))
        (inputs, feed) = AsyncStream.makeStream(
            of: (Int, XraySessionReducer.Input).self, bufferingPolicy: .unbounded)
    }

    private var source: String { XraySessionReducer.source(for: runtime.id) }
    private var configPath: String { env.runPath(RunLayout.xrayConfig(runtime.id)) }
    private var pidPath: String { env.runPath(RunLayout.xrayPID(runtime.id)) }

    // MARK: - Lifecycle

    /// Writes the config (0600, root-owned: it holds the UUID) and spawns the first attempt.
    /// Throws only for problems no retry would fix (untrusted binary, unwritable run dir).
    func start() async throws(DaemonError) {
        try BinaryValidator.validate(path: env.xrayPath, name: "xray", teamID: env.teamID)
        do {
            try AtomicFile.write(runtime.config, to: configPath)
        } catch {
            throw .internalError(message: "cannot write xray config: \(error)")
        }
        stopping = false
        startPump()
        spawn(attempt: backoff.nextAttempt)
    }

    func stop() async {
        stopping = true
        restartTask?.cancel()
        restartTask = nil
        if let process {
            hub.post(.info, "stopping xray (pid \(process.pid))", source: source)
            _ = await process.terminate(timeout: XraySession.stopTimeout)
        }
        feed.finish()
        await pump?.value
        pump = nil
        unlink(configPath)
        unlink(pidPath)
    }

    /// User-initiated: kill the current attempt, reset backoff, start again right away —
    /// also with `autoReconnect` off.
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
        _ = await process.terminate(timeout: XraySession.stopTimeout)
    }

    func setAutoReconnect(_ enabled: Bool) {
        autoReconnect = enabled
    }

    // MARK: - Process

    private func spawn(attempt: Int) {
        generation += 1
        let generation = generation
        let feed = feed
        let spawned: ManagedProcess
        do {
            spawned = try ManagedProcess(
                spec: ProcessSpec(
                    executable: env.xrayPath,
                    arguments: XrayArguments.arguments(
                        for: runtime, runDirectory: env.runDirectory),
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
        // xray binds with SO_REUSEPORT: a leftover from a crashed daemon would share the port
        // silently instead of failing, so startup must be able to find and kill it.
        try? AtomicFile.write("\(spawned.pid)\n", to: pidPath)
        feed.yield((generation, .processStarted(attempt: attempt)))
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

    private func handle(_ input: XraySessionReducer.Input, generation: Int) async {
        guard generation == self.generation else { return }
        let before = reducer.state
        let effects = reducer.handle(input)
        for effect in effects {
            perform(effect)
        }
        if reducer.state != before {
            events.yield(.tunnel(id: runtime.id, state: reducer.state))
        }
    }

    private func perform(_ effect: XraySessionReducer.Effect) {
        switch effect {
        case .log(let level, let message):
            hub.post(level, message, source: source)
        case .exited:
            let uptime = process.map { Date().timeIntervalSince($0.startedAt) } ?? 0
            process = nil
            unlink(pidPath)
            guard !stopping else { return }
            if manualRestart {
                manualRestart = false
                spawn(attempt: 1)
                return
            }
            guard autoReconnect else {
                postLogs(reducer.handle(.retriesDisabled))
                return
            }
            let delay = backoff.nextDelay(afterUptime: .seconds(uptime))
            let attempt = backoff.nextAttempt
            let seconds = TimeInterval(delay.components.seconds)
            postLogs(reducer.handle(.restartScheduled(attempt: attempt, nextIn: seconds)))
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.respawnAfterBackoff(attempt: attempt)
            }
        }
    }

    /// Follow-up inputs fed from inside `perform` only ever log.
    private func postLogs(_ effects: [XraySessionReducer.Effect]) {
        for case .log(let level, let message) in effects {
            hub.post(level, message, source: source)
        }
    }

    private func respawnAfterBackoff(attempt: Int) {
        guard !stopping, process == nil else { return }
        spawn(attempt: attempt)
    }
}
