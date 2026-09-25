import Foundation
import WayforkCore

// Local proxy ports (F17, docs/design/01-data-model.md, "Local proxy"): one loopback port
// per tunnel or group, handed out by the app from 1081 up, kept while switched off.

extension AppModel {
    /// Turns the port on or off; the first turn-on picks the lowest free port.
    func setLocalProxy(exitID: UUID, enabled: Bool) {
        update { store in
            let port = store.localProxy(ofExit: exitID)?.port ?? store.nextFreeLocalProxyPort()
            store.setLocalProxy(LocalProxy(isEnabled: enabled, port: port), forExit: exitID)
        }
        if let name = store.exitName(id: exitID) {
            logs.app(.info, "local proxy \(enabled ? "on" : "off"): \(name)")
        }
    }

    /// Changes the port. Returns an error message, or nil when it went through.
    @discardableResult
    func setLocalProxyPort(exitID: UUID, _ text: String) -> String? {
        if let problem = LocalProxyText.portProblem(text, store: store, excluding: exitID) {
            return problem
        }
        let port = Int(text.trimmingCharacters(in: .whitespaces))!
        update { store in
            let enabled = store.localProxy(ofExit: exitID)?.isEnabled ?? false
            store.setLocalProxy(LocalProxy(isEnabled: enabled, port: port), forExit: exitID)
        }
        return nil
    }

    /// The daemon could not bind this exit's port (`proxy.portInUse`).
    func isLocalProxyPortTaken(exitID: UUID) -> Bool {
        status?.proxyPortInUse.contains(exitID.uuidString.lowercased()) == true
    }
}

extension Store {
    /// Writes the proxy on the tunnel or group `id` names.
    fileprivate mutating func setLocalProxy(_ proxy: LocalProxy, forExit id: UUID) {
        if let index = tunnels.firstIndex(where: { $0.id == id }) {
            tunnels[index].localProxy = proxy
        } else if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].localProxy = proxy
        }
    }
}
