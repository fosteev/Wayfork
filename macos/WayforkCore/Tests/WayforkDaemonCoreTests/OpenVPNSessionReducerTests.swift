import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let tunnelID = "11111111-2222-3333-4444-555555555555"

private func reducer(credentials: Credentials? = nil, keyPassphrase: String? = nil)
    -> OpenVPNSessionReducer
{
    OpenVPNSessionReducer(
        context: .init(
            id: tunnelID, interface: "utun101", credentials: credentials,
            keyPassphrase: keyPassphrase))
}

private func sends(_ effects: [OpenVPNSessionReducer.Effect]) -> [String] {
    effects.compactMap {
        if case .send(let command) = $0 { return command }
        return nil
    }
}

private func state(_ name: String, _ description: String = "", ip: String? = nil)
    -> OpenVPNSessionReducer.Input
{
    .management(.state(ManagementState(name: name, description: description, tunnelIP: ip)))
}

@Test func happyPathConnectsAddsRouteAndReportsDNS() {
    var r = reducer(credentials: Credentials(username: "u", password: "p"))
    _ = r.handle(.processStarted(attempt: 1))
    #expect(r.state == .connecting(attempt: 1))

    let hello = r.handle(.managementConnected)
    #expect(sends(hello) == ["state on", "log on", "bytecount 5", "hold release"])

    let auth = r.handle(.management(.passwordNeeded(kind: "Auth")))
    #expect(sends(auth) == ["username \"Auth\" \"u\"", "password \"Auth\" \"p\""])
    _ = r.handle(state("WAIT"))
    #expect(r.state == .connecting(attempt: 1))

    let push = r.handle(
        .management(
            .log(
                flags: "I",
                message: "PUSH: Received control message: 'PUSH_REPLY,dhcp-option DNS 10.8.0.1'")))
    #expect(push.contains(.discoveredDNS(["10.8.0.1"])))

    let now = Date()
    let connected = r.handle(state("CONNECTED", "SUCCESS", ip: "10.8.0.2"), now: now)
    #expect(r.state == .connected(since: now, ip: "10.8.0.2", interface: "utun101"))
    #expect(connected.contains(.addScopedRoute(interface: "utun101")))

    // A second CONNECTED (after openvpn's own soft reset) must not add the route twice.
    let again = r.handle(state("CONNECTED", "SUCCESS", ip: "10.8.0.2"))
    #expect(!again.contains(.addScopedRoute(interface: "utun101")))
}

@Test func everyHoldIsReleased() {
    // openvpn hibernates again after each soft restart (`--management-hold` is persistent);
    // seen 2026-08-26: after `server_poll` the process sat in hold forever.
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.managementConnected)
    let first = r.handle(.management(.hold("Waiting for hold release:0")))
    #expect(sends(first) == ["hold release"])
    _ = r.handle(state("WAIT"))
    _ = r.handle(state("RECONNECTING", "server_poll"))
    #expect(r.state == .reconnecting(attempt: 1, nextIn: 0, reason: "server_poll"))
    let again = r.handle(.management(.hold("Waiting for hold release:0")))
    #expect(sends(again) == ["hold release"])
    #expect(r.state == .reconnecting(attempt: 1, nextIn: 0, reason: "server_poll"))
}

@Test func reconnectingDropsRouteAndExitIsTransient() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.managementConnected)
    _ = r.handle(state("CONNECTED", "SUCCESS", ip: "10.8.0.2"))

    let reconnecting = r.handle(state("RECONNECTING", "ping-restart"))
    #expect(reconnecting.contains(.deleteScopedRoute(interface: "utun101")))
    #expect(r.state == .reconnecting(attempt: 1, nextIn: 0, reason: "ping-restart"))

    _ = r.handle(.managementClosed)
    let exited = r.handle(.processExited(.signaled(signal: 9)))
    #expect(exited.contains(.exited(.transient(reason: "ping-restart"))))
    #expect(!exited.contains(.deleteScopedRoute(interface: "utun101")))

    _ = r.handle(.restartScheduled(attempt: 2, nextIn: 2))
    #expect(r.state == .reconnecting(attempt: 2, nextIn: 2, reason: "ping-restart"))
    _ = r.handle(.processStarted(attempt: 2))
    #expect(r.state == .connecting(attempt: 2))
}

@Test func exitWhileConnectedRemovesRoute() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.managementConnected)
    _ = r.handle(state("CONNECTED", "SUCCESS", ip: "10.8.0.2"))
    let exited = r.handle(.processExited(.exited(status: 1)))
    #expect(exited.contains(.deleteScopedRoute(interface: "utun101")))
    #expect(exited.contains(.exited(.transient(reason: "exit status 1"))))
}

@Test func missingCredentialsIsPermanent() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.managementConnected)
    let effects = r.handle(.management(.passwordNeeded(kind: "Auth")))
    #expect(sends(effects) == ["signal SIGTERM"])
    #expect(r.state == .failed(reason: "ovpn.needsCredentials", permanent: true))
    // Later prompts are ignored while we wait for the process to die.
    #expect(sends(r.handle(.management(.passwordNeeded(kind: "Auth")))).isEmpty)
    let exited = r.handle(.processExited(.exited(status: 0)))
    #expect(exited.contains(.exited(.permanent(.needsCredentials))))
    #expect(r.state == .failed(reason: "ovpn.needsCredentials", permanent: true))
}

