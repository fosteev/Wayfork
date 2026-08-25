import Darwin
import Dispatch
import Foundation
import os

public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public enum ProcessExit: Sendable, Hashable {
    case exited(status: Int32)
    case signaled(signal: Int32)
}

/// Result of `ManagedProcess.awaitStartup`.
public enum StartupOutcome: Sendable, Hashable {
    /// The started signal fired.
    case started
    /// Neither the signal nor an exit happened within the grace period.
    case survived
    case exited(ProcessExit)
}

public enum ProcessOutputStream: Sendable {
    case stdout
    case stderr
}

public struct ProcessEventHandlers: Sendable {
    public var onLine: @Sendable (ProcessOutputStream, String) -> Void
    public var onExit: @Sendable (ProcessExit) -> Void

    public init(
        onLine: @escaping @Sendable (ProcessOutputStream, String) -> Void,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) {
        self.onLine = onLine
        self.onExit = onExit
    }
}

public enum ManagedProcessError: Error, Sendable, Equatable {
    case spawnFailed(errno: Int32)
}

public final class ManagedProcess: Sendable {
    public let pid: pid_t
    public let spec: ProcessSpec
    public let startedAt: Date

    private let runtime: ManagedProcessRuntime

    public init(spec: ProcessSpec, handlers: ProcessEventHandlers) throws {
        var standardOutput = [Int32](repeating: -1, count: 2)
        var standardError = [Int32](repeating: -1, count: 2)
        guard pipe(&standardOutput) == 0 else {
            throw ManagedProcessError.spawnFailed(errno: errno)
        }
        guard pipe(&standardError) == 0 else {
            let savedErrno = errno
            Darwin.close(standardOutput[0])
            Darwin.close(standardOutput[1])
            throw ManagedProcessError.spawnFailed(errno: savedErrno)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var actionsInitialized = false
        var attributesInitialized = false
        defer {
            if actionsInitialized {
                posix_spawn_file_actions_destroy(&actions)
            }
            if attributesInitialized {
                posix_spawnattr_destroy(&attributes)
            }
        }

        var setupError = posix_spawn_file_actions_init(&actions)
        actionsInitialized = setupError == 0
        if setupError == 0 {
            setupError = posix_spawnattr_init(&attributes)
            attributesInitialized = setupError == 0
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addopen(
                &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_adddup2(
                &actions, standardOutput[1], STDOUT_FILENO)
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_adddup2(
                &actions, standardError[1], STDERR_FILENO)
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addclose(&actions, standardOutput[0])
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addclose(&actions, standardError[0])
        }
        if setupError == 0, let workingDirectory = spec.workingDirectory {
            setupError = workingDirectory.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
        }

        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        if setupError == 0 {
            setupError = posix_spawnattr_setsigmask(&attributes, &emptyMask)
        }
        if setupError == 0 {
            setupError = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        }
        if setupError == 0 {
            let flags = Int16(
                POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
            setupError = posix_spawnattr_setflags(&attributes, flags)
        }

        guard setupError == 0 else {
            Darwin.close(standardOutput[0])
            Darwin.close(standardOutput[1])
            Darwin.close(standardError[0])
            Darwin.close(standardError[1])
            throw ManagedProcessError.spawnFailed(errno: setupError)
        }

        let arguments = [spec.executable] + spec.arguments
        let environment = spec.environment.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value)"
        }
        var spawnedPID: pid_t = 0
        let spawnError = withCStringArray(arguments) { argumentVector in
            withCStringArray(environment) { environmentVector in
                spec.executable.withCString { executable in
                    posix_spawn(
                        &spawnedPID,
                        executable,
                        &actions,
                        &attributes,
                        argumentVector,
                        environmentVector
                    )
                }
            }
        }

        Darwin.close(standardOutput[1])
        Darwin.close(standardError[1])
        guard spawnError == 0 else {
            Darwin.close(standardOutput[0])
            Darwin.close(standardError[0])
            throw ManagedProcessError.spawnFailed(errno: spawnError)
        }
        // The read loop drains until EAGAIN; a blocking descriptor would park the shared
        // queue (and with it stderr and exit handling) on a quiet child.
        for descriptor in [standardOutput[0], standardError[0]] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }

        pid = spawnedPID
        self.spec = spec
        startedAt = Date()
        runtime = ManagedProcessRuntime(
            pid: spawnedPID,
            standardOutput: standardOutput[0],
            standardError: standardError[0],
            handlers: handlers
        )
        runtime.start()
    }

