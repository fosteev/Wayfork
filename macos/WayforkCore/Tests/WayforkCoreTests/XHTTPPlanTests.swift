import Foundation
import Testing

@testable import WayforkCore

private let bundlePath = "/Applications/Wayfork.app"
private let xhttpUUID = "00000000-0000-4000-8000-0000000000aa"
private let realityKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
private let extraJSON = #"{"xPaddingBytes":"100-1000","noSSEHeader":true}"#

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func realityMeta(
    server: String = "xhttp.example.net", transport: ProxyTransport? = nil
) -> VLESSMeta {
    VLESSMeta(
        server: server, port: 443, security: .reality, sni: "www.apple.com",
        realityPublicKey: realityKey, realityShortID: "0123abcd",
        transport: transport ?? .xhttp(path: "/", host: nil, mode: nil, extra: nil))
}

private func tlsMeta() -> VLESSMeta {
    VLESSMeta(
        server: "cdn.example.net", port: 8443, security: .tls, sni: "front.example.net",
        fingerprint: "firefox", alpn: ["h2", "http/1.1"],
        transport: .xhttp(
            path: "/xh", host: "origin.example.net", mode: "packet-up", extra: extraJSON))
}

private func dict(_ any: Any?) -> [String: Any]? { any as? [String: Any] }

private func streamSettings(_ config: String) throws -> [String: Any] {
    let outbounds = try #require(try json(config)["outbounds"] as? [[String: Any]])
    return try #require(dict(outbounds[0]["streamSettings"]))
}

// MARK: - Model

@Test func xrayPortFollowsTheSlotAndExistsOnlyForXHTTP() {
    let xhttp = Tunnel(name: "X", slot: 3, kind: .vless(realityMeta()))
    #expect(xhttp.xrayPort == 47103)
    #expect(Tunnel(name: "X0", slot: 0, kind: .vless(realityMeta())).xrayPort == 47100)
    #expect(Tunnel(name: "X31", slot: 31, kind: .vless(realityMeta())).xrayPort == 47131)
    #expect(Tunnel.xrayPorts == 47100..<47132)
    #expect(Fixtures.home.xrayPort == nil)  // VLESS over TCP stays inside sing-box
    #expect(Fixtures.work.xrayPort == nil)
    let ws = VLESSMeta(
        server: "s.example", port: 443, security: .tls, transport: .ws(path: "/", host: nil))
    #expect(Tunnel(name: "WS", slot: 2, kind: .vless(ws)).xrayPort == nil)
}

@Test func planWithoutAnXrayKeyDecodesAsEmptyAndTheHashSeesXray() throws {
    let single = SingBoxPlan(config: "{}\n", ruleSets: [:])
    let plain = RuntimePlan(singBox: single, openVPN: [])
    var object = try #require(
        try JSONSerialization.jsonObject(with: JSONCoding.compactEncoder.encode(plain))
            as? [String: Any])
    object.removeValue(forKey: "xray")
    let old = try JSONCoding.decoder.decode(
        RuntimePlan.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.xray.isEmpty)
    #expect(old.planHash == plain.planHash)

    let one = XrayRuntime(id: "aaaaaaaa-0000-0000-0000-000000000001", port: 47100, config: "a")
    let changed = XrayRuntime(id: one.id, port: 47100, config: "b")
    let withOne = RuntimePlan(singBox: single, openVPN: [], xray: [one])
    #expect(withOne.planHash != plain.planHash)
    #expect(RuntimePlan(singBox: single, openVPN: [], xray: [changed]).planHash != withOne.planHash)
    #expect(one.configHash == Hashing.sha256Hex("a"))
    let round = try JSONCoding.decoder.decode(
        RuntimePlan.self, from: JSONCoding.compactEncoder.encode(withOne))
    #expect(round == withOne)
}

// MARK: - XrayConfigGenerator

