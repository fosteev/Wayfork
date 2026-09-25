import Darwin
import Foundation
import Testing
import os

@testable import WayforkDaemonCore

/// Minimal unix-domain server for the tests: listens, accepts one client on a background
/// queue and hands the accepted descriptor over.
private final class UnixSocketServer: Sendable {
    let path: String
    private let listener: Int32
    private let accepted = OSAllocatedUnfairLock<Int32>(initialState: -1)

    init(path: String = "/tmp/wf-\(UUID().uuidString.prefix(8)).sock") throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count + 1)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
    }

    func acceptInBackground() {
        let listener = listener
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            self.accepted.withLock { $0 = client }
        }
    }

    func waitForClient() async -> Int32 {
        for _ in 0..<100 {
            let client = accepted.withLock { $0 }
            if client >= 0 { return client }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return -1
    }

    func send(_ text: String, to client: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    func read(from client: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress, $0.count) }
        return String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
    }

    func closeClient(_ client: Int32) {
        _ = Darwin.close(client)
    }

    deinit {
        _ = Darwin.close(listener)
        unlink(path)
    }
}

private final class LineRecorder: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let closed = OSAllocatedUnfairLock<(Bool, (any Error)?)>(initialState: (false, nil))

    var handlers: UnixSocketLineClientHandlers {
        UnixSocketLineClientHandlers(
            onLine: { line in self.lines.withLock { $0.append(line) } },
            onClose: { error in self.closed.withLock { $0 = (true, error) } })
    }

    func waitForLines(_ count: Int) async -> [String] {
        for _ in 0..<100 {
            let snapshot = lines.withLock { $0 }
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lines.withLock { $0 }
    }

    func waitForClose() async -> (Bool, (any Error)?) {
        for _ in 0..<100 {
            let snapshot = closed.withLock { $0 }
            if snapshot.0 { return snapshot }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return closed.withLock { $0 }
    }
}

@Test func exchangesLinesAndReportsPeerClose() async throws {
    let server = try UnixSocketServer()
    server.acceptInBackground()
    let recorder = LineRecorder()
    let client = try await UnixSocketLineClient.connect(
        path: server.path, timeout: .seconds(2), handlers: recorder.handlers)
    let peer = await server.waitForClient()
    try #require(peer >= 0)

    server.send(">INFO:hello\r\n>HOLD:Waiting", to: peer)
    server.send(" for hold release:0\r\n", to: peer)
    #expect(await recorder.waitForLines(2) == [">INFO:hello", ">HOLD:Waiting for hold release:0"])

    try client.send("hold release")
    #expect(server.read(from: peer) == "hold release\n")

    server.closeClient(peer)
    let (closed, error) = await recorder.waitForClose()
    #expect(closed)
    #expect(error == nil)
    #expect(throws: UnixSocketError.closed) { try client.send("state on") }
}

@Test func connectTimesOutWhenSocketNeverAppears() async {
    let recorder = LineRecorder()
    let path = "/tmp/wf-missing-\(UUID().uuidString.prefix(8)).sock"
    await #expect(throws: UnixSocketError.connectTimedOut(path: path)) {
        _ = try await UnixSocketLineClient.connect(
            path: path, retryInterval: .milliseconds(20), timeout: .milliseconds(150),
            handlers: recorder.handlers)
    }
}

@Test func connectRetriesUntilSocketAppears() async throws {
    let recorder = LineRecorder()
    let path = "/tmp/wf-late-\(UUID().uuidString.prefix(8)).sock"
    let serverBox = OSAllocatedUnfairLock<UnixSocketServer?>(initialState: nil)
    let starter = Task {
        try await Task.sleep(for: .milliseconds(300))
        let server = try UnixSocketServer(path: path)
        server.acceptInBackground()
        serverBox.withLock { $0 = server }
    }
    let client = try await UnixSocketLineClient.connect(
        path: path, retryInterval: .milliseconds(50), timeout: .seconds(3),
        handlers: recorder.handlers)
    try await starter.value
    let server = try #require(serverBox.withLock { $0 })
    let peer = await server.waitForClient()
    #expect(peer >= 0)
    client.close()
    let (closed, error) = await recorder.waitForClose()
    #expect(closed && error == nil)
    server.closeClient(peer)
}
