import Foundation
import Testing

@testable import WayforkCore

/// Evaluates the generated matchers, including ordered references and transport conditions.
/// This is fixture evidence; the pinned engine separately validates the emitted syntax.
struct GeneratedRuleWitness {
    let root: [String: Any]
    let files: [String: [[String: Any]]]

    init(config: String, ruleSets: [String: String]) throws {
        root = try #require(
            try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        files = try ruleSets.reduce(into: [:]) { result, entry in
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(entry.value.utf8)) as? [String: Any])
            result[String(entry.key.dropLast(5))] = try #require(
                object["rules"] as? [[String: Any]])
        }
    }

    init(_ output: SingBoxConfigGenerator.Output) throws {
        try self.init(config: output.config, ruleSets: output.ruleSets)
    }

    func route(host: String = "", ip: String = "", app: String = "", network: String = "tcp")
        -> String
    {
        let section = root["route"] as? [String: Any] ?? [:]
        for rule in section["rules"] as? [[String: Any]] ?? [] {
            guard rule["outbound"] != nil || rule["action"] as? String == "reject" else { continue }
            if matches(rule, host: host, ip: ip, app: app, network: network) {
                return rule["outbound"] as? String ?? "reject"
            }
        }
        return section["final"] as? String ?? "unknown"
    }

    func dns(_ host: String, type: String = "A") -> String {
        let section = root["dns"] as? [String: Any] ?? [:]
        for rule in section["rules"] as? [[String: Any]] ?? [] {
            guard matches(rule, host: host, query: type) else { continue }
            if rule["rcode"] as? String == "NXDOMAIN" { return "NXDOMAIN" }
            return rule["server"] as? String ?? rule["action"] as? String ?? "unknown"
        }
        return section["final"] as? String ?? "unknown"
    }

    private func matches(
        _ rule: [String: Any], host: String, ip: String = "", app: String = "",
        network: String = "tcp", query: String = "A"
    ) -> Bool {
        func strings(_ key: String) -> [String] {
            if let array = rule[key] as? [String] { return array }
            return (rule[key] as? String).map { [$0] } ?? []
        }
        func regex(_ pattern: String, _ value: String) -> Bool {
            guard !value.isEmpty, let expression = try? NSRegularExpression(pattern: pattern) else {
                return false
            }
            return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
                != nil
        }
        var result: Bool
        if let nested = rule["rules"] as? [[String: Any]], rule["type"] as? String == "logical" {
            let values = nested.map {
                matches($0, host: host, ip: ip, app: app, network: network, query: query)
            }
            result =
                rule["mode"] as? String == "and" ? values.allSatisfy { $0 } : values.contains(true)
        } else {
            var matchers: [Bool] = []
            if rule["rule_set"] != nil {
                matchers.append(
                    strings("rule_set").contains { tag in
                        if tag == "block-ads" {
                            return ["ads.example", "example.com", "cdn.example.net"].contains(host)
                        }
                        return (files[tag] ?? []).contains {
                            matches(
                                $0, host: host, ip: ip, app: app, network: network, query: query)
                        }
                    })
            }
            if rule["domain"] != nil { matchers.append(strings("domain").contains(host)) }
            if rule["domain_suffix"] != nil {
                matchers.append(
                    !host.isEmpty && strings("domain_suffix").contains { host.hasSuffix($0) })
            }
            if rule["domain_regex"] != nil {
                matchers.append(strings("domain_regex").contains { regex($0, host) })
            }
            if rule["process_path"] != nil {
                matchers.append(!app.isEmpty && strings("process_path").contains(app))
            }
            if rule["process_path_regex"] != nil {
                matchers.append(strings("process_path_regex").contains { regex($0, app) })
            }
            if rule["ip_cidr"] != nil {
                matchers.append(
                    IPv4Prefix(ip).map { address in
                        strings("ip_cidr").contains { IPv4Prefix($0)?.contains(address) == true }
                    } ?? false)
            }
            if rule["ip_is_private"] as? Bool == true {
                matchers.append(
                    IPv4Prefix(ip).map { address in
                        ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].contains {
                            IPv4Prefix($0)?.contains(address) == true
                        }
                    } ?? false)
            }
            result = matchers.isEmpty || matchers.contains(true)
        }
        if rule["network"] != nil { result = result && strings("network").contains(network) }
        if rule["query_type"] != nil { result = result && strings("query_type").contains(query) }
        return rule["invert"] as? Bool == true ? !result : result
    }
}

