import Foundation
import Testing

@testable import WayforkCore

enum Fixtures {
    /// The repo-level `fixtures/` directory, shared with the Windows client's Dart and Go
    /// tests: golden inputs/outputs of the generator, parser samples, protocol captures.
    static let root: URL = {
        // <repo>/Wayfork/WayforkCore/Tests/WayforkCoreTests/ModelTests.swift → <repo>/fixtures
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("fixtures")
    }()

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    static let workID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let homeID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let date = Date(timeIntervalSince1970: 1_787_659_200)  // 2026-08-25T12:00:00Z

    static let work = Tunnel(
        id: workID,
        name: "Work",
        slot: 0,
        kind: .openVPN(
            OpenVPNMeta(
                remotes: [Remote(host: "vpn.example.org", port: 1194, proto: "udp")],
                needsCredentials: true,
                needsKeyPassphrase: false,
                discoveredDNS: ["10.8.0.1"],
                configHash: "abc")),
        createdAt: date)

    static let home = Tunnel(
        id: homeID,
        name: "Home",
        slot: 1,
        kind: .vless(
            VLESSMeta(
                server: "home.example.net",
                port: 443,
                flow: "xtls-rprx-vision",
                security: .reality,
                sni: "www.apple.com",
                fingerprint: "chrome",
                // 32 bytes (0…31) base64url: a syntactically valid X25519 key for `sing-box check`.
                realityPublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
                realityShortID: "0123abcd")),
        createdAt: date)

    static func store(rules: [Rule] = []) -> Store {
        Store(tunnels: [work, home], rules: rules)
    }
}

@Test func storeRoundTripsThroughJSON() throws {
    let rules = [
        Rule(pattern: "example.com", tunnelID: Fixtures.workID),
        Rule(
            pattern: "*.cdn.example.net", match: .wildcard, tunnelID: Fixtures.homeID, note: "cdn"),
    ]
    let store = Fixtures.store(rules: rules)
    let data = try StoreCodec.encode(store)
    let decoded = try StoreCodec.decode(data)
    #expect(decoded == store)

    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"openVPN\" : {"))
    #expect(json.contains("\"vless\" : {"))
    #expect(!json.contains("\"_0\""))
    #expect(json.contains("\"createdAt\" : \"2026-08-25T12:00:00Z\""))
}

@Test func storeRefusesNewerSchema() throws {
    let data = Data("{\"schemaVersion\": 99, \"tunnels\": [], \"rules\": []}".utf8)
    #expect(throws: StoreCodec.Error.newerSchema(found: 99, supported: Store.currentSchemaVersion))
    {
        try StoreCodec.decode(data)
    }
}

@Test func settingsDecodeWithMissingKeys() throws {
    let data = Data(
        "{\"schemaVersion\": 1, \"tunnels\": [], \"rules\": [], \"settings\": {\"logLevel\": \"debug\"}}"
            .utf8)
    let store = try StoreCodec.decode(data)
    #expect(store.settings.logLevel == .debug)
    #expect(store.settings.autoReconnect == true)
    #expect(store.settings.directDNS == .system)
}

@Test func slotsAndInterfaceNames() {
    let store = Fixtures.store()
    #expect(store.nextFreeSlot() == 2)
    #expect(Fixtures.work.interfaceName == "utun101")
    #expect(Fixtures.home.interfaceName == nil)
    #expect(Fixtures.work.outboundTag == "t-00000000-0000-4000-8000-000000000001")
    #expect(Fixtures.work.ruleSetFileName == "rules-t-00000000-0000-4000-8000-000000000001.json")

    var full = Store()
    full.tunnels = (0..<Tunnel.maxSlots).map {
        Tunnel(
            name: "t\($0)", slot: $0, kind: .vless(VLESSMeta(server: "s", port: 1, security: .none))
        )
    }
    #expect(full.nextFreeSlot() == nil)
}

