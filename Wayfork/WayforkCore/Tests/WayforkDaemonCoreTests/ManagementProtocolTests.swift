import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

@Test func parsesStateNotifications() {
    let connected = ManagementProtocol.parse(
        ">STATE:1724592000,CONNECTED,SUCCESS,10.8.0.2,203.0.113.1,1194,192.168.1.5,54321,,")
    #expect(
        connected
            == .state(
                ManagementState(
                    time: 1_724_592_000, name: "CONNECTED", description: "SUCCESS",
                    tunnelIP: "10.8.0.2", remoteIP: "203.0.113.1")))
    #expect(
        ManagementProtocol.parse(">STATE:1724592001,RECONNECTING,connection-reset,,,,,")
            == .state(
                ManagementState(
                    time: 1_724_592_001, name: "RECONNECTING", description: "connection-reset")))
    #expect(
        ManagementProtocol.parse(">STATE:1724592002,WAIT,,,,,,")
            == .state(ManagementState(time: 1_724_592_002, name: "WAIT")))
}

@Test func parsesLogPasswordFatalAndReplies() {
    #expect(
        ManagementProtocol.parse(">LOG:1724592000,I,TLS: Initial packet, sid=1, x=2")
            == .log(flags: "I", message: "TLS: Initial packet, sid=1, x=2"))
    #expect(
        ManagementProtocol.parse(">PASSWORD:Need 'Auth' username/password")
            == .passwordNeeded(kind: "Auth"))
    #expect(
        ManagementProtocol.parse(">PASSWORD:Need 'Private Key' password")
            == .passwordNeeded(kind: "Private Key"))
    #expect(
        ManagementProtocol.parse(">PASSWORD:Verification Failed: 'Auth'")
            == .passwordVerificationFailed(kind: "Auth"))
    #expect(
        ManagementProtocol.parse(">FATAL:Options error: Unrecognized option")
            == .fatal("Options error: Unrecognized option"))
    #expect(
        ManagementProtocol.parse(">HOLD:Waiting for hold release:0")
            == .hold("Waiting for hold release:0"))
    #expect(
        ManagementProtocol.parse(">INFO:OpenVPN Management Interface Version 5")
            == .info("OpenVPN Management Interface Version 5"))
    #expect(ManagementProtocol.parse(">BYTECOUNT:123,456") == .bytecount(in: 123, out: 456))
    #expect(
        ManagementProtocol.parse("SUCCESS: hold release succeeded")
            == .success("hold release succeeded"))
    #expect(ManagementProtocol.parse("ERROR: unknown command") == .error("unknown command"))
    #expect(ManagementProtocol.parse("END") == .other("END"))
    #expect(ManagementProtocol.parse(">NOTIFY:info,x") == .other(">NOTIFY:info,x"))
    #expect(
        ManagementProtocol.parse(">PASSWORD:Auth-Token:abc") == .other(">PASSWORD:Auth-Token:abc"))
}

@Test func logFlagsMapToLevels() {
    #expect(ManagementProtocol.level(forLogFlags: "I") == .info)
    #expect(ManagementProtocol.level(forLogFlags: "W") == .warning)
    #expect(ManagementProtocol.level(forLogFlags: "N") == .warning)
    #expect(ManagementProtocol.level(forLogFlags: "F") == .error)
    #expect(ManagementProtocol.level(forLogFlags: "D") == .debug)
    #expect(ManagementProtocol.level(forLogFlags: "") == .info)
}

@Test func extractsPushedDNS() {
    let line =
        "PUSH: Received control message: 'PUSH_REPLY,dhcp-option DNS 10.8.0.1,"
        + "route 10.8.0.0 255.255.255.0,dhcp-option DNS 10.8.0.2,dhcp-option DNS 10.8.0.1,"
        + "dhcp-option DOMAIN corp,ifconfig 10.8.0.6 255.255.255.0,peer-id 3'"
    #expect(ManagementProtocol.pushedDNS(fromLogMessage: line) == ["10.8.0.1", "10.8.0.2"])
    #expect(
        ManagementProtocol.pushedDNS(
            fromLogMessage:
                "PUSH: Received control message: 'PUSH_REPLY,ifconfig 10.8.0.6 255.255.255.0'")
            == [])
    #expect(ManagementProtocol.pushedDNS(fromLogMessage: "TLS: soft reset") == nil)
}

@Test func commandsAreQuoted() {
    #expect(ManagementCommand.username(kind: "Auth", "alice") == "username \"Auth\" \"alice\"")
    #expect(
        ManagementCommand.password(kind: "Auth", "p\"a\\s s")
            == "password \"Auth\" \"p\\\"a\\\\s s\"")
    #expect(
        ManagementCommand.password(kind: "Private Key", "pp") == "password \"Private Key\" \"pp\"")
}
