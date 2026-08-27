import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let tunnelA = "aaaaaaaa-0000-0000-0000-000000000001"
private let tunnelB = "aaaaaaaa-0000-0000-0000-000000000002"

private func connection(
    _ id: String, chains: [String], up: UInt64, down: UInt64
) -> ClashConnection {
    ClashConnection(id: id, chains: chains, upload: up, download: down)
}

private let t0 = Date(timeIntervalSince1970: 1_756_140_000)

// MARK: - Clash API config

@Test func clashAPIInjectionAddsTheControllerAndKeepsTheRest() throws {
    let config = """
        {
          "log": { "level": "info" },
          "dns": { "servers": [ { "tag": "direct-dns", "address": "local" } ], "strategy": "ipv4_only" },
          "inbounds": [ { "type": "tun", "tag": "tun-in", "auto_route": true, "mtu": 1400,
                          "route_exclude_address": ["10.0.0.0/8", "224.0.0.0/4"] } ],
          "route": { "rules": [ { "protocol": "dns", "action": "hijack-dns" } ], "final": "direct" },
          "experimental": { "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true } }
        }
        """
    let endpoint = ClashAPIEndpoint(port: 41234, secret: String(repeating: "ab", count: 32))
    let injected = try ClashAPIConfig.inject(endpoint, into: config)
    let root = try #require(
        try JSONSerialization.jsonObject(with: Data(injected.utf8)) as? [String: Any])
    let experimental = try #require(root["experimental"] as? [String: Any])
    let clash = try #require(experimental["clash_api"] as? [String: Any])
    #expect(clash["external_controller"] as? String == "127.0.0.1:41234")
    #expect(clash["secret"] as? String == endpoint.secret)
    #expect(clash.count == 2)
    let cache = try #require(experimental["cache_file"] as? [String: Any])
    #expect(cache["store_fakeip"] as? Bool == true)
    #expect(cache["enabled"] as? Bool == true)
    let inbound = try #require((root["inbounds"] as? [[String: Any]])?.first)
    #expect(inbound["auto_route"] as? Bool == true)
    #expect(inbound["mtu"] as? Int == 1400)
    #expect(inbound["route_exclude_address"] as? [String] == ["10.0.0.0/8", "224.0.0.0/4"])
    #expect((root["route"] as? [String: Any])?["final"] as? String == "direct")
    #expect(!injected.contains("\\/"))
    #expect(injected.hasSuffix("\n"))
}

@Test func clashAPIInjectionCreatesExperimentalWhenMissing() throws {
    let endpoint = ClashAPIEndpoint(port: 1, secret: "s")
    let injected = try ClashAPIConfig.inject(endpoint, into: "{\"log\": {}}")
    let root = try #require(
        try JSONSerialization.jsonObject(with: Data(injected.utf8)) as? [String: Any])
    let clash = try #require(
        (root["experimental"] as? [String: Any])?["clash_api"] as? [String: Any])
    #expect(clash["external_controller"] as? String == "127.0.0.1:1")
    #expect(clash["secret"] as? String == "s")
}

@Test func clashAPIInjectionRejectsNonObjects() {
    let endpoint = ClashAPIEndpoint(port: 1, secret: "s")
    #expect(throws: ClashAPIError.notAnObject) {
        try ClashAPIConfig.inject(endpoint, into: "[1, 2]")
    }
    #expect(throws: ClashAPIError.self) {
        try ClashAPIConfig.inject(endpoint, into: "{ not json")
    }
}

@Test func clashAPIEndpointGeneration() throws {
    let endpoint = try ClashAPIEndpoint.generate()
    #expect(endpoint.port >= 1024)
    #expect(endpoint.secret.count == 64)
    let hex = endpoint.secret.allSatisfy { $0.isHexDigit }
    #expect(hex)
    #expect(endpoint.externalController == "127.0.0.1:\(endpoint.port)")
    #expect(
        endpoint.connectionsURL.absoluteString == "http://127.0.0.1:\(endpoint.port)/connections")
    #expect(ClashAPIEndpoint.randomSecret() != ClashAPIEndpoint.randomSecret())
}