@Test func effectiveRulesFollowTunnelOrder() {
    let r1 = Rule(pattern: "a.com", tunnelID: Fixtures.homeID)
    let r2 = Rule(pattern: "b.com", tunnelID: Fixtures.workID)
    let orphan = Rule(pattern: "c.com", tunnelID: UUID())
    let store = Fixtures.store(rules: [orphan, r1, r2])
    #expect(store.effectiveRules.map(\.pattern) == ["b.com", "a.com", "c.com"])
}

@Test func exportDocumentRoundTrip() throws {
    let store = Fixtures.store(rules: [Rule(pattern: "example.com", tunnelID: Fixtures.workID)])
    let document = ExportDocument(
        exportedAt: Fixtures.date,
        includesSecrets: false,
        tunnels: store.tunnels.map { ExportedTunnel(tunnel: $0) },
        rules: store.rules,
        settings: store.settings)
    let data = try document.encode()
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"format\" : \"wayfork-export\""))
    #expect(!json.contains("\"slot\""))
    #expect(try ExportDocument.decode(data) == document)

    let bogus = Data(
        "{\"format\":\"other\",\"version\":1,\"exportedAt\":\"2026-08-25T12:00:00Z\",\"includesSecrets\":false,\"tunnels\":[],\"rules\":[],\"settings\":{}}"
            .utf8)
    #expect(throws: ExportDocument.Error.unknownFormat("other")) {
        try ExportDocument.decode(bogus)
    }
}

@Test func exampleExportFileDecodes() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/export.example.json")
    let document = try ExportDocument.decode(try Data(contentsOf: url))
    #expect(document.tunnels.count == 2)
    #expect(document.tunnels[0].kind.isOpenVPN)
    #expect(document.tunnels[1].kind.vless?.security == .reality)
    #expect(document.rules.count == 3)
    #expect(document.rules[2].isException)
    #expect(document.defaultTunnelID == document.tunnels[1].id)
}

@Test func xpcPayloadsRoundTrip() throws {
    let status = RuntimeStatus(
        engine: .running(since: Fixtures.date),
        tunnels: [
            "a": .connected(since: Fixtures.date, ip: "10.8.0.2", interface: "utun101"),
            "b": .reconnecting(attempt: 3, nextIn: 4, reason: "ping-restart"),
            "c": .failed(reason: "auth", permanent: true),
        ],
        planHash: "h",
        discoveredDNS: ["a": ["10.8.0.1"]])
    let data = try XPCCodec.encode(status)
    #expect(try XPCCodec.decode(RuntimeStatus.self, from: data) == status)

    let result = ApplyResult.failure(.configInvalid(output: "bad json"))
    #expect(try XPCCodec.decode(ApplyResult.self, from: try XPCCodec.encode(result)) == result)
}

@Test func planHashesIgnoreRuleSetContentForConfigHash() {
    let a = SingBoxPlan(config: "{}", ruleSets: ["r.json": "1"])
    let b = SingBoxPlan(config: "{}", ruleSets: ["r.json": "2"])
    #expect(a.configHash == b.configHash)
    let planA = RuntimePlan(singBox: a, openVPN: [])
    let planB = RuntimePlan(singBox: b, openVPN: [])
    #expect(planA.planHash != planB.planHash)

    let ovpn1 = OpenVPNRuntime(id: "x", interface: "utun101", config: "client")
    let ovpn2 = OpenVPNRuntime(
        id: "x", interface: "utun101", config: "client",
        credentials: Credentials(username: "u", password: "p"))
    #expect(ovpn1.configHash != ovpn2.configHash)
}

@Test func logLevelOrderingAndMappings() {
    #expect(LogLevel.error < LogLevel.debug)
    #expect(LogLevel.warning < LogLevel.info)
    #expect(LogLevel.info.openVPNVerbosity == 3)
    #expect(LogLevel.debug.openVPNVerbosity == 4)
    #expect(LogLevel.error.openVPNVerbosity == 1)
    #expect(LogLevel.warning.singBoxLevel == "warn")
}

