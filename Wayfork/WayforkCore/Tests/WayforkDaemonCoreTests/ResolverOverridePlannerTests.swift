import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

// docs/design/05-daemon.md, "System resolver override" (F12).

private let tun = "172.19.0.1"
private let wifi = "104C30BD-0000-0000-0000-000000000001"
private let ethernet = "104C30BD-0000-0000-0000-000000000002"
private let dhcp = ResolverEntry(
    serverAddresses: ["192.168.31.1"], searchDomains: ["lan"], domainName: "lan")
private let ours = ResolverEntry(serverAddresses: [tun], searchDomains: ["lan"], domainName: "lan")

private func plan(
    active: Bool = true, primary: String? = wifi, state: ResolverEntry? = dhcp,
    manual: [String] = [], saved: ResolverOverrideRecord? = nil
) -> (actions: [ResolverOverrideAction], state: ResolverOverrideState) {
    ResolverOverridePlanner.plan(
        active: active,
        snapshot: ResolverSnapshot(
            primaryService: primary, stateEntry: state, manualServers: manual),
        saved: saved, address: tun)
}

@Test func firstActivationSavesTheDHCPEntryAndWritesTheTUNAddress() {
    let result = plan()
    #expect(
        result.actions == [
            .write(
                service: wifi, entry: ours,
                record: ResolverOverrideRecord(service: wifi, original: dhcp))
        ])
    #expect(result.state == .active(service: wifi))
}

@Test func anAbsentEntryIsRememberedAsAbsent() {
    let result = plan(state: nil)
    #expect(
        result.actions == [
            .write(
                service: wifi, entry: ResolverEntry(serverAddresses: [tun]),
                record: ResolverOverrideRecord(service: wifi, original: nil))
        ])
}

@Test func aConsistentOverrideNeedsNothing() {
    let saved = ResolverOverrideRecord(service: wifi, original: dhcp)
    let result = plan(state: ours, saved: saved)
    #expect(result.actions.isEmpty)
    #expect(result.state == .active(service: wifi))
}

@Test func aConfigdRewriteBecomesTheNewOriginal() {
    let saved = ResolverOverrideRecord(service: wifi, original: dhcp)
    let renewed = ResolverEntry(serverAddresses: ["192.168.31.5"], searchDomains: ["home"])
    let result = plan(state: renewed, saved: saved)
    #expect(
        result.actions == [
            .write(
                service: wifi,
                entry: ResolverEntry(serverAddresses: [tun], searchDomains: ["home"]),
                record: ResolverOverrideRecord(service: wifi, original: renewed))
        ])
}

@Test func aNewPrimaryServiceRestoresTheOldOneFirst() {
    let saved = ResolverOverrideRecord(service: wifi, original: dhcp)
    let wired = ResolverEntry(serverAddresses: ["10.0.0.1"])
    let result = plan(primary: ethernet, state: wired, saved: saved)
    #expect(
        result.actions == [
            .restore(saved),
            .write(
                service: ethernet, entry: ResolverEntry(serverAddresses: [tun]),
                record: ResolverOverrideRecord(service: ethernet, original: wired)),
        ])
    #expect(result.state == .active(service: ethernet))
}

@Test func manualDNSIsReportedAsShadowingButStillWritten() {
    let result = plan(manual: ["8.8.8.8"])
    #expect(result.actions.count == 1)
    #expect(result.state == .shadowed(manual: ["8.8.8.8"]))
}

@Test func deactivationRestoresOnlyWhatWasSaved() {
    #expect(plan(active: false).actions.isEmpty)
    #expect(plan(active: false).state == .off)
    let saved = ResolverOverrideRecord(service: wifi, original: dhcp)
    #expect(plan(active: false, state: ours, saved: saved).actions == [.restore(saved)])
}

@Test func networkDownRestoresAndFails() {
    let saved = ResolverOverrideRecord(service: wifi, original: dhcp)
    let result = plan(primary: nil, state: nil, saved: saved)
    #expect(result.actions == [.restore(saved)])
    #expect(result.state == .failed(reason: "no primary network service"))
    #expect(plan(primary: nil, state: nil).actions.isEmpty)
}

@Test func theRecordRoundTripsThroughJSON() throws {
    let record = ResolverOverrideRecord(service: wifi, original: dhcp)
    let data = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(ResolverOverrideRecord.self, from: data) == record)
    let absent = ResolverOverrideRecord(service: wifi, original: nil)
    let data2 = try JSONEncoder().encode(absent)
    #expect(try JSONDecoder().decode(ResolverOverrideRecord.self, from: data2) == absent)
}
