import Foundation
import Testing

@testable import WayforkCore

// F10: application rules (docs/design/01-data-model.md, 03-routing.md).

@Test func appRulesNormalizeBundlePaths() throws {
    #expect(
        try RulePattern.normalize(" /Applications/Telegram.app/ ", match: .app)
            == "/Applications/Telegram.app")
    #expect(
        try RulePattern.normalize("file:///Applications/Foo%20Bar.app", match: .app)
            == "/Applications/Foo Bar.app")
    // Case is kept: paths are case-preserving.
    #expect(
        try RulePattern.normalize("/Users/me/Apps/Beta.APP", match: .app)
            == "/Users/me/Apps/Beta.APP")
    #expect(throws: RulePatternError.empty) { try RulePattern.normalize("  ", match: .app) }
    for bad in ["Telegram.app", "/Applications/Telegram", "/Applications/../x.app", ".app"] {
        #expect(throws: RulePatternError.notAnAppBundle, "\(bad)") {
            try RulePattern.normalize(bad, match: .app)
        }
    }
    // A path is not a hostname (URL-part stripping leaves nothing) and a hostname is not
    // a path.
    #expect(throws: RulePatternError.empty) {
        try RulePattern.normalize("/Applications/Telegram.app", match: .suffix)
    }
    #expect(throws: RulePatternError.notAnAppBundle) {
        try RulePattern.normalize("telegram.org", match: .app)
    }
}

@Test func appRulesMatchProcessesNotHosts() throws {
    #expect(
        !RulePattern.matches(
            host: "telegram.org", pattern: "/Applications/Telegram.app", match: .app))
    let regex = RulePattern.appPathRegex("/Applications/Foo (Beta).app")
    #expect(regex == "^/Applications/Foo \\(Beta\\)\\.app/")
    let compiled = try Regex(regex)
    #expect("/Applications/Foo (Beta).app/Contents/MacOS/Foo".firstMatch(of: compiled) != nil)
    #expect(
        "/Applications/Foo (Beta).app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
            .firstMatch(of: compiled) != nil)
    #expect("/Applications/Foo (Beta).app 2/Contents/MacOS/Foo".firstMatch(of: compiled) == nil)
    #expect("/Applications/Foo (Beta)_app/Contents/MacOS/Foo".firstMatch(of: compiled) == nil)
    #expect(RulePattern.appName("/Applications/Foo Bar.app") == "Foo Bar")
    #expect(RulePattern.appName("/x/y") == "y")
}

@Test func validatorTreatsAppRulesLikeDomains() {
    let telegram = "/Applications/Telegram.app"
    let first = Rule(pattern: telegram, match: .app, tunnelID: Fixtures.workID)
    let duplicate = Rule(pattern: telegram, match: .app, tunnelID: Fixtures.workID)
    let shadowed = Rule(pattern: telegram, match: .app, tunnelID: Fixtures.homeID)
    // A bundle whose name looks like a tunnel's server host never "covers" that server.
    let lookalike = Rule(
        pattern: "/Applications/vpn.example.org.app", match: .app, tunnelID: Fixtures.homeID)
    let store = Fixtures.store(rules: [first, duplicate, shadowed, lookalike])
    let issues = RuleValidator.validate(store)
    #expect(issues[first.id] == nil)
    #expect(issues[duplicate.id] == [.duplicate(of: first.id)])
    #expect(issues[shadowed.id] == [.shadowed(by: first.id)])
    #expect(issues[lookalike.id] == nil)
    let active = RuleValidator.activeRules(store)
    #expect(active[Fixtures.workID]?.map(\.id) == [first.id])
    #expect(active[Fixtures.homeID]?.map(\.id) == [lookalike.id])
}

@Test func ruleSetsEmitAppRulesAsASeparateRule() throws {
    let rules = [
        Rule(pattern: "example.com", tunnelID: Fixtures.workID),
        Rule(pattern: "/Applications/Telegram.app", match: .app, tunnelID: Fixtures.workID),
    ]
    let objects = try ruleObjects(RuleSetGenerator.render(rules: rules))
    #expect(objects.count == 2)
    #expect(objects[0].keys.sorted() == ["domain", "domain_suffix"])
    #expect(objects[1].keys.sorted() == ["process_path_regex"])
    #expect(objects[1]["process_path_regex"] as? [String] == ["^/Applications/Telegram\\.app/"])

    let appOnly = try ruleObjects(RuleSetGenerator.render(rules: [rules[1]]))
    #expect(appOnly.count == 1)
    #expect(appOnly[0].keys.sorted() == ["process_path_regex"])

    let direct = try ruleObjects(
        RuleSetGenerator.renderDirect(exceptions: [
            Rule(pattern: "/Applications/Bank.app", match: .app, target: .direct)
        ]))
    #expect(direct.count == 2)
    #expect(direct[0]["domain"] as? [String] == RuleSetGenerator.builtInDirectDomains)
    #expect(direct[1]["process_path_regex"] as? [String] == ["^/Applications/Bank\\.app/"])
}

@Test func storeSchemaTwoKeepsAppRulesAndMigratesFromOne() throws {
    let legacy = Data(
        "{\"schemaVersion\": 1, \"tunnels\": [], \"rules\": [], \"settings\": {}}".utf8)
    let migrated = try StoreCodec.decode(legacy)
    #expect(migrated.schemaVersion == 2)
    #expect(Store.currentSchemaVersion == 2)

    let store = Fixtures.store(rules: [
        Rule(pattern: "/Applications/Telegram.app", match: .app, tunnelID: Fixtures.workID)
    ])
    let data = try StoreCodec.encode(store)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"schemaVersion\" : 2"))
    #expect(json.contains("\"match\" : \"app\""))
    #expect(try StoreCodec.decode(data) == store)

    let document = ExportDocument(
        exportedAt: Fixtures.date, includesSecrets: false, tunnels: [], rules: store.rules,
        settings: Settings())
    #expect(document.version == 2)
    #expect(try ExportDocument.decode(document.encode()).rules == store.rules)
}

private func ruleObjects(_ text: String) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    return object?["rules"] as? [[String: Any]] ?? []
}
