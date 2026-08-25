import Foundation
import WayforkCore
import WayforkDaemonCore

/// Accepts connections from the signed app only and hands each one a `DaemonService`
/// (docs/design/05-daemon.md, "Client verification").
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let supervisor: Supervisor
    private let hub: ClientHub
    private let requirement: String?

    init(supervisor: Supervisor, hub: ClientHub, teamID: String?) {
        self.supervisor = supervisor
        self.hub = hub
        requirement = teamID.map { CodeSigningRequirement.client(teamID: $0) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        guard let requirement else {
            hub.post(
                .error, "rejecting client pid \(connection.processIdentifier): no Team ID baked in")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: WayforkDaemonXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WayforkClientXPC.self)
        let service = DaemonService(connection: connection, supervisor: supervisor, hub: hub)
        connection.exportedObject = service
        let hub = hub
        let connectionID = ObjectIdentifier(connection)
        let pid = connection.processIdentifier
        connection.invalidationHandler = {
            hub.post(.info, "client pid \(pid) disconnected")
            Task { await hub.unsubscribe(connectionID: connectionID) }
        }
        connection.resume()
        hub.post(.info, "client pid \(pid) connected")
        return true
    }
}

/// `NSXPCConnection` is not `Sendable`; the service only touches it from the XPC queue
/// (`subscribe`) and never mutates it, hence `@unchecked`.
final class DaemonService: NSObject, WayforkDaemonXPC, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let supervisor: Supervisor
    private let hub: ClientHub

    init(connection: NSXPCConnection, supervisor: Supervisor, hub: ClientHub) {
        self.connection = connection
        self.supervisor = supervisor
        self.hub = hub
    }

    func getInfo(_ reply: @escaping @Sendable (Data) -> Void) {
        let supervisor = supervisor
        Task { reply(Self.encode(await supervisor.info())) }
    }

    func apply(_ plan: Data, _ reply: @escaping @Sendable (Data) -> Void) {
        let decoded: RuntimePlan
        do {
            decoded = try XPCCodec.decode(RuntimePlan.self, from: plan)
        } catch {
            reply(
                Self.encode(ApplyResult.failure(.planInvalid(reason: "undecodable plan: \(error)")))
            )
            return
        }
        let supervisor = supervisor
        Task { reply(Self.encode(await supervisor.apply(decoded))) }
    }

    func stop(_ reply: @escaping @Sendable (Data) -> Void) {
        let supervisor = supervisor
        Task { reply(Self.encode(await supervisor.stop())) }
    }

    func reconnect(tunnelID: String, _ reply: @escaping @Sendable (Data) -> Void) {
        let supervisor = supervisor
        Task { reply(Self.encode(await supervisor.reconnect(tunnelID: tunnelID))) }
    }

    func getStatus(_ reply: @escaping @Sendable (Data) -> Void) {
        let supervisor = supervisor
        Task { reply(Self.encode(await supervisor.currentStatus())) }
    }

    func subscribe(_ reply: @escaping @Sendable (Data) -> Void) {
        guard let connection else {
            reply(Self.encode(ApplyResult.failure(.internalError(message: "connection gone"))))
            return
        }
        let hub = hub
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            hub.post(.warning, "push to client failed: \(error.localizedDescription)")
        }
        guard let client = proxy as? any WayforkClientXPC else {
            reply(Self.encode(ApplyResult.failure(.internalError(message: "bad client proxy"))))
            return
        }
        let box = ClientProxy(proxy: client, connectionID: ObjectIdentifier(connection))
        Task {
            await hub.subscribe(box)
            reply(Self.encode(ApplyResult.success))
        }
    }

    func collectDiagnostics(_ reply: @escaping @Sendable (Data) -> Void) {
        let supervisor = supervisor
        Task { reply(Self.encode(await supervisor.diagnostics())) }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? XPCCodec.encode(value)) ?? Data()
    }
}
