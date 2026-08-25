import Foundation
import Testing

@testable import WayforkCore

private let bundlePath = "/Applications/Wayfork.app"
private let homeUUID = "00000000-0000-4000-8000-0000000000aa"

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func twoTunnelStore() -> Store {
    Fixtures.store(rules: [
        Rule(pattern: "example.com", tunnelID: Fixtures.workID),
        Rule(pattern: "api.other.com", match: .exact, tunnelID: Fixtures.workID),
        Rule(pattern: "*.cdn.example.com", match: .wildcard, tunnelID: Fixtures.homeID),
        Rule(pattern: "disabled.example", tunnelID: Fixtures.homeID, isEnabled: false),
    ])
}

private func generate(_ store: Store, uuids: [UUID: String] = [Fixtures.homeID: homeUUID])
    -> SingBoxConfigGenerator.Output
{
    SingBoxConfigGenerator.generate(
        SingBoxConfigGenerator.Input(
            store: store, vlessUUIDs: uuids,
            openVPNBinaryPath: RuntimePlanBuilder.openVPNBinaryPath(bundlePath: bundlePath)))
}

@Test func generatedConfigFollowsRoutingDesign() throws {
    let output = generate(twoTunnelStore())
    let config = try json(output.config)
    let work = Fixtures.work
    let home = Fixtures.home

    let dns = try #require(config["dns"] as? [String: Any])
    let servers = try #require(dns["servers"] as? [[String: Any]])
    #expect(
        servers.map { $0["tag"] as? String } == ["dns-direct", "dns-\(work.outboundTag)", "fakeip"])
    #expect(servers[0]["type"] as? String == "local")
    #expect(servers[1]["server"] as? String == "10.8.0.1")
    #expect(servers[1]["detour"] as? String == work.outboundTag)
    let dnsRules = try #require(dns["rules"] as? [[String: Any]])
    #expect(dnsRules.count == 2)
    #expect(dnsRules[0]["rule_set"] as? String == "rules-direct")
    #expect(dnsRules[0]["server"] as? String == "dns-direct")
    #expect(dnsRules[1]["rule_set"] as? [String] == [work.ruleSetTag, home.ruleSetTag])
    #expect(dnsRules[1]["server"] as? String == "fakeip")
    #expect(dns["final"] as? String == "dns-direct")
    #expect(dns["strategy"] as? String == "ipv4_only")

    let inbounds = try #require(config["inbounds"] as? [[String: Any]])
    #expect(inbounds[0]["interface_name"] as? String == "utun100")
    #expect(inbounds[0]["auto_route"] as? Bool == true)

    let outbounds = try #require(config["outbounds"] as? [[String: Any]])
    #expect(
        outbounds.map { $0["tag"] as? String } == ["direct", work.outboundTag, home.outboundTag])
    #expect(outbounds[1]["bind_interface"] as? String == "utun101")
    #expect(
        (outbounds[1]["domain_resolver"] as? [String: Any])?["strategy"] as? String == "ipv4_only")
    #expect(outbounds[2]["type"] as? String == "vless")
    #expect(outbounds[2]["uuid"] as? String == homeUUID)
    #expect(outbounds[2]["flow"] as? String == "xtls-rprx-vision")
    let tls = try #require(outbounds[2]["tls"] as? [String: Any])
    #expect(tls["server_name"] as? String == "www.apple.com")
    #expect(
        (tls["reality"] as? [String: Any])?["public_key"] as? String
            == Fixtures.home.kind.vless?.realityPublicKey)
    #expect((tls["utls"] as? [String: Any])?["fingerprint"] as? String == "chrome")
    #expect(outbounds[2]["transport"] == nil)

    let route = try #require(config["route"] as? [String: Any])
    let rules = try #require(route["rules"] as? [[String: Any]])
    #expect(rules[0]["action"] as? String == "sniff")
    #expect(rules[1]["action"] as? String == "hijack-dns")
    #expect(
        rules[2]["process_path"] as? [String] == [
            "/Applications/Wayfork.app/Contents/Resources/bin/openvpn"
        ])
    #expect(rules[3]["rule_set"] as? String == "rules-direct")
    #expect(rules[3]["outbound"] as? String == "direct")
    #expect(rules[4]["rule_set"] as? String == work.ruleSetTag)
    #expect(rules[5]["rule_set"] as? String == home.ruleSetTag)
    #expect(rules[6]["ip_is_private"] as? Bool == true)
    #expect(route["final"] as? String == "direct")
    #expect(route["default_domain_resolver"] as? String == "dns-direct")
    let ruleSets = try #require(route["rule_set"] as? [[String: Any]])
    #expect(
        ruleSets.map { $0["path"] as? String } == [
            "rules-direct.json", work.ruleSetFileName, home.ruleSetFileName,
        ])
    #expect(output.defaultTunnel == nil)

    #expect(
        output.ruleSets.keys.sorted()
            == ["rules-direct.json", home.ruleSetFileName, work.ruleSetFileName].sorted())
    let direct = try json(output.ruleSets["rules-direct.json"]!)
    let directRule = try #require((direct["rules"] as? [[String: Any]])?.first)
    #expect(directRule["domain"] as? [String] == ["localhost"])
    #expect(
        directRule["domain_suffix"] as? [String] == [
            ".local", ".lan", ".internal", ".home.arpa", ".localhost",
        ])
    let workRules = try json(output.ruleSets[work.ruleSetFileName]!)
    let workRule = try #require((workRules["rules"] as? [[String: Any]])?.first)
    #expect(workRule["domain"] as? [String] == ["example.com", "api.other.com"])
    #expect(workRule["domain_suffix"] as? [String] == [".example.com"])
    let homeRules = try json(output.ruleSets[home.ruleSetFileName]!)
    let homeRule = try #require((homeRules["rules"] as? [[String: Any]])?.first)
    #expect(homeRule["domain_regex"] as? [String] == ["^.+\\.cdn\\.example\\.com$"])
    #expect(homeRule["domain"] == nil)
}

