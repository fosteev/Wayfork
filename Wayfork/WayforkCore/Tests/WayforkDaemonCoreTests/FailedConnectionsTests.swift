import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func feed(_ tracker: inout FailedConnections, _ lines: [(LogLevel, String)]) {
    for (index, (level, line)) in lines.enumerated() {
        tracker.ingest(line, level: level, at: t0.addingTimeInterval(Double(index)))
    }
}

@Test func failedConnectionJoinsTheLinesOfOneId() {
    var tracker = FailedConnections()
    feed(
        &tracker,
        [
            (.info, "[3921 0ms] inbound/tun[tun-in]: inbound connection to 203.0.113.9:443"),
            (.info, "[3921 1ms] router: sniffed protocol: tls, domain: cdn.gamepatch.example.net"),
            (
                .info,
                "[3921 1ms] router: found process path: /Applications/Game.app/Contents/MacOS/Game"
            ),
            (.info, "[3921 2ms] router: match[5] rule_set=rules-t-aaa => t-aaa"),
            (.info, "[3922 0ms] inbound/tun[tun-in]: inbound connection to fine.example.com:443"),
            (
                .info,
                "[3922 1ms] router: found process path: /Applications/Game.app/Contents/MacOS/Game"
            ),
            (
                .error,
                "[3921 5004ms] inbound/tun[tun-in]: open connection to cdn.gamepatch.example.net:443: dial tcp 203.0.113.9:443: i/o timeout"
            ),
            (.info, "[3930 0ms] inbound/tun[tun-in]: inbound connection to 203.0.113.9:443"),
            (.info, "[3930 1ms] router: sniffed protocol: tls, domain: cdn.gamepatch.example.net"),
            (
                .info,
                "[3930 1ms] router: found process path: /Applications/Game.app/Contents/MacOS/Game"
            ),
            (.info, "[3930 2ms] router: match[5] rule_set=rules-t-aaa => t-aaa"),
            (
                .error,
                "[3930 5002ms] inbound/tun[tun-in]: open connection to cdn.gamepatch.example.net:443: dial tcp 203.0.113.9:443: i/o timeout"
            ),
        ])
    let rows = tracker.snapshot
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.host == "cdn.gamepatch.example.net")
    #expect(row.processPath == "/Applications/Game.app/Contents/MacOS/Game")
    #expect(row.exit == "aaa")
    #expect(row.reason == .noAnswer)
    #expect(row.count == 2)
    #expect(row.lastSeen == t0.addingTimeInterval(11))
    #expect(row.id == "cdn.gamepatch.example.net|/Applications/Game.app/Contents/MacOS/Game")
    // F20: opened once per id at the match line, failed once per ERROR line, both under
    // the tunnel's exit id.
    let exits = tracker.exits
    #expect(exits["aaa"]?.opened == 2)
    #expect(exits["aaa"]?.failed == 2)
    #expect(exits["aaa"]?.blocked == 0)
    #expect(exits["aaa"]?.lastFailure == .noAnswer)
    #expect(exits["aaa"]?.lastFailedAt == t0.addingTimeInterval(11))
}

