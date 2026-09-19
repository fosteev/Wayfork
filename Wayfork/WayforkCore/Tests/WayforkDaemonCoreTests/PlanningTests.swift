import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let idA = "aaaaaaaa-0000-0000-0000-000000000001"
private let idB = "aaaaaaaa-0000-0000-0000-000000000002"

private func runtime(_ id: String, interface: String = "utun101", config: String = "remote x")
    -> OpenVPNRuntime
{
    OpenVPNRuntime(id: id, interface: interface, config: config)
}

private func plan(
    _ openVPN: [OpenVPNRuntime], ruleSets: [String: String] = [:], config: String = "{}"
) -> RuntimePlan {
    RuntimePlan(singBox: SingBoxPlan(config: config, ruleSets: ruleSets), openVPN: openVPN)
}

private func reason(_ error: DaemonError?) -> String {
    if case .planInvalid(let reason) = error { return reason }
    return ""
}

private func validationError(_ plan: RuntimePlan, blockListPath: String? = nil) -> DaemonError? {
    do {
        try PlanValidator.validate(plan, blockListPath: blockListPath)
        return nil
    } catch {
        return error
    }
}

@Test func interfaceNames() {
    #expect(InterfaceName.unit(of: "utun101") == 101)
    #expect(InterfaceName.unit(of: "utun199") == 199)
    #expect(InterfaceName.unit(of: "utun99") == nil)
    #expect(InterfaceName.unit(of: "utun200") == nil)
    #expect(InterfaceName.unit(of: "utun1010") == nil)
    #expect(InterfaceName.unit(of: "en0") == nil)
    #expect(InterfaceName.unit(of: "utun1٠1") == nil)
    #expect(InterfaceName.isOpenVPNInterface("utun101"))
    #expect(InterfaceName.isOpenVPNInterface("utun132"))
    #expect(!InterfaceName.isOpenVPNInterface("utun100"))
    #expect(!InterfaceName.isOpenVPNInterface("utun133"))
    #expect(InterfaceName.isRoutable("utun100"))
}

@Test func routeCommands() throws {
    #expect(
        try RouteCommand.addScopedDefault(interface: "utun101")
            == ["-n", "add", "-inet", "default", "-ifscope", "utun101", "-interface", "utun101"])
    #expect(
        try RouteCommand.deleteScopedDefault(interface: "utun101")
            == ["-n", "delete", "-inet", "default", "-ifscope", "utun101"])
    #expect(throws: RouteCommand.Error.invalidInterface("en0; rm -rf /")) {
        try RouteCommand.addScopedDefault(interface: "en0; rm -rf /")
    }
    let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: utun100
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
    #expect(RouteCommand.interface(fromGetOutput: output) == "utun100")
    #expect(
        RouteCommand.interface(fromGetOutput: "route: writing to routing socket: not in table")
            == nil)
}

@Test func openVPNArgv() {
    let argv = OpenVPNArguments.arguments(
        for: runtime(idA), runDirectory: "/run", logLevel: .debug)
    #expect(argv.first == "--config")
    #expect(argv[1] == "/run/t-\(idA).ovpn")
    #expect(argv.contains("--route-nopull"))
    #expect(argv.contains("--management-hold"))
    #expect(argv.contains("--management-query-passwords"))
    let management = argv.firstIndex(of: "--management")!
    #expect(argv[management + 1] == "/run/t-\(idA).sock")
    #expect(argv[management + 2] == "unix")
    let verb = argv.firstIndex(of: "--verb")!
    #expect(argv[verb + 1] == "4")
    let scriptSecurity = argv.firstIndex(of: "--script-security")!
    #expect(argv[scriptSecurity + 1] == "1")
    #expect(argv.suffix(2) == ["--dns-updown", "disable"])
    #expect(!argv.contains { $0.contains("\n") || $0.isEmpty })

    #expect(
        SingBoxArguments.run(runDirectory: "/run")
            == ["run", "-D", "/run", "-c", "/run/sing-box.json"])
    #expect(SingBoxArguments.check(runDirectory: "/run").first == "check")
}