@Test func generatorHonorsDNSSettingsAndSkipsUnusableTunnels() throws {
    var store = twoTunnelStore()
    store.settings.directDNS = .custom(servers: ["9.9.9.9", "1.1.1.1"])
    store.settings.logLevel = .debug
    if case .openVPN(var meta) = store.tunnels[0].kind {
        meta.dns = .custom(servers: ["10.1.1.1"])
        store.tunnels[0].kind = .openVPN(meta)
    }
    // Home has no UUID this time → left out entirely.
    let output = generate(store, uuids: [:])
    let config = try json(output.config)
    let dns = try #require(config["dns"] as? [String: Any])
    let servers = try #require(dns["servers"] as? [[String: Any]])
    #expect(servers[0]["type"] as? String == "udp")
    #expect(servers[0]["server"] as? String == "9.9.9.9")
    #expect(servers[0]["detour"] as? String == "direct")
    #expect(servers[1]["server"] as? String == "10.1.1.1")
    #expect((config["log"] as? [String: Any])?["level"] as? String == "debug")
    #expect(output.routedTunnels.map(\.id) == [Fixtures.workID])
    #expect(output.ruleSets.count == 2)

    // Nothing routed at all: only the Direct rule-set remains, still a valid config.
    var empty = store
    empty.tunnels = []
    let bare = generate(empty, uuids: [:])
    let bareConfig = try json(bare.config)
    #expect(((bareConfig["dns"] as? [String: Any])?["rules"] as? [Any])?.count == 1)
    #expect(((bareConfig["route"] as? [String: Any])?["rule_set"] as? [Any])?.count == 1)
    #expect(bare.ruleSets.keys.sorted() == ["rules-direct.json"])
}

// MARK: - F8: default tunnel and exceptions

private func defaultTunnelStore(defaultID: UUID) -> Store {
    var store = twoTunnelStore()
    store.defaultTunnelID = defaultID
    store.rules.append(Rule(pattern: "bank.example.org", target: .direct))
    store.rules.append(Rule(pattern: "*.intranet.example", match: .wildcard, target: .direct))
    // An exception that shadows the Work rule for example.com: the exception wins.
    store.rules.append(Rule(pattern: "example.com", target: .direct))
    return store
}

@Test func openVPNDefaultTunnelRoutesEverythingElse() throws {
    let output = generate(defaultTunnelStore(defaultID: Fixtures.workID))
    let config = try json(output.config)
    let work = Fixtures.work
    #expect(output.defaultTunnel?.id == work.id)

    let route = try #require(config["route"] as? [String: Any])
    #expect(route["final"] as? String == work.outboundTag)
    let dns = try #require(config["dns"] as? [String: Any])
    #expect(dns["final"] as? String == "dns-\(work.outboundTag)")
    let dnsRules = try #require(dns["rules"] as? [[String: Any]])
    #expect(dnsRules.count == 3)
    #expect(dnsRules[2]["query_type"] as? [String] == ["A", "AAAA"])
    #expect(dnsRules[2]["server"] as? String == "fakeip")
    #expect(dnsRules[2]["rule_set"] == nil)
    // No extra resolver for an OpenVPN default: its udp server already exists.
    let servers = try #require(dns["servers"] as? [[String: Any]])
    #expect(
        servers.map { $0["tag"] as? String } == ["dns-direct", "dns-\(work.outboundTag)", "fakeip"])

    let direct = try json(output.ruleSets["rules-direct.json"]!)
    let directRule = try #require((direct["rules"] as? [[String: Any]])?.first)
    #expect(directRule["domain"] as? [String] == ["localhost", "bank.example.org", "example.com"])
    #expect(directRule["domain_regex"] as? [String] == ["^.+\\.intranet\\.example$"])
    // The shadowed Work rule is dropped from its rule-set.
    let workRules = try json(output.ruleSets[work.ruleSetFileName]!)
    let workRule = try #require((workRules["rules"] as? [[String: Any]])?.first)
    #expect(workRule["domain"] as? [String] == ["api.other.com"])
}