@Test func authRejectedAndKeyPassphraseArePermanent() {
    var r = reducer(credentials: Credentials(username: "u", password: "p"))
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.managementConnected)
    _ = r.handle(.management(.passwordVerificationFailed(kind: "Auth")))
    #expect(r.state == .failed(reason: "ovpn.authFailed", permanent: true))
    // RECONNECTING after the failure does not resurrect the tunnel.
    _ = r.handle(state("RECONNECTING", "auth-failure"))
    #expect(r.state == .failed(reason: "ovpn.authFailed", permanent: true))

    var k = reducer(keyPassphrase: "wrong")
    _ = k.handle(.processStarted(attempt: 1))
    _ = k.handle(.managementConnected)
    #expect(
        sends(k.handle(.management(.passwordNeeded(kind: "Private Key"))))
            == ["password \"Private Key\" \"wrong\""])
    _ = k.handle(.management(.fatal("Error: private key password verification failed")))
    #expect(k.state == .failed(reason: "ovpn.keyPassphrase", permanent: true))

    var n = reducer()
    _ = n.handle(.processStarted(attempt: 1))
    _ = n.handle(.managementConnected)
    _ = n.handle(.management(.passwordNeeded(kind: "Private Key")))
    #expect(n.state == .failed(reason: "ovpn.needsKeyPassphrase", permanent: true))
}

@Test func fatalClassification() {
    #expect(
        OpenVPNFailure.permanentReason(
            forFatal: "Options error: Unrecognized option or missing parameter(s) in x:1: foo")
            == .configError)
    #expect(
        OpenVPNFailure.permanentReason(forFatal: "Cannot load inline certificate file")
            == .configError)
    #expect(
        OpenVPNFailure.permanentReason(
            forFatal: "Error: private key password verification failed") == .keyPassphrase)
    #expect(OpenVPNFailure.permanentReason(forFatal: "TLS Error: TLS handshake failed") == nil)

    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    _ = r.handle(.managementConnected)
    _ = r.handle(.management(.fatal("Options error: bad")))
    #expect(r.state == .failed(reason: "ovpn.configError", permanent: true))

    var t = reducer()
    _ = t.handle(.processStarted(attempt: 1))
    _ = t.handle(.management(.fatal("TLS Error: TLS handshake failed")))
    #expect(t.state == .connecting(attempt: 1))
    let exited = t.handle(.processExited(.exited(status: 1)))
    #expect(exited.contains(.exited(.transient(reason: "TLS Error: TLS handshake failed"))))
    _ = t.handle(.retriesDisabled)
    #expect(t.state == .failed(reason: "ovpn.exited", permanent: false))
}

@Test func logLinesCarryParsedLevel() {
    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    let effects = r.handle(.management(.log(flags: "W", message: "WARNING: something")))
    #expect(effects == [.log(.warning, "WARNING: something")])
}

@Test func processOutputIsForwardedOnlyBeforeManagementIsUp() {
    #expect(OpenVPNOutput.parse("1724592000 I TLS: soft reset").flags == "I")
    #expect(OpenVPNOutput.parse("1724592000 I TLS: soft reset").message == "TLS: soft reset")
    #expect(OpenVPNOutput.parse("garbage line").flags == "")

    var r = reducer()
    _ = r.handle(.processStarted(attempt: 1))
    #expect(
        r.handle(.processLine("1724592000 I library versions: OpenSSL 3.5.8"))
            == [.log(.info, "library versions: OpenSSL 3.5.8")])
    _ = r.handle(.managementConnected)
    #expect(r.handle(.processLine("1724592000 I TLS: soft reset")).isEmpty)

    // An options error kills openvpn before the socket exists: only stdout tells us.
    var o = reducer()
    _ = o.handle(.processStarted(attempt: 1))
    let effects = o.handle(
        .processLine(
            "1724592000 F Options error: Unrecognized option or missing or extra parameter(s) in x:3: foo"
        ))
    #expect(
        effects.first
            == .log(
                .error,
                "Options error: Unrecognized option or missing or extra parameter(s) in x:3: foo"))
    #expect(o.state == .failed(reason: "ovpn.configError", permanent: true))
    let exited = o.handle(.processExited(.exited(status: 1)))
    #expect(exited.contains(.exited(.permanent(.configError))))
}

@Test func openedInterfaceMustMatchThePlannedOne() {
    var ok = reducer()
    _ = ok.handle(.processStarted(attempt: 1))
    #expect(
        ok.handle(.processLine("1724592000 I Opened utun device utun101"))
            == [.log(.info, "Opened utun device utun101")])
    #expect(ok.state != .failed(reason: "ovpn.configError", permanent: true))

    var wrong = reducer()
    _ = wrong.handle(.processStarted(attempt: 1))
    let effects = wrong.handle(.processLine("1724592000 I Opened utun device utun4"))
    #expect(effects.contains(.log(.info, "Opened utun device utun4")))
    #expect(wrong.state == .failed(reason: "ovpn.configError", permanent: true))
    #expect(
        effects.contains(
            .log(
                .error, "tunnel failed: ovpn.configError — openvpn opened utun4 instead of utun101")
        ))

    // The same line through the management interface once it is up.
    var viaManagement = reducer()
    _ = viaManagement.handle(.processStarted(attempt: 1))
    _ = viaManagement.handle(.managementConnected)
    _ = viaManagement.handle(.management(.log(flags: "I", message: "Opened utun device utun7")))
    #expect(viaManagement.state == .failed(reason: "ovpn.configError", permanent: true))
    #expect(OpenVPNOutput.openedInterface(in: "Opened utun device utun105") == "utun105")
    #expect(OpenVPNOutput.openedInterface(in: "utun device [utun4] opened") == nil)
}