@Test func codeSigningRequirements() {
    #expect(
        CodeSigningRequirement.client(teamID: "ABCDE12345")
            == "anchor apple generic and identifier \"com.wayfork.app\" "
            + "and certificate leaf[subject.OU] = \"ABCDE12345\"")
    #expect(
        CodeSigningRequirement.binary(name: "sing-box", teamID: "ABCDE12345")
            == "anchor apple generic and identifier \"com.wayfork.bin.sing-box\" "
            + "and certificate leaf[subject.OU] = \"ABCDE12345\"")
    #expect(CodeSigningRequirement.isValidTeamID("RRXLDDNHK5"))
    #expect(!CodeSigningRequirement.isValidTeamID(""))
    #expect(!CodeSigningRequirement.isValidTeamID("$(DEVELOPMENT_TEAM)"))
}

@Test func planValidation() {
    #expect(validationError(plan([runtime(idA)], ruleSets: ["rules-t-\(idA).json": "{}"])) == nil)
    #expect(validationError(plan([], ruleSets: ["rules-direct.json": "{}"])) == nil)
    #expect(
        validationError(plan([runtime(idA)], ruleSets: ["rules-t-\(idA)-ip.json": "{}"])) == nil)
    #expect(validationError(plan([], ruleSets: ["rules-direct-ip.json": "{}"])) == nil)
    #expect(PlanValidator.ruleSetID(fromFileName: "rules-t-\(idA)-ip.json") == idA)
    #expect(
        reason(validationError(plan([], ruleSets: ["rules-t--ip.json": "{}"]))).contains(
            "rules-t-<id>.json"))
    #expect(
        reason(validationError(plan([runtime(idA), runtime(idB, interface: "utun101")])))
            .contains("used twice"))
    #expect(
        reason(validationError(plan([runtime(idA), runtime(idA, interface: "utun102")])))
            .contains("duplicate"))
    #expect(reason(validationError(plan([runtime(idA, interface: "utun100")]))).contains("outside"))
    #expect(reason(validationError(plan([runtime("../etc/passwd")]))).contains("UUID"))
    #expect(reason(validationError(plan([runtime(idA.uppercased())]))).contains("UUID"))
    #expect(reason(validationError(plan([runtime(idA, config: "")]))).contains("empty"))
    #expect(reason(validationError(plan([], config: ""))).contains("empty"))
    #expect(
        reason(validationError(plan([], ruleSets: ["../x.json": "{}"])))
            .contains("rules-t-<id>.json"))
    #expect(
        reason(validationError(plan([], ruleSets: ["rules-t-x.json": "{}"])))
            .contains("rules-t-<id>.json"))
    let big = String(repeating: "x", count: RuntimePlan.maxConfigBytes + 1)
    #expect(reason(validationError(plan([runtime(idA, config: big)]))).contains("limit"))
    #expect(reason(validationError(plan([runtime(idA, config: "a\u{0}b")]))).contains("NUL"))

    let many = (0..<(RuntimePlan.maxTunnels + 1)).map {
        runtime(
            String(format: "aaaaaaaa-0000-0000-0000-%012d", $0), interface: "utun\(101 + $0 % 32)")
    }
    #expect(reason(validationError(plan(many))).contains("exceed"))

    var wrongVersion = plan([])
    wrongVersion.version = 99
    #expect(reason(validationError(wrongVersion)).contains("version"))
}

