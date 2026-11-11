import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let firstRule = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
private let secondRule = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
private let trafficStart = Date(timeIntervalSince1970: 1_000)

private func flow(
    _ id: String, rule: UUID?, down: UInt64, up: UInt64 = 0,
    exit: String = "t-00000000-0000-4000-8000-000000000001", network: String = "tcp"
) -> ClashConnection {
    ClashConnection(
        id: id, chains: [exit], upload: up, download: down, network: network,
        matchedRule: rule.map {
            "network=\(network) rule_set=rules-r-\($0.uuidString.lowercased()) => route(\(exit))"
        } ?? "final")
}

@Test func ruleTrafficDecodesBundledSingBoxRouteDescription() throws {
    // Shape observed from bundled sing-box 1.13.19 with a loopback mixed inbound,
    // a TCP-narrowed per-row rule-set, and a streaming HTTP response (no TUN).
    let data = Data(
        #"{"connections":[{"id":"sample","chains":["direct"],"upload":73,"download":131235,"rule":"network=tcp rule_set=rules-r-00000000-0000-4000-8000-000000000101 => route(direct)","rulePayload":"","metadata":{"network":"tcp"}}]}"#
            .utf8)
    let connection = try #require(ClashConnections.decode(data).connections.first)
    #expect(connection.ruleID == firstRule.uuidString.lowercased())
    #expect(connection.download == 131_235)

    var broad = connection
    broad.matchedRule = "rule_set=rules-r-\(secondRule.uuidString) => route(direct)"
    #expect(broad.ruleID == secondRule.uuidString.lowercased())
    broad.matchedRule = "network=udp rule_set=rules-r-\(firstRule) => route(direct)"
    #expect(broad.ruleID == firstRule.uuidString.lowercased())
}

@Test func ruleTrafficNeverGuessesFromLegacyOrAmbiguousRoutes() {
    let descriptions: [String?] = [
        nil, "final", "rule_set=rules-direct => route(direct)",
        "rule_set=rules-t-\(firstRule) => route(direct)",
        "rule_set=rules-r-not-a-uuid => route(direct)",
        "rule_set=[rules-r-\(firstRule) rules-r-\(secondRule)] => route(direct)",
        "rule_set=rules-r-\(firstRule)-suffix => route(direct)",
        "!(rule_set=rules-r-\(firstRule)) => route(direct)",
        "rule_set=rules-r-\(firstRule) => reject",
        "domain=rules-r-\(firstRule) => route(direct)",
    ]
    for description in descriptions {
        var connection = flow("x", rule: firstRule, down: 10)
        connection.matchedRule = description
        #expect(connection.ruleID == nil)
    }
}

@Test func ruleRatesSeparateRowsOnSameExitAndAttributeDirectPins() throws {
    var accumulator = TrafficAccumulator()
    accumulator.restartConnections(at: trafficStart)
    let snapshot = accumulator.ingest(
        [
            flow("domain", rule: firstRule, down: 100, up: 20),
            flow("app", rule: secondRule, down: 600, up: 40),
            flow("udp", rule: firstRule, down: 50, up: 10, network: "udp"),
            flow("final", rule: nil, down: 9_000),
            flow("direct-pin", rule: secondRule, down: 200, up: 20, exit: "direct"),
        ], at: trafficStart.addingTimeInterval(2))
    let a = try #require(snapshot.counters(forRule: firstRule))
    let b = try #require(snapshot.counters(forRule: secondRule))
    #expect(a.downBytesPerSecond == 75)
    #expect(a.upBytesPerSecond == 15)
    #expect(a.connections == 2)
    #expect(b.downBytesPerSecond == 400)
    #expect(b.upBytesPerSecond == 30)
    #expect(b.connections == 2)
    #expect(snapshot.direct.downTotal == 200)
    #expect(snapshot.tunnels.values.first?.downTotal == 9_750)
    #expect(snapshot.rules?.count == 2)
}