@Test func realityConfigSpeaksXHTTPOverALoopbackSocksInbound() throws {
    let text = try #require(
        XrayConfigGenerator.generate(meta: realityMeta(), uuid: xhttpUUID, port: 47101))
    let config = try json(text)
    #expect(dict(config["log"])?["loglevel"] as? String == "warning")

    let inbound = try #require((config["inbounds"] as? [[String: Any]])?.first)
    #expect((config["inbounds"] as? [Any])?.count == 1)
    #expect(inbound["listen"] as? String == "127.0.0.1")
    #expect(inbound["port"] as? Int == 47101)
    #expect(inbound["protocol"] as? String == "socks")
    let socks = try #require(dict(inbound["settings"]))
    #expect(socks["udp"] as? Bool == true && socks["ip"] as? String == "127.0.0.1")

    let outbounds = try #require(config["outbounds"] as? [[String: Any]])
    #expect(outbounds.count == 1)
    #expect(outbounds[0]["protocol"] as? String == "vless")
    let vnext = try #require(
        (dict(outbounds[0]["settings"])?["vnext"] as? [[String: Any]])?.first)
    #expect(vnext["address"] as? String == "xhttp.example.net" && vnext["port"] as? Int == 443)
    let user = try #require((vnext["users"] as? [[String: Any]])?.first)
    #expect(user["id"] as? String == xhttpUUID && user["encryption"] as? String == "none")
    #expect(user["flow"] == nil)

    let stream = try streamSettings(text)
    #expect(stream["network"] as? String == "xhttp")
    #expect(stream["security"] as? String == "reality")
    let reality = try #require(dict(stream["realitySettings"]))
    #expect(reality["serverName"] as? String == "www.apple.com")
    #expect(reality["fingerprint"] as? String == "chrome")  // default when the link has no fp
    #expect(reality["password"] as? String == realityKey)
    #expect(reality["shortId"] as? String == "0123abcd")
    #expect(stream["tlsSettings"] == nil)
    let xhttp = try #require(dict(stream["xhttpSettings"]))
    #expect(xhttp["path"] as? String == "/")
    #expect(xhttp["mode"] as? String == "auto")
    #expect(xhttp["host"] == nil && xhttp["extra"] == nil)
    // No mux (XHTTP accepts only XUDP), no routing, no DNS.
    #expect(outbounds[0]["mux"] == nil && config["routing"] == nil && config["dns"] == nil)
}

@Test func tlsConfigCarriesHostModeAndExtraAsAnObject() throws {
    let text = try #require(
        XrayConfigGenerator.generate(meta: tlsMeta(), uuid: xhttpUUID, port: 47105))
    let stream = try streamSettings(text)
    #expect(stream["security"] as? String == "tls")
    let tls = try #require(dict(stream["tlsSettings"]))
    #expect(tls["serverName"] as? String == "front.example.net")
    #expect(tls["alpn"] as? [String] == ["h2", "http/1.1"])
    #expect(tls["fingerprint"] as? String == "firefox")
    #expect(tls["allowInsecure"] == nil)
    #expect(stream["realitySettings"] == nil)
    let xhttp = try #require(dict(stream["xhttpSettings"]))
    #expect(xhttp["path"] as? String == "/xh")
    #expect(xhttp["host"] as? String == "origin.example.net")
    #expect(xhttp["mode"] as? String == "packet-up")
    // `extra` is embedded as an object, not as the string the link carried.
    let extra = try #require(dict(xhttp["extra"]))
    #expect(extra["xPaddingBytes"] as? String == "100-1000")
    #expect(extra["noSSEHeader"] as? Bool == true)

    var bare = tlsMeta()
    bare.sni = nil
    bare.alpn = []
    bare.fingerprint = nil
    let bareStream = try streamSettings(
        try #require(XrayConfigGenerator.generate(meta: bare, uuid: xhttpUUID, port: 47105)))
    let bareTLS = try #require(dict(bareStream["tlsSettings"]))
    #expect(bareTLS["serverName"] as? String == "cdn.example.net")  // falls back to the host
    #expect(bareTLS["alpn"] == nil && bareTLS["fingerprint"] == nil)
}

