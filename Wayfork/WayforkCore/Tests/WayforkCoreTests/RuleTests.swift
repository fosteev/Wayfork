import Foundation
import Testing

@testable import WayforkCore

@Test func punycodeMatchesReferenceVectors() {
    #expect(Punycode.encode("bücher") == "bcher-kva")
    #expect(Punycode.encode("münchen") == "mnchen-3ya")
    #expect(Punycode.encode("пример") == "e1afmkfd")
    #expect(Punycode.encode("рф") == "p1ai")
    #expect(Punycode.encode("日本語") == "wgv71a119e")
    #expect(Punycode.toASCII("ascii") == "ascii")
    #expect(Punycode.toASCII("пример") == "xn--e1afmkfd")
}

@Test func normalizeStripsURLPartsAndCase() throws {
    #expect(
        try RulePattern.normalize("HTTPS://User@Example.COM:443/path?q=1#x", match: .suffix)
            == "example.com")
    #expect(try RulePattern.normalize("  example.com.  ", match: .exact) == "example.com")
    #expect(try RulePattern.normalize("api.example.com:8443", match: .exact) == "api.example.com")
    #expect(try RulePattern.normalize("localhost", match: .exact) == "localhost")
}

@Test func normalizeConvertsIDNToPunycode() throws {
    #expect(try RulePattern.normalize("Пример.РФ", match: .suffix) == "xn--e1afmkfd.xn--p1ai")
    #expect(try RulePattern.normalize("*.пример.рф", match: .wildcard) == "*.xn--e1afmkfd.xn--p1ai")
}

@Test func normalizeRejectsInvalidInput() {
    #expect(throws: RulePatternError.empty) {
        try RulePattern.normalize("https://", match: .suffix)
    }
    #expect(throws: RulePatternError.wildcardNotAllowed) {
        try RulePattern.normalize("*.example.com", match: .suffix)
    }
    #expect(throws: RulePatternError.wildcardRequired) {
        try RulePattern.normalize("example.com", match: .wildcard)
    }
    #expect(throws: RulePatternError.invalidHostname("ex ample")) {
        try RulePattern.normalize("ex ample.com", match: .suffix)
    }
    #expect(throws: RulePatternError.invalidHostname("-bad")) {
        try RulePattern.normalize("-bad.example.com", match: .suffix)
    }
    #expect(throws: RulePatternError.invalidHostname("")) {
        try RulePattern.normalize("a..b", match: .suffix)
    }
    #expect(throws: RulePatternError.looksLikeIP) {
        try RulePattern.normalize("1.2.3.4", match: .exact)
    }
    #expect(throws: RulePatternError.tooLong) {
        try RulePattern.normalize(
            Array(repeating: "abcdefghij", count: 26).joined(separator: "."), match: .suffix)
    }
}

@Test func inferMatch() {
    #expect(RulePattern.inferMatch("example.com") == .suffix)
    #expect(RulePattern.inferMatch("*.example.com") == .wildcard)
}

@Test func matchingSemantics() {
    #expect(RulePattern.matches(host: "example.com", pattern: "example.com", match: .suffix))
    #expect(RulePattern.matches(host: "a.b.example.com", pattern: "example.com", match: .suffix))
    #expect(!RulePattern.matches(host: "notexample.com", pattern: "example.com", match: .suffix))

    #expect(RulePattern.matches(host: "api.example.com", pattern: "api.example.com", match: .exact))
    #expect(
        !RulePattern.matches(host: "v2.api.example.com", pattern: "api.example.com", match: .exact))

    #expect(
        RulePattern.matches(
            host: "a.cdn.example.com", pattern: "*.cdn.example.com", match: .wildcard))
    #expect(
        RulePattern.matches(
            host: "a.b.cdn.example.com", pattern: "*.cdn.example.com", match: .wildcard))
    #expect(
        !RulePattern.matches(
            host: "cdn.example.com", pattern: "*.cdn.example.com", match: .wildcard))
    #expect(RulePattern.wildcardRegex("*.cdn.example.com") == "^.+\\.cdn\\.example\\.com$")
}

