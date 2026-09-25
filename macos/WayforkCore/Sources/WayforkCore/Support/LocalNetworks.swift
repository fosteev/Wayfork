import Darwin
import Foundation

/// One of the Mac's own IPv4 networks — the "covers your LAN" check of IP rules (F11).
public struct LocalNetwork: Hashable, Sendable {
    public var interface: String
    public var prefix: IPv4Prefix

    public init(interface: String, prefix: IPv4Prefix) {
        self.interface = interface
        self.prefix = prefix
    }

    /// The networks of every interface that is up, not loopback, not a tunnel, with a real
    /// subnet (no point-to-point /32, no link-local). Empty when the lookup fails.
    public static func current() -> [LocalNetwork] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [LocalNetwork] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sockaddr = entry.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET),
                let maskaddr = entry.ifa_netmask,
                entry.ifa_flags & UInt32(IFF_UP) != 0,
                entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("lo") else { continue }
            let address = ipv4(sockaddr)
            let bits = ipv4(maskaddr).nonzeroBitCount
            let prefix = IPv4Prefix(address: address, bits: bits)
            guard bits > 0, bits < 32, prefix.address >> 16 != 0xA9FE else { continue }
            let network = LocalNetwork(interface: name, prefix: prefix)
            if !result.contains(network) { result.append(network) }
        }
        return result
    }

    private static func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }
}