// MARK: - F8: rule targets and the default tunnel

@Test func ruleJSONStaysBackwardCompatible() throws {
    // A pre-F8 rule: tunnelID only.
    let legacy = Data(
        """
        {"id":"00000000-0000-4000-8000-000000000101","pattern":"example.com","match":"suffix",
         "tunnelID":"00000000-0000-4000-8000-000000000001","isEnabled":true,"note":null}
        """.utf8)
    let rule = try JSONCoding.decoder.decode(Rule.self, from: legacy)
    #expect(rule.target == .tunnel(Fixtures.workID))
    #expect(rule.tunnelID == Fixtures.workID)
    #expect(!rule.isException)

    // An exception: target: direct, no tunnelID.
    let exception = Rule(pattern: "bank.example.org", target: .direct, note: "keep local")
    let data = try JSONCoding.prettyEncoder.encode(exception)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"target\" : \"direct\""))
    #expect(!json.contains("tunnelID"))
    let decoded = try JSONCoding.decoder.decode(Rule.self, from: data)
    #expect(decoded == exception)
    #expect(decoded.tunnelID == nil)

    // A tunnel rule never writes `target`.
    let tunnelJSON = String(
        decoding: try JSONCoding.prettyEncoder.encode(
            Rule(pattern: "a.com", tunnelID: Fixtures.workID)), as: UTF8.self)
    #expect(!tunnelJSON.contains("\"target\""))

    // Neither → invalid; unknown target → invalid.
    let neither = Data(
        "{\"id\":\"00000000-0000-4000-8000-000000000101\",\"pattern\":\"a.com\",\"match\":\"suffix\",\"isEnabled\":true}"
            .utf8)
    #expect(throws: DecodingError.self) { try JSONCoding.decoder.decode(Rule.self, from: neither) }
    let unknown = Data(
        "{\"id\":\"00000000-0000-4000-8000-000000000101\",\"pattern\":\"a.com\",\"match\":\"suffix\",\"target\":\"reject\",\"isEnabled\":true}"
            .utf8)
    #expect(throws: DecodingError.self) { try JSONCoding.decoder.decode(Rule.self, from: unknown) }
}

@Test func storeDefaultTunnelRoundTripsAndDefaultsToNil() throws {
    var store = Fixtures.store(rules: [Rule(pattern: "bank.example.org", target: .direct)])
    #expect(try StoreCodec.decode(StoreCodec.encode(store)).defaultTunnelID == nil)
    // A store written before F8 has no key at all.
    let legacy = Data(
        "{\"schemaVersion\": 1, \"tunnels\": [], \"rules\": [], \"settings\": {}}".utf8)
    #expect(try StoreCodec.decode(legacy).defaultTunnelID == nil)

    store.defaultTunnelID = Fixtures.workID
    let decoded = try StoreCodec.decode(StoreCodec.encode(store))
    #expect(decoded == store)
    #expect(decoded.effectiveDefaultTunnel?.id == Fixtures.workID)
    #expect(decoded.exceptions.map(\.pattern) == ["bank.example.org"])

    var disabled = store
    disabled.tunnels[0].isEnabled = false
    #expect(disabled.effectiveDefaultTunnel == nil)
    var missing = store
    missing.defaultTunnelID = UUID()
    #expect(missing.effectiveDefaultTunnel == nil)
}

@Test func effectiveRulesPutExceptionsFirst() {
    let exception = Rule(pattern: "x.com", target: .direct)
    let r1 = Rule(pattern: "a.com", tunnelID: Fixtures.homeID)
    let r2 = Rule(pattern: "b.com", tunnelID: Fixtures.workID)
    let orphan = Rule(pattern: "c.com", tunnelID: UUID())
    let store = Fixtures.store(rules: [orphan, r1, r2, exception])
    #expect(store.effectiveRules.map(\.pattern) == ["x.com", "b.com", "a.com", "c.com"])
    #expect(store.rules(for: .direct).map(\.id) == [exception.id])
}
