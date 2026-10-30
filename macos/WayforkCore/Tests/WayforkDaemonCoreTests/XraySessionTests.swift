import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let idA = "bbbbbbbb-0000-4000-8000-000000000001"
private let idB = "bbbbbbbb-0000-4000-8000-000000000002"
private let openVPNID = "bbbbbbbb-0000-4000-8000-0000000000ff"

private func reducer(port: Int = 47100) -> XraySessionReducer {
    XraySessionReducer(context: .init(id: idA, port: port))
}

private func logs(_ effects: [XraySessionReducer.Effect]) -> [(LogLevel, String)] {
    effects.compactMap {
        if case .log(let level, let message) = $0 { return (level, message) }
        return nil
    }
}

// Lines as the pinned xray 26.10.29 prints them on stdout (captured 2026-10-30).
private let banner = "Xray 26.10.29 (Xray, Penetrates Everything.) 0afec66 (go1.27.3 darwin/arm64)"
private let readingConfig =
    "2026/10/30 09:38:51.448304 [Info] infra/conf/serial: Reading config: &{Name:/x.json Format:json}"
private let started = "2026/10/30 09:38:51.451616 [Warning] core: Xray 26.10.29 started"
private let bindFailure =
    "Failed to start: app/proxyman/inbound: failed to listen TCP on 47100 > transport/internet: failed to listen on address: 127.0.0.1:47100 > listen tcp 127.0.0.1:47100: bind: address already in use"

// MARK: - Reducer

@Test func xrayIsConnectedOnlyAfterItsStartedLine() {
    var r = reducer()
    let start = r.handle(.processStarted(attempt: 1))
    #expect(r.state == .connecting(attempt: 1))
    #expect(logs(start).map(\.1) == ["xray started (attempt 1, 127.0.0.1:47100)"])

    // The banner and the config line arrive before the inbound listens.
    _ = r.handle(.processLine(banner))
    _ = r.handle(.processLine(readingConfig))
    // A warning that is not the started line does not count either.
    _ = r.handle(
        .processLine("2026/10/30 09:38:51.450000 [Warning] core: Xray 26.10.29 deprecated"))
    #expect(r.state == .connecting(attempt: 1))

    let now = Date(timeIntervalSince1970: 1_000)
    let up = r.handle(.processLine(started), now: now)
    #expect(r.state == .connected(since: now, ip: nil, interface: "127.0.0.1:47100"))
    #expect(logs(up).map(\.0) == [.warning])
}

@Test func xrayLogLinesLoseTheirTimestampAndKeepTheirLevel() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    let cases: [(String, LogLevel, String)] = [
        (readingConfig, .info, "infra/conf/serial: Reading config: &{Name:/x.json Format:json}"),
        ("2026/10/30 09:40:00.000001 [Error] app/x: boom", .error, "app/x: boom"),
        ("2026/10/30 09:40:00.000001 [Debug] app/x: detail", .debug, "app/x: detail"),
        ("2026/10/30 09:40:00.000001 [Warning] app/x: odd", .warning, "app/x: odd"),
        (banner, .info, banner),
        (bindFailure, .error, bindFailure),
        ("panic: runtime error: index", .error, "panic: runtime error: index"),
    ]
    for (line, level, message) in cases {
        let got = logs(r.handle(.processLine(line)))
        #expect(got.count == 1, "\(line)")
        #expect(got.first?.0 == level, "\(line)")
        #expect(got.first?.1 == message, "\(line)")
    }
}

@Test func aBindFailureIsTransientAndBecomesTheReconnectReason() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.processLine(banner))
    _ = r.handle(.processLine(bindFailure))
    let exit = r.handle(.processExited(.exited(status: 255)))
    #expect(exit.contains(.exited))
    #expect(logs(exit).map(\.1) == ["xray exited (exit status 255)"])

    _ = r.handle(.restartScheduled(attempt: 2, nextIn: 2))
    #expect(r.state == .reconnecting(attempt: 2, nextIn: 2, reason: bindFailure))
    #expect(r.attempt == 2)

    // The next attempt starts clean: no stale reason carried into the following exit.
    _ = r.handle(.processStarted(attempt: 2))
    #expect(r.state == .connecting(attempt: 2))
    _ = r.handle(.processExited(.signaled(signal: 9)))
    _ = r.handle(.restartScheduled(attempt: 3, nextIn: 4))
    #expect(r.state == .reconnecting(attempt: 3, nextIn: 4, reason: "signal 9"))
}

@Test func aCrashAfterConnectingIsReportedWithTheExitAsReason() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.processLine(started))
    #expect(r.state.isConnected)
    _ = r.handle(.processExited(.exited(status: 2)))
    _ = r.handle(.restartScheduled(attempt: 1, nextIn: 1))
    #expect(r.state == .reconnecting(attempt: 1, nextIn: 1, reason: "exit status 2"))
}

@Test func xrayWithoutAutoReconnectFailsNonPermanently() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.processExited(.exited(status: 1)))
    let effects = r.handle(.retriesDisabled)
    #expect(r.state == .failed(reason: XraySessionReducer.exitedReason, permanent: false))
    #expect(XraySessionReducer.exitedReason == "xray.exited")
    #expect(logs(effects).map(\.0) == [.warning])
}

