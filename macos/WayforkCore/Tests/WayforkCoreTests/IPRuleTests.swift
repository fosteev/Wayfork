import Foundation
import Testing

@testable import WayforkCore

// F11: IP rules (docs/design/01-data-model.md, 03-routing.md).

@Test func ipv4PrefixParsesAddressesAndSubnets() throws {
    let host = try #require(IPv4Prefix("203.0.113.7"))
    #expect(host.bits == 32 && host.isHost)
    #expect(host.canonical == "203.0.113.7" && host.description == "203.0.113.7/32")
    let net = try #require(IPv4Prefix("10.8.0.5/24"))
    #expect(net.canonical == "10.8.0.0/24")
    for bad in [
        "10.8.0.0/33", "10.8.0.0/-1", "10.8.0.0/+1", "10.8/16", "::1", "10.8.0.0/", "x", "",
    ] {
        #expect(IPv4Prefix(bad) == nil, "\(bad)")
    }
    let ten = try #require(IPv4Prefix("10.0.0.0/8"))
    #expect(ten.overlaps(net) && net.overlaps(ten) && !net.overlaps(host))
    #expect(ten.subtracting(all: [net]).count == 16)
    let two = ten.subtracting(all: [net, IPv4Prefix("10.9.0.0/16")!]).map(\.description)
    #expect(two.contains("10.8.1.0/24") && !two.contains("10.9.0.0/16") && two.count == 15)
    #expect(ten.subtracting(all: [ten]).isEmpty)
    #expect(net.subtracting(all: [host]) == [net])
}

@Test func ipRulesNormalizeToCanonicalForm() throws {
    #expect(try RulePattern.normalize(" 10.8.0.5/24 ", match: .ip) == "10.8.0.0/24")
    #expect(try RulePattern.normalize("203.0.113.7", match: .ip) == "203.0.113.7")
    #expect(try RulePattern.normalize("203.0.113.7/32", match: .ip) == "203.0.113.7")
    #expect(try RulePattern.normalize("http://10.8.0.5:8080/x", match: .ip) == "10.8.0.5")
    #expect(try RulePattern.normalize("10.8.0.5:22", match: .ip) == "10.8.0.5")
    #expect(throws: RulePatternError.empty) { try RulePattern.normalize(" ", match: .ip) }
    for bad in ["example.com", "::1", "10.8.0.0/33", "2001:db8::/32"] {
        #expect(throws: RulePatternError.invalidIP, "\(bad)") {
            try RulePattern.normalize(bad, match: .ip)
        }
    }
    for reserved in [
        "0.0.0.0/0", "127.0.0.1", "169.254.1.1", "224.0.0.1", "255.255.255.255", "198.18.0.5",
        "198.19.0.0/16", "172.19.0.1",
    ] {
        #expect(throws: RulePatternError.reservedRange, "\(reserved)") {
            try RulePattern.normalize(reserved, match: .ip)
        }
    }
    // Wider than a reserved range is fine: the generator carves the hole.
    #expect(try RulePattern.normalize("172.16.0.0/12", match: .ip) == "172.16.0.0/12")
    #expect(try RulePattern.normalize("198.0.0.0/8", match: .ip) == "198.0.0.0/8")
    // Domain kinds point at the IP kind; a lone number is still just invalid.
    #expect(throws: RulePatternError.looksLikeIP) {
        try RulePattern.normalize("10.8.0.0/24", match: .suffix)
    }
    #expect(throws: RulePatternError.looksLikeIP) {
        try RulePattern.normalize("203.0.113.7", match: .exact)
    }
    #expect(throws: RulePatternError.invalidHostname("1234")) {
        try RulePattern.normalize("1234", match: .suffix)
    }
    #expect(RulePattern.inferMatch("10.8.0.0/24") == .ip)
    #expect(RulePattern.inferMatch("https://203.0.113.7/") == .ip)
    #expect(RulePattern.inferMatch("example.com") == .suffix)
    #expect(RulePattern.inferMatch("*.10.8.0.0") == .wildcard)
    #expect(!RulePattern.matches(host: "10.8.0.5", pattern: "10.8.0.0/24", match: .ip))
}