@Test func validatorFlagsDuplicatesShadowsAndTunnelProblems() {
    let workRule = Rule(pattern: "example.com", tunnelID: Fixtures.workID)
    let shadowed = Rule(pattern: "example.com", tunnelID: Fixtures.homeID)
    let duplicate = Rule(pattern: "example.com", tunnelID: Fixtures.workID)
    let orphan = Rule(pattern: "x.com", tunnelID: UUID())
    let coversServer = Rule(pattern: "example.org", tunnelID: Fixtures.homeID)
    let differentMatch = Rule(pattern: "example.com", match: .exact, tunnelID: Fixtures.homeID)

    // Home comes after Work in store order even though its rules are listed first.
    let store = Fixtures.store(rules: [
        shadowed, workRule, duplicate, orphan, coversServer, differentMatch,
    ])
    let issues = RuleValidator.validate(store)

    #expect(issues[workRule.id] == nil)
    #expect(issues[shadowed.id] == [.shadowed(by: workRule.id)])
    #expect(issues[duplicate.id] == [.duplicate(of: workRule.id)])
    #expect(issues[orphan.id] == [.tunnelMissing])
    #expect(issues[coversServer.id] == [.coversTunnelServer(tunnelName: "Work")])
    #expect(issues[differentMatch.id] == nil)

    let active = RuleValidator.activeRules(store)
    #expect(active[Fixtures.workID]?.map(\.id) == [workRule.id])
    #expect(active[Fixtures.homeID]?.map(\.id) == [coversServer.id, differentMatch.id])
}

@Test func validatorTreatsDisabledTunnelRulesAsInert() {
    var store = Fixtures.store(rules: [
        Rule(pattern: "example.com", tunnelID: Fixtures.workID),
        Rule(pattern: "example.com", tunnelID: Fixtures.homeID),
    ])
    store.tunnels[0].isEnabled = false
    let issues = RuleValidator.validate(store)
    #expect(issues[store.rules[0].id] == [.tunnelDisabled])
    // The disabled tunnel's rule does not shadow; the Home rule is the first active one.
    #expect(issues[store.rules[1].id] == nil)
    #expect(RuleValidator.activeRules(store)[Fixtures.homeID]?.count == 1)
    #expect(RuleValidator.activeRules(store)[Fixtures.workID] == nil)
}

// MARK: - F8: exceptions and the default tunnel

@Test func validatorTreatsTheDirectGroupAsFirst() {
    let exception = Rule(pattern: "example.com", target: .direct)
    let duplicateException = Rule(pattern: "example.com", target: .direct)
    let workRule = Rule(pattern: "example.com", tunnelID: Fixtures.workID)
    let other = Rule(pattern: "other.com", tunnelID: Fixtures.workID)
    // An exception covering a tunnel's own server host is fine (it keeps it direct).
    let coversServer = Rule(pattern: "example.org", target: .direct)
    let store = Fixtures.store(rules: [
        workRule, exception, duplicateException, other, coversServer,
    ])
    let issues = RuleValidator.validate(store)
    #expect(issues[exception.id] == nil)
    #expect(issues[duplicateException.id] == [.duplicate(of: exception.id)])
    #expect(issues[workRule.id] == [.shadowed(by: exception.id)])
    #expect(issues[other.id] == nil)
    #expect(issues[coversServer.id] == nil)

    #expect(RuleValidator.activeExceptions(store).map(\.id) == [exception.id, coversServer.id])
    #expect(RuleValidator.activeRules(store)[Fixtures.workID]?.map(\.id) == [other.id])

    // A disabled exception neither shadows nor is emitted.
    var paused = store
    paused.rules[1].isEnabled = false
    paused.rules[2].isEnabled = false
    #expect(RuleValidator.validate(paused)[workRule.id] == nil)
    #expect(RuleValidator.activeExceptions(paused).map(\.id) == [coversServer.id])
}

