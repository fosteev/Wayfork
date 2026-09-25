import Darwin
import Foundation
import Testing
import os

@testable import WayforkDaemonCore

private enum RecordedProcessEvent: Sendable, Equatable {
    case line(ProcessOutputStream, String)
    case exit(ProcessExit)
}

private final class ProcessEventRecorder: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [RecordedProcessEvent]())

    func append(_ event: RecordedProcessEvent) {
        events.withLock { $0.append(event) }
    }

    func snapshot() -> [RecordedProcessEvent] {
        events.withLock { $0 }
    }
}

private func startProcess(_ spec: ProcessSpec) throws -> (ManagedProcess, ProcessEventRecorder) {
    let recorder = ProcessEventRecorder()
    let process = try ManagedProcess(
        spec: spec,
        handlers: ProcessEventHandlers(
            onLine: { recorder.append(.line($0, $1)) },
            onExit: { recorder.append(.exit($0)) }
        )
    )
    return (process, recorder)
}

@Test func managedProcessCapturesStandardOutputBeforeExit() async throws {
    let (process, recorder) = try startProcess(
        ProcessSpec(executable: "/bin/echo", arguments: ["hello"]))
    #expect(await process.exit == .exited(status: 0))
    #expect(recorder.snapshot() == [.line(.stdout, "hello"), .exit(.exited(status: 0))])
}

@Test func managedProcessCapturesStandardErrorAndFailureStatus() async throws {
    let (process, recorder) = try startProcess(
        ProcessSpec(executable: "/bin/ls", arguments: ["/nonexistent-xyz"]))
    let processExit = await process.exit
    #expect(processExit == .exited(status: 1))
    let events = recorder.snapshot()
    #expect(events.last == .exit(processExit))
    #expect(
        events.contains {
            if case .line(.stderr, let line) = $0 {
                return line.contains("nonexistent-xyz")
            }
            return false
        })
}

@Test func managedProcessTerminateUsesSIGTERM() async throws {
    let (process, _) = try startProcess(
        ProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
    let clock = ContinuousClock()
    let started = clock.now
    #expect(await process.terminate(timeout: .seconds(2)) == .signaled(signal: SIGTERM))
    #expect(started.duration(to: clock.now) < .seconds(2))
}

@Test func managedProcessUsesOnlySpecifiedEnvironment() async throws {
    let (process, recorder) = try startProcess(
        ProcessSpec(
            executable: "/usr/bin/env",
            arguments: [],
            environment: ["WAYFORK_ONLY": "yes"]
        ))
    #expect(await process.exit == .exited(status: 0))
    #expect(
        recorder.snapshot() == [
            .line(.stdout, "WAYFORK_ONLY=yes"), .exit(.exited(status: 0)),
        ])
}

@Test func managedProcessUsesWorkingDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let (process, recorder) = try startProcess(
        ProcessSpec(executable: "/bin/pwd", arguments: [], workingDirectory: directory.path))
    #expect(await process.exit == .exited(status: 0))
    // /var → /private/var: compare against realpath(3), Foundation strips "/private".
    let resolved = String(cString: realpath(directory.path, nil))
    #expect(recorder.snapshot().first == .line(.stdout, resolved))
}

@Test func managedProcessExitCanBeAwaitedAfterCompletion() async throws {
    let (process, _) = try startProcess(
        ProcessSpec(executable: "/usr/bin/printf", arguments: ["done\n"]))
    #expect(await process.exit == .exited(status: 0))

    let clock = ContinuousClock()
    let started = clock.now
    #expect(await process.exit == .exited(status: 0))
    #expect(started.duration(to: clock.now) < .milliseconds(100))
}

@Test func managedProcessDeliversAllLinesBeforeExitHandler() async throws {
    let output = (0..<5_000).map { "line-\($0)" }.joined(separator: "\n") + "\n"
    let (process, recorder) = try startProcess(
        ProcessSpec(executable: "/usr/bin/printf", arguments: [output]))
    #expect(await process.exit == .exited(status: 0))

    let events = recorder.snapshot()
    #expect(events.count == 5_001)
    #expect(events.last == .exit(.exited(status: 0)))
    #expect(
        events.dropLast().allSatisfy {
            if case .line(.stdout, _) = $0 {
                return true
            }
            return false
        })
}

// MARK: - Cancellable exit waits (regression: `apply` hung forever after "sing-box started")

@Test func managedProcessWaitForExitReturnsNilWhenCancelled() async throws {
    let (process, _) = try startProcess(ProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
    defer { process.signal(SIGKILL) }
    let waiter = Task { await process.waitForExit() }
    try await Task.sleep(for: .milliseconds(100))
    let clock = ContinuousClock()
    let start = clock.now
    waiter.cancel()
    #expect(await waiter.value == nil)
    #expect(clock.now - start < .seconds(2))
}

@Test func managedProcessWaitForExitReturnsNilWhenAlreadyCancelled() async throws {
    let (process, _) = try startProcess(ProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
    defer { process.signal(SIGKILL) }
    let waiter = Task {
        try? await Task.sleep(for: .seconds(10))  // cancelled before we reach waitForExit
        return await process.waitForExit()
    }
    waiter.cancel()
    #expect(await waiter.value == nil)
}

@Test func managedProcessWaitForExitDeliversTheExit() async throws {
    let (process, _) = try startProcess(ProcessSpec(executable: "/bin/sleep", arguments: ["0.2"]))
    #expect(await process.waitForExit() == .exited(status: 0))
    #expect(await process.waitForExit() == .exited(status: 0))  // after the fact
}

@Test func awaitStartupReturnsStartedWhileProcessKeepsRunning() async throws {
    let (process, _) = try startProcess(ProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
    defer { process.signal(SIGKILL) }
    let (signal, continuation) = AsyncStream.makeStream(of: Void.self)
    Task {
        try? await Task.sleep(for: .milliseconds(100))
        continuation.yield()
    }
    let clock = ContinuousClock()
    let start = clock.now
    let outcome = await process.awaitStartup(startedSignal: signal, grace: .seconds(10))
    #expect(outcome == .started)
    #expect(clock.now - start < .seconds(5), "must not wait for the process to exit")
}

@Test func awaitStartupReturnsSurvivedAfterGrace() async throws {
    let (process, _) = try startProcess(ProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
    defer { process.signal(SIGKILL) }
    let (signal, _) = AsyncStream.makeStream(of: Void.self)
    let outcome = await process.awaitStartup(startedSignal: signal, grace: .milliseconds(200))
    #expect(outcome == .survived)
}

@Test func awaitStartupReportsEarlyExit() async throws {
    let (process, _) = try startProcess(
        ProcessSpec(executable: "/bin/sh", arguments: ["-c", "exit 3"]))
    let (signal, _) = AsyncStream.makeStream(of: Void.self)
    let outcome = await process.awaitStartup(startedSignal: signal, grace: .seconds(10))
    #expect(outcome == .exited(.exited(status: 3)))
}