@Test func validatorChecksIPRulesAgainstServersAndLAN() {
    var office = Fixtures.work
    office.kind = .openVPN(
        OpenVPNMeta(
            remotes: [Remote(host: "203.0.113.7", port: 1194, proto: "udp")],
            needsCredentials: false, needsKeyPassphrase: false, discoveredDNS: [],
            configHash: "x"))
    let first = Rule(pattern: "10.8.0.0/24", match: .ip, tunnelID: Fixtures.workID)
    let duplicate = Rule(pattern: "10.8.0.0/24", match: .ip, tunnelID: Fixtures.workID)
    let shadowed = Rule(pattern: "10.8.0.0/24", match: .ip, tunnelID: Fixtures.homeID)
    let coversServer = Rule(pattern: "203.0.113.0/24", match: .ip, tunnelID: Fixtures.homeID)
    let coversLAN = Rule(pattern: "192.168.0.0/16", match: .ip, tunnelID: Fixtures.workID)
    let directLAN = Rule(pattern: "192.168.1.0/24", match: .ip, target: .direct)
    var store = Fixtures.store(rules: [
        first, duplicate, shadowed, coversServer, coversLAN, directLAN,
    ])
    store.tunnels[0] = office
    let lan = LocalNetwork(interface: "en0", prefix: IPv4Prefix("192.168.1.0/24")!)
    let issues = RuleValidator.validate(store, localNetworks: [lan])
    #expect(issues[first.id] == nil)
    #expect(issues[duplicate.id] == [.duplicate(of: first.id)])
    #expect(issues[shadowed.id] == [.shadowed(by: first.id)])
    #expect(issues[coversServer.id] == [.coversTunnelServer(tunnelName: "Work")])
    #expect(
        issues[coversLAN.id] == [.coversLocalNetwork(interface: "en0", network: "192.168.1.0/24")])
    #expect(issues[directLAN.id] == nil)
    // Warnings do not deactivate a rule.
    let active = RuleValidator.activeRules(store)
    #expect(active[Fixtures.workID]?.map(\.id) == [first.id, coversLAN.id])
    #expect(active[Fixtures.homeID]?.map(\.id) == [coversServer.id])
    #expect(RuleValidator.activeExceptions(store).map(\.id) == [directLAN.id])
}

@Test func ipRuleSetsAreSeparateFiles() throws {
    let rules = [
        Rule(pattern: "example.com", tunnelID: Fixtures.workID),
        Rule(pattern: "10.8.0.0/24", match: .ip, tunnelID: Fixtures.workID),
        Rule(pattern: "203.0.113.7", match: .ip, tunnelID: Fixtures.workID),
        Rule(pattern: "172.16.0.0/12", match: .ip, tunnelID: Fixtures.workID),
    ]
    let domains = try ruleObjectsOf(RuleSetGenerator.render(rules: rules))
    #expect(domains.count == 1 && domains[0]["ip_cidr"] == nil)
    let ip = try ruleObjectsOf(RuleSetGenerator.renderIP(rules: rules))
    #expect(ip.count == 1)
    let ranges = try #require(ip[0]["ip_cidr"] as? [String])
    #expect(Array(ranges.prefix(2)) == ["10.8.0.0/24", "203.0.113.7/32"])
    // The TUN subnet is carved out of the wide range.
    let tun = IPv4Prefix("172.19.0.0/30")!
    #expect(!ranges.contains("172.16.0.0/12") && ranges.contains("172.24.0.0/13"))
    #expect(!ranges.compactMap { IPv4Prefix($0) }.contains { $0.contains(tun) })
    #expect(try ruleObjectsOf(RuleSetGenerator.renderIP(rules: [rules[0]])).isEmpty)

    let files = RuleSetGenerator.generate(
        tunnels: [Fixtures.work], activeRules: [Fixtures.workID: rules],
        exceptions: [Rule(pattern: "192.0.2.0/24", match: .ip, target: .direct)])
    #expect(
        files.keys.sorted()
            == [
                "rules-direct-ip.json", "rules-direct.json", Fixtures.work.ipRuleSetFileName,
                Fixtures.work.ruleSetFileName,
            ].sorted())
    #expect(
        try ruleObjectsOf(files["rules-direct-ip.json"]!)[0]["ip_cidr"] as? [String]
            == ["192.0.2.0/24"])
}

private func ruleObjectsOf(_ text: String) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    return object?["rules"] as? [[String: Any]] ?? []
}
