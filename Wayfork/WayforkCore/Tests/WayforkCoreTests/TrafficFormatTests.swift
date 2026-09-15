import Foundation
import Testing

@testable import WayforkCore

@Test func trafficBytesUseDecimalUnitsWithFixedDigits() {
    #expect(TrafficFormat.bytes(0) == "0 B")
    #expect(TrafficFormat.bytes(999) == "999 B")
    #expect(TrafficFormat.bytes(1000) == "1.0 KB")
    #expect(TrafficFormat.bytes(1234) == "1.2 KB")
    #expect(TrafficFormat.bytes(9949) == "9.9 KB")
    #expect(TrafficFormat.bytes(9950) == "10 KB")
    #expect(TrafficFormat.bytes(85_000) == "85 KB")
    #expect(TrafficFormat.bytes(123_456) == "123 KB")
    #expect(TrafficFormat.bytes(999_400) == "999 KB")
    #expect(TrafficFormat.bytes(999_500) == "1.0 MB")
    #expect(TrafficFormat.bytes(1_200_000) == "1.2 MB")
    #expect(TrafficFormat.bytes(12_000_000) == "12 MB")
    #expect(TrafficFormat.bytes(88_000_000) == "88 MB")
    #expect(TrafficFormat.bytes(1_200_000_000) == "1.2 GB")
    #expect(TrafficFormat.bytes(3_500_000_000_000) == "3.5 TB")
    #expect(TrafficFormat.bytes(UInt64.max) == "18447 PB")  // units stop at PB
}

@Test func trafficRateAndLabels() {
    #expect(TrafficFormat.rate(0) == "0 B/s")
    #expect(TrafficFormat.rate(1234.4) == "1.2 KB/s")
    #expect(TrafficFormat.rate(-5) == "0 B/s")
    #expect(TrafficFormat.rate(.nan) == "0 B/s")
    #expect(TrafficFormat.rate(.infinity) == "0 B/s")
    let counters = TrafficCounters(
        downBytesPerSecond: 1_200_000, upBytesPerSecond: 85_000, downTotal: 1_200_000_000,
        upTotal: 88_000_000, connections: 14)
    #expect(TrafficFormat.rateLabel(counters) == "↓ 1.2 MB/s ↑ 85 KB/s")
    #expect(TrafficFormat.rateLabel(nil) == "↓ — ↑ —")
    #expect(TrafficFormat.tooltip(counters) == "Since Turn On: ↓ 1.2 GB ↑ 88 MB · 14 connections")
    #expect(
        TrafficFormat.tooltip(TrafficCounters(connections: 1))
            == "Since Turn On: ↓ 0 B ↑ 0 B · 1 connection")
    #expect(TrafficCounters.zero.isIdle)
    #expect(!counters.isIdle)
}

// MARK: - Latency (F14)

@Test func latencyBandsAndLabels() {
    #expect(LatencyBand(milliseconds: 0) == .good)
    #expect(LatencyBand(milliseconds: 100) == .good)
    #expect(LatencyBand(milliseconds: 101) == .fair)
    #expect(LatencyBand(milliseconds: 300) == .fair)
    #expect(LatencyBand(milliseconds: 301) == .poor)
    #expect(LatencyFormat.label(62) == "62 ms")
    #expect(LatencyFormat.duration(30) == "30 s")
    #expect(LatencyFormat.duration(125) == "2 min")
    #expect(LatencyFormat.duration(3900) == "1 h 05 min")
    let sample = LatencySample(
        milliseconds: 62, history: [58, 71, nil, 62], failedInARow: 0, lastSuccess: Date())
    #expect(
        LatencyFormat.tooltip(sample)
            == "Measured through the tunnel every 10 s · last 2 min: min 58, max 71 ms")
    #expect(LatencyFormat.tooltip(LatencySample()) == "Measured through the tunnel every 10 s")
    let now = Date()
    let down = LatencySample(
        history: [nil, nil, nil], failedInARow: 3, unreachable: true,
        lastSuccess: now.addingTimeInterval(-125))
    #expect(
        LatencyFormat.unreachableDetail(down, now: now) == "No answer through the tunnel for 2 min")
    let never = LatencySample(history: [nil, nil, nil], failedInARow: 3, unreachable: true)
    #expect(
        LatencyFormat.unreachableDetail(never, now: now) == "No answer through the tunnel for 30 s")
}

@Test func trafficSnapshotDecodesWithoutLatency() throws {
    let json =
        #"{"sampledAt":0,"interval":1,"tunnels":{},"direct":{"downBytesPerSecond":0,"upBytesPerSecond":0,"downTotal":0,"upTotal":0,"connections":0}}"#
    let decoded = try JSONDecoder().decode(TrafficSnapshot.self, from: Data(json.utf8))
    #expect(decoded.latency.isEmpty)
    let full = TrafficSnapshot(
        sampledAt: Date(), interval: 1, tunnels: [:], direct: .zero,
        latency: ["a": LatencySample(milliseconds: 5, history: [5])])
    let roundTrip = try JSONDecoder().decode(
        TrafficSnapshot.self, from: try JSONEncoder().encode(full))
    #expect(roundTrip.latency["a"]?.milliseconds == 5)
}

@Test func routedTunnelIDsComeFromRuleSetNames() {
    let plan = RuntimePlan(
        singBox: SingBoxPlan(
            config: "{}",
            ruleSets: [
                "rules-t-bbb.json": "", "rules-t-aaa.json": "", "rules-t-aaa-ip.json": "",
                "rules-direct.json": "", "rules-direct-ip.json": "",
            ]),
        openVPN: [], autoReconnect: true, logLevel: .info, overrideSystemDNS: true)
    #expect(plan.routedTunnelIDs == ["aaa", "bbb"])
    #expect(plan.routedGroupIDs.isEmpty)
}

@Test func routedGroupIDsAndSnapshotGroupsRoundTrip() throws {
    let plan = RuntimePlan(
        singBox: SingBoxPlan(
            config: "{}",
            ruleSets: ["rules-g-ggg.json": "", "rules-g-ggg-ip.json": "", "rules-t-aaa.json": ""]),
        openVPN: [])
    #expect(plan.routedGroupIDs == ["ggg"])
    #expect(plan.routedTunnelIDs == ["aaa"])
    let legacy =
        #"{"sampledAt":0,"interval":1,"tunnels":{},"direct":{"downBytesPerSecond":0,"upBytesPerSecond":0,"downTotal":0,"upTotal":0,"connections":0}}"#
    let decoded = try JSONDecoder().decode(TrafficSnapshot.self, from: Data(legacy.utf8))
    #expect(decoded.groups.isEmpty)
    let full = TrafficSnapshot(
        sampledAt: Date(), interval: 1, tunnels: [:], direct: .zero,
        groups: ["ggg": GroupState(activeMember: "aaa"), "hhh": GroupState()])
    let roundTrip = try JSONDecoder().decode(
        TrafficSnapshot.self, from: try JSONEncoder().encode(full))
    #expect(roundTrip.groups["ggg"]?.activeMember == "aaa")
    #expect(roundTrip.groups["hhh"] == GroupState(activeMember: nil))
}