@Test func securityNoneEmitsNoTLSBlockAndIsDeterministic() throws {
    var meta = realityMeta()
    meta.security = .none
    let text = try #require(XrayConfigGenerator.generate(meta: meta, uuid: xhttpUUID, port: 47100))
    let stream = try streamSettings(text)
    #expect(stream["security"] as? String == "none")
    #expect(stream["tlsSettings"] == nil && stream["realitySettings"] == nil)
    #expect(XrayConfigGenerator.generate(meta: meta, uuid: xhttpUUID, port: 47100) == text)
}

@Test func onlyXHTTPTunnelsGetAnXrayConfig() {
    #expect(
        XrayConfigGenerator.generate(meta: Fixtures.home.kind.vless!, uuid: "u", port: 1) == nil)
    let grpc = realityMeta(transport: .grpc(serviceName: "g"))
    #expect(XrayConfigGenerator.generate(meta: grpc, uuid: "u", port: 1) == nil)
}

// MARK: - RuntimePlanBuilder

private func xhttpStore(slot: Int = 1) -> Store {
    var store = Fixtures.store(rules: [Rule(pattern: "example.com", tunnelID: Fixtures.homeID)])
    store.tunnels[1].slot = slot
    store.tunnels[1].kind = .vless(realityMeta())
    return store
}

private func openVPNSecrets() -> PlanSecrets {
    PlanSecrets(
        vlessUUIDs: [Fixtures.homeID: xhttpUUID],
        openVPNConfigs: [Fixtures.workID: "client\nremote vpn.example.org 1194\n"])
}

@Test func builderMakesOneXrayRuntimePerEnabledXHTTPTunnel() throws {
    let result = RuntimePlanBuilder.build(
        store: xhttpStore(slot: 4), secrets: openVPNSecrets(), bundlePath: bundlePath)
    #expect(result.warnings.isEmpty)
    #expect(result.plan.openVPN.count == 1)
    let runtime = try #require(result.plan.xray.first)
    #expect(result.plan.xray.count == 1)
    #expect(runtime.id == Fixtures.homeID.uuidString.lowercased())
    #expect(runtime.port == 47104)
    #expect(runtime.config.contains(xhttpUUID))
    #expect(runtime.configHash == Hashing.sha256Hex(runtime.config))
    #expect(
        runtime.config
            == XrayConfigGenerator.generate(meta: realityMeta(), uuid: xhttpUUID, port: 47104))
    // The same port reaches sing-box, and the tunnel is routed.
    #expect(result.routedTunnels.map(\.id).contains(Fixtures.homeID))
    let outbounds = try #require(
        try json(result.plan.singBox.config)["outbounds"] as? [[String: Any]])
    let socks = try #require(outbounds.first { $0["tag"] as? String == Fixtures.home.outboundTag })
    #expect(socks["server_port"] as? Int == 47104)
    #expect(!result.plan.singBox.config.contains(xhttpUUID))  // the UUID never reaches sing-box
}

@Test func builderLeavesOutXHTTPTunnelsThatCannotRun() {
    let missing = RuntimePlanBuilder.build(
        store: xhttpStore(), secrets: PlanSecrets(), bundlePath: bundlePath)
    #expect(missing.plan.xray.isEmpty)
    #expect(missing.warnings.contains(.missingSecret(tunnelID: Fixtures.homeID)))
    #expect(!missing.routedTunnels.map(\.id).contains(Fixtures.homeID))
    #expect(!missing.plan.singBox.config.contains("\"socks\""))

    var disabled = xhttpStore()
    disabled.tunnels[1].isEnabled = false
    let off = RuntimePlanBuilder.build(
        store: disabled, secrets: openVPNSecrets(), bundlePath: bundlePath)
    #expect(off.plan.xray.isEmpty && off.warnings.isEmpty)

    // Native VLESS (TCP) stays inside sing-box: no xray process.
    let native = RuntimePlanBuilder.build(
        store: Fixtures.store(), secrets: openVPNSecrets(), bundlePath: bundlePath)
    #expect(native.plan.xray.isEmpty)
}

