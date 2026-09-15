import Foundation

/// A loopback SOCKS5 / HTTP port that sends an app through one tunnel or group without a
/// rule (F17, docs/design/01-data-model.md, "Local proxy"). The port is kept while the
/// switch is off so turning it back on gives the same address.
public struct LocalProxy: Codable, Sendable, Hashable {
    public static let portRange = 1024...65535
    /// The app hands out ports from here up (the lowest free one).
    public static let firstPort = 1081
    public static let listenAddress = "127.0.0.1"

    public var isEnabled: Bool
    /// `LocalProxy.portRange`, unique across tunnels and groups.
    public var port: Int

    public init(isEnabled: Bool, port: Int) {
        self.isEnabled = isEnabled
        self.port = port
    }

    /// `127.0.0.1:1081`.
    public var address: String { "\(LocalProxy.listenAddress):\(port)" }

    /// What *Copy* puts on the pasteboard: the `socks5h` form, so the client hands the name
    /// to the proxy and nothing is resolved outside the tunnel (03-routing.md).
    public var copyText: String { "socks5h://\(address)" }

    /// sing-box inbound tag: `proxy-t-<id>` / `proxy-g-<id>`.
    public static let inboundTagPrefix = "proxy-"

    public static func inboundTag(forOutboundTag outboundTag: String) -> String {
        inboundTagPrefix + outboundTag
    }

    /// The outbound tag behind an inbound tag (`proxy-t-<id>` → `t-<id>`); nil otherwise.
    public static func outboundTag(fromInboundTag tag: String) -> String? {
        guard tag.hasPrefix(inboundTagPrefix), tag.count > inboundTagPrefix.count else {
            return nil
        }
        return String(tag.dropFirst(inboundTagPrefix.count))
    }
}

extension Store {
    /// Ports held by every tunnel and group (on or off), by owner id.
    public var localProxyPorts: [UUID: Int] {
        var ports: [UUID: Int] = [:]
        for tunnel in tunnels {
            if let proxy = tunnel.localProxy { ports[tunnel.id] = proxy.port }
        }
        for group in groups {
            if let proxy = group.localProxy { ports[group.id] = proxy.port }
        }
        return ports
    }

    /// The lowest port from `LocalProxy.firstPort` up that no tunnel or group holds.
    public func nextFreeLocalProxyPort() -> Int {
        let used = Set(localProxyPorts.values)
        var port = LocalProxy.firstPort
        while used.contains(port) { port += 1 }
        return port
    }

    /// The name of the other tunnel or group holding `port`, when one does.
    public func localProxyPortOwner(_ port: Int, excluding id: UUID) -> String? {
        localProxyPorts.first { $0.key != id && $0.value == port }.flatMap { exitName(id: $0.key) }
    }

    /// The local proxy of a tunnel or group, whichever `id` is.
    public func localProxy(ofExit id: UUID) -> LocalProxy? {
        tunnel(id: id)?.localProxy ?? group(id: id)?.localProxy
    }
}
