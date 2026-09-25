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

/// The recorded 1.13.19 log (fixtures/logs/sing-box-1.13.19.log, the F19 live check of
/// 2026-09-19) is the contract: ANSI-coloured ids, no `router: match` line, an info-level
/// failure line naming its own outbound. This feeds the whole file through
/// `SingBoxLog.level(of:)` / `.message(of:)` exactly as `SingBoxEngine`'s relay does, then
/// `FailedConnections.ingest`.
@Test func failedConnectionReadsTheSingBox1_13_19LiveLogFixture() throws {
    var tracker = FailedConnections()
    for (index, raw) in try Fixtures.lines("logs/sing-box-1.13.19.log").enumerated() {
        let level = SingBoxLog.level(of: raw)
        let message = SingBoxLog.message(of: raw)
        #expect(!message.contains("\u{1B}"))
        guard FailedConnections.isInteresting(message) else { continue }
        tracker.ingest(message, level: level, at: t0.addingTimeInterval(Double(index)))
    }
    let rows = Dictionary(uniqueKeysWithValues: tracker.snapshot.map { ($0.host, $0) })
    #expect(rows.count == 2)
    let chat = try #require(rows["chat.example.net"])
    #expect(chat.processPath?.hasSuffix("Messenger") == true)
    #expect(chat.count == 1)
    #expect(chat.reason == .noAnswer)
    #expect(chat.exit == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    // `stripPort` drops the port from every host, IP literal or not (pre-existing), so the
    // game server's row is keyed by the bare address.
    let game = try #require(rows["203.0.113.40"])
    #expect(game.processPath?.hasSuffix("Game") == true)
    #expect(game.count == 1)
    #expect(game.reason == .refused)
    #expect(game.exit == "direct")
    // F20: the tunnel opens 3 times (Messenger's TCP failure, the cli's TCP success dialled
    // twice but counted once, the browser's UDP flow) and fails once; direct opens twice
    // (the browser's TCP success, the game's TCP failure) and fails once. The DNS lines
    // never join a connection (they fail `isInteresting` / `split`, having no bearing here).
    let exits = tracker.exits
    #expect(exits["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.opened == 3)
    #expect(exits["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.failed == 1)
    #expect(exits["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.lastFailure == .noAnswer)
    #expect(exits["direct"]?.opened == 2)
    #expect(exits["direct"]?.failed == 1)
    #expect(exits["direct"]?.lastFailure == .refused)
    #expect(exits["direct"]?.blocked == 0)
    #expect(exits.count == 2)
}

@Test func failedConnectionExitsNilOpenedUnderProblemsOnly() {
    // Log detail Problems: only the failure lines exist, no outbound dial line is ever
    // seen — opened stays nil for every exit and every failure is attributed to `direct`.
    var tracker = FailedConnections()
    feed(
        &tracker,
        [
            (
                .info,
                "[70 30ms] connection: open connection to a.example.net:443 using outbound/direct[direct]: dial tcp 198.51.100.2:443: connect: connection refused"
            ),
            (
                .info,
                "[71 30ms] connection: open connection to b.example.net:443 using outbound/direct[direct]: dial tcp 198.51.100.3:443: connect: connection refused"
            ),
        ])
    let exits = tracker.exits
    #expect(exits["direct"]?.opened == nil)
    #expect(exits["direct"]?.failed == 2)
    #expect(exits.count == 1)
}

@Test func failedConnectionExitsGroupTagMapsToGroupID() {
    // Not seen in the live log (roadmap risk): whether a group's outbound line names the
    // group or the member it picked. Kept as the group's own tag until a live log with a
    // group is recorded.
    var tracker = FailedConnections()
    feed(
        &tracker,
        [
            (
                .info,
                "[80 0ms] inbound/tun[tun-in]: inbound connection to 198.18.0.9:443"
            ),
            (
                .info,
                "[80 1ms] outbound/urltest[g-ccc]: outbound connection to streaming.example.com:443"
            ),
            (
                .info,
                "[80 3ms] connection: open connection to streaming.example.com:443 using outbound/urltest[g-ccc]: dial tcp 203.0.113.5:443: i/o timeout"
            ),
        ])
    let exits = tracker.exits
    #expect(exits["ccc"]?.opened == 1)
    #expect(exits["ccc"]?.failed == 1)
    #expect(exits["ccc"]?.lastFailure == .noAnswer)
    #expect(exits["ccc"]?.blocked == 0)
}

@Test func failedConnectionBlockListShapeIsUnverified() {
    // Not seen in the live log either (roadmap risk); F18's `BlockCounter` reads the same
    // shape. Kept exactly as it was pending a live line with a block-list hit.
    var tracker = FailedConnections()
    feed(
        &tracker,
        [
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
        ])
    let rows = Dictionary(uniqueKeysWithValues: tracker.snapshot.map { ($0.host, $0) })
    #expect(rows["telemetry.example.com"]?.reason == .blocked)
    #expect(rows["telemetry.example.com"]?.processPath?.hasSuffix("Game") == true)
    #expect(rows["telemetry.example.com"]?.exit == "")
    #expect(rows["ads.example.net."]?.reason == .blocked)
    #expect(tracker.exits["direct"]?.blocked == 2)
}

@Test func failedConnectionsPreFilterAndCapacity() {
    #expect(
        FailedConnections.isInteresting("[1 0ms] inbound/tun[tun-in]: inbound connection to a:1"))
    #expect(FailedConnections.isInteresting("[1 0ms] router: found process path: /x"))
    #expect(
        FailedConnections.isInteresting(
            "[1 0ms] outbound/direct[direct]: outbound connection to a:1"))
    #expect(
        FailedConnections.isInteresting(
            "[1 5.0s] connection: open connection to a:1 using outbound/direct[direct]: i/o timeout"
        ))
    #expect(!FailedConnections.isInteresting("sing-box started (0.02s)"))
    #expect(!FailedConnections.isInteresting("[1 0ms] router: some other line"))
    // Dead shapes from before the 1.13.19 fix: a bare `using` no longer means anything.
    #expect(!FailedConnections.isInteresting("[1 0ms] router: no match, using direct"))
    var tracker = FailedConnections()
    for index in 0..<(FailedHost.capacity + 5) {
        tracker.ingest(
            "[\(index) 1ms] connection: open connection to host\(index).example:443 using outbound/direct[direct]: dial tcp: i/o timeout",
            level: .info, at: t0.addingTimeInterval(Double(index)))
    }
    #expect(tracker.snapshot.count == FailedHost.capacity)
    #expect(tracker.snapshot.last?.host == "host5.example")
}
