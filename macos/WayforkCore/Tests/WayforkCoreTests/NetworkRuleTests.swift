import Foundation
import Testing

@testable import WayforkCore

// F23: Rule.network (docs/design/01-data-model.md, "Network-narrowed rules").

private let discord = "/Applications/Discord.app"

@Test func networkRoundTripsAndIsNormalizedForDomains() throws {
    let narrowed = Rule(
        pattern: discord, match: .app, target: .direct, network: .udp)
    let decoded = try JSONCoding.decoder.decode(
        Rule.self, from: JSONCoding.prettyEncoder.encode(narrowed))
    #expect(decoded == narrowed)
    #expect(decoded.network == .udp)

    // Absent when both: the encoded form of an ordinary rule has no `network` key.
    let plain = Rule(pattern: discord, match: .app, tunnelID: Fixtures.workID)
    let text = String(decoding: try JSONCoding.prettyEncoder.encode(plain), as: UTF8.self)
    #expect(!text.contains("network"))

    // Domain kinds never carry one: initializer, mutation and a hand-edited file agree.
    #expect(Rule(pattern: "a.com", tunnelID: Fixtures.workID, network: .tcp).network == nil)
    var rule = Rule(pattern: "10.0.0.0/8", match: .ip, tunnelID: Fixtures.workID, network: .tcp)
    #expect(rule.network == .tcp)
    rule.match = .suffix
    #expect(rule.network == nil)
    rule.network = .udp
    #expect(rule.network == nil)

    let json = """
        {"id": "\(UUID().uuidString)", "pattern": "a.com", "match": "suffix",
         "tunnelID": "\(Fixtures.workID.uuidString)", "isEnabled": true, "network": "tcp"}
        """
    #expect(try JSONCoding.decoder.decode(Rule.self, from: Data(json.utf8)).network == nil)
}

@Test func storeSchemaThreeMigratesFromTwoAndRefusesFour() throws {
    let v2 = Data(
        "{\"schemaVersion\": 2, \"tunnels\": [], \"rules\": [], \"settings\": {}}".utf8)
    #expect(try StoreCodec.decode(v2).schemaVersion == 3)
    #expect(Store.currentSchemaVersion == 3)
    let v4 = Data("{\"schemaVersion\": 4, \"tunnels\": [], \"rules\": []}".utf8)
    #expect(throws: StoreCodec.Error.newerSchema(found: 4, supported: 3)) {
        try StoreCodec.decode(v4)
    }
    let store = Fixtures.store(rules: [
        Rule(pattern: discord, match: .app, target: .direct, network: .udp)
    ])
    #expect(try StoreCodec.decode(StoreCodec.encode(store)) == store)
    #expect(ExportDocument.currentVersion == 3)
}

@Test func validatorRanksNarrowedRules() {
    func issues(_ rules: [Rule]) -> [UUID: [RuleIssue]] {
        RuleValidator.validate(Fixtures.store(rules: rules))
    }
    func app(_ target: RuleTarget, _ network: RuleNetwork? = nil) -> Rule {
        Rule(pattern: discord, match: .app, target: target, network: network)
    }

    // `Discord → Direct` shadows `Discord, UDP → Work`.
    let direct = app(.direct)
    let udpWork = app(.tunnel(Fixtures.workID), .udp)
    #expect(issues([udpWork, direct])[udpWork.id] == [.shadowed(by: direct.id)])

    // `Discord, UDP → Direct` shadows nothing under Work: TCP still goes there.
    let udpDirect = app(.direct, .udp)
    let work = app(.tunnel(Fixtures.workID))
    #expect(issues([udpDirect, work])[work.id] == nil)

    // …but does shadow the same narrowed rule.
    let udpHome = app(.tunnel(Fixtures.homeID), .udp)
    #expect(issues([udpDirect, udpHome])[udpHome.id] == [.shadowed(by: udpDirect.id)])

    // `Discord, UDP → Work` next to `Discord → Work` is legal and not flagged.
    #expect(issues([work, udpWork]).isEmpty)

    // A narrowed rule of a later section beats a both-networks rule of an earlier one, so
    // the later both-networks rule is not shadowed by it, and the reverse is not either.
    let homeBoth = app(.tunnel(Fixtures.homeID))
    #expect(issues([work, homeBoth])[homeBoth.id] == [.shadowed(by: work.id)])
    let homeTCP = app(.tunnel(Fixtures.homeID), .tcp)
    #expect(issues([work, homeTCP])[homeTCP.id] == nil)
    #expect(issues([work, homeTCP])[work.id] == nil)

    // Same pattern + match + network + target is a duplicate; a different network is not.
    let first = app(.tunnel(Fixtures.workID), .tcp)
    let again = app(.tunnel(Fixtures.workID), .tcp)
    let other = app(.tunnel(Fixtures.workID), .udp)
    let result = issues([first, again, other])
    #expect(result[again.id] == [.duplicate(of: first.id)])
    #expect(result[other.id] == nil)
}