private let workTarget = RuleTarget.tunnel(Fixtures.workID)
private let homeTarget = RuleTarget.tunnel(Fixtures.homeID)
private let workTag = Fixtures.work.outboundTag
private let homeTag = Fixtures.home.outboundTag

private func listStore(_ lists: [RuleList], _ rows: [Rule]) -> Store {
    Store(tunnels: [Fixtures.work, Fixtures.home], rules: rows, lists: lists)
}

private func listOutput(_ store: Store, secrets: Bool = true, block: Bool = false)
    -> SingBoxConfigGenerator.Output
{
    SingBoxConfigGenerator.generate(
        .init(
            store: store,
            vlessUUIDs: secrets ? [Fixtures.homeID: "00000000-0000-4000-8000-0000000000aa"] : [:],
            openVPNBinaryPath: "/x/openvpn", blockListPath: block ? "/x/block-ads.srs" : nil))
}

@Test func listOrderAndRowOrderAreActualRoutingPrecedence() throws {
    let first = RuleList(name: "First", target: .exit(workTarget))
    let middle = RuleList(name: "Middle", target: .exit(homeTarget))
    let last = RuleList(name: "Last", target: .exit(workTarget))
    let a = Rule(pattern: "first.example", listID: first.id)
    let b = Rule(pattern: "example.com", listID: middle.id)
    let c = Rule(pattern: "api.example.com", match: .exact, listID: last.id)
    var store = listStore([first, middle, last], [a, b, c])
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "api.example.com") == homeTag)
    try store.reorderList(last.id, to: 0)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "api.example.com") == workTag)
    store.tunnels.reverse()
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "api.example.com") == workTag)
    // Exact and suffix rows retain their own position even when they share an exit.
    let domain = Rule(pattern: "example.com", listID: first.id)
    let exact = Rule(
        pattern: "api.example.com", match: .exact, target: homeTarget, listID: first.id)
    store = listStore([first], [domain, exact])
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "api.example.com") == workTag)
    try store.moveRule(exact.id, to: first.id, position: 0)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "api.example.com") == homeTag)
}

@Test func transportAndMixedMatchersStayAtTheirRowPosition() throws {
    let first = RuleList(name: "First", target: .exit(workTarget))
    let second = RuleList(name: "Second", target: .exit(homeTarget))
    let broad = Rule(pattern: "/Applications/Chat.app", match: .app, listID: first.id)
    let udp = Rule(pattern: broad.pattern, match: .app, listID: second.id, network: .udp)
    var store = listStore([first, second], [broad, udp])
    let app = "/Applications/Chat.app/Contents/MacOS/Chat"
    #expect(try GeneratedRuleWitness(listOutput(store)).route(app: app, network: "udp") == workTag)
    try store.reorderList(second.id, to: 0)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(app: app, network: "udp") == homeTag)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(app: app, network: "tcp") == workTag)
    // Same-list narrowing is also positional; a partial overlap must not suppress broad TCP.
    var sibling = udp
    sibling.listID = first.id
    sibling.target = homeTarget
    store = listStore([first], [sibling, broad])
    #expect(RuleValidator.validate(store)[broad.id] == nil)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(app: app, network: "udp") == homeTag)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(app: app, network: "tcp") == workTag)
    let domain = Rule(pattern: "example.com", listID: second.id)
    store = listStore([first, second], [broad, domain])
    #expect(
        try GeneratedRuleWitness(listOutput(store)).route(host: "example.com", app: app) == workTag)
    try store.reorderList(second.id, to: 0)
    #expect(
        try GeneratedRuleWitness(listOutput(store)).route(host: "example.com", app: app) == homeTag)
    let wide = Rule(pattern: "203.0.113.0/24", match: .ip, listID: first.id)
    let narrow = Rule(pattern: "203.0.113.42", match: .ip, listID: second.id)
    store = listStore([first, second], [wide, narrow])
    #expect(try GeneratedRuleWitness(listOutput(store)).route(ip: "203.0.113.42") == workTag)
    try store.reorderList(second.id, to: 0)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(ip: "203.0.113.42") == homeTag)
}