@Test func vlessDefaultTunnelGetsADoTResolver() throws {
    let output = generate(defaultTunnelStore(defaultID: Fixtures.homeID))
    let config = try json(output.config)
    let home = Fixtures.home
    let route = try #require(config["route"] as? [String: Any])
    #expect(route["final"] as? String == home.outboundTag)
    let dns = try #require(config["dns"] as? [String: Any])
    #expect(dns["final"] as? String == "dns-\(home.outboundTag)")
    let servers = try #require(dns["servers"] as? [[String: Any]])
    let dot = try #require(servers.first { $0["tag"] as? String == "dns-\(home.outboundTag)" })
    #expect(dot["type"] as? String == "tls")
    #expect(dot["server"] as? String == "1.1.1.1")
    #expect(dot["detour"] as? String == home.outboundTag)
}

@Test func unusableDefaultTunnelFallsBackToDirect() throws {
    // Disabled default → behaves as if none were set.
    var disabled = defaultTunnelStore(defaultID: Fixtures.workID)
    disabled.tunnels[0].isEnabled = false
    let output = generate(disabled)
    #expect(output.defaultTunnel == nil)
    let config = try json(output.config)
    #expect((config["route"] as? [String: Any])?["final"] as? String == "direct")
    #expect((config["dns"] as? [String: Any])?["final"] as? String == "dns-direct")
    #expect(((config["dns"] as? [String: Any])?["rules"] as? [Any])?.count == 2)

    // VLESS default without its UUID → left out of the config, so no default either.
    let noSecret = generate(defaultTunnelStore(defaultID: Fixtures.homeID), uuids: [:])
    #expect(noSecret.defaultTunnel == nil)
    #expect((try json(noSecret.config)["route"] as? [String: Any])?["final"] as? String == "direct")

    // Unknown id → no default.
    var unknown = twoTunnelStore()
    unknown.defaultTunnelID = UUID()
    #expect(generate(unknown).defaultTunnel == nil)

    // Exceptions without a default still land in rules-direct.json.
    var exceptionsOnly = twoTunnelStore()
    exceptionsOnly.rules.append(Rule(pattern: "bank.example.org", target: .direct))
    let direct = try json(generate(exceptionsOnly).ruleSets["rules-direct.json"]!)
    let directRule = try #require((direct["rules"] as? [[String: Any]])?.first)
    #expect(directRule["domain"] as? [String] == ["localhost", "bank.example.org"])
}

@Test func emptyRuleSetIsStillEmitted() throws {
    let store = Fixtures.store()
    let output = generate(store)
    let document = try json(output.ruleSets[Fixtures.work.ruleSetFileName]!)
    #expect(document["version"] as? Int == 3)
    #expect((document["rules"] as? [Any])?.isEmpty == true)
}

@Test func vlessOutboundVariants() {
    let ws = VLESSMeta(
        server: "s", port: 443, security: .tls, sni: "sni", alpn: ["h2", "http/1.1"],
        transport: .ws(path: "/x", host: "h"), allowInsecure: true)
    let out = SingBoxConfigGenerator.vlessOutbound(ws, tag: "t", uuid: "u")
    #expect((out["transport"] as? [String: Any])?["type"] as? String == "ws")
    #expect(
        ((out["transport"] as? [String: Any])?["headers"] as? [String: String]) == ["Host": "h"])
    #expect((out["tls"] as? [String: Any])?["alpn"] as? [String] == ["h2", "http/1.1"])
    #expect((out["tls"] as? [String: Any])?["insecure"] as? Bool == true)
    #expect((out["tls"] as? [String: Any])?["utls"] == nil)
    #expect(out["flow"] == nil)

    let plain = SingBoxConfigGenerator.vlessOutbound(
        VLESSMeta(server: "s", port: 80, security: .none, transport: .grpc(serviceName: "svc")),
        tag: "t", uuid: "u")
    #expect(plain["tls"] == nil)
    #expect((plain["transport"] as? [String: Any])?["service_name"] as? String == "svc")
}

