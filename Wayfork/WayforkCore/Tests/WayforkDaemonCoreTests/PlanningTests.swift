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

private func validationError(_ plan: RuntimePlan) -> DaemonError? {
    do {
        try PlanValidator.validate(plan)
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

@Test func runLayoutNames() {
    #expect(RunLayout.openVPNConfig(idA) == "t-\(idA).ovpn")
    #expect(RunLayout.ruleSet(idA) == "rules-t-\(idA).json")
    #expect(RunLayout.isTransient("sing-box.json"))
    #expect(!RunLayout.isTransient("cache.db"))
    #expect(RunLayout.isPIDFile("t-\(idA).pid"))
    #expect(RunLayout.childLog(source: "openvpn:\(idA)") == "openvpn-\(idA).log")
    #expect(PlanValidator.ruleSetID(fromFileName: "rules-t-\(idA).json") == idA)
}
