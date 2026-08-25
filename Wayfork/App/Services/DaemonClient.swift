import Foundation
import WayforkCore
import os

/// XPC client for `WayforkDaemon` (docs/design/05-daemon.md, "XPC interface"). Owns one
/// `NSXPCConnection` to the Mach service, forwards status/log pushes to the main actor and
/// reports interruptions so the model can reattach.
@MainActor
final class DaemonClient {
    enum Failure: Error, LocalizedError {
        case notConnected
        /// The message could not be delivered (connection invalid or interrupted).
        case transport(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to the Wayfork helper."
            case .transport(let message): "Can't reach the Wayfork helper: \(message)"
            case .decoding(let message): "Unexpected reply from the Wayfork helper: \(message)"
            }
        }
    }

    var onStatus: ((RuntimeStatus) -> Void)?
    var onLogLines: (([LogLine]) -> Void)?
    /// The daemon process went away (crash, unregister, update); the connection object is
    /// still usable and relaunches the daemon on the next message.
    var onInterruption: (() -> Void)?
    var onInvalidation: (() -> Void)?

    private var connection: NSXPCConnection?
    private let log = Logger(subsystem: WayforkIdentifiers.app, category: "xpc")

    var isConnected: Bool { connection != nil }

    func connect() {
        guard connection == nil else { return }
        let receiver = ClientReceiver(
            onStatus: { [weak self] status in self?.onStatus?(status) },
            onLogLines: { [weak self] lines in self?.onLogLines?(lines) })
        let connection = NSXPCConnection(
            machServiceName: WayforkIdentifiers.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WayforkDaemonXPC.self)
        connection.exportedInterface = NSXPCInterface(with: WayforkClientXPC.self)
        connection.exportedObject = receiver
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleInvalidation() }
        }
        connection.resume()
        self.connection = connection
        log.info("connecting to \(WayforkIdentifiers.machService, privacy: .public)")
    }

    func disconnect() {
        guard let connection else { return }
        self.connection = nil
        connection.invalidate()
    }

    // MARK: - Calls

    func getInfo() async throws -> DaemonInfo {
        try await call(DaemonInfo.self) { proxy, reply in proxy.getInfo(reply) }
    }

    func getStatus() async throws -> RuntimeStatus {
        try await call(RuntimeStatus.self) { proxy, reply in proxy.getStatus(reply) }
    }

    func apply(_ plan: RuntimePlan) async throws -> ApplyResult {
        let data = try XPCCodec.encode(plan)
        return try await call(ApplyResult.self) { proxy, reply in proxy.apply(data, reply) }
    }

    func stop() async throws -> ApplyResult {
        try await call(ApplyResult.self) { proxy, reply in proxy.stop(reply) }
    }

    func reconnect(tunnelID: UUID) async throws -> ApplyResult {
        let id = tunnelID.uuidString.lowercased()
        return try await call(ApplyResult.self) { proxy, reply in
            proxy.reconnect(tunnelID: id, reply)
        }
    }

    func subscribe() async throws -> ApplyResult {
        try await call(ApplyResult.self) { proxy, reply in proxy.subscribe(reply) }
    }

    func collectDiagnostics() async throws -> DaemonDiagnostics {
        try await call(DaemonDiagnostics.self) { proxy, reply in proxy.collectDiagnostics(reply) }
    }

    // MARK: - Plumbing

    private func call<T: Decodable & Sendable>(
        _ type: T.Type,
        _ invoke: (any WayforkDaemonXPC, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> T {
        guard let connection else { throw Failure.notConnected }
        let reply = ReplyOnce()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            reply.arm(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                reply.resume(.failure(Failure.transport(error.localizedDescription)))
            }
            guard let daemon = proxy as? any WayforkDaemonXPC else {
                reply.resume(.failure(Failure.notConnected))
                return
            }
            invoke(daemon) { data in reply.resume(.success(data)) }
        }
        do {
            return try XPCCodec.decode(T.self, from: data)
        } catch {
            throw Failure.decoding("\(error)")
        }
    }

    private func handleInterruption() {
        log.warning("helper connection interrupted")
        onInterruption?()
    }

    private func handleInvalidation() {
        guard connection != nil else { return }  // our own disconnect()
        log.warning("helper connection invalidated")
        connection = nil
        onInvalidation?()
    }
}

/// Resumes a continuation at most once: XPC may call both the reply and the error handler.
private final class ReplyOnce: Sendable {
    private let state = OSAllocatedUnfairLock<CheckedContinuation<Data, any Error>?>(
        initialState: nil)

    func arm(_ continuation: CheckedContinuation<Data, any Error>) {
        state.withLock { $0 = continuation }
    }

    func resume(_ result: Result<Data, any Error>) {
        let continuation = state.withLock { stored -> CheckedContinuation<Data, any Error>? in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(with: result)
    }
}

/// Exported object the daemon pushes into. Called on an XPC queue; hops to the main actor.
private final class ClientReceiver: NSObject, WayforkClientXPC, @unchecked Sendable {
    private let onStatus: @MainActor @Sendable (RuntimeStatus) -> Void
    private let onLogLines: @MainActor @Sendable ([LogLine]) -> Void

    init(
        onStatus: @escaping @MainActor @Sendable (RuntimeStatus) -> Void,
        onLogLines: @escaping @MainActor @Sendable ([LogLine]) -> Void
    ) {
        self.onStatus = onStatus
        self.onLogLines = onLogLines
    }

    func statusChanged(_ status: Data) {
        guard let decoded = try? XPCCodec.decode(RuntimeStatus.self, from: status) else { return }
        let handler = onStatus
        Task { @MainActor in handler(decoded) }
    }

    func logLines(_ batch: Data) {
        guard let decoded = try? XPCCodec.decode([LogLine].self, from: batch) else { return }
        let handler = onLogLines
        Task { @MainActor in handler(decoded) }
    }
}