@Test func ruleRatesUseDeltasAndDoNotReplayBytesWhenRouteChanges() throws {
    var accumulator = TrafficAccumulator()
    accumulator.restartConnections(at: trafficStart)
    _ = accumulator.ingest(
        [flow("x", rule: firstRule, down: 1_000, up: 200)],
        at: trafficStart.addingTimeInterval(1))
    let next = accumulator.ingest(
        [flow("x", rule: firstRule, down: 1_200, up: 240)],
        at: trafficStart.addingTimeInterval(3))
    #expect(next.counters(forRule: firstRule)?.downBytesPerSecond == 100)
    #expect(next.counters(forRule: firstRule)?.downTotal == 1_200)
    let moved = accumulator.ingest(
        [
            flow("x", rule: secondRule, down: 1_250, up: 250, exit: "direct")
        ], at: trafficStart.addingTimeInterval(4))
    #expect(moved.counters(forRule: firstRule)?.isIdle == true)
    #expect(moved.counters(forRule: firstRule)?.connections == 0)
    #expect(moved.counters(forRule: secondRule)?.downTotal == 50)
    #expect(moved.counters(forRule: secondRule)?.upTotal == 10)
}

@Test func ruleRatesHandleRollbackDisappearRestartAndReset() {
    var accumulator = TrafficAccumulator()
    accumulator.restartConnections(at: trafficStart)
    _ = accumulator.ingest(
        [flow("x", rule: firstRule, down: 100)],
        at: trafficStart.addingTimeInterval(1))
    let rolledBack = accumulator.ingest(
        [flow("x", rule: firstRule, down: 20)],
        at: trafficStart.addingTimeInterval(2))
    #expect(rolledBack.counters(forRule: firstRule)?.downTotal == 120)
    #expect(rolledBack.counters(forRule: firstRule)?.downBytesPerSecond == 20)
    let gone = accumulator.ingest([], at: trafficStart.addingTimeInterval(3))
    #expect(gone.counters(forRule: firstRule)?.connections == 0)
    #expect(gone.counters(forRule: firstRule)?.isIdle == true)
    #expect(gone.counters(forRule: firstRule)?.downTotal == 120)
    accumulator.restartConnections(at: trafficStart.addingTimeInterval(4))
    let restarted = accumulator.ingest(
        [flow("new", rule: firstRule, down: 30)],
        at: trafficStart.addingTimeInterval(5))
    #expect(restarted.counters(forRule: firstRule)?.downTotal == 150)
    #expect(restarted.counters(forRule: firstRule)?.downBytesPerSecond == 30)
    accumulator.reset()
    let reset = accumulator.ingest([], at: trafficStart.addingTimeInterval(6))
    #expect(reset.rules?.isEmpty == true)
    #expect(reset.counters(forRule: firstRule) == .zero)
}

@Test func ruleTrafficPayloadDistinguishesOlderHelperFromIdle() throws {
    let old = TrafficSnapshot(sampledAt: trafficStart, interval: 1, tunnels: [:], direct: .zero)
    let oldData = try XPCCodec.encode(old)
    let oldRoundTrip = try XPCCodec.decode(TrafficSnapshot.self, from: oldData)
    #expect(oldRoundTrip.counters(forRule: firstRule) == nil)
    #expect(TrafficFormat.rateLabel(oldRoundTrip.counters(forRule: firstRule)) == "↓ — ↑ —")
    var supported = old
    supported.rules = [:]
    let data = try XPCCodec.encode(supported)
    let decoded = try XPCCodec.decode(TrafficSnapshot.self, from: data)
    #expect(decoded.counters(forRule: firstRule) == .zero)
    #expect(TrafficFormat.rateLabel(decoded.counters(forRule: firstRule)) == "↓ 0 B/s ↑ 0 B/s")
    supported.rules = [firstRule.uuidString.lowercased(): TrafficCounters(downBytesPerSecond: 123)]
    let populated = try XPCCodec.decode(TrafficSnapshot.self, from: XPCCodec.encode(supported))
    #expect(populated.counters(forRule: firstRule)?.downBytesPerSecond == 123)
}