    /// `kill(pid, signal)`; a process that is already gone (ESRCH) is not an error.
    public func signal(_ signal: Int32) {
        _ = Darwin.kill(pid, signal)
    }

    public func terminate(timeout: Duration) async -> ProcessExit {
        signal(SIGTERM)
        return await withTaskGroup(of: TerminationRace.self, returning: ProcessExit.self) {
            group in
            group.addTask { .exited(await self.exit) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            while let result = await group.next() {
                switch result {
                case .exited(let processExit):
                    group.cancelAll()
                    return processExit
                case .timedOut:
                    self.signal(SIGKILL)
                case .cancelled:
                    continue
                }
            }
            return await self.exit
        }
    }

    /// Resolves once the process has exited and both pipes are drained. Not cancellable:
    /// a task waiting here blocks until the process is gone (see `waitForExit()`).
    public var exit: ProcessExit {
        get async {
            await runtime.exit()
        }
    }

    /// Like `exit`, but returns nil as soon as the calling task is cancelled. Use this in
    /// task groups that race the exit against other events; `exit` would keep the group
    /// alive until the process dies.
    public func waitForExit() async -> ProcessExit? {
        await runtime.waitForExit()
    }

    /// Races three events after a spawn: the caller's "started" signal (typically fed from
    /// a log line), the process exiting, and `grace` elapsing with the process still alive.
    /// Returns as soon as the first one happens; the process keeps running.
    public func awaitStartup(startedSignal: AsyncStream<Void>, grace: Duration) async
        -> StartupOutcome
    {
        await withTaskGroup(of: StartupOutcome.self) { group in
            group.addTask {
                for await _ in startedSignal { return .started }
                return .survived  // stream finished or task cancelled: let the others decide
            }
            group.addTask {
                if let exit = await self.waitForExit() { return .exited(exit) }
                return .survived
            }
            group.addTask {
                try? await Task.sleep(for: grace)
                return .survived
            }
            let first = await group.next() ?? .survived
            group.cancelAll()
            return first
        }
    }
}

private enum TerminationRace: Sendable {
    case exited(ProcessExit)
    case timedOut
    case cancelled
}

private struct ManagedProcessState {
    var standardOutputSplitter = LineSplitter()
    var standardErrorSplitter = LineSplitter()
    var closedPipeCount = 0
    var reapedExit: ProcessExit?
    var deliveredExit: ProcessExit?
    var continuations: [CheckedContinuation<ProcessExit, Never>] = []
    var exitWaiters: [Int: CheckedContinuation<ProcessExit?, Never>] = [:]
    /// Waiters whose task was cancelled before they registered their continuation.
    var cancelledExitWaiters: Set<Int> = []
    var nextExitWaiterID = 0
    var readSources: [DispatchSourceRead] = []
    var processSource: DispatchSourceProcess?
}

private final class ManagedProcessRuntime: Sendable {
    private let pid: pid_t
    private let standardOutput: Int32
    private let standardError: Int32
    private let handlers: ProcessEventHandlers
    private let queue = DispatchQueue(label: "com.wayfork.daemon.managed-process")
    private let state = OSAllocatedUnfairLock(initialState: ManagedProcessState())

    init(
        pid: pid_t,
        standardOutput: Int32,
        standardError: Int32,
        handlers: ProcessEventHandlers
    ) {
        self.pid = pid
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.handlers = handlers
    }

    func start() {
        let outputSource = makeReadSource(fileDescriptor: standardOutput, stream: .stdout)
        let errorSource = makeReadSource(fileDescriptor: standardError, stream: .stderr)
        let processSource = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: queue)
        processSource.setEventHandler { [weak self] in
            self?.reapProcess()
        }
        state.withLock {
            $0.readSources = [outputSource, errorSource]
            $0.processSource = processSource
        }
        outputSource.resume()
        errorSource.resume()
        processSource.resume()
    }