@Test func theXrayRuntimeChangesThePlanHashButNotTheSingBoxHash() {
    let secrets = openVPNSecrets()
    let first = RuntimePlanBuilder.build(
        store: xhttpStore(), secrets: secrets, bundlePath: bundlePath)
    var changedSecrets = secrets
    changedSecrets.vlessUUIDs[Fixtures.homeID] = "00000000-0000-4000-8000-0000000000bb"
    let second = RuntimePlanBuilder.build(
        store: xhttpStore(), secrets: changedSecrets, bundlePath: bundlePath)
    #expect(first.plan.singBox.configHash == second.plan.singBox.configHash)
    #expect(first.plan.planHash != second.plan.planHash)
    #expect(first.plan.xray[0].configHash != second.plan.xray[0].configHash)
}

// MARK: - sing-box side

private func generate(
    _ store: Store, resolved: [String: [String]] = [:], xrayPath: String? = "/x/xray"
) -> SingBoxConfigGenerator.Output {
    SingBoxConfigGenerator.generate(
        SingBoxConfigGenerator.Input(
            store: store, vlessUUIDs: [Fixtures.homeID: xhttpUUID], openVPNBinaryPath: "/x/openvpn",
            xrayBinaryPath: xrayPath, resolvedServerAddresses: resolved))
}

private func routeRules(_ output: SingBoxConfigGenerator.Output) throws -> [[String: Any]] {
    try #require(dict(try json(output.config)["route"])?["rules"] as? [[String: Any]])
}

@Test func xhttpTunnelIsASocksOutboundAndNeverAVLESSOne() throws {
    let output = generate(xhttpStore(slot: 2))
    let outbounds = try #require(try json(output.config)["outbounds"] as? [[String: Any]])
    let tag = Fixtures.home.outboundTag
    let mine = outbounds.filter { $0["tag"] as? String == tag }
    #expect(mine.count == 1)
    #expect(mine[0]["type"] as? String == "socks")
    #expect(mine[0]["server"] as? String == "127.0.0.1")
    #expect(mine[0]["server_port"] as? Int == 47102)
    #expect(mine[0]["version"] as? String == "5")
    // Nothing of the VLESS dial leaks into sing-box.
    #expect(!outbounds.contains { $0["type"] as? String == "vless" })
    #expect(mine[0]["uuid"] == nil && mine[0]["tls"] == nil && mine[0]["transport"] == nil)
    #expect(!output.config.contains("xhttp.example.net:") && !output.config.contains(realityKey))
    // Still routed like any tunnel.
    let rules = try routeRules(output)
    #expect(rules.contains { $0["outbound"] as? String == tag && $0["rule_set"] != nil })
}

@Test func theXrayProcessAndItsServerGoDirect() throws {
    let output = generate(
        xhttpStore(), resolved: ["xhttp.example.net": ["198.51.100.7", "198.51.100.2"]])
    let rules = try routeRules(output)
    let processIndex = try #require(rules.firstIndex { $0["process_path"] != nil })
    #expect(rules[processIndex]["process_path"] as? [String] == ["/x/openvpn", "/x/xray"])
    #expect(rules[processIndex]["outbound"] as? String == "direct")
    let server = rules[processIndex + 1]
    #expect(server["outbound"] as? String == "direct")
    // Store order: Work's OpenVPN remote, then the XHTTP server.
    #expect(server["domain"] as? [String] == ["vpn.example.org", "xhttp.example.net"])
    #expect(server["ip_cidr"] as? [String] == ["198.51.100.2/32", "198.51.100.7/32"])

    // The name must resolve to a real address, never a fake IP.
    let dns = try #require(dict(try json(output.config)["dns"]))
    let dnsRules = try #require(dns["rules"] as? [[String: Any]])
    #expect(
        dnsRules.contains {
            $0["domain"] as? [String] == ["vpn.example.org", "xhttp.example.net"]
                && $0["server"] as? String == "dns-direct"
        })

    // An IP literal server needs no name entry, only the address.
    var literal = xhttpStore()
    literal.tunnels[1].kind = .vless(realityMeta(server: "203.0.113.50"))
    let literalRules = try routeRules(generate(literal))
    #expect(literalRules[processIndex + 1]["ip_cidr"] as? [String] == ["203.0.113.50/32"])
    #expect(literalRules[processIndex + 1]["domain"] as? [String] == ["vpn.example.org"])
}