// MARK: - Reconcile

private func xray(_ id: String, port: Int = 47100, config: String = "{\"a\":1}") -> XrayRuntime {
    XrayRuntime(id: id, port: port, config: config)
}

private func plan(_ xray: [XrayRuntime], openVPN: [OpenVPNRuntime] = []) -> RuntimePlan {
    RuntimePlan(singBox: SingBoxPlan(config: "{}", ruleSets: [:]), openVPN: openVPN, xray: xray)
}

@Test func reconcileDiffsXrayByConfigHash() {
    let a = xray(idA)
    let b = xray(idB, port: 47101, config: "{\"b\":1}")
    let p = plan([a, b])

    let cold = ReconcilePlanner.plan(from: ReconcileState(), to: p)
    #expect(cold.startXray == [idA, idB])
    #expect(cold.stopXray.isEmpty)
    #expect(cold.startOpenVPN.isEmpty && cold.stopOpenVPN.isEmpty)

    let current = ReconcileState(
        singBoxRunning: true, singBoxConfigHash: p.singBox.configHash,
        xray: [idA: a.configHash, idB: b.configHash])
    #expect(ReconcilePlanner.plan(from: current, to: p).isNoOp)

    // A's config changed (new server, new port, …): restart A only.
    let changed = ReconcilePlanner.plan(
        from: current, to: plan([xray(idA, config: "{\"a\":2}"), b]))
    #expect(changed.stopXray == [idA])
    #expect(changed.startXray == [idA])
    #expect(!changed.isNoOp)

    // B removed: stop B, nothing starts.
    let removed = ReconcilePlanner.plan(from: current, to: plan([a]))
    #expect(removed.stopXray == [idB])
    #expect(removed.startXray.isEmpty)
    #expect(!removed.isNoOp)

    // The xray config has a fixed log level: a plan log level change leaves it running.
    var verbose = p
    verbose.logLevel = .debug
    #expect(ReconcilePlanner.plan(from: current, to: verbose).isNoOp)
}

@Test func xrayAndOpenVPNDiffsDoNotMix() {
    let ovpn = OpenVPNRuntime(id: openVPNID, interface: "utun101", config: "remote x")
    let a = xray(idA)
    let p = plan([a], openVPN: [ovpn])
    let current = ReconcileState(
        singBoxRunning: true, singBoxConfigHash: p.singBox.configHash,
        openVPN: [openVPNID: OpenVPNArguments.diffKey(for: ovpn, logLevel: p.logLevel)])
    let actions = ReconcilePlanner.plan(from: current, to: p)
    #expect(actions.startXray == [idA])
    #expect(actions.stopOpenVPN.isEmpty && actions.startOpenVPN.isEmpty)

    // An OpenVPN-only plan stops a running xray and leaves OpenVPN alone.
    var both = current
    both.xray = [idA: a.configHash]
    let dropped = ReconcilePlanner.plan(from: both, to: plan([], openVPN: [ovpn]))
    #expect(dropped.stopXray == [idA])
    #expect(dropped.stopOpenVPN.isEmpty && dropped.startOpenVPN.isEmpty)
}

// MARK: - Files and argv

@Test func xrayRunFilesAreTransientAndItsPIDFileIsFound() {
    #expect(RunLayout.xrayConfig(idA) == "t-\(idA).xray.json")
    #expect(RunLayout.xrayPID(idA) == "t-\(idA).xray.pid")
    #expect(RunLayout.xrayPID(idA) != RunLayout.openVPNPID(idA))
    #expect(RunLayout.isTransient(RunLayout.xrayConfig(idA)))
    #expect(RunLayout.isPIDFile(RunLayout.xrayPID(idA)))
    #expect(!RunLayout.isRuleSet(RunLayout.xrayConfig(idA)))
}

@Test func xrayLogSourceMapsToItsFileAndBack() {
    #expect(XraySessionReducer.source(for: idA) == "xray:\(idA)")
    #expect(RunLayout.childLog(source: "xray:\(idA)") == "xray-\(idA).log")
    for source in ["xray:\(idA)", "openvpn:\(idA)", "sing-box", "daemon"] {
        let stem = String(RunLayout.childLog(source: source).dropLast(".log".count))
        #expect(RunLayout.source(forChildLogStem: stem) == source, "\(source)")
    }
}

@Test func xrayArgvRunsTheConfigInTheRunDirectory() {
    let run = "/Library/Application Support/Wayfork/run"
    #expect(
        XrayArguments.arguments(for: xray(idA), runDirectory: run) == [
            "run", "-c", "\(run)/t-\(idA).xray.json",
        ])
}

// MARK: - App/daemon agreement on the log source (stage 4b)

@Test func appLogSourceMatchesTheDaemonsXraySourceKey() {
    let tunnel = Tunnel(
        name: "X", slot: 0,
        kind: .vless(
            VLESSMeta(
                server: "xhttp.example.net", port: 443, security: .tls, sni: "xhttp.example.net",
                transport: .xhttp(path: "/", host: nil, mode: nil, extra: nil))))
    #expect(
        tunnel.logSource
            == XraySessionReducer.source(for: tunnel.id.uuidString.lowercased()))
}