    func exit() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            let completed = state.withLock { state -> ProcessExit? in
                if let deliveredExit = state.deliveredExit {
                    return deliveredExit
                }
                state.continuations.append(continuation)
                return nil
            }
            if let completed {
                continuation.resume(returning: completed)
            }
        }
    }

    func waitForExit() async -> ProcessExit? {
        let id = state.withLock { state -> Int in
            state.nextExitWaiterID += 1
            return state.nextExitWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<ProcessExit?, Never>) in
                let immediate = state.withLock { state -> ProcessExit?? in
                    if let deliveredExit = state.deliveredExit { return .some(deliveredExit) }
                    if state.cancelledExitWaiters.remove(id) != nil { return .some(nil) }
                    state.exitWaiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<ProcessExit?, Never>? in
                if let waiter = state.exitWaiters.removeValue(forKey: id) { return waiter }
                if state.deliveredExit == nil { state.cancelledExitWaiters.insert(id) }
                return nil
            }
            waiter?.resume(returning: nil)
        }
    }

    private func makeReadSource(
        fileDescriptor: Int32, stream: ProcessOutputStream
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else {
                return
            }
            self.readAvailable(from: fileDescriptor, stream: stream, source: source)
        }
        return source
    }

    private func readAvailable(
        from fileDescriptor: Int32, stream: ProcessOutputStream, source: DispatchSourceRead
    ) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let bytesRead = Darwin.read(fileDescriptor, &bytes, bytes.count)
            if bytesRead > 0 {
                let chunk = Array(bytes.prefix(bytesRead))
                let lines = state.withLock { state in
                    switch stream {
                    case .stdout:
                        return state.standardOutputSplitter.append(chunk)
                    case .stderr:
                        return state.standardErrorSplitter.append(chunk)
                    }
                }
                for line in lines {
                    handlers.onLine(stream, line)
                }
                continue
            }
            if bytesRead == 0 {
                closePipe(fileDescriptor: fileDescriptor, stream: stream, source: source)
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            closePipe(fileDescriptor: fileDescriptor, stream: stream, source: source)
            return
        }
    }

    private func closePipe(
        fileDescriptor: Int32, stream: ProcessOutputStream, source: DispatchSourceRead
    ) {
        source.cancel()
        Darwin.close(fileDescriptor)
        let leftover = state.withLock { state -> String? in
            state.closedPipeCount += 1
            switch stream {
            case .stdout:
                return state.standardOutputSplitter.flush()
            case .stderr:
                return state.standardErrorSplitter.flush()
            }
        }
        if let leftover {
            handlers.onLine(stream, leftover)
        }
        finishIfReady()
    }

    private func reapProcess() {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR

        let processExit: ProcessExit
        if result == pid {
            if status & 0x7F == 0 {
                processExit = .exited(status: (status >> 8) & 0xFF)
            } else {
                processExit = .signaled(signal: status & 0x7F)
            }
        } else {
            processExit = .exited(status: -1)
        }

        state.withLock {
            $0.processSource?.cancel()
            $0.reapedExit = processExit
        }
        finishIfReady()
    }

    private func finishIfReady() {
        let completion = state.withLock {
            state -> (
                ProcessExit, [CheckedContinuation<ProcessExit, Never>],
                [CheckedContinuation<ProcessExit?, Never>]
            )? in
            guard state.closedPipeCount == 2, let processExit = state.reapedExit,
                state.deliveredExit == nil
            else {
                return nil
            }
            state.deliveredExit = processExit
            let continuations = state.continuations
            state.continuations.removeAll()
            let waiters = Array(state.exitWaiters.values)
            state.exitWaiters.removeAll()
            state.cancelledExitWaiters.removeAll()
            return (processExit, continuations, waiters)
        }
        guard let (processExit, continuations, waiters) = completion else {
            return
        }
        handlers.onExit(processExit)
        for continuation in continuations {
            continuation.resume(returning: processExit)
        }
        for waiter in waiters {
            waiter.resume(returning: processExit)
        }
    }
}

private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) rethrows -> Result {
    var storage = strings.map { strdup($0) }
    storage.append(nil)
    defer {
        for pointer in storage where pointer != nil {
            free(pointer)
        }
    }
    return try storage.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}