@Test func planBuilderSkipsTunnelsWithoutSecrets() throws {
    let store = twoTunnelStore()
    let secrets = PlanSecrets(
        vlessUUIDs: [:],
        openVPNConfigs: [Fixtures.workID: "client\nremote vpn.example.org 1194\n"],
        credentials: [Fixtures.workID: Credentials(username: "u", password: "p")])
    let result = RuntimePlanBuilder.build(store: store, secrets: secrets, bundlePath: bundlePath)
    #expect(result.warnings == [.missingSecret(tunnelID: Fixtures.homeID)])
    #expect(result.routedTunnels.map(\.id) == [Fixtures.workID])
    #expect(result.plan.openVPN.count == 1)
    #expect(result.plan.openVPN[0].interface == "utun101")
    #expect(result.plan.openVPN[0].id == Fixtures.workID.uuidString.lowercased())
    #expect(result.plan.openVPN[0].credentials?.username == "u")
    #expect(result.plan.singBox.ruleSets.count == 2)  // Work + rules-direct.json
    #expect(result.plan.singBox.configHash == Hashing.sha256Hex(result.plan.singBox.config))

    // Same input → identical plan hash; a rule change → different plan, same config hash.
    let again = RuntimePlanBuilder.build(store: store, secrets: secrets, bundlePath: bundlePath)
    #expect(again.plan.planHash == result.plan.planHash)
    var changed = store
    changed.rules.append(Rule(pattern: "new.example", tunnelID: Fixtures.workID))
    let next = RuntimePlanBuilder.build(store: changed, secrets: secrets, bundlePath: bundlePath)
    #expect(next.plan.planHash != result.plan.planHash)
    #expect(next.plan.singBox.configHash == result.plan.singBox.configHash)
}

/// Golden files under `Tests/WayforkCoreTests/Golden/<variant>/`. Regenerate with
/// `WAYFORK_UPDATE_GOLDEN=1 swift test` after an intentional generator change and review the diff.
@Test func generatedConfigMatchesGoldenFiles() throws {
    let goldenRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Golden")
    let update = ProcessInfo.processInfo.environment["WAYFORK_UPDATE_GOLDEN"] != nil
    for (name, output) in configVariants() {
        let dir = goldenRoot.appendingPathComponent(name)
        var files = output.ruleSets
        files["sing-box.json"] = output.config
        if update {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
            for (file, contents) in files {
                try contents.write(
                    to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            continue
        }
        let expectedFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(expectedFiles == files.keys.sorted(), "file list for \(name)")
        for (file, contents) in files {
            let expected = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            #expect(contents == expected, "\(name)/\(file) differs from golden")
        }
    }
}

private func configVariants() -> [(String, SingBoxConfigGenerator.Output)] {
    var variants: [(String, SingBoxConfigGenerator.Output)] = [
        ("two-tunnels", generate(twoTunnelStore()))
    ]
    var custom = twoTunnelStore()
    custom.settings.directDNS = .custom(servers: ["9.9.9.9"])
    custom.settings.logLevel = .debug
    variants.append(("custom-dns", generate(custom)))
    var none = twoTunnelStore()
    none.tunnels = []
    variants.append(("no-tunnels", generate(none)))
    var ws = twoTunnelStore()
    ws.tunnels[1].kind = .vless(
        VLESSMeta(
            server: "s.example", port: 443, security: .tls, fingerprint: "safari", alpn: ["h2"],
            transport: .ws(path: "/x", host: "h.example")))
    variants.append(("vless-ws", generate(ws)))
    variants.append(("default-openvpn", generate(defaultTunnelStore(defaultID: Fixtures.workID))))
    variants.append(("default-vless", generate(defaultTunnelStore(defaultID: Fixtures.homeID))))
    return variants
}

/// Runs `sing-box check` on the generated config when the fetched binary is available
/// (scripts/fetch-bins.sh); skipped otherwise.
@Test func singBoxAcceptsGeneratedConfigs() throws {
    let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/bin/sing-box")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        return
    }

    for (name, output) in configVariants() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wayfork-singbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try output.config.write(
            to: dir.appendingPathComponent("sing-box.json"), atomically: true, encoding: .utf8)
        for (file, contents) in output.ruleSets {
            try contents.write(
                to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["check", "-D", dir.path, "-c", "sing-box.json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "sing-box check failed for \(name): \(log)")
    }
}
