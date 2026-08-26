import Foundation
import SystemConfiguration

/// The system resolvers (`State:/Network/Global/DNS`), the default gateway and primary
/// service (`State:/Network/Global/IPv4`) and the primary service's manual resolvers
/// (`Setup:/Network/Service/<primary>/DNS`). The generator routes the *effective* resolvers
/// into the TUN so that `hijack-dns` sees their queries — except a resolver that *is* the
/// gateway (docs/design/03-routing.md, "Notes on specific choices").
public enum SystemDNS {
    static let dnsKey = "State:/Network/Global/DNS"
    static let ipv4Key = "State:/Network/Global/IPv4"
    static let manualDNSPattern = "Setup:/Network/Service/[^/]+/DNS"

    public struct Snapshot: Equatable, Sendable {
        /// IPv4 addresses of the system resolvers, unique, in configuration order.
        public var servers: [String]
        /// The IPv4 default gateway, if any.
        public var router: String?
        /// The primary network service (`PrimaryService` of `Global/IPv4`), if any.
        public var primaryService: String?
        /// IPv4 resolvers entered by hand for the primary service (System Settings ›
        /// Network › DNS). They take precedence over the daemon's override (F12).
        public var manualServers: [String]

        public init(
            servers: [String], router: String?, primaryService: String? = nil,
            manualServers: [String] = []
        ) {
            self.servers = servers
            self.router = router
            self.primaryService = primaryService
            self.manualServers = manualServers
        }

        /// The resolvers mDNSResponder actually uses while the daemon overrides the system
        /// resolver with `override` (F12): the manual ones when present, else the override
        /// itself. `nil` (override off) leaves the plain system resolvers.
        public func effectiveServers(override: String?) -> [String] {
            guard let override else { return servers }
            return manualServers.isEmpty ? [override] : manualServers
        }

        /// The effective resolvers the generator may route into the TUN. A host route for
        /// the default gateway through the TUN makes the gateway unreachable from the
        /// physical interface, which cuts every direct and tunnel-server connection
        /// (2026-08-26, "network is unreachable" on every dial), so the gateway is never
        /// carved out.
        public func routable(override: String? = nil) -> [String] {
            effectiveServers(override: override).filter { $0 != router }
        }

        /// The effective resolvers that cannot be routed into the TUN (the default gateway).
        public func unroutable(override: String? = nil) -> [String] {
            effectiveServers(override: override).filter { $0 == router }
        }
    }

    /// Empty without a network configuration; IPv6 resolvers are left out (the TUN is
    /// IPv4-only).
    public static func snapshot() -> Snapshot {
        guard let store = SCDynamicStoreCreate(nil, "Wayfork" as CFString, nil, nil) else {
            return Snapshot(servers: [], router: nil)
        }
        var servers: [String] = []
        if let dns = SCDynamicStoreCopyValue(store, dnsKey as CFString) as? [String: Any] {
            servers = ipv4Addresses(dns)
        }
        var router: String?
        var primary: String?
        if let ipv4 = SCDynamicStoreCopyValue(store, ipv4Key as CFString) as? [String: Any] {
            if let value = ipv4[kSCPropNetIPv4Router as String] as? String, IPv4Prefix(value) != nil
            {
                router = value
            }
            primary = ipv4[kSCDynamicStorePropNetPrimaryService as String] as? String
        }
        var manual: [String] = []
        if let primary,
            let setup = SCDynamicStoreCopyValue(
                store, "Setup:/Network/Service/\(primary)/DNS" as CFString) as? [String: Any]
        {
            manual = ipv4Addresses(setup)
        }
        return Snapshot(
            servers: servers, router: router, primaryService: primary, manualServers: manual)
    }

    /// `ServerAddresses` of a DNS entry: IPv4 only, unique, in order.
    static func ipv4Addresses(_ entry: [String: Any]) -> [String] {
        guard let addresses = entry[kSCPropNetDNSServerAddresses as String] as? [String] else {
            return []
        }
        var result: [String] = []
        for address in addresses where IPv4Prefix(address) != nil && !result.contains(address) {
            result.append(address)
        }
        return result
    }

    /// Calls `onChange` on `queue` whenever the system resolvers, the default gateway /
    /// primary service or a service's manual DNS change. Notifications stop when the
    /// instance is released.
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
                SCDynamicStoreSetNotificationKeys(
                    store, [SystemDNS.dnsKey, SystemDNS.ipv4Key] as CFArray,
                    [SystemDNS.manualDNSPattern] as CFArray),
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