@Test func pinsFollowDefaultAndPauseHaveDistinctRoutingAndDNS() throws {
    let follow = RuleList(name: "Follow", target: .everythingElse, showInMenu: false)
    let lower = RuleList(name: "Lower", target: .exit(homeTarget))
    let row = Rule(pattern: "example.com", listID: follow.id)
    let lowerRow = Rule(pattern: "api.example.com", match: .exact, listID: lower.id)
    var store = listStore([follow, lower], [row, lowerRow])
    var witness = try GeneratedRuleWitness(listOutput(store))
    #expect(witness.route(host: "api.example.com") == "direct")
    #expect(witness.dns("api.example.com") == "dns-direct")
    #expect(witness.dns("api.example.com", type: "TXT") == "dns-direct")
    store.defaultTunnelID = Fixtures.workID
    witness = try GeneratedRuleWitness(listOutput(store))
    #expect(witness.route(host: "api.example.com") == workTag)
    #expect(witness.dns("api.example.com") == "fakeip")
    #expect(witness.dns("api.example.com", type: "TXT") == "dns-" + workTag)
    try store.updateList(follow.id) { $0.isEnabled = false }
    witness = try GeneratedRuleWitness(listOutput(store))
    #expect(witness.route(host: "api.example.com") == homeTag)
    // Direct pins elevate while enabled, but pausing removes pins too.
    try store.pinRule(row.id, to: .direct)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "api.example.com") == homeTag)
    try store.updateList(follow.id) { $0.isEnabled = true }
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "api.example.com") == "direct")
    // A tunnel pin in a Direct list belongs after blocking.
    try store.updateList(follow.id) { $0.target = .exit(.direct) }
    try store.pinRule(row.id, to: workTarget)
    store.settings.blockList = .init(isEnabled: true)
    #expect(
        try GeneratedRuleWitness(listOutput(store, block: true)).route(host: "example.com")
            == "reject")
    try store.pinRule(row.id, to: nil)
    #expect(
        try GeneratedRuleWitness(listOutput(store, block: true)).route(host: "example.com")
            == "direct")
}

@Test func orderedDNSUsesOnlyDomainRowsAndProtectsBootstrapAndLocalNames() throws {
    let first = RuleList(name: "First", target: .exit(workTarget))
    let follow = RuleList(name: "Follow", target: .everythingElse)
    var store = listStore(
        [first, follow],
        [
            Rule(pattern: "example.com", listID: first.id),
            Rule(pattern: "api.example.com", match: .exact, listID: follow.id),
            Rule(pattern: "/Applications/Chat.app", match: .app, listID: first.id, network: .udp),
            Rule(pattern: "203.0.113.0/24", match: .ip, listID: first.id, network: .tcp),
            Rule(pattern: "local", listID: first.id),
            Rule(pattern: "vpn.example.org", listID: first.id),
        ])
    let output = listOutput(store)
    let witness = try GeneratedRuleWitness(output)
    for type in ["A", "AAAA"] { #expect(witness.dns("api.example.com", type: type) == "fakeip") }
    #expect(witness.dns("api.example.com", type: "TXT") == "dns-direct")
    #expect(witness.dns("printer.local") == "dns-direct")
    #expect(witness.dns("vpn.example.org") == "dns-direct")
    #expect(witness.dns(SingBoxConfigGenerator.resolverProbeName) == "predefined")
    #expect(witness.dns(SingBoxConfigGenerator.ddrDiscoveryName) == "reject")
    let dns = try #require(witness.root["dns"] as? [String: Any])
    let rules = try #require(dns["rules"] as? [[String: Any]])
    let forbidden = Set(["ip_cidr", "process_path", "process_path_regex", "network"])
    #expect(rules.allSatisfy { forbidden.isDisjoint(with: $0.keys) })
    let nonDomainTags = Set(
        store.rules.filter { $0.isApp || $0.isIP }.map {
            "rules-r-" + $0.id.uuidString.lowercased()
        })
    #expect(
        rules.allSatisfy { rule in
            (rule["rule_set"] as? String).map { !nonDomainTags.contains($0) } ?? true
        })
    store.settings.blockList = .init(isEnabled: true, exceptions: ["example.com"])
    #expect(try GeneratedRuleWitness(listOutput(store, block: true)).dns("example.com") == "fakeip")
    #expect(
        try GeneratedRuleWitness(listOutput(store, block: true)).dns("ads.example") == "NXDOMAIN")
}