@Test func reconcileDiff() {
    let p = plan(
        [runtime(idA), runtime(idB, interface: "utun102")],
        ruleSets: ["rules-t-\(idA).json": "A", "rules-t-\(idB).json": "B"])
    let keyA = OpenVPNArguments.diffKey(for: runtime(idA), logLevel: .info)
    let keyB = OpenVPNArguments.diffKey(for: runtime(idB, interface: "utun102"), logLevel: .info)

    // Cold start: everything starts.
    let cold = ReconcilePlanner.plan(from: ReconcileState(), to: p)
    #expect(
        cold
            == ReconcileActions(
                stopOpenVPN: [], startOpenVPN: [idA, idB], singBox: .start, staleRuleSets: []))

    // Same plan again: no-op.
    let current = ReconcileState(
        singBoxRunning: true, singBoxConfigHash: p.singBox.configHash,
        ruleSets: p.singBox.ruleSets, openVPN: [idA: keyA, idB: keyB])
    #expect(ReconcilePlanner.plan(from: current, to: p).isNoOp)

    // Rule edit: rewrite one file, no restart.
    var rules = p
    rules.singBox.ruleSets["rules-t-\(idB).json"] = "B2"
    #expect(
        ReconcilePlanner.plan(from: current, to: rules).singBox
            == .rewriteRuleSets(files: ["rules-t-\(idB).json"]))

    // Tunnel B removed: stop it, sing-box config changed → restart, stale rule-set.
    let removed = plan(
        [runtime(idA)], ruleSets: ["rules-t-\(idA).json": "A"], config: "{\"v\":2}")
    let actions = ReconcilePlanner.plan(from: current, to: removed)
    #expect(actions.stopOpenVPN == [idB])
    #expect(actions.startOpenVPN.isEmpty)
    #expect(actions.singBox == .restart)
    #expect(actions.staleRuleSets == ["rules-t-\(idB).json"])

    // Config body of A changed: restart A only.
    let changed = plan(
        [runtime(idA, config: "remote y"), runtime(idB, interface: "utun102")],
        ruleSets: p.singBox.ruleSets)
    let restart = ReconcilePlanner.plan(from: current, to: changed)
    #expect(restart.stopOpenVPN == [idA])
    #expect(restart.startOpenVPN == [idA])
    #expect(restart.singBox == .none)

    // Log level change restarts every OpenVPN process.
    var verbose = p
    verbose.logLevel = .debug
    let verboseActions = ReconcilePlanner.plan(from: current, to: verbose)
    #expect(verboseActions.stopOpenVPN == [idA, idB])
    #expect(verboseActions.startOpenVPN == [idA, idB])

    // sing-box died: start it, leave tunnels alone.
    var dead = current
    dead.singBoxRunning = false
    let revive = ReconcilePlanner.plan(from: dead, to: p)
    #expect(revive.singBox == .start)
    #expect(revive.stopOpenVPN.isEmpty && revive.startOpenVPN.isEmpty)
}

@Test func backoffAndCrashCounter() {
    var backoff = BackoffPolicy()
    #expect(backoff.nextAttempt == 1)
    #expect(backoff.nextDelay(afterUptime: .seconds(1)) == .seconds(1))
    #expect(backoff.nextDelay(afterUptime: .seconds(1)) == .seconds(2))
    #expect(backoff.nextDelay(afterUptime: .seconds(1)) == .seconds(4))
    #expect(backoff.nextAttempt == 4)
    for _ in 0..<10 { _ = backoff.nextDelay(afterUptime: .seconds(1)) }
    #expect(backoff.nextDelay(afterUptime: .seconds(1)) == .seconds(60))
    #expect(backoff.nextDelay(afterUptime: .seconds(61)) == .seconds(1))
    backoff.reset()
    #expect(backoff.failures == 0)

    var counter = CrashCounter(limit: 3, window: 60)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let hits = [0, 10, 20].map { counter.recordExit(at: t0.addingTimeInterval($0)) }
    #expect(hits == [false, false, true])
    counter.reset()
    // Three exits spread over more than the window never trip the counter.
    let spread = [100, 170, 240].map { counter.recordExit(at: t0.addingTimeInterval($0)) }
    #expect(spread == [false, false, false])
}

@Test func ringBufferKeepsNewest() {
    var ring = RingBuffer<Int>(capacity: 3)
    ring.append(contentsOf: [1, 2])
    #expect(ring.elements == [1, 2])
    ring.append(contentsOf: [3, 4, 5])
    #expect(ring.elements == [3, 4, 5])
    #expect(ring.suffix(2) == [4, 5])
    ring.append(6)
    #expect(ring.elements == [4, 5, 6])
    ring.removeAll()
    #expect(ring.isEmpty)
}

@Test func singBoxLogParsing() {
    let line = "+0300 2026-08-25 12:00:00 INFO inbound/tun[tun-in]: started"
    #expect(SingBoxLog.level(of: line) == .info)
    #expect(SingBoxLog.message(of: line) == "inbound/tun[tun-in]: started")
    #expect(
        SingBoxLog.level(of: "+0300 2026-08-25 12:00:00 WARN[123] dns: ERROR in upstream")
            == .warning)
    #expect(
        SingBoxLog.level(of: "+0300 2026-08-25 12:00:00 ERROR[123] start service: bind") == .error)
    #expect(SingBoxLog.level(of: "+0300 2026-08-25 12:00:00 FATAL start: x") == .error)
    #expect(SingBoxLog.level(of: "DEBUG[0001] router: x") == .debug)
    #expect(SingBoxLog.level(of: "panic: runtime error") == .info)
    #expect(SingBoxLog.isStartedLine("+0300 2026-08-25 12:00:00 INFO sing-box started (0.02s)"))
    #expect(
        !SingBoxLog.isStartedLine("+0300 2026-08-25 12:00:00 INFO inbound/tun[tun-in]: started"))
    #expect(SingBoxLog.message(of: "plain text") == "plain text")
}

