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
    static let startupGrace: Duration = .seconds(3)
    static let stopTimeout: Duration = .seconds(5)
    static let logTailLines = 20

    private let env: DaemonEnvironment
    private let hub: ClientHub
    private let events: AsyncStream<SupervisorEvent>.Continuation

    /// Hash of the config the running (or last started) process was started with.
    private(set) var configHash: String?
    /// Rule-set files currently on disk.
    private(set) var ruleSets: [String: String] = [:]
    private var checkedConfigHash: String?
    private var process: ManagedProcess?
    private var generation = 0
    private var stopping = false
    private var crashes = CrashCounter()
    private var backoff = BackoffPolicy()
    private var restartTask: Task<Void, Never>?
    private var recent = LineCollector(capacity: SingBoxEngine.logTailLines)
    private(set) var state: EngineState = .stopped {
        didSet { if state != oldValue { events.yield(.engine(state)) } }
    }

    init(env: DaemonEnvironment, hub: ClientHub, events: AsyncStream<SupervisorEvent>.Continuation)
    {
        self.env = env
        self.hub = hub
        self.events = events
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

    func deleteRuleSets(_ names: [String]) {
        for name in names {
            unlink(env.runPath(name))
            ruleSets[name] = nil
        }
    }

    /// Writes the candidate config next to the live one, runs `sing-box check` on it and
    /// promotes it to `sing-box.json` only when the check passes.
    func check(config: String, hash: String) async throws(DaemonError) {
        try BinaryValidator.validate(path: env.singBoxPath, name: "sing-box", teamID: env.teamID)
        let candidate = env.runPath(RunLayout.singBoxConfig + ".check")
        do {
            try AtomicFile.write(config, to: candidate)
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
    }

    // MARK: - Lifecycle

    /// Spawns sing-box for the config installed by `check` and verifies it came up.
    func start() async throws(DaemonError) {
        guard process == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        stopping = false
        try BinaryValidator.validate(path: env.singBoxPath, name: "sing-box", teamID: env.teamID)
        state = .starting
        configHash = checkedConfigHash
        generation += 1
        let generation = generation
        let hub = hub
        let collector = LineCollector(capacity: SingBoxEngine.logTailLines)
        recent = collector
        let (started, startedSignal) = AsyncStream.makeStream(of: Void.self)
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
            state = .failed(reason: "singbox.startFailed")
            throw .startFailed(logTail: ["posix_spawn failed: \(error)"])
        }
        process = spawned
        try? AtomicFile.write("\(spawned.pid)\n", to: env.runPath(RunLayout.singBoxPID))
        hub.post(.info, "sing-box started (pid \(spawned.pid))")

        let outcome = await spawned.awaitStartup(
            startedSignal: started, grace: SingBoxEngine.startupGrace)
        guard process === spawned else { return }  // stopped meanwhile
        var failure: String?
        switch outcome {
        case .exited(let exit):
            failure = "exited during startup (\(exit))"
        case .started, .survived:
            if if_nametoindex(SingBoxEngine.interface) == 0 {
                failure = "\(SingBoxEngine.interface) did not come up"
            } else if let via = await RouteHelper.interface(forAddress: "1.1.1.1"),
                via != SingBoxEngine.interface
            {
                failure = "public traffic routes via \(via), not \(SingBoxEngine.interface)"
            }
        }
        guard process === spawned else { return }
        if let failure {
            hub.post(.error, "sing-box startup verification failed: \(failure)")
            stopping = true
            _ = await spawned.terminate(timeout: SingBoxEngine.stopTimeout)
            process = nil
            unlink(env.runPath(RunLayout.singBoxPID))
            state = .failed(reason: "singbox.startFailed")
            throw .startFailed(logTail: [failure] + collector.snapshot())
        }
        crashes.reset()
        backoff.reset()
        state = .running(since: Date())
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        stopping = true
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

    private func handleExit(_ exit: ProcessExit, generation: Int) {
        guard generation == self.generation, let exited = process, !stopping else { return }
        let uptime = Date().timeIntervalSince(exited.startedAt)
        process = nil
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