@Test func unavailableTargetsFallThroughButPinsAndDefaultGroupsRemainDynamic() throws {
    let home = RuleList(name: "Home", target: .exit(homeTarget))
    let work = RuleList(name: "Work", target: .exit(workTarget))
    let a = Rule(pattern: "example.com", listID: home.id)
    let b = Rule(pattern: "example.com", listID: work.id)
    var store = listStore([home, work], [a, b])
    #expect(
        try GeneratedRuleWitness(listOutput(store, secrets: false)).route(host: "example.com")
            == workTag)
    store.tunnels[1].isEnabled = false
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "example.com") == workTag)
    store.tunnels.removeLast()
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "example.com") == workTag)
    try store.pinRule(a.id, to: .direct)
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "example.com") == "direct")
    try store.pinRule(a.id, to: nil)
    try store.updateList(home.id) { $0.target = .everythingElse }
    let group = TunnelGroup(
        name: "Group", members: [Fixtures.workID, Fixtures.homeID], createdAt: Fixtures.date)
    store.groups = [group]
    store.defaultTunnelID = group.id
    #expect(
        try GeneratedRuleWitness(listOutput(store)).route(host: "example.com") == group.outboundTag)
    store.groups[0].members = [Fixtures.homeID]
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: "example.com") == "direct")
}

@Test func membershipOperationsAreAtomicAndPreservePins() throws {
    let a = RuleList(name: "A", target: .exit(workTarget))
    let b = RuleList(name: "B", target: .everythingElse)
    let row = Rule(pattern: "example.com", target: .direct, listID: a.id)
    var store = listStore([a, b], [row])
    try store.moveRule(row.id, to: b.id)
    #expect(store.rules[0].target == .direct)
    try store.pinRule(row.id, to: nil)
    #expect(store.target(for: store.rules[0]) == .direct)
    let original = store
    #expect(throws: ListValidationError.invalidName) {
        try store.updateList(a.id) { $0.name = "B" }
    }
    #expect(store == original)
    try store.createList(.init(name: "New", target: .exit(.direct)))
    #expect(store.lists.first?.name == "New")
    try store.deleteList(b.id)
    #expect(store.rules.isEmpty)
    var bad = original
    bad.rules[0].listID = UUID()
    #expect(throws: ListValidationError.orphanRule) { try StoreCodec.encode(bad) }
    bad = original
    bad.rules.append(bad.rules[0])
    #expect(throws: ListValidationError.duplicateRuleID) { try StoreCodec.encode(bad) }
    let encoded = try StoreCodec.encode(original)
    #expect(try StoreCodec.decode(encoded) == original)
}

@Test func listValidationUsesActiveMembershipAndNamesTheWinningRow() throws {
    let a = RuleList(name: "A", target: .exit(workTarget))
    let b = RuleList(name: "B", target: .exit(homeTarget))
    let off = Rule(pattern: "example.com", listID: a.id, isEnabled: false)
    let first = Rule(pattern: "example.com", listID: a.id)
    let duplicate = Rule(pattern: "example.com", target: homeTarget, listID: a.id)
    let shadowed = Rule(pattern: "example.com", listID: b.id)
    var store = listStore([a, b], [off, first, duplicate, shadowed])
    let issues = RuleValidator.validate(store)
    #expect(issues[off.id] == nil)
    #expect(issues[first.id] == nil)
    #expect(issues[duplicate.id] == [.duplicate(of: first.id)])
    #expect(issues[shadowed.id] == [.shadowed(by: first.id)])
    try store.updateList(a.id) { $0.isEnabled = false }
    #expect(RuleValidator.validate(store)[shadowed.id] == nil)
    #expect(RuleValidator.resolvedRules(store).map(\.rule.id) == [shadowed.id])
}