@Test func withoutAnXHTTPTunnelTheDirectRulesAreAsBefore() throws {
    let rules = try routeRules(generate(Fixtures.store()))
    let processIndex = try #require(rules.firstIndex { $0["process_path"] != nil })
    #expect(rules[processIndex]["process_path"] as? [String] == ["/x/openvpn"])
    // And without a binary path the rule stays as it was even if a tunnel needs xray.
    let noPath = try routeRules(generate(xhttpStore(), xrayPath: nil))
    let index = try #require(noPath.firstIndex { $0["process_path"] != nil })
    #expect(noPath[index]["process_path"] as? [String] == ["/x/openvpn"])
}

@Test func anXHTTPDefaultTunnelResolvesThroughItsSocksOutbound() throws {
    var store = xhttpStore()
    store.defaultTunnelID = Fixtures.homeID
    let output = generate(store)
    #expect(output.defaultTunnel?.id == Fixtures.homeID)
    let config = try json(output.config)
    let dns = try #require(dict(config["dns"]))
    let tag = "dns-\(Fixtures.home.outboundTag)"
    #expect(dns["final"] as? String == tag)
    let servers = try #require(dns["servers"] as? [[String: Any]])
    let dot = try #require(servers.first { $0["tag"] as? String == tag })
    #expect(dot["type"] as? String == "tls")
    #expect(dot["detour"] as? String == Fixtures.home.outboundTag)
}

@Test func hostResolverPreResolvesXHTTPServersOnly() {
    var store = xhttpStore()
    #expect(HostResolver.serverHosts(in: store) == ["vpn.example.org", "xhttp.example.net"])
    #expect(HostResolver.openVPNHosts(in: store) == ["vpn.example.org"])
    store.tunnels[1].kind = .vless(realityMeta(server: "203.0.113.50"))
    #expect(HostResolver.serverHosts(in: store) == ["vpn.example.org"])
    store.tunnels[1].kind = .vless(
        VLESSMeta(server: "tcp.example.net", port: 443, security: .tls))
    #expect(HostResolver.serverHosts(in: store) == ["vpn.example.org"])
    store = xhttpStore()
    store.tunnels[1].isEnabled = false
    #expect(HostResolver.serverHosts(in: store) == ["vpn.example.org"])
}

// MARK: - Goldens (fixtures/xray/<variant>/)

private func goldenVariants() -> [(String, Store, [String: [String]])] {
    var reality = xhttpStore()
    reality.tunnels[1].kind = .vless(realityMeta())
    reality.rules.append(
        Rule(pattern: "*.cdn.example.com", match: .wildcard, tunnelID: Fixtures.homeID))

    // The default tunnel is XHTTP, so the DoT detour and `route.final` go through the socks
    // outbound too.
    var tls = xhttpStore(slot: 5)
    tls.tunnels[1].kind = .vless(tlsMeta())
    tls.defaultTunnelID = Fixtures.homeID
    return [
        ("xhttp-reality", reality, ["xhttp.example.net": ["198.51.100.7"]]),
        ("xhttp-tls-extra", tls, [:]),
    ]
}

/// What was fed to the builder, recorded as `input.json` next to the outputs.
private struct XrayGoldenInput: Codable {
    var store: Store
    var vlessUUIDs: [String: String]
    var bundlePath: String
    var resolvedServerAddresses: [String: [String]]