@Test func narrowedRulesGoToTheirOwnFilesOnly() throws {
    let tcpApp = Rule(
        pattern: "/Applications/Slack.app", match: .app, tunnelID: Fixtures.homeID,
        network: .tcp)
    let tcpIP = Rule(
        pattern: "203.0.113.0/24", match: .ip, tunnelID: Fixtures.homeID, network: .tcp)
    let both = Rule(pattern: discord, match: .app, tunnelID: Fixtures.homeID)
    let udpDirect = Rule(pattern: discord, match: .app, target: .direct, network: .udp)

    let files = RuleSetGenerator.generate(
        tunnels: [Fixtures.work, Fixtures.home],
        activeRules: [Fixtures.homeID: [tcpApp, tcpIP, both]], exceptions: [udpDirect])
    let home = "rules-t-\(Fixtures.homeID.uuidString.lowercased())"
    #expect(files["\(home)-tcp.json"] != nil)
    #expect(files["\(home)-udp.json"] == nil)
    #expect(files["rules-direct-udp.json"] != nil)
    #expect(files["rules-direct-tcp.json"] == nil)
    #expect(files.keys.filter { $0.hasSuffix("-tcp.json") || $0.hasSuffix("-udp.json") }.count == 2)

    let narrowed = try objects(files["\(home)-tcp.json"] ?? "")
    #expect(narrowed.count == 2)
    #expect(narrowed[0]["process_path_regex"] as? [String] == ["^/Applications/Slack\\.app/"])
    #expect(narrowed[1]["ip_cidr"] as? [String] == ["203.0.113.0/24"])

    // The ordinary files hold only the both-networks rules.
    let ordinary = try objects(files["\(home).json"] ?? "")
    #expect(ordinary.count == 1)
    #expect(ordinary[0]["process_path_regex"] as? [String] == ["^/Applications/Discord\\.app/"])
    #expect(try objects(files["\(home)-ip.json"] ?? "").isEmpty)
    let direct = try objects(files["rules-direct.json"] ?? "")
    #expect(direct.count == 1)  // built-in names only
    #expect(try objects(files["rules-direct-ip.json"] ?? "").isEmpty)

    // Nothing narrowed: no extra files at all.
    let none = RuleSetGenerator.generate(
        tunnels: [Fixtures.work], activeRules: [Fixtures.workID: [both]])
    #expect(none.keys.sorted().count == 4)
}

@Test func narrowedRoutingOrder() throws {
    let store = Fixtures.store(rules: [
        Rule(pattern: discord, match: .app, tunnelID: Fixtures.workID),
        Rule(pattern: discord, match: .app, target: .direct, network: .udp),
        Rule(pattern: "/Applications/Slack.app", match: .app, tunnelID: Fixtures.homeID, network: .tcp),
    ])
    let input = SingBoxConfigGenerator.Input(
        store: store, vlessUUIDs: [Fixtures.homeID: "00000000-0000-4000-8000-0000000000aa"],
        openVPNBinaryPath: "/x/openvpn")
    let output = SingBoxConfigGenerator.generate(input)
    let config = try #require(
        try JSONSerialization.jsonObject(with: Data(output.config.utf8)) as? [String: Any])
    let route = try #require(config["route"] as? [String: Any])
    let rules = try #require(route["rule_set"] as? [[String: Any]])
    let tags = rules.compactMap { $0["tag"] as? String }
    let home = "rules-t-\(Fixtures.homeID.uuidString.lowercased())"
    #expect(tags.contains("rules-direct-udp"))
    #expect(tags.contains("\(home)-tcp"))
    let routeRules = try #require(route["rules"] as? [[String: Any]])
    func index(of tag: String) -> Int? {
        routeRules.firstIndex { ($0["rule_set"] as? [String])?.contains(tag) == true }
    }
    let directUDP = try #require(index(of: "rules-direct-udp"))
    let homeTCP = try #require(index(of: "\(home)-tcp"))
    let workPlain = try #require(index(of: "rules-t-\(Fixtures.workID.uuidString.lowercased())"))
    #expect(try #require(index(of: "rules-direct")) < directUDP)
    #expect(directUDP < homeTCP)
    #expect(homeTCP < workPlain)
    #expect(routeRules[directUDP]["network"] as? [String] == ["udp"])
    #expect(routeRules[directUDP]["outbound"] as? String == "direct")
    #expect(routeRules[homeTCP]["network"] as? [String] == ["tcp"])
}

@Test func quickAddNeverTouchesNarrowedRules() {
    let narrowed = Rule(
        pattern: "203.0.113.0/24", match: .ip, tunnelID: Fixtures.workID, network: .tcp)
    let store = Fixtures.store(rules: [narrowed])
    let target = RuleTarget.tunnel(Fixtures.homeID)
    guard case .add(let rule) = QuickAdd.evaluate(input: "203.0.113.0/24", target: target, store: store)
    else {
        Issue.record("expected an add next to the narrowed rule")
        return
    }
    #expect(rule.network == nil)
    #expect(!QuickAdd.isUpdate(input: "203.0.113.0/24", store: store))
    #expect(QuickAdd.isUpdate(input: "203.0.113.0/24", store: store, network: .tcp))
    guard
        case .update(let updated) = QuickAdd.evaluate(
            input: "203.0.113.0/24", target: target, store: store, network: .tcp)
    else {
        Issue.record("expected an update of the narrowed rule")
        return
    }
    #expect(updated.id == narrowed.id)
    #expect(updated.network == .tcp)
}

@Test func controlMatchTreatsAppPathsAsAppRules() {
    #expect(RulePattern.inferControlMatch("/Applications/Discord.app") == .app)
    #expect(RulePattern.inferControlMatch("/Applications/Discord.APP") == .app)
    #expect(RulePattern.inferControlMatch("discord.com") == .suffix)
    #expect(RulePattern.inferControlMatch("10.0.0.0/8") == .ip)
    // The popover's inference never yields an app rule.
    #expect(RulePattern.inferMatch("/Applications/Discord.app") != .app)

    let rule = Rule(pattern: discord, match: .app, target: .direct, network: .udp)
    #expect(ControlRuleInfo(rule, via: "direct").network == .udp)
    let params = ControlParams(pattern: discord, via: "direct", network: .udp)
    #expect(
        (try? JSONDecoder().decode(ControlParams.self, from: JSONEncoder().encode(params)))?
            .network == .udp)
}

private func objects(_ text: String) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    return object?["rules"] as? [[String: Any]] ?? []
}