@Test func legacyMigrationPreservesActualRuntimePrecedenceAndSuppression() throws {
    let patterns: [(RuleTarget, RuleNetwork?, String)] = [
        (workTarget, nil, "/Applications/Discord.app"),
        (homeTarget, .udp, "/Applications/Discord.app"),
        (homeTarget, nil, "/Applications/Chat.app"),
        (workTarget, .tcp, "/Applications/Chat.app"),
    ]
    var source = Store(tunnels: [Fixtures.work, Fixtures.home], rules: [], lists: [])
    source.schemaVersion = 3
    source.rules = patterns.map { target, network, pattern in
        Rule(pattern: pattern, match: .app, target: target, network: network)
    }
    let disabledFirst = Rule(
        pattern: "duplicate.example", target: workTarget, isEnabled: false, note: "keep me")
    let duplicate = Rule(
        pattern: disabledFirst.pattern, target: workTarget,
        note: "enabled but previously suppressed")
    let unavailable = Rule(pattern: "secret.example", target: workTarget)
    let fallback = Rule(pattern: unavailable.pattern, target: homeTarget)
    source.rules += [disabledFirst, duplicate, unavailable, fallback]
    var raw = try #require(
        try JSONSerialization.jsonObject(with: JSONCoding.prettyEncoder.encode(source))
            as? [String: Any])
    raw.removeValue(forKey: "lists")
    let data = try JSONSerialization.data(withJSONObject: raw)
    let migrated = try StoreCodec.decode(data)
    #expect(try StoreCodec.decode(data) == migrated)
    #expect(migrated.rules.count == source.rules.count)
    #expect(migrated.rules.allSatisfy { $0.target == nil })
    let archives = migrated.lists.filter { !$0.isEnabled }
    #expect(archives.count == 1)
    #expect(archives[0].id == duplicate.id)
    #expect(archives[0].showInMenu == false)
    #expect(migrated.rules(in: archives[0].id).map(\.id) == [duplicate.id])
    #expect(
        migrated.list(id: try #require(migrated.rules.first { $0.id == fallback.id }?.listID))?
            .isEnabled == true)
    for old in source.rules {
        var row = try #require(migrated.rules.first { $0.id == old.id })
        row.listID = nil
        row.target = old.target
        #expect(row == old)
    }
    let full = PlanSecrets(
        vlessUUIDs: [Fixtures.homeID: "00000000-0000-4000-8000-0000000000aa"],
        openVPNConfigs: [Fixtures.workID: "client\nremote vpn.example.org 1194\n"])
    var withoutWork = full
    withoutWork.openVPNConfigs = [:]
    var withoutHome = full
    withoutHome.vlessUUIDs = [:]
    for secrets in [full, withoutWork, withoutHome, PlanSecrets()] {
        for defaultID: UUID? in [nil, Fixtures.workID, Fixtures.homeID] {
            var old = source
            old.defaultTunnelID = defaultID
            var new = migrated
            new.defaultTunnelID = defaultID
            let before = FrozenF23RuntimeBuilder.build(
                store: old, secrets: secrets, bundlePath: "/Applications/Wayfork.app"
            ).plan.singBox
            let after = RuntimePlanBuilder.build(
                store: new, secrets: secrets, bundlePath: "/Applications/Wayfork.app"
            ).plan.singBox
            let lhs = try GeneratedRuleWitness(config: before.config, ruleSets: before.ruleSets)
            let rhs = try GeneratedRuleWitness(config: after.config, ruleSets: after.ruleSets)
            for app in ["Discord", "Chat"] {
                for network in ["tcp", "udp"] {
                    let process = "/Applications/\(app).app/Contents/MacOS/\(app)"
                    #expect(
                        lhs.route(app: process, network: network)
                            == rhs.route(app: process, network: network))
                }
            }
            for host in [
                "duplicate.example", "secret.example", "unmatched.example", "vpn.example.org",
                "printer.local",
            ] {
                #expect(lhs.route(host: host) == rhs.route(host: host))
                for type in ["A", "AAAA", "TXT"] {
                    #expect(lhs.dns(host, type: type) == rhs.dns(host, type: type))
                }
            }
        }
    }
    // The archived enabled duplicate stays inert until the user explicitly reviews/enables it.
    var enabled = migrated
    #expect(
        try GeneratedRuleWitness(listOutput(enabled)).route(host: duplicate.pattern) == "direct")
    try enabled.updateList(archives[0].id) { $0.isEnabled = true }
    #expect(try GeneratedRuleWitness(listOutput(enabled)).route(host: duplicate.pattern) == workTag)
}