@Test func failedConnectionReasonsAndTheProblemsLevelShape() {
    var tracker = FailedConnections()
    feed(
        &tracker,
        [
            // Log detail Problems: only the error line exists — host from it, no app.
            (
                .error,
                "ERROR [40 30ms] inbound/tun[tun-in]: open connection to matchmaking.example.net:5555: dial tcp 198.51.100.2:5555: connect: connection refused"
            ),
            // A tunnel whose interface is down.
            (.info, "[41 0ms] inbound/tun[tun-in]: inbound connection to api.example.org:443"),
            (.info, "[41 1ms] router: match[2] rule_set=rules-t-bbb => t-bbb"),
            (
                .error,
                "[41 3ms] inbound/tun[tun-in]: open connection to api.example.org:443: dial tcp 198.51.100.5:443: connect: network is unreachable"
            ),
            // The same error direct is not a tunnel problem.
            (.info, "[42 0ms] inbound/tun[tun-in]: inbound connection to lan.example:80"),
            (.info, "[42 1ms] router: match[9] rule_set=rules-direct => direct"),
            (
                .error,
                "[42 3ms] inbound/tun[tun-in]: open connection to lan.example:80: dial tcp 10.0.0.9:80: connect: no route to host"
            ),
            // Blocked by the list: a route reject and a resolver answer.
            (
                .info,
                "[43 0ms] inbound/tun[tun-in]: inbound connection to telemetry.example.com:443"
            ),
            (
                .info,
                "[43 1ms] router: found process path: /Applications/Game.app/Contents/MacOS/Game"
            ),
            (
                .info,
                "[43 1ms] router: match[3] logical(and)[rule_set=block-ads !domain_suffix=[.example.org]] => reject"
            ),
            (.info, "[44 0ms] dns: exchange ads.example.net. IN A"),
            (.info, "[44 0ms] dns: match[4] rule_set=block-ads => predefined"),
            // A name that does not exist, and an unknown error.
            (
                .error,
                "[45 12ms] inbound/tun[tun-in]: open connection to nope.example.invalid:443: lookup nope.example.invalid: no such host"
            ),
            (
                .error,
                "[46 12ms] inbound/tun[tun-in]: open packet connection to game.example.net:27015: something odd happened"
            ),
            // A UDP flow and an IPv6 literal.
            (.info, "[47 0ms] inbound/tun[tun-in]: inbound packet connection to [2001:db8::1]:53"),
            (
                .error,
                "[47 9ms] inbound/tun[tun-in]: open packet connection to [2001:db8::1]:53: dial udp: i/o timeout"
            ),
            // Noise that must not count.
            (.info, "[48 0ms] inbound/tun[tun-in]: inbound connection to ok.example.com:443"),
            (.info, "[48 1ms] router: match[5] rule_set=rules-t-aaa => t-aaa"),
            (.info, "sing-box started (0.02s)"),
        ])
    let rows = Dictionary(uniqueKeysWithValues: tracker.snapshot.map { ($0.host, $0) })
    #expect(rows.count == 8)
    #expect(rows["matchmaking.example.net"]?.reason == .refused)
    #expect(rows["matchmaking.example.net"]?.processPath == nil)
    #expect(rows["matchmaking.example.net"]?.exit == "direct")
    #expect(
        rows["api.example.org"]?.reason == .tunnelDown && rows["api.example.org"]?.exit == "bbb")
    #expect(
        rows["lan.example"]?.reason == .other("dial tcp 10.0.0.9:80: connect: no route to host"))
    #expect(rows["telemetry.example.com"]?.reason == .blocked)
    #expect(rows["telemetry.example.com"]?.processPath?.hasSuffix("Game") == true)
    #expect(rows["telemetry.example.com"]?.exit == "")
    #expect(rows["ads.example.net."]?.reason == .blocked)
    #expect(rows["nope.example.invalid"]?.reason == .noSuchName)
    #expect(rows["game.example.net"]?.reason == .other("something odd happened"))
    #expect(rows["2001:db8::1"]?.reason == .noAnswer)
    #expect(rows["ok.example.com"] == nil)
    // Newest first.
    #expect(tracker.snapshot.first?.host == "2001:db8::1")
    // F20: opened only counts a routed exit (id 40/45/46/47 never saw a match line, so
    // their failures land on `direct`); blocked lines never touch opened or failed.
    let exits = tracker.exits
    #expect(exits["direct"]?.opened == 1)  // id 42's `=> direct` match line
    #expect(exits["direct"]?.failed == 5)  // id 40, 42, 45, 46, 47
    #expect(exits["direct"]?.blocked == 2)  // the block-list reject + the predefined dns
    #expect(exits["direct"]?.lastFailure == .noAnswer)  // id 47, the last error line
    #expect(exits["bbb"]?.opened == 1)
    #expect(exits["bbb"]?.failed == 1)
    #expect(exits["bbb"]?.lastFailure == .tunnelDown)
    #expect(exits["aaa"]?.opened == 1)  // id 48: routed but never failed
    #expect(exits["aaa"]?.failed == 0)
    #expect(exits["aaa"]?.blocked == 0)
    tracker.clear()
    #expect(tracker.snapshot.isEmpty)
    #expect(tracker.exits.isEmpty)
}

@Test func failedConnectionExitsNilOpenedUnderProblemsOnly() {
    // Log detail Problems: only ERROR lines exist, no match line is ever seen — opened
    // stays nil for every exit and every failure is attributed to `direct`.
    var tracker = FailedConnections()
    feed(
        &tracker,
        [
            (
                .error,
                "ERROR [70 30ms] inbound/tun[tun-in]: open connection to a.example.net:443: dial tcp 198.51.100.2:443: connect: connection refused"
            ),
            (
                .error,
                "ERROR [71 30ms] inbound/tun[tun-in]: open connection to b.example.net:443: dial tcp 198.51.100.3:443: connect: connection refused"
            ),
        ])
    let exits = tracker.exits
    #expect(exits["direct"]?.opened == nil)
    #expect(exits["direct"]?.failed == 2)
    #expect(exits.count == 1)
}

@Test func failedConnectionExitsGroupTagMapsToGroupID() {
    var tracker = FailedConnections()
    feed(
        &tracker,
        [
            (
                .info,
                "[80 0ms] inbound/tun[tun-in]: inbound connection to streaming.example.com:443"
            ),
            (.info, "[80 1ms] router: match[1] rule_set=rules-g-ccc => g-ccc"),
            (
                .error,
                "[80 3ms] inbound/tun[tun-in]: open connection to streaming.example.com:443: dial tcp 203.0.113.5:443: i/o timeout"
            ),
        ])
    let exits = tracker.exits
    #expect(exits["ccc"]?.opened == 1)
    #expect(exits["ccc"]?.failed == 1)
    #expect(exits["ccc"]?.lastFailure == .noAnswer)
    #expect(exits["ccc"]?.blocked == 0)
}

@Test func failedConnectionsPreFilterAndCapacity() {
    #expect(
        FailedConnections.isInteresting("[1 0ms] inbound/tun[tun-in]: inbound connection to a:1"))
    #expect(FailedConnections.isInteresting("[1 0ms] router: found process path: /x"))
    #expect(!FailedConnections.isInteresting("sing-box started (0.02s)"))
    #expect(!FailedConnections.isInteresting("[1 0ms] router: some other line"))
    var tracker = FailedConnections()
    for index in 0..<(FailedHost.capacity + 5) {
        tracker.ingest(
            "[\(index) 1ms] inbound/tun[tun-in]: open connection to host\(index).example:443: dial tcp: i/o timeout",
            level: .error, at: t0.addingTimeInterval(Double(index)))
    }
    #expect(tracker.snapshot.count == FailedHost.capacity)
    #expect(tracker.snapshot.last?.host == "host5.example")
}