/// Every golden config still passes `sing-box check` with the Clash API injected (when the
/// fetched binary is available, as in `SingBoxGeneratorTests`).
@Test func singBoxAcceptsInjectedGoldenConfigs() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binary = packageRoot.deletingLastPathComponent().appendingPathComponent(
        "Resources/bin/sing-box")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
    let goldenRoot = Fixtures.url("singbox")
    let variants = try FileManager.default.contentsOfDirectory(atPath: goldenRoot.path).sorted()
    #expect(!variants.isEmpty)
    for variant in variants {
        let source = goldenRoot.appendingPathComponent(variant)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wayfork-clash-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: dir)
        let original = try String(
            contentsOf: source.appendingPathComponent("sing-box.json"), encoding: .utf8)
        let endpoint = try ClashAPIEndpoint.generate()
        try ClashAPIConfig.inject(endpoint, into: original).write(
            to: dir.appendingPathComponent("sing-box.json"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["check", "-D", dir.path, "-c", "sing-box.json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "sing-box check failed for \(variant): \(log)")
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - /connections decoding

@Test func clashConnectionsDecodeTheFixture() throws {
    let decoded = try ClashConnections.decode(Fixtures.data("clash/connections.json"))
    #expect(decoded.connections.count == 5)
    let first = decoded.connections[0]
    #expect(first.id == "0f8a9c8e-1d2b-4c3a-9e8f-7a6b5c4d3e2f")
    #expect(first.chains == ["t-\(tunnelA)"])
    #expect(first.upload == 4096)
    #expect(first.download == 1_048_576)
    #expect(decoded.connections[4].chains == [])  // `null`
    #expect(TrafficAccumulator.Exit(chains: first.chains) == .tunnel(tunnelA))
    #expect(TrafficAccumulator.Exit(chains: ["direct"]) == .direct)
    #expect(TrafficAccumulator.Exit(chains: ["dns-out"]) == .direct)
    #expect(TrafficAccumulator.Exit(chains: []) == .direct)
    #expect(TrafficAccumulator.Exit(chains: ["direct", "t-\(tunnelB)"]) == .tunnel(tunnelB))
}

@Test func clashConnectionsTolerateNullAndNegativeCounters() throws {
    let decoded = try ClashConnections.decode(Data("{\"connections\": null}".utf8))
    #expect(decoded.connections.isEmpty)
    let odd = try ClashConnections.decode(
        Data("{\"connections\": [{\"id\": \"x\", \"upload\": -5}]}".utf8))
    #expect(odd.connections == [ClashConnection(id: "x", chains: [], upload: 0, download: 0)])
}

// MARK: - Accumulator

@Test func accumulatorAttributesTheFixtureAndRatesTheFirstSample() throws {
    let decoded = try ClashConnections.decode(Fixtures.data("clash/connections.json"))
    var accumulator = TrafficAccumulator()
    accumulator.restartConnections(at: t0)
    let snapshot = accumulator.ingest(decoded.connections, at: t0.addingTimeInterval(2))
    #expect(snapshot.interval == 2)
    #expect(snapshot.sampledAt == t0.addingTimeInterval(2))
    let a = snapshot.counters(forTunnel: tunnelA)
    #expect(a.downTotal == 1_048_576)
    #expect(a.upTotal == 4096)
    #expect(a.downBytesPerSecond == 524_288)
    #expect(a.upBytesPerSecond == 2048)
    #expect(a.connections == 1)
    let b = snapshot.counters(forTunnel: tunnelB)
    #expect(b.downTotal == 524_288)
    #expect(b.connections == 1)
    // direct + dns-out + the chain-less one
    #expect(snapshot.direct.downTotal == 65536 + 128)
    #expect(snapshot.direct.upTotal == 512 + 64)
    #expect(snapshot.direct.connections == 3)
    #expect(snapshot.counters(forTunnel: "missing") == .zero)
    #expect(snapshot.tunnels.count == 2)
}

@Test func accumulatorUsesDeltasForConnectionsSeenBefore() {
    var accumulator = TrafficAccumulator()
    accumulator.restartConnections(at: t0)
    _ = accumulator.ingest(
        [connection("c1", chains: ["t-\(tunnelA)"], up: 100, down: 1000)],
        at: t0.addingTimeInterval(1))
    let second = accumulator.ingest(
        [
            connection("c1", chains: ["t-\(tunnelA)"], up: 150, down: 1500),
            connection("c2", chains: ["direct"], up: 10, down: 20),
        ],
        at: t0.addingTimeInterval(3))
    #expect(second.interval == 2)
    let a = second.counters(forTunnel: tunnelA)
    #expect(a.downTotal == 1500)
    #expect(a.upTotal == 150)
    #expect(a.downBytesPerSecond == 250)
    #expect(a.upBytesPerSecond == 25)
    #expect(second.direct.downTotal == 20)
    #expect(second.direct.downBytesPerSecond == 10)
    #expect(second.direct.connections == 1)

    // c1 closed: nothing more is added, the rate drops to zero, totals stay.
    let third = accumulator.ingest(
        [connection("c2", chains: ["direct"], up: 10, down: 20)], at: t0.addingTimeInterval(4))
    let a3 = third.counters(forTunnel: tunnelA)
    #expect(a3.downTotal == 1500)
    #expect(a3.isIdle)
    #expect(a3.connections == 0)
    #expect(third.direct.isIdle)
    #expect(third.direct.connections == 1)
}

@Test func accumulatorTotalsSurviveRestartsAndResetOnStop() {
    var accumulator = TrafficAccumulator()
    accumulator.restartConnections(at: t0)
    _ = accumulator.ingest(
        [connection("c1", chains: ["t-\(tunnelA)"], up: 100, down: 1000)],
        at: t0.addingTimeInterval(1))

    // sing-box restarted: the same id reappears with smaller counters → counted in full.
    accumulator.restartConnections(at: t0.addingTimeInterval(5))
    let afterRestart = accumulator.ingest(
        [connection("c1", chains: ["t-\(tunnelA)"], up: 5, down: 50)],
        at: t0.addingTimeInterval(6))
    #expect(afterRestart.interval == 1)
    #expect(afterRestart.counters(forTunnel: tunnelA).downTotal == 1050)
    #expect(afterRestart.counters(forTunnel: tunnelA).downBytesPerSecond == 50)

    accumulator.reset()
    accumulator.restartConnections(at: t0.addingTimeInterval(10))
    let fresh = accumulator.ingest([], at: t0.addingTimeInterval(11))
    #expect(fresh.tunnels.isEmpty)
    #expect(fresh.direct == .zero)
}

@Test func accumulatorHandlesReusedIDsAndExitChanges() {
    var accumulator = TrafficAccumulator()
    accumulator.restartConnections(at: t0)
    _ = accumulator.ingest(
        [connection("c1", chains: ["t-\(tunnelA)"], up: 100, down: 1000)],
        at: t0.addingTimeInterval(1))
    // Counter went backwards under the same id: treated as a new connection.
    let reused = accumulator.ingest(
        [connection("c1", chains: ["t-\(tunnelA)"], up: 10, down: 20)],
        at: t0.addingTimeInterval(2))
    #expect(reused.counters(forTunnel: tunnelA).downTotal == 1020)
    // Same id now on another exit: full count on the new exit, nothing on the old one.
    let moved = accumulator.ingest(
        [connection("c1", chains: ["direct"], up: 10, down: 30)], at: t0.addingTimeInterval(3))
    #expect(moved.counters(forTunnel: tunnelA).downTotal == 1020)
    #expect(moved.counters(forTunnel: tunnelA).isIdle)
    #expect(moved.direct.downTotal == 30)
}

@Test func accumulatorWithoutAStartTimeReportsZeroRates() {
    var accumulator = TrafficAccumulator()
    let snapshot = accumulator.ingest(
        [connection("c1", chains: ["direct"], up: 1, down: 2)], at: t0)
    #expect(snapshot.interval == 0)
    #expect(snapshot.direct.isIdle)
    #expect(snapshot.direct.downTotal == 2)
}

@Test func trafficSnapshotRoundTripsThroughTheCodec() throws {
    let snapshot = TrafficSnapshot(
        sampledAt: t0, interval: 1,
        tunnels: [tunnelA: TrafficCounters(downBytesPerSecond: 1.5, downTotal: 3, connections: 2)],
        direct: TrafficCounters(upBytesPerSecond: 2, upTotal: 4))
    let data = try XPCCodec.encode(snapshot)
    #expect(try XPCCodec.decode(TrafficSnapshot.self, from: data) == snapshot)
}