@Test func frozenSchemaOneTwoThreeGoldensPreserveRouteAndDNSOutcomes() throws {
    let root = Fixtures.url("legacy-f23/singbox")
    let cases = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    #expect(cases.count >= 20)
    for name in cases {
        let directory = root.appendingPathComponent(name)
        let inputData = try Data(contentsOf: directory.appendingPathComponent("input.json"))
        let input = try #require(
            try JSONSerialization.jsonObject(with: inputData) as? [String: Any])
        let original = try #require(input["store"] as? [String: Any])
        let config = try String(
            contentsOf: directory.appendingPathComponent("sing-box.json"), encoding: .utf8)
        var files: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where file != "input.json" && file != "sing-box.json" {
            files[file] = try String(
                contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
        }
        let before = try GeneratedRuleWitness(config: config, ruleSets: files)
        func uuids(_ key: String) -> [UUID: String] {
            (input[key] as? [String: String] ?? [:]).reduce(into: [:]) { result, item in
                if let id = UUID(uuidString: item.key) { result[id] = item.value }
            }
        }
        var keys: [UUID: WireGuardSecrets] = [:]
        if let values = input["wireGuardKeys"] as? [String: Any] {
            for (id, value) in values {
                if let id = UUID(uuidString: id) {
                    keys[id] = try JSONCoding.decoder.decode(
                        WireGuardSecrets.self, from: JSONSerialization.data(withJSONObject: value))
                }
            }
        }
        for version in [1, 2, 3] {
            var object = original
            object["schemaVersion"] = version
            let store = try StoreCodec.decode(JSONSerialization.data(withJSONObject: object))
            let after = try GeneratedRuleWitness(
                SingBoxConfigGenerator.generate(
                    .init(
                        store: store,
                        vlessUUIDs: uuids("vlessUUIDs"), wireGuardKeys: keys,
                        passwords: uuids("passwords"),
                        vmessUUIDs: uuids("vmessUUIDs"),
                        openVPNBinaryPath: input["openVPNBinaryPath"] as? String ?? "/x/openvpn",
                        resolvedServerAddresses: input["resolvedServerAddresses"]
                            as? [String: [String]] ?? [:],
                        systemDNSServers: input["systemDNSServers"] as? [String] ?? [],
                        networkResolvers: input["networkResolvers"] as? [String] ?? [],
                        blockListPath: input["blockListPath"] as? String)))
            var hosts = [
                "example.com", "api.example.com", "api.other.com", "a.cdn.example.com",
                "unmatched.example", "vpn.example.org", "printer.local", "ads.example",
                "cdn.example.net",
            ]
            hosts += store.rules.filter { !$0.isApp && !$0.isIP }.map {
                $0.pattern.replacingOccurrences(of: "*", with: "www")
            }
            for host in hosts {
                #expect(
                    before.route(host: host) == after.route(host: host),
                    "\(name), schema \(version), \(host)")
                for type in ["A", "AAAA", "TXT"] {
                    #expect(
                        before.dns(host, type: type) == after.dns(host, type: type),
                        "\(name), schema \(version), \(host), \(type)")
                }
            }
            for app in store.rules.filter(\.isApp).map(\.pattern) {
                for network in ["tcp", "udp"] {
                    #expect(
                        before.route(app: app + "/Contents/MacOS/App", network: network)
                            == after.route(app: app + "/Contents/MacOS/App", network: network))
                }
            }
            for ip in ["203.0.113.7", "203.0.113.42", "198.51.100.42", "10.8.0.7", "192.168.50.7"] {
                for network in ["tcp", "udp"] {
                    #expect(
                        before.route(ip: ip, network: network)
                            == after.route(ip: ip, network: network))
                }
            }
        }
    }
}

