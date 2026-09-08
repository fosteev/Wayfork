import Foundation

/// Resolves the OpenVPN servers' hostnames for the plan (docs/design/03-routing.md, "Notes on
/// specific choices"). Blocking `getaddrinfo`: call it off the main actor.
public enum HostResolver {
    /// Non-literal OpenVPN and WireGuard server hosts, lowercased, unique, in store order.
    public static func serverHosts(in store: Store) -> [String] {
        var hosts: [String] = []
        for tunnel in store.tunnels where tunnel.isEnabled {
            let candidates: [String]
            switch tunnel.kind {
            case .openVPN(let meta): candidates = meta.remotes.map(\.host)
            case .wireGuard(let meta): candidates = meta.peers.map(\.host)
            case .vless, .shadowsocks, .trojan, .vmess: candidates = []
            }
            for candidate in candidates
            where candidate.contains("/") || IPv4Prefix(candidate)?.isHost != true {
                let host = candidate.lowercased()
                if !host.isEmpty, !hosts.contains(host) { hosts.append(host) }
            }
        }
        return hosts
    }

    /// Non-literal `remote` hosts of the enabled OpenVPN tunnels, lowercased, unique, in
    /// store order.
    public static func openVPNHosts(in store: Store) -> [String] {
        var hosts: [String] = []
        for tunnel in store.tunnels where tunnel.isEnabled {
            guard case .openVPN(let meta) = tunnel.kind else { continue }
            for remote in meta.remotes where IPv4Prefix(remote.host) == nil {
                let host = remote.host.lowercased()
                if !host.isEmpty, !hosts.contains(host) { hosts.append(host) }
            }
        }
        return hosts
    }

    /// IPv4 addresses per host (sorted, unique). Hosts that do not resolve are left out.
    public static func resolveIPv4(_ hosts: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for host in hosts {
            // A lookup made while Wayfork is already On goes through Wayfork's own resolver
            // (F12), which answers with a fake IP for every name that is not yet in the
            // config's "server hosts → dns-direct" rule — the case on the first apply after
            // a tunnel is added. Such an answer is a name in disguise, never a server
            // address: pinning it as a WireGuard peer would dial the TUN in circles. The
            // Dart client has always filtered them; this is the Swift twin.
            let addresses = resolveIPv4(host).filter { !FakeIPIndex.isFakeIP($0) }
            if !addresses.isEmpty { result[host] = addresses }
        }
        return result
    }

    static func resolveIPv4(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var addresses = Set<String>()
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let entry = node {
            if entry.pointee.ai_family == AF_INET, let address = entry.pointee.ai_addr {
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        addresses.insert(
                            buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
                    }
                }
            }
            node = entry.pointee.ai_next
        }
        return addresses.sorted()
    }
}
