import Foundation

public struct WireGuardImportResult: Sendable, Equatable, Codable {
    public var privateKey: String
    public var presharedKey: String?
    public var meta: WireGuardMeta
    public var name: String

    public init(
        privateKey: String, presharedKey: String? = nil, meta: WireGuardMeta, name: String
    ) {
        self.privateKey = privateKey
        self.presharedKey = presharedKey
        self.meta = meta
        self.name = name
    }
}

public enum WireGuardImportError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupported(String)
}

public enum WireGuardConfParser {
    private enum Section {
        case interface
        case peer
        case ignored
    }

    private struct ParsedSection {
        var values: [String: [String]] = [:]

        mutating func append(key: String, value: String) {
            values[key.lowercased(), default: []].append(value)
        }

        func last(_ key: String) -> String? {
            values[key.lowercased()]?.last
        }

        func list(_ key: String) -> [String] {
            values[key.lowercased(), default: []].flatMap { value in
                value.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    public static func parse(_ text: String) throws -> WireGuardImportResult {
        var interface: ParsedSection?
        var peers: [ParsedSection] = []
        var section: Section?

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.first == "[", line.last == "]" {
                let name = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch name.lowercased() {
                case "interface":
                    guard interface == nil else {
                        throw WireGuardImportError.invalid("multiple Interface sections")
                    }
                    interface = ParsedSection()
                    section = .interface
                case "peer":
                    peers.append(ParsedSection())
                    section = .peer
                default:
                    section = .ignored
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            switch section {
            case .interface:
                interface?.append(key: key, value: value)
            case .peer:
                peers[peers.count - 1].append(key: key, value: value)
            case .ignored, .none:
                break
            }
        }

        guard let interface else {
            throw WireGuardImportError.invalid("Interface section is missing")
        }
        guard !peers.isEmpty else {
            throw WireGuardImportError.invalid("at least one Peer section is required")
        }
        guard let privateKey = nonempty(interface.last("PrivateKey")) else {
            throw WireGuardImportError.invalid("PrivateKey is missing")
        }
        try validateKey(privateKey, field: "PrivateKey")

        let addresses = interface.list("Address").compactMap(normalizedIPv4Prefix)
        guard !addresses.isEmpty else {
            throw WireGuardImportError.invalid("Address must contain an IPv4 prefix")
        }
        let discoveredDNS = interface.list("DNS").filter { value in
            guard !value.contains("/") else { return false }
            guard let prefix = IPv4Prefix(value) else { return false }
            return prefix.isHost
        }
        let mtu = try parseMTU(interface.last("MTU"))

        var resultPeers: [WireGuardPeer] = []
        var presharedKey: String?
        for (index, peer) in peers.enumerated() {
            guard let publicKey = nonempty(peer.last("PublicKey")) else {
                throw WireGuardImportError.invalid("peer \(index + 1) PublicKey is missing")
            }
            try validateKey(publicKey, field: "peer \(index + 1) PublicKey")

            let peerPresharedKey = nonempty(peer.last("PresharedKey"))
            if let peerPresharedKey {
                guard index == 0 else {
                    throw WireGuardImportError.unsupported(
                        "preshared keys are supported on the first peer only")
                }
                try validateKey(peerPresharedKey, field: "PresharedKey")
                presharedKey = peerPresharedKey
            }

            guard let endpoint = nonempty(peer.last("Endpoint")) else {
                throw WireGuardImportError.invalid("peer \(index + 1) Endpoint is missing")
            }
            let (host, port) = try parseEndpoint(endpoint)
            // A bare address is normalized to /32 like `Address`: wg accepts
            // `AllowedIPs = 10.0.0.5`, sing-box refuses a prefix-less entry outright
            // ("decode config"), which would import cleanly and then fail to start.
            let allowedIPs = peer.list("AllowedIPs").compactMap(normalizedIPv4Prefix)
            guard !allowedIPs.isEmpty else {
                throw WireGuardImportError.invalid("peer \(index + 1) AllowedIPs must contain IPv4")
            }
            let keepalive = try parseKeepalive(peer.last("PersistentKeepalive"), peer: index + 1)
            resultPeers.append(
                WireGuardPeer(
                    host: host, port: port, publicKey: publicKey,
                    hasPresharedKey: peerPresharedKey != nil, allowedIPs: allowedIPs,
                    keepalive: keepalive))
        }

        return WireGuardImportResult(
            privateKey: privateKey,
            presharedKey: presharedKey,
            meta: WireGuardMeta(
                addresses: addresses, peers: resultPeers, mtu: mtu, discoveredDNS: discoveredDNS),
            name: resultPeers[0].host)
    }

    private static func stripComment(_ line: String) -> String {
        let index = [line.firstIndex(of: "#"), line.firstIndex(of: ";")].compactMap { $0 }.min()
        return index.map { String(line[..<$0]) } ?? line
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func validateKey(_ value: String, field: String) throws {
        guard Data(base64Encoded: value)?.count == 32 else {
            throw WireGuardImportError.invalid("\(field) must be base64 encoding of 32 bytes")
        }
    }

    private static func normalizedIPv4Prefix(_ value: String) -> String? {
        guard IPv4Prefix(value) != nil else { return nil }
        return value.contains("/") ? value : "\(value)/32"
    }

    private static func parseMTU(_ value: String?) throws -> Int? {
        guard let value = nonempty(value) else { return nil }
        guard value.allSatisfy(\.isNumber), let mtu = Int(value), (576...9_000).contains(mtu)
        else {
            throw WireGuardImportError.invalid("MTU must be between 576 and 9000")
        }
        return mtu
    }

    private static func parseEndpoint(_ value: String) throws -> (String, Int) {
        if value.first == "[" {
            throw WireGuardImportError.unsupported("IPv6 peer endpoints are not supported")
        }
        guard let colon = value.lastIndex(of: ":") else {
            throw WireGuardImportError.invalid("Endpoint must be host:port")
        }
        let host = String(value[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPort = String(value[value.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(":"), !rawPort.isEmpty,
            rawPort.allSatisfy(\.isNumber), let port = Int(rawPort), (1...65_535).contains(port)
        else {
            throw WireGuardImportError.invalid("Endpoint must be host:port with port 1...65535")
        }
        return (host, port)
    }

    private static func parseKeepalive(_ value: String?, peer: Int) throws -> Int? {
        guard let value = nonempty(value) else { return nil }
        guard value.allSatisfy(\.isNumber), let keepalive = Int(value),
            (0...65_535).contains(keepalive)
        else {
            throw WireGuardImportError.invalid(
                "peer \(peer) PersistentKeepalive must be between 0 and 65535")
        }
        return keepalive == 0 ? nil : keepalive
    }
}