@Test func exportFourPreservesInheritancePinsAndMergeIdentity() throws {
    let list = RuleList(
        name: "Shared", color: 2, target: .everythingElse, isEnabled: false, showInMenu: false)
    let inherited = Rule(pattern: "example.com", listID: list.id)
    let pinned = Rule(pattern: "bank.example", target: .direct, listID: list.id, note: "pin")
    let store = listStore([list], [inherited, pinned])
    let document = try StoreExporter.document(
        store: store, secretStore: InMemorySecretStore(), includeSecrets: false,
        exportedAt: Fixtures.date)
    let roundtrip = try ExportDocument.decode(document.encode())
    #expect(roundtrip.lists == store.lists)
    #expect(roundtrip.rules == store.rules)
    let replaced = StoreImporter.apply(roundtrip, to: .empty, mode: .replace)
    #expect(replaced.store.lists == store.lists)
    #expect(replaced.store.rules == store.rules)
    #expect(replaced.store.rules[0].target == nil)
    // Same ID with different list binding is copied/remapped, never overwrites live routing.
    var changed = store
    changed.lists[0].target = .exit(workTarget)
    changed.lists[0].isEnabled = true
    changed.rules[0].pattern = "changed.example"
    let incoming = try StoreExporter.document(
        store: changed, secretStore: InMemorySecretStore(), includeSecrets: false,
        exportedAt: Fixtures.date)
    let merged = StoreImporter.apply(incoming, to: store, mode: .merge)
    #expect(merged.store.lists.count == 2)
    #expect(merged.store.lists[0] == list)
    #expect(merged.store.lists[1].id != list.id)
    #expect(merged.store.lists[1].name == "Shared (2)")
    #expect(merged.store.rules.count == 4)
    #expect(merged.store.rules[0] == inherited)
    #expect(merged.store.rules[2].id != inherited.id)
    #expect(merged.store.rules[2].listID == merged.store.lists[1].id)
    let repeated = StoreImporter.apply(incoming, to: merged.store, mode: .merge)
    #expect(repeated.store == merged.store)
    #expect(repeated.rulesAdded == 0)
    // Name collisions without identity collisions keep distinct routing lists.
    var sameName = incoming
    sameName.lists[0].id = UUID()
    for i in sameName.rules.indices { sameName.rules[i].listID = sameName.lists[0].id }
    let distinct = StoreImporter.apply(sameName, to: store, mode: .merge)
    #expect(distinct.store.lists.count == 2)
    #expect(distinct.store.lists[1].id == sameName.lists[0].id)
}

@Test func exitDeletionKeepsShellsAndOtherPins() throws {
    let list = RuleList(name: "Work list", target: .exit(workTarget))
    let inherited = Rule(pattern: "inherited.example", listID: list.id)
    let pinned = Rule(pattern: "pinned.example", target: homeTarget, listID: list.id)
    let samePin = Rule(pattern: "same.example", target: workTarget, listID: list.id)
    var store = listStore([list], [inherited, pinned, samePin])
    store.removeRules(boundTo: workTarget)
    store.tunnels.removeAll { $0.id == Fixtures.workID }
    #expect(store.lists == [list])
    #expect(store.rules == [pinned])
    #expect(try GeneratedRuleWitness(listOutput(store)).route(host: pinned.pattern) == homeTag)
}

@Test func listCreationControlBatchIsAtomicAndRollbackKeepsNewerGUIWork() throws {
    let list = RuleList(name: "New", target: .everythingElse)
    let row = Rule(pattern: "example.com", listID: list.id)
    let edit = StoreEdit.batch([.insertList(list), .insertRule(row, before: nil)])
    var store = Store.empty
    #expect(edit.apply(to: &store) == nil)
    let pending = PendingControlChange(
        edit: edit, description: "new list rule", deadline: Fixtures.date)
    let decoded = try JSONCoding.decoder.decode(
        PendingControlChange.self, from: JSONCoding.prettyEncoder.encode(pending))
    #expect(decoded == pending)
    #expect(decoded.edit.inverse.apply(to: &store) == nil)
    #expect(store == .empty)
    #expect(edit.apply(to: &store) == nil)
    let gui = Rule(pattern: "gui.example", target: .direct, listID: list.id)
    store.rules.append(gui)
    #expect(edit.inverse.apply(to: &store) == nil)
    #expect(store.rules == [gui])
    #expect(store.lists == [list])
    let before = store
    let invalid = StoreEdit.batch([
        .setLogLevel(from: store.settings.logLevel, to: .debug),
        .insertRule(Rule(pattern: "orphan.example", listID: UUID()), before: nil),
    ])
    #expect(invalid.apply(to: &store) != nil)
    #expect(store == before)
}

