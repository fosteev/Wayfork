import Darwin
import Foundation
import WayforkCore
import WayforkDaemonCore

/// Owns the sing-box child: config/rule-set files, `sing-box check`, start with startup
/// verification, crash counting and backoff restarts
/// (docs/design/03-routing.md "Startup verification", docs/design/05-daemon.md "Supervisor").
actor SingBoxEngine {
    static let source = "sing-box"
    static let interface = "utun100"
    /// How long the start waits for the "started" line before the first check; it keeps a
    /// `utun100` a previous process has not finished tearing down out of the answer.
    static let startupGrace: Duration = .seconds(3)
    /// How often the startup check repeats while the TUN comes up (H1).
    static let startupPoll: Duration = .milliseconds(500)
    /// How long from the spawn the check may keep failing before the attempt is given up.
    static let startupTimeout: Duration = .seconds(12)
    /// A start that never verifies is retried once before it counts as failed.
    static let startAttempts = 2
    static let stopTimeout: Duration = .seconds(5)
    static let logTailLines = 20

    private let env: DaemonEnvironment
    private let hub: ClientHub
    private let events: AsyncStream<SupervisorEvent>.Continuation
    private let sampler: TrafficSampler
    private let closer = ConnectionCloser()
    /// How long after a rule-set rewrite the reload has landed (measured ~350 ms on 1.13.19).
    static let ruleSetReloadGrace: Duration = .seconds(1)

    /// Hash of the config the running (or last started) process was started with.
    private(set) var configHash: String?
    /// Rule-set files currently on disk.
    private(set) var ruleSets: [String: String] = [:]
    private var checkedConfigHash: String?
    /// Clash API endpoint written into the config by `check` / used by the running process.
    private var checkedEndpoint: ClashAPIEndpoint?
    private var endpoint: ClashAPIEndpoint?
    private var process: ManagedProcess?
    private var generation = 0
    private var stopping = false
    /// `abortStartup()` was called while a start was still verifying.
    private var startupAborted = false
    /// A start is verifying; an exit belongs to it, not to `handleExit`.
    private var startupPending = false
    private var crashes = CrashCounter()
    private var backoff = BackoffPolicy()
    private var restartTask: Task<Void, Never>?
    private var recent = LineCollector(capacity: SingBoxEngine.logTailLines)
    private(set) var state: EngineState = .stopped {
        didSet { if state != oldValue { events.yield(.engine(state)) } }
    }

    init(
        env: DaemonEnvironment, hub: ClientHub, events: AsyncStream<SupervisorEvent>.Continuation,
        sampler: TrafficSampler
    ) {
        self.env = env
        self.hub = hub
        self.events = events
        self.sampler = sampler
    }

    var isRunning: Bool { process != nil }

    // MARK: - Files

    func writeRuleSets(_ files: [String: String]) throws(DaemonError) {
        for (name, contents) in files.sorted(by: { $0.key < $1.key }) {
            do {
                try AtomicFile.write(contents, to: env.runPath(name))
            } catch {
                throw .internalError(message: "cannot write \(name): \(error)")
            }
            ruleSets[name] = contents
        }
    }

    /// After `writeRuleSets`: once sing-box has reloaded the files, close the connections the
    /// change covers (all of them when it is unknown) so they reconnect under the new rules
    /// (docs/design/05-daemon.md, "Connection cut on rule change").
    func cutConnections(matching change: RuleSetSelectors?) {
        Task { [weak self] in
            try? await Task.sleep(for: SingBoxEngine.ruleSetReloadGrace)
            guard let self else { return }
            await self.performCut(change)
        }
    }

    private func performCut(_ change: RuleSetSelectors?) async {
        guard let endpoint, process != nil else { return }
        do {
            let closed = try await closer.close(matching: change, at: endpoint)
            hub.post(
                .info,
                change == nil
                    ? "rules changed: closed all \(closed) connection(s)"
                    : "rules changed: closed \(closed) affected connection(s)")
        } catch {
            hub.post(.warning, "rules changed: cannot close connections (\(error))")
        }
    }

    func deleteRuleSets(_ names: [String]) {
        for name in names {
            unlink(env.runPath(name))
            ruleSets[name] = nil
        }
    }

    /// Writes the candidate config next to the live one — with a fresh Clash API endpoint
    /// injected for traffic sampling (F9) — runs `sing-box check` on it and promotes it to
    /// `sing-box.json` only when the check passes.
    func check(config: String, hash: String) async throws(DaemonError) {
        try BinaryValidator.validate(path: env.singBoxPath, name: "sing-box", teamID: env.teamID)
        let endpoint: ClashAPIEndpoint
        let injected: String
        do {
            endpoint = try ClashAPIEndpoint.generate()
            injected = try ClashAPIConfig.inject(endpoint, into: config)
        } catch {
            throw .internalError(message: "cannot prepare clash api: \(error)")
        }
        let candidate = env.runPath(RunLayout.singBoxConfig + ".check")
        do {
            try AtomicFile.write(injected, to: candidate)
        } catch {
            throw .internalError(message: "cannot write config: \(error)")
        }
        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(
                env.singBoxPath, ["check", "-D", env.runDirectory, "-c", candidate],
                workingDirectory: env.runDirectory)
        } catch {
            unlink(candidate)
            throw .internalError(message: "cannot run sing-box check: \(error)")
        }
        guard result.succeeded else {
            unlink(candidate)
            throw .configInvalid(output: result.output)
        }
        guard rename(candidate, env.runPath(RunLayout.singBoxConfig)) == 0 else {
            let code = errno
            unlink(candidate)
            throw .internalError(message: "cannot install config: errno \(code)")
        }
        checkedConfigHash = hash
        checkedEndpoint = endpoint
    }

    // MARK: - Lifecycle

    /// Spawns sing-box for the config installed by `check` and verifies it came up. A start
    /// that never verifies is retried once before it counts as failed
    /// (docs/design/03-routing.md, "Startup verification").
    func start() async throws(DaemonError) {
        guard process == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        stopping = false
        startupAborted = false
        try BinaryValidator.validate(path: env.singBoxPath, name: "sing-box", teamID: env.teamID)
        state = .starting
        for attempt in 1...SingBoxEngine.startAttempts {
            switch await startAttempt(attempt) {
            case .verified, .abandoned:
                return
            case .spawnFailed(let message):
                state = .failed(reason: "singbox.startFailed")
                throw .startFailed(logTail: [message])
            case .unverified(let tail):
                guard attempt < SingBoxEngine.startAttempts else {
                    state = .failed(reason: "singbox.startFailed")
                    throw .startFailed(logTail: tail)
                }
                hub.post(
                    .warning,
                    "starting sing-box once more after: \(tail.first ?? "startup verification failed")"
                )
            }
        }
    }

    /// How one spawn-and-verify attempt ended.
    private enum StartAttempt {
        case verified
        /// The window ran out, or the process exited during startup; the tail is the failure
        /// line followed by the last log lines of this attempt.
        case unverified(tail: [String])
        /// A stop or a newer apply took over; it sets the state itself.
        case abandoned
        case spawnFailed(String)
    }

    private func startAttempt(_ attempt: Int) async -> StartAttempt {
        configHash = checkedConfigHash
        endpoint = checkedEndpoint
        generation += 1
        let generation = generation
        let hub = hub
        let collector = LineCollector(capacity: SingBoxEngine.logTailLines)
        recent = collector
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
        // startupPending stays set until the child is dealt with: it is what keeps
        // `handleExit` from treating a termination of our own as a crash worth restarting.
        startupPending = true
        let spawned: ManagedProcess
        do {
            spawned = try ManagedProcess(
                spec: ProcessSpec(
                    executable: env.singBoxPath,
                    arguments: SingBoxArguments.run(runDirectory: env.runDirectory),
                    workingDirectory: env.runDirectory),
                handlers: ProcessEventHandlers(
                    onLine: { _, line in
                        collector.append(line)
                        hub.post(
                            LogLine(
                                source: SingBoxEngine.source, level: SingBoxLog.level(of: line),
                                message: SingBoxLog.message(of: line)))
                        if SingBoxLog.isStartedLine(line) { startedSignal.yield() }
                    },
                    onExit: { [weak self] exit in
                        startedSignal.finish()
                        guard let self else { return }
                        Task { await self.handleExit(exit, generation: generation) }
                    }))
        } catch {
            startupPending = false
            return .spawnFailed("posix_spawn failed: \(error)")
        }
        process = spawned
        try? AtomicFile.write("\(spawned.pid)\n", to: env.runPath(RunLayout.singBoxPID))
        hub.post(
            .info,
            attempt == 1
                ? "sing-box started (pid \(spawned.pid))"
                : "sing-box started (pid \(spawned.pid), attempt \(attempt))")

        let wait = await awaitStartup(spawned, startedSignal: started)
        switch wait {
        case .abandoned:
            if process === spawned {
                // Nothing is going to supervise this child: kill it and let whoever
                // interrupted the start (a stop, a newer apply) set the state.
                _ = await spawned.terminate(timeout: SingBoxEngine.stopTimeout)
                if process === spawned {
                    process = nil
                    unlink(env.runPath(RunLayout.singBoxPID))
                }
            }
            startupPending = false
            return .abandoned
        case .failed(let failure):
            hub.post(.error, "sing-box startup verification failed: \(failure)")
            _ = await spawned.terminate(timeout: SingBoxEngine.stopTimeout)
            process = nil
            startupPending = false
            unlink(env.runPath(RunLayout.singBoxPID))
            return .unverified(tail: [failure] + collector.snapshot())
        case .up:
            break
        }
        startupPending = false
        crashes.reset()
        backoff.reset()
        state = .running(since: Date())
        if let endpoint {
            await sampler.start(endpoint)
        }
        return .verified
    }

    private enum StartupWait {
        case up
        case failed(String)
        case abandoned
    }

    /// Waits for the "started" line (or the grace period), then repeats the startup check
    /// every `startupPoll` until it passes or `startupTimeout` from the spawn is up.
    private func awaitStartup(_ spawned: ManagedProcess, startedSignal: AsyncStream<Void>) async
        -> StartupWait
    {
        let deadline = ContinuousClock.now + SingBoxEngine.startupTimeout
        switch await spawned.awaitStartup(
            startedSignal: startedSignal, grace: SingBoxEngine.startupGrace)
        {
        case .exited(let exit):
            return .failed("exited during startup (\(exit))")
        case .started, .survived:
            break
        }
        while true {
            if startupAborted || stopping || process !== spawned { return .abandoned }
            guard let failure = await verifyStartup() else { return .up }
            if ContinuousClock.now >= deadline { return .failed(failure) }
            switch await pollTick(spawned) {
            case .exited(let exit): return .failed("exited during startup (\(exit))")
            case .elapsed: continue
            }
        }
    }

    /// The check itself: `utun100` exists and a public address leaves through it. nil = up.
    private func verifyStartup() async -> String? {
        if if_nametoindex(SingBoxEngine.interface) == 0 {
            return "\(SingBoxEngine.interface) did not come up"
        }
        if let via = await RouteHelper.interface(forAddress: "1.1.1.1"),
            via != SingBoxEngine.interface
        {
            return "public traffic routes via \(via), not \(SingBoxEngine.interface)"
        }
        return nil
    }

    private enum PollTick: Sendable {
        case exited(ProcessExit)
        case elapsed
    }

    /// One poll interval, cut short when the process dies.
    private nonisolated func pollTick(_ spawned: ManagedProcess) async -> PollTick {
        await withTaskGroup(of: PollTick.self) { group in
            group.addTask {
                if let exit = await spawned.waitForExit() { return .exited(exit) }
                return .elapsed
            }
            group.addTask {
                try? await Task.sleep(for: SingBoxEngine.startupPoll)
                return .elapsed
            }
            let first = await group.next() ?? .elapsed
            group.cancelAll()
            return first
        }
    }

    /// Makes a start that is still verifying give up, so an `apply` or a `stop` waiting
    /// behind it is not held for the whole verification window (H1). Ignored when no start
    /// is in flight.
    func abortStartup() {
        if startupPending { startupAborted = true }
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        stopping = true
        await sampler.pause()
        if let process {
            hub.post(.info, "stopping sing-box (pid \(process.pid))")
            _ = await process.terminate(timeout: SingBoxEngine.stopTimeout)
        }
        process = nil
        configHash = nil
        unlink(env.runPath(RunLayout.singBoxPID))
        state = .stopped
    }

    func logTail() -> [String] {
        recent.snapshot()
    }

    // MARK: - Exit handling

    private func handleExit(_ exit: ProcessExit, generation: Int) async {
        guard generation == self.generation, let exited = process, !stopping, !startupPending
        else { return }
        let uptime = Date().timeIntervalSince(exited.startedAt)
        process = nil
        await sampler.pause()
        unlink(env.runPath(RunLayout.singBoxPID))
        hub.post(.error, "sing-box exited unexpectedly (\(exit)) after \(Int(uptime)) s")
        if crashes.recordExit() {
            hub.post(
                .error,
                "sing-box crashed \(crashes.limit) times within \(Int(crashes.window)) s; giving up"
            )
            state = .failed(reason: "singbox.startFailed")
            return
        }
        let delay = backoff.nextDelay(afterUptime: .seconds(uptime))
        state = .starting
        hub.post(.info, "restarting sing-box in \(delay)")
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.start()
            } catch {
                self.hub.post(.error, "sing-box restart failed: \(error)")
            }
        }
    }
}