@Test func singBoxLogStripsAnsiFromTheFixtureLines() throws {
    // sing-box 1.13.19 wraps the connection id in an ANSI colour + reset
    // (`\e[38;5;147m3216874115\e[0m`); the relay is the one place that strips it (F19
    // live check, 2026-09-19).
    let raw = try Fixtures.lines("logs/sing-box-1.13.19.log")
    #expect(raw.contains { $0.contains("\u{1B}[") })
    for line in raw {
        let level = SingBoxLog.level(of: line)
        let message = SingBoxLog.message(of: line)
        #expect(!message.contains("\u{1B}"), "escape left in: \(message)")
        #expect(level == .info)
    }
    let messengerLine = raw.first { $0.contains("outbound connection to chat.example.net") }
    #expect(
        SingBoxLog.message(of: try #require(messengerLine))
            == "[3216874115 2ms] outbound/vless[t-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa]: outbound connection to chat.example.net:5222"
    )
}

@Test func runLayoutNames() {
    #expect(RunLayout.openVPNConfig(idA) == "t-\(idA).ovpn")
    #expect(RunLayout.ruleSet(idA) == "rules-t-\(idA).json")
    #expect(RunLayout.isTransient("sing-box.json"))
    #expect(!RunLayout.isTransient("cache.db"))
    #expect(RunLayout.isPIDFile("t-\(idA).pid"))
    #expect(RunLayout.childLog(source: "openvpn:\(idA)") == "openvpn-\(idA).log")
    #expect(PlanValidator.ruleSetID(fromFileName: "rules-t-\(idA).json") == idA)
}

@Test func openVPNArgumentsPinTheUtunUnitThroughDevNode() {
    let args = OpenVPNArguments.arguments(
        for: runtime(idA, interface: "utun105"), runDirectory: "/run", logLevel: .info)
    #expect(args.contains(["--dev", "tun", "--dev-type", "tun", "--dev-node", "utun105"]))
    #expect(!args.contains(["--dev", "utun105"]))
    #expect(args.contains(["--route-nopull"]))
}

extension Array where Element == String {
    /// True when `slice` appears contiguously.
    fileprivate func contains(_ slice: [String]) -> Bool {
        guard !slice.isEmpty, count >= slice.count else { return false }
        return indices.dropLast(slice.count - 1).contains {
            self[$0..<$0 + slice.count].elementsEqual(slice)
        }
    }
}

// MARK: - F17

private func proxyConfig(_ inbounds: [(tag: String, listen: String, port: Int)]) -> String {
    let list = inbounds.map {
        #"{"type":"mixed","tag":"\#($0.tag)","listen":"\#($0.listen)","listen_port":\#($0.port)}"#
    }
    return
        #"{"inbounds":[{"type":"tun","tag":"tun-in"},\#(list.joined(separator: ","))],"route":{"rules":[{"action":"sniff"},{"inbound":["proxy-t-\#(idA)"],"outbound":"t-\#(idA)"},{"inbound":["proxy-g-\#(idB)"],"outbound":"g-\#(idB)"}]}}"#
}

@Test func localProxyInboundsAreValidated() {
    let good = proxyConfig([
        ("proxy-t-\(idA)", "127.0.0.1", 1081), ("proxy-g-\(idB)", "127.0.0.1", 1082),
    ])
    #expect(validationError(plan([], config: good)) == nil)
    let inbounds = SingBoxPlan(config: good, ruleSets: [:]).localProxyInbounds
    #expect(inbounds.map(\.port) == [1081, 1082])
    #expect(inbounds.map(\.exitID) == [idA, idB])
    #expect(inbounds[1].outboundTag == "g-\(idB)")
    #expect(
        reason(
            validationError(plan([], config: proxyConfig([("proxy-t-\(idA)", "0.0.0.0", 1081)])))
        )
        .contains("loopback"))
    #expect(
        reason(
            validationError(plan([], config: proxyConfig([("proxy-t-\(idA)", "127.0.0.1", 80)])))
        )
        .contains("range"))
    let samePort = proxyConfig([
        ("proxy-t-\(idA)", "127.0.0.1", 1081), ("proxy-g-\(idB)", "127.0.0.1", 1081),
    ])
    #expect(reason(validationError(plan([], config: samePort))).contains("two inbounds"))
    let sameExit = proxyConfig([
        ("proxy-t-\(idA)", "127.0.0.1", 1081), ("proxy-t-\(idA)", "127.0.0.1", 1082),
    ])
    #expect(reason(validationError(plan([], config: sameExit))).contains("two local proxy ports"))
    #expect(
        reason(validationError(plan([], config: proxyConfig([("socks-in", "127.0.0.1", 1081)]))))
            .contains("proxy-t-<id>"))
}

