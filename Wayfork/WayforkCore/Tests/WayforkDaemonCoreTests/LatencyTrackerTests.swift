import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

@Test func latencyTrackerKeepsAWindowAndCountsFailures() {
    var tracker = LatencyTracker()
    let start = Date(timeIntervalSince1970: 1_000_000)
    for i in 0..<15 {
        let at = start.addingTimeInterval(Double(i) * LatencyProbe.interval)
        #expect(tracker.record(tunnel: "work", milliseconds: 50 + i, at: at) == nil)
    }
    let sample = tracker.samples["work"]!
    #expect(sample.history.count == LatencyProbe.historyLength)
    #expect(sample.history.first == 53)
    #expect(sample.milliseconds == 64)
    #expect(sample.failedInARow == 0)
    #expect(!sample.unreachable)
    #expect(sample.lastSuccess == start.addingTimeInterval(14 * LatencyProbe.interval))

    // Two failures are a blip; the third marks the tunnel unreachable, once.
    let later = start.addingTimeInterval(200)
    #expect(tracker.record(tunnel: "work", milliseconds: nil, at: later) == nil)
    #expect(tracker.record(tunnel: "work", milliseconds: nil, at: later) == nil)
    #expect(
        tracker.record(tunnel: "work", milliseconds: nil, at: later)
            == .becameUnreachable(tunnel: "work", failures: 3))
    #expect(tracker.record(tunnel: "work", milliseconds: nil, at: later) == nil)
    let down = tracker.samples["work"]!
    #expect(down.unreachable && down.failedInARow == 4 && down.milliseconds == nil)
    #expect(down.lastSuccess == sample.lastSuccess)
    #expect(down.history.suffix(4).allSatisfy { $0 == nil })

    // Recovery is reported once and clears the streak.
    #expect(
        tracker.record(tunnel: "work", milliseconds: 70, at: later)
            == .recovered(tunnel: "work", milliseconds: 70))
    #expect(tracker.record(tunnel: "work", milliseconds: 71, at: later) == nil)
    #expect(!tracker.samples["work"]!.unreachable)
}

@Test func latencyTrackerResetRetainAndClear() {
    var tracker = LatencyTracker()
    let now = Date()
    for _ in 0..<3 { tracker.record(tunnel: "lab", milliseconds: nil, at: now) }
    tracker.record(tunnel: "home", milliseconds: 180, at: now)
    #expect(tracker.samples["lab"]!.unreachable)
    tracker.resetStreak(tunnel: "lab")
    #expect(!tracker.samples["lab"]!.unreachable)
    #expect(tracker.samples["lab"]!.failedInARow == 0)
    #expect(tracker.samples["lab"]!.history.count == 3)  // the history stays
    tracker.retain(tunnels: ["home"])
    #expect(tracker.samples.keys.sorted() == ["home"])
    tracker.clear()
    #expect(tracker.samples.isEmpty)
}

@Test func clashDelayEndpointAndDecoding() throws {
    let endpoint = ClashAPIEndpoint(port: 9090, secret: "s")
    let url = endpoint.delayURL(
        outboundTag: "t-abc", probeURL: LatencyProbe.url, timeout: LatencyProbe.timeout)
    #expect(url.host == "127.0.0.1" && url.port == 9090 && url.path == "/proxies/t-abc/delay")
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.first { $0.name == "url" }?.value == "https://cp.cloudflare.com/generate_204")
    #expect(query.first { $0.name == "timeout" }?.value == "5000")
    #expect(try ClashDelay.decode(Data(#"{"delay": 62}"#.utf8)) == 62)
    #expect(throws: (any Error).self) { try ClashDelay.decode(Data(#"{"message":"x"}"#.utf8)) }
}

// MARK: - F16

@Test func clashProxyDecodingAndSelectBody() throws {
    let endpoint = ClashAPIEndpoint(port: 9090, secret: "s")
    #expect(endpoint.proxyURL(outboundTag: "g-abc").path == "/proxies/g-abc")
    let proxy = try ClashProxy.decode(
        Data(
            #"{"type":"Selector","name":"g-abc","now":"t-one","all":["t-one","t-two"],"history":[]}"#
                .utf8))
    #expect(proxy.now == "t-one" && proxy.all == ["t-one", "t-two"])
    let bare = try ClashProxy.decode(Data(#"{"type":"URLTest","name":"g-abc"}"#.utf8))
    #expect(bare.now == nil && bare.all.isEmpty)
    #expect(throws: (any Error).self) { try ClashProxy.decode(Data("[]".utf8)) }
    let body = try JSONSerialization.jsonObject(with: ClashProxy.selectBody(memberTag: "t-two"))
    #expect(body as? [String: String] == ["name": "t-two"])
}

@Test func firstLiveWantsTheFirstMemberWhoseProbePassed() {
    let samples: [String: LatencySample] = [
        "a": LatencySample(milliseconds: nil, failedInARow: 1),
        "b": LatencySample(milliseconds: 80),
        "c": LatencySample(milliseconds: 20),
    ]
    #expect(GroupSelection.wantedMember(order: ["a", "b", "c"], samples: samples) == "b")
    #expect(GroupSelection.wantedMember(order: ["c", "b"], samples: samples) == "c")
    // A member without a sample yet is not live; nothing passing leaves the selector alone.
    #expect(GroupSelection.wantedMember(order: ["a", "x"], samples: samples) == nil)
}