    init(store: Store, resolved: [String: [String]]) {
        self.store = store
        // Rule ids never reach the output; number them so the record is stable across runs.
        for index in self.store.rules.indices {
            self.store.rules[index].id = UUID(
                uuidString: String(format: "00000000-0000-4000-8000-0000000001%02x", index))!
        }
        vlessUUIDs = [Fixtures.homeID.uuidString.lowercased(): xhttpUUID]
        bundlePath = bundlePathForGolden
        resolvedServerAddresses = resolved
    }

    func encoded() throws -> String {
        String(decoding: try JSONCoding.prettyEncoder.encode(self), as: UTF8.self) + "\n"
    }
}

private let bundlePathForGolden = bundlePath

private func goldenFiles(
    _ store: Store, resolved: [String: [String]]
) throws -> [String: String] {
    let input = XrayGoldenInput(store: store, resolved: resolved)
    let result = RuntimePlanBuilder.build(
        store: store,
        secrets: PlanSecrets(
            vlessUUIDs: [Fixtures.homeID: xhttpUUID],
            openVPNConfigs: [Fixtures.workID: "client\nremote vpn.example.org 1194\n"]),
        bundlePath: bundlePath, resolvedServerAddresses: resolved)
    var files = ["input.json": try input.encoded(), "sing-box.json": result.plan.singBox.config]
    for runtime in result.plan.xray {
        files["xray-\(runtime.id).json"] = runtime.config
    }
    return files
}

/// Swift-only goldens: the Dart and Go suites enumerate `fixtures/singbox/`, so XHTTP
/// variants live in `fixtures/xray/` until the Windows twin lands. Regenerate with
/// `WAYFORK_UPDATE_GOLDEN=1`.
@Test func xhttpGoldensMatch() throws {
    let root = Fixtures.url("xray")
    let update = ProcessInfo.processInfo.environment["WAYFORK_UPDATE_GOLDEN"] != nil
    for (name, store, resolved) in goldenVariants() {
        let files = try goldenFiles(store, resolved: resolved)
        let dir = root.appendingPathComponent(name)
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

/// The pinned binary is the judge of field names and values: it rejects an unknown `mode`
/// or an empty REALITY `password`, which a golden comparison alone cannot see.
@Test func theBundledXrayAcceptsTheGoldenConfigs() throws {
    let binary = Fixtures.root.deletingLastPathComponent()
        .appendingPathComponent("macos/Resources/bin/xray")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        return  // not fetched (CI): scripts/fetch-bins.sh
    }
    let root = Fixtures.url("xray")
    var checked = 0
    for (name, _, _) in goldenVariants() {
        let dir = root.appendingPathComponent(name)
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where file.hasPrefix("xray-") {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["run", "-test", "-c", dir.appendingPathComponent(file).path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(
                process.terminationStatus == 0 && text.contains("Configuration OK"),
                "xray -test rejected \(name)/\(file): \(text.suffix(400))")
            checked += 1
        }
    }
    #expect(checked == 2)
}

/// The pinned sing-box has to accept the `socks` outbound, the rule order and the DoT detour
/// through it, which only its own `check` can say.
@Test func singBoxAcceptsTheXHTTPPlans() throws {
    let binary = Fixtures.root.deletingLastPathComponent()
        .appendingPathComponent("macos/Resources/bin/sing-box")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        return  // not fetched (CI): scripts/fetch-bins.sh
    }
    for (name, store, resolved) in goldenVariants() {
        let result = RuntimePlanBuilder.build(
            store: store,
            secrets: PlanSecrets(
                vlessUUIDs: [Fixtures.homeID: xhttpUUID],
                openVPNConfigs: [Fixtures.workID: "client\nremote vpn.example.org 1194\n"]),
            bundlePath: bundlePath, resolvedServerAddresses: resolved)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wayfork-xhttp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try result.plan.singBox.config.write(
            to: dir.appendingPathComponent("sing-box.json"), atomically: true, encoding: .utf8)
        for (file, contents) in result.plan.singBox.ruleSets {
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