@Test func secretAwareValidationUsesTheSameAvailableExitProjection() {
    let home = RuleList(name: "Home", target: .exit(homeTarget))
    let work = RuleList(name: "Work", target: .exit(workTarget))
    let a = Rule(pattern: "example.com", listID: home.id)
    let b = Rule(pattern: "example.com", listID: work.id)
    let store = listStore([home, work], [a, b])
    let available = RuleValidator.availableExitIDs(store, missingSecrets: [Fixtures.homeID])
    let issues = RuleValidator.validate(store, routedExitIDs: available)
    #expect(issues[a.id] == [.missingSecret])
    #expect(issues[b.id] == nil)
    #expect(RuleValidator.resolvedRules(store, routedExitIDs: available).map(\.rule.id) == [b.id])
}

@Test func fullReplaceRetainsDuplicateSourceRowsAndConflictingBindingsAreRejected() throws {
    let list = RuleList(name: "A", target: .everythingElse)
    let one = Rule(pattern: "example.com", listID: list.id)
    let two = Rule(pattern: "example.com", listID: list.id)
    let store = listStore([list], [one, two])
    let document = try StoreExporter.document(
        store: store, secretStore: InMemorySecretStore(), includeSecrets: false)
    let outcome = StoreImporter.apply(document, to: .empty, mode: .replace)
    #expect(outcome.store.rules == [one, two])
    var object = try #require(
        try JSONSerialization.jsonObject(with: StoreCodec.encode(store)) as? [String: Any])
    var rows = try #require(object["rules"] as? [[String: Any]])
    rows[0]["target"] = "everythingElse"
    object["rules"] = rows
    #expect(throws: Error.self) {
        try StoreCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
    rows[0]["target"] = "direct"
    rows[0]["tunnelID"] = Fixtures.workID.uuidString
    object["rules"] = rows
    #expect(throws: StoreCodec.Error.invalidDocument) {
        try StoreCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
    rows[0].removeValue(forKey: "tunnelID")
    rows[0]["target"] = NSNull()
    object["rules"] = rows
    #expect(throws: StoreCodec.Error.invalidDocument) {
        try StoreCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
}

@Test func repeatedImportReusesOnlyTheExpectedDisambiguatedListName() throws {
    let existing = RuleList(name: "Sites", target: .exit(workTarget))
    let incoming = RuleList(name: "Sites", target: .exit(homeTarget))
    let row = Rule(pattern: "example.com", listID: incoming.id)
    let source = listStore([incoming], [row])
    let document = try StoreExporter.document(
        store: source, secretStore: InMemorySecretStore(), includeSecrets: false,
        exportedAt: Fixtures.date)
    let destination = listStore([existing], [])

    let first = StoreImporter.apply(document, to: destination, mode: .merge)
    #expect(first.store.lists.map(\.id) == [existing.id, incoming.id])
    #expect(first.store.lists.map(\.name) == ["Sites", "Sites (2)"])
    #expect(first.store.rules == [row])
    let second = StoreImporter.apply(document, to: first.store, mode: .merge)
    #expect(second.store == first.store)
    #expect(second.rulesAdded == 0)

    var renamed = first.store
    try renamed.updateList(incoming.id) { $0.name = "Custom sites" }
    let afterRename = StoreImporter.apply(document, to: renamed, mode: .merge)
    #expect(afterRename.store.lists.count == 3)
    #expect(afterRename.store.list(id: incoming.id)?.name == "Custom sites")
    let imported = try #require(afterRename.store.lists.last)
    #expect(imported.id != incoming.id)
    #expect(imported.name == "Sites (2)")
    #expect(afterRename.store.rules.count == 2)
    #expect(afterRename.store.rules.last?.listID == imported.id)
}
