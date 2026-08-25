import Foundation
import WayforkCore
import WayforkDaemonCore
import os

/// `NSXPCConnection` proxies are thread-safe by contract; the box lets the actor hold one.
final class ClientProxy: @unchecked Sendable {
    let proxy: any WayforkClientXPC
    /// Identity of the connection that produced the proxy, for "still the subscriber?".
    let connectionID: ObjectIdentifier

    init(proxy: any WayforkClientXPC, connectionID: ObjectIdentifier) {
        self.proxy = proxy
        self.connectionID = connectionID
    }
}

/// Thread-safe collector of the newest lines a child printed.
final class LineCollector: Sendable {
    private let lines: OSAllocatedUnfairLock<RingBuffer<String>>

    init(capacity: Int = 1000) {
        lines = OSAllocatedUnfairLock(initialState: RingBuffer(capacity: capacity))
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    func snapshot() -> [String] {
        lines.withLock { $0.elements }
    }
}

/// Everything that flows from the daemon to the app: status (coalesced 100 ms) and log
/// lines (batched 250 ms / 200 lines), plus the per-source ring buffers and raw log files
/// (docs/design/05-daemon.md, "Logging plumbing").
actor ClientHub {
    static let ringCapacity = 2000
    static let batchLimit = 200
    static let batchInterval: Duration = .milliseconds(250)
    static let statusInterval: Duration = .milliseconds(100)

    private let logDirectory: String
    private let osLog = Logger(subsystem: WayforkIdentifiers.daemon, category: "log")
    private nonisolated let stream: AsyncStream<LogLine>
    private nonisolated let sink: AsyncStream<LogLine>.Continuation
    private var client: ClientProxy?
    private var status = RuntimeStatus.stopped
    private var statusFlush: Task<Void, Never>?
    private var pending: [LogLine] = []
    private var logFlush: Task<Void, Never>?
    private var rings: [String: RingBuffer<LogLine>] = [:]
    private var files: [String: RotatingLogFile] = [:]
    private var pump: Task<Void, Never>?

    init(logDirectory: String) {
        self.logDirectory = logDirectory
        (stream, sink) = AsyncStream.makeStream(
            of: LogLine.self, bufferingPolicy: .bufferingNewest(10_000))
    }

    /// Ordered, non-blocking entry point usable from any thread (child pipe queues, XPC).
    nonisolated func post(_ line: LogLine) {
        sink.yield(line)
    }

    nonisolated func post(_ level: LogLevel, _ message: String, source: String = "daemon") {
        post(LogLine(source: source, level: level, message: message))
    }

    func start() {
        guard pump == nil else { return }
        let stream = stream
        pump = Task { [weak self] in
            for await line in stream {
                guard let self else { return }
                await self.ingest(line)
            }
        }
    }

    // MARK: - Subscribers

    /// Replaces the subscriber and replays the current status plus every ring buffer.
    func subscribe(_ client: ClientProxy) {
        self.client = client
        send(status: status, to: client)
        let replay = rings.values.flatMap(\.elements).sorted { $0.ts < $1.ts }
        if !replay.isEmpty {
            send(lines: replay, to: client)
        }
    }

    func unsubscribe(connectionID: ObjectIdentifier) {
        if client?.connectionID == connectionID {
            client = nil
        }
    }

    // MARK: - Status

    func currentStatus() -> RuntimeStatus {
        status
    }

    func setStatus(_ status: RuntimeStatus) {
        guard status != self.status else { return }
        self.status = status
        guard statusFlush == nil else { return }
        statusFlush = Task { [weak self] in
            try? await Task.sleep(for: ClientHub.statusInterval)
            await self?.flushStatus()
        }
    }

    private func flushStatus() {
        statusFlush = nil
        if let client {
            send(status: status, to: client)
        }
    }

    // MARK: - Logs

    private func ingest(_ line: LogLine) {
        osLog.log(
            level: line.level.osLogType,
            "\(line.source, privacy: .public): \(line.message, privacy: .public)")
        rings[line.source, default: RingBuffer(capacity: ClientHub.ringCapacity)].append(line)
        file(for: line.source)?.append(line.formatted)
        pending.append(line)
        if pending.count >= ClientHub.batchLimit {
            flushLogs()
        } else if logFlush == nil {
            logFlush = Task { [weak self] in
                try? await Task.sleep(for: ClientHub.batchInterval)
                await self?.flushLogs()
            }
        }
    }

    private func flushLogs() {
        logFlush?.cancel()
        logFlush = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        if let client {
            send(lines: batch, to: client)
        }
    }

    /// Last `count` lines of every raw log file on disk, keyed by file stem
    /// (`daemon`, `sing-box`, `openvpn-<id>`).
    func tails(_ count: Int) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: logDirectory)) ?? []
        for name in names where name.hasSuffix(".log") {
            let stem = String(name.dropLast(".log".count))
            let source =
                stem.hasPrefix("openvpn-")
                ? "openvpn:" + stem.dropFirst("openvpn-".count) : stem
            result[stem] = file(for: source)?.tail(count) ?? []
        }
        return result
    }

    private func file(for source: String) -> RotatingLogFile? {
        if let existing = files[source] { return existing }
        let path = (logDirectory as NSString).appendingPathComponent(
            RunLayout.childLog(source: source))
        guard let opened = try? RotatingLogFile(path: path) else { return nil }
        files[source] = opened
        return opened
    }

    private func send(status: RuntimeStatus, to client: ClientProxy) {
        guard let data = try? XPCCodec.encode(status) else { return }
        client.proxy.statusChanged(data)
    }

    private func send(lines: [LogLine], to client: ClientProxy) {
        guard let data = try? XPCCodec.encode(lines) else { return }
        client.proxy.logLines(data)
    }
}

extension LogLine {
    /// `2026-08-25T12:00:00.123Z INFO message` — the raw file format.
    var formatted: String {
        "\(LogLine.timestampStyle.format(ts)) \(level.rawValue.uppercased()) \(message)"
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .error: .error
        case .warning: .default
        case .info: .info
        case .debug: .debug
        }
    }
}