@Test func takenPortIsParsedAndStrippedFromTheConfig() throws {
    let line =
        "FATAL[0000] start service: initialize inbound/mixed[proxy-t-\(idA)]: listen tcp 127.0.0.1:1081: bind: address already in use"
    #expect(SingBoxLog.inboundBindFailure(line) == "proxy-t-\(idA)")
    #expect(SingBoxLog.inboundBindFailure("INFO[0000] sing-box started (0.02s)") == nil)
    #expect(SingBoxLog.inboundBindFailure("bind: address already in use") == nil)

    let config = proxyConfig([
        ("proxy-t-\(idA)", "127.0.0.1", 1081), ("proxy-g-\(idB)", "127.0.0.1", 1082),
    ])
    let stripped = try #require(
        LocalProxyStripper.strip(inboundTag: "proxy-t-\(idA)", from: config))
    let root = try #require(
        try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any])
    let inbounds = try #require(root["inbounds"] as? [[String: Any]])
    #expect(inbounds.map { $0["tag"] as? String } == ["tun-in", "proxy-g-\(idB)"])
    let rules = try #require((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
    #expect(rules.count == 2)
    #expect(rules[1]["outbound"] as? String == "g-\(idB)")
    #expect(LocalProxyStripper.strip(inboundTag: "proxy-t-missing", from: config) == nil)
}

// MARK: - F18

@Test func blockListPathMustBeTheBundledOne() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "wayfork-blocklist-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let present = dir.appendingPathComponent("block-ads.srs").path
    try Data().write(to: URL(fileURLWithPath: present))
    func config(_ path: String) -> String {
        #"{"route":{"rule_set":[{"type":"local","tag":"rules-direct","format":"source","path":"rules-direct.json"},{"type":"local","tag":"block-ads","format":"binary","path":"\#(path)"}]}}"#
    }
    #expect(SingBoxPlan(config: config(present), ruleSets: [:]).binaryRuleSetPaths == [present])
    #expect(SingBoxPlan(config: config(present), ruleSets: [:]).hasBlockList)
    #expect(!SingBoxPlan(config: "{}", ruleSets: [:]).hasBlockList)
    #expect(validationError(plan([], config: config(present)), blockListPath: present) == nil)
    #expect(
        reason(validationError(plan([], config: config("/etc/passwd")), blockListPath: present))
            .contains("not the bundled block list"))
    #expect(reason(validationError(plan([], config: config(present)))).contains("not the bundled"))
    let missing = dir.appendingPathComponent("gone.srs").path
    #expect(
        reason(validationError(plan([], config: config(missing)), blockListPath: missing))
            .contains("missing"))
}

@Test func blockCounterCountsMatchesUntilMidnight() {
    #expect(
        BlockCounter.isBlockedLine(
            "INFO[0012] [3924010537 0ms] router: match[3] logical(and)[rule_set=block-ads !domain_suffix=[.example.com]] => reject"
        ))
    #expect(
        BlockCounter.isBlockedLine(
            "INFO[0012] [1 0ms] dns: match[4] rule_set=block-ads => predefined"))
    #expect(
        !BlockCounter.isBlockedLine(
            "INFO[0012] [1 0ms] router: match[5] rule_set=rules-direct => direct"))
    #expect(!BlockCounter.isBlockedLine("INFO[0012] rule_set=block-ads loaded"))

    var counter = BlockCounter()
    let calendar = Calendar(identifier: .gregorian)
    let noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
    counter.record(at: noon, calendar: calendar)
    counter.record(at: noon.addingTimeInterval(60), calendar: calendar)
    #expect(counter.value(at: noon.addingTimeInterval(3600), calendar: calendar) == 2)
    let tomorrow = noon.addingTimeInterval(13 * 3600)
    #expect(counter.value(at: tomorrow, calendar: calendar) == 0)
    counter.record(at: tomorrow, calendar: calendar)
    #expect(counter.value(at: tomorrow, calendar: calendar) == 1)
    counter.reset()
    #expect(counter.value(at: tomorrow, calendar: calendar) == 0)
}
