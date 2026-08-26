import Foundation
import SystemConfiguration

/// The system resolvers (`State:/Network/Global/DNS`). The generator routes them into the
/// TUN so that `hijack-dns` sees the system resolver's queries
/// (docs/design/03-routing.md, "Notes on specific choices").
public enum SystemDNS {
    static let key = "State:/Network/Global/DNS"

    /// IPv4 addresses of the current system resolvers, unique, in configuration order.
    /// Empty without a network configuration; IPv6 resolvers are left out (the TUN is
    /// IPv4-only).
    public static func servers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Wayfork" as CFString, nil, nil),
            let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
            let addresses = value[kSCPropNetDNSServerAddresses as String] as? [String]
        else { return [] }
        var result: [String] = []
        for address in addresses where IPv4Prefix(address) != nil && !result.contains(address) {
            result.append(address)
        }
        return result
    }

    /// Calls `onChange` on `queue` whenever the system resolvers change. Notifications stop
    /// when the instance is released.
    public final class Watcher {
        private final class Box: @unchecked Sendable {
            let handler: @Sendable () -> Void
            init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        }

        private let box: Box
        private let store: SCDynamicStore

        public init?(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
            let box = Box(onChange)
            var context = SCDynamicStoreContext(
                version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().handler()
            }
            guard
                let store = SCDynamicStoreCreate(nil, "Wayfork" as CFString, callback, &context),
                SCDynamicStoreSetNotificationKeys(store, [SystemDNS.key] as CFArray, nil),
                SCDynamicStoreSetDispatchQueue(store, queue)
            else { return nil }
            self.box = box
            self.store = store
        }

        deinit {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
    }
}