@Test func defaultTunnelIssues() {
    var store = Fixtures.store()
    #expect(RuleValidator.defaultTunnelIssue(store) == nil)
    store.defaultTunnelID = Fixtures.workID
    #expect(RuleValidator.defaultTunnelIssue(store) == nil)
    #expect(
        RuleValidator.defaultTunnelIssue(store, missingSecrets: [Fixtures.workID])
            == .missingSecret)
    store.tunnels[0].isEnabled = false
    #expect(RuleValidator.defaultTunnelIssue(store) == .disabled)
    store.defaultTunnelID = UUID()
    #expect(RuleValidator.defaultTunnelIssue(store) == .missing)
}

// MARK: - F15

@Test func registrableDomainHeuristic() {
    #expect(RulePattern.registrableDomain(of: "news.example.com") == "example.com")
    #expect(RulePattern.registrableDomain(of: "a.b.c.example.org") == "example.org")
    #expect(RulePattern.registrableDomain(of: "example.com") == "example.com")
    #expect(RulePattern.registrableDomain(of: "Example.COM") == "example.com")
    #expect(RulePattern.registrableDomain(of: "www.example.co.uk") == "example.co.uk")
    #expect(RulePattern.registrableDomain(of: "a.example.com.au") == "example.com.au")
    #expect(RulePattern.registrableDomain(of: "cdn.static.co") == "static.co")
    #expect(RulePattern.registrableDomain(of: "intranet") == "intranet")
}

@Test func planRouteFinalReadsTheDefaultExit() {
    let direct = SingBoxPlan(config: #"{"route":{"final":"direct","rules":[]}}"#, ruleSets: [:])
    #expect(direct.routeFinal == "direct")
    let tunnel = SingBoxPlan(config: #"{"route":{"final":"t-abc"}}"#, ruleSets: [:])
    #expect(tunnel.routeFinal == "t-abc")
    #expect(SingBoxPlan(config: "not json", ruleSets: [:]).routeFinal == nil)
}

// MARK: - F16

@Test func groupRulesRoundTripAndOrderAfterTunnels() throws {
    var store = Fixtures.store(rules: [])
    let group = TunnelGroup(
        name: "Streaming", members: [Fixtures.homeID, Fixtures.workID], policy: .firstLive,
        createdAt: Fixtures.date)
    store.groups = [group]
    store.rules = [
        Rule(pattern: "video.example.com", target: .group(group.id)),
        Rule(pattern: "example.com", tunnelID: Fixtures.workID),
        Rule(pattern: "bank.example", target: .direct),
    ]
    // Direct, tunnels, then groups.
    #expect(
        store.effectiveRules.map(\.pattern) == ["bank.example", "example.com", "video.example.com"])
    let data = try StoreCodec.encode(store)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"groupID\""))
    #expect(json.contains("\"policy\" : \"firstLive\""))
    let decoded = try StoreCodec.decode(data)
    #expect(decoded == store)
    #expect(decoded.rules[0].target == .group(group.id))
    #expect(decoded.rules[0].exitID == group.id && decoded.rules[0].tunnelID == nil)
    #expect(store.exitName(id: group.id) == "Streaming")
    #expect(!store.isNameAvailable("streaming"))

    // The default may name a group; it needs an enabled member.
    store.defaultTunnelID = group.id
    #expect(store.effectiveDefaultExit == .group(group))
    #expect(store.effectiveDefaultTunnel == nil)
    store.tunnels[0].isEnabled = false
    store.tunnels[1].isEnabled = false
    #expect(store.effectiveDefaultExit == nil)
    let issues = RuleValidator.validate(store)
    #expect(issues[store.rules[0].id] == [.tunnelDisabled])
    #expect(RuleValidator.activeRules(store)[group.id] == nil)
    store.tunnels[0].isEnabled = true
    #expect(RuleValidator.activeRules(store)[group.id]?.count == 1)
    // A group rule shadowed by an earlier tunnel rule with the same pattern.
    store.rules.append(Rule(pattern: "example.com", target: .group(group.id)))
    #expect(RuleValidator.validate(store)[store.rules[3].id] == [.shadowed(by: store.rules[1].id)])
}
