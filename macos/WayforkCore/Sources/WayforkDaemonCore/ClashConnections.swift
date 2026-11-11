import Foundation

/// One entry of `GET /connections`, reduced to what the sampler and the connection cut
/// need. `upload` and `download` are cumulative for the connection's lifetime; the
/// `metadata` fields stay inside the daemon.
public struct ClashConnection: Sendable, Hashable {
    public var id: String
    /// Outbound chain, e.g. `["t-<tunnel id>"]` or `["direct"]`.
    public var chains: [String]
    public var upload: UInt64
    public var download: UInt64
    /// `metadata.network`: `"tcp"` or `"udp"` (the dead-UDP detector keys on the latter).
    public var network: String
    /// `metadata.host`: the fake-ip or sniffed domain; empty for a bare IP connection.
    public var host: String
    /// `metadata.destinationIP`
    public var destinationIP: String
    /// `metadata.processPath`; empty when sing-box could not find the process.
    public var processPath: String
    /// sing-box's matched route description, not the selected outbound or the host.
    public var matchedRule: String?

    /// F24 emits one rule-set per row. Only accept that exact generated route shape;
    /// legacy, built-in, final and unfamiliar routes have no attributable user rule.
    public var ruleID: String? {
        guard let matchedRule else { return nil }
        let parts = matchedRule.components(separatedBy: " => ")
        guard parts.count == 2, parts[1].hasPrefix("route("), parts[1].hasSuffix(")") else {
            return nil
        }
        var conditions = parts[0].components(separatedBy: " ")
        if conditions.first == "network=tcp" || conditions.first == "network=udp" {
            conditions.removeFirst()
        }
        let prefix = "rule_set=rules-r-"
        guard conditions.count == 1, conditions[0].hasPrefix(prefix) else { return nil }
        let id = String(conditions[0].dropFirst(prefix.count))
        guard id.count == 36, let uuid = UUID(uuidString: id) else { return nil }
        return uuid.uuidString.lowercased()
    }

    public init(
        id: String, chains: [String], upload: UInt64, download: UInt64,
        network: String = "", host: String = "", destinationIP: String = "",
        processPath: String = "", matchedRule: String? = nil
    ) {
        self.id = id
        self.chains = chains
        self.upload = upload
        self.download = download
        self.network = network
        self.host = host
        self.destinationIP = destinationIP
        self.processPath = processPath
        self.matchedRule = matchedRule
    }
}

extension ClashConnection: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, chains, upload, download, metadata, rule
    }

    private enum MetadataKeys: String, CodingKey {
        case network, host, destinationIP, processPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chains = try c.decodeIfPresent([String].self, forKey: .chains) ?? []
        upload = UInt64(max(0, try c.decodeIfPresent(Int64.self, forKey: .upload) ?? 0))
        download = UInt64(max(0, try c.decodeIfPresent(Int64.self, forKey: .download) ?? 0))
        matchedRule = try c.decodeIfPresent(String.self, forKey: .rule)
        if let m = try? c.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata) {
            network = (try? m.decodeIfPresent(String.self, forKey: .network)) ?? ""
            host = (try? m.decodeIfPresent(String.self, forKey: .host)) ?? ""
            destinationIP = (try? m.decodeIfPresent(String.self, forKey: .destinationIP)) ?? ""
            processPath = (try? m.decodeIfPresent(String.self, forKey: .processPath)) ?? ""
        } else {
            network = ""
            host = ""
            destinationIP = ""
            processPath = ""
        }
    }
}

/// `GET /connections` of sing-box's Clash API. Other fields (`downloadTotal`, `memory`, the
/// rest of `metadata`) are ignored; nothing per-connection ever leaves the daemon.
public struct ClashConnections: Decodable, Sendable {
    public var connections: [ClashConnection]

    public init(connections: [ClashConnection]) {
        self.connections = connections
    }

    private enum CodingKeys: String, CodingKey {
        case connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Clash-style servers send `null` instead of an empty list.
        connections = try c.decodeIfPresent([ClashConnection].self, forKey: .connections) ?? []
    }

    public static func decode(_ data: Data) throws -> ClashConnections {
        try JSONDecoder().decode(ClashConnections.self, from: data)
    }
}
