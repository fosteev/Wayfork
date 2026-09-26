import Foundation
import Testing

@testable import WayforkCore

// MARK: - GuideState

@Test func guideAutoOpensOnlyWithoutTunnelsAndNoOutcome() {
    #expect(GuideState().shouldAutoOpen(tunnelCount: 0))
    #expect(!GuideState().shouldAutoOpen(tunnelCount: 1))
    #expect(!GuideState(outcome: .finished).shouldAutoOpen(tunnelCount: 0))
    #expect(!GuideState(outcome: .skipped).shouldAutoOpen(tunnelCount: 0))
}

@Test func guideCardShowsWhileActiveNotDismissedNotAllDone() {
    #expect(!GuideState().showsCard)
    #expect(GuideState(cardActive: true).showsCard)
    #expect(!GuideState(cardActive: true, cardDismissed: true).showsCard)
    #expect(
        !GuideState(
            cardActive: true, cardDone: [.popoverRule, .cantReach, .appRule]
        ).showsCard)
    #expect(GuideState(cardActive: true, cardDone: [.popoverRule]).showsCard)
}

@Test func guideResumeStepOnlyWithoutOutcome() {
    #expect(GuideState(stoppedAt: .addVPN).resumeStep == .addVPN)
    #expect(GuideState(outcome: .finished, stoppedAt: .addVPN).resumeStep == nil)
    #expect(GuideState(outcome: .skipped, stoppedAt: .addVPN).resumeStep == nil)
    #expect(GuideState().resumeStep == nil)
}

@Test func guideStateRoundTripsThroughJSON() throws {
    let state = GuideState(
        outcome: .finished, stoppedAt: .turnOn, cardActive: true, cardDismissed: false,
        cardDone: [.cantReach, .appRule])
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(GuideState.self, from: data)
    #expect(decoded == state)
}

@Test func guideStepsCompareInRailOrder() {
    #expect(GuideStep.sites.isAfter(.addVPN))
    #expect(!GuideStep.addVPN.isAfter(.addVPN))
    #expect(!GuideStep.welcome.isAfter(.helper))
}

// MARK: - GuideTryItCheck

private func snapshot(
    at date: Date, exits: [String: ExitStats] = [:], tunnels: [String: TrafficCounters] = [:],
    recentHosts: [RecentHost] = []
) -> TrafficSnapshot {
    TrafficSnapshot(
        sampledAt: date, interval: 1, tunnels: tunnels, direct: .init(), recentHosts: recentHosts,
        exits: exits)
}

@Test func tryItProvesSitesWhenTunnelOpenedCountGrows() {
    let id = UUID()
    let start = Date()
    let baseline = snapshot(at: start, exits: [id.uuidString.lowercased(): ExitStats(opened: 2)])
    let check = GuideTryItCheck(
        tunnelID: id, mode: .onlyTheseSites, baseline: baseline, openedAt: start)
    let later = snapshot(
        at: start.addingTimeInterval(5),
        exits: [id.uuidString.lowercased(): ExitStats(opened: 3)])
    #expect(check.evaluate(latest: later, now: start.addingTimeInterval(5)).sitesProven)
    let unchanged = snapshot(
        at: start.addingTimeInterval(5),
        exits: [id.uuidString.lowercased(): ExitStats(opened: 2)])
    #expect(!check.evaluate(latest: unchanged, now: start.addingTimeInterval(5)).sitesProven)
}

@Test func tryItFallsBackToDownloadRateWithoutMatchLines() {
    let id = UUID()
    let start = Date()
    let baseline = snapshot(at: start)
    let check = GuideTryItCheck(
        tunnelID: id, mode: .onlyTheseSites, baseline: baseline, openedAt: start)
    let flowing = snapshot(
        at: start.addingTimeInterval(5),
        tunnels: [id.uuidString.lowercased(): TrafficCounters(downBytesPerSecond: 12_000)])
    #expect(check.evaluate(latest: flowing, now: start.addingTimeInterval(5)).sitesProven)
    // Past the 20 s window, the rate no longer counts on its own.
    #expect(!check.evaluate(latest: flowing, now: start.addingTimeInterval(25)).sitesProven)
}

@Test func tryItFindsOtherHostAfterBaselineOnly() {
    let id = UUID()
    let start = Date()
    let stale = RecentHost(
        host: "old.example.com", exit: "direct", lastSeen: start.addingTimeInterval(-5))
    let baseline = snapshot(at: start, recentHosts: [stale])
    let check = GuideTryItCheck(
        tunnelID: id, mode: .onlyTheseSites, baseline: baseline, openedAt: start)
    let fresh = RecentHost(host: "apple.com", exit: "direct", lastSeen: start.addingTimeInterval(4))
    let later = snapshot(at: start.addingTimeInterval(5), recentHosts: [fresh, stale])
    #expect(
        check.evaluate(latest: later, now: start.addingTimeInterval(5)).otherHost == "apple.com")
}

@Test func tryItOtherHostUsesTunnelExitInExceptMode() {
    let id = UUID()
    let start = Date()
    let baseline = snapshot(at: start)
    let check = GuideTryItCheck(
        tunnelID: id, mode: .everythingExceptThese, baseline: baseline, openedAt: start)
    let viaDirect = RecentHost(
        host: "notmine.example.com", exit: "direct", lastSeen: start.addingTimeInterval(2))
    let viaTunnel = RecentHost(
        host: "generic.example.com", exit: id.uuidString.lowercased(),
        lastSeen: start.addingTimeInterval(3))
    let later = snapshot(at: start.addingTimeInterval(5), recentHosts: [viaTunnel, viaDirect])
    #expect(
        check.evaluate(latest: later, now: start.addingTimeInterval(5)).otherHost
            == "generic.example.com")
}

@Test func tryItProvesSitesThroughDirectExitInExceptMode() {
    let id = UUID()
    let start = Date()
    let baseline = snapshot(
        at: start,
        exits: ["direct": ExitStats(opened: 4), id.uuidString.lowercased(): ExitStats(opened: 9)])
    let check = GuideTryItCheck(
        tunnelID: id, mode: .everythingExceptThese, baseline: baseline, openedAt: start)
    // Only the tunnel moved: the user's sites (direct rules) are not proven yet.
    let tunnelOnly = snapshot(
        at: start.addingTimeInterval(5),
        exits: ["direct": ExitStats(opened: 4), id.uuidString.lowercased(): ExitStats(opened: 12)])
    #expect(!check.evaluate(latest: tunnelOnly, now: start.addingTimeInterval(5)).sitesProven)
    let directGrew = snapshot(
        at: start.addingTimeInterval(6),
        exits: ["direct": ExitStats(opened: 5), id.uuidString.lowercased(): ExitStats(opened: 12)])
    #expect(check.evaluate(latest: directGrew, now: start.addingTimeInterval(6)).sitesProven)
}
