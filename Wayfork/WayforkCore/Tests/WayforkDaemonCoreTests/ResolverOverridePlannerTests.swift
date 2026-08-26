import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

// docs/design/05-daemon.md, "System resolver override" (F12).

private let tun = "172.19.0.2"
private let wifi = "aaaaaaaa-0000-0000-0000-000000000001"
private let ethernet = "aaaaaaaa-0000-0000-0000-000000000002"
private let manual = ResolverEntry(serverAddresses: ["8.8.8.8"], searchDomains: ["corp"])
private let manualRaw = Data("<plist/>".utf8)
private let ours = ResolverEntry(serverAddresses: [tun], searchDomains: ["corp", "lan"])

private func plan(
    active: Bool = true, primary: String? = wifi, entry: ResolverEntry? = manual,
    raw: Data? = manualRaw, network: [String] = ["lan"], saved: ResolverOverrideRecord? = nil
) -> (actions: [ResolverOverrideAction], state: ResolverOverrideState) {
    ResolverOverridePlanner.plan(
        active: active,
        snapshot: ResolverSnapshot(
            primaryService: primary, entry: entry, entryRaw: raw, networkSearchDomains: network),
        saved: saved, address: tun)
}

@Test func firstActivationSavesTheManualEntryAndWritesTheResolver() {
    let result = plan()
    #expect(
        result.actions == [
            .write(
                service: wifi, entry: ours,
                record: ResolverOverrideRecord(
                    service: wifi, original: manual, originalRaw: manualRaw))
        ])
    #expect(result.state == .active(service: wifi))
}

@Test func noManualEntryIsRememberedAsNoneAndKeepsTheNetworkSearchDomain() {
    let result = plan(entry: nil, raw: nil)
    #expect(
        result.actions == [
            .write(
                service: wifi,
                entry: ResolverEntry(serverAddresses: [tun], searchDomains: ["lan"]),
                record: ResolverOverrideRecord(service: wifi, original: nil, originalRaw: nil))
        ])
}

@Test func aConsistentOverrideNeedsNothing() {
    let saved = ResolverOverrideRecord(service: wifi, original: manual, originalRaw: manualRaw)
    let result = plan(entry: ours, saved: saved)
    #expect(result.actions.isEmpty)
    #expect(result.state == .active(service: wifi))
}

@Test func aUserEditBecomesTheNewOriginal() {
    let saved = ResolverOverrideRecord(service: wifi, original: manual, originalRaw: manualRaw)
    let edited = ResolverEntry(serverAddresses: ["1.1.1.1"])
    let editedRaw = Data("<edited/>".utf8)
    let result = plan(entry: edited, raw: editedRaw, saved: saved)
    #expect(
        result.actions == [
            .write(
                service: wifi,
                entry: ResolverEntry(serverAddresses: [tun], searchDomains: ["lan"]),
                record: ResolverOverrideRecord(
                    service: wifi, original: edited, originalRaw: editedRaw))
        ])
}

@Test func aNewPrimaryServiceRestoresTheOldOneFirst() {
    let saved = ResolverOverrideRecord(service: wifi, original: manual, originalRaw: manualRaw)
    let result = plan(primary: ethernet, entry: nil, raw: nil, network: [], saved: saved)
    #expect(
        result.actions == [
            .restore(saved),
            .write(
                service: ethernet, entry: ResolverEntry(serverAddresses: [tun]),
                record: ResolverOverrideRecord(service: ethernet, original: nil, originalRaw: nil)),
        ])
    #expect(result.state == .active(service: ethernet))
}

@Test func deactivationRestoresOnlyWhatWasSaved() {
    #expect(plan(active: false).actions.isEmpty)
    #expect(plan(active: false).state == .off)
    let saved = ResolverOverrideRecord(service: wifi, original: manual, originalRaw: manualRaw)
    #expect(plan(active: false, entry: ours, saved: saved).actions == [.restore(saved)])
}

@Test func networkDownRestoresAndFails() {
    let saved = ResolverOverrideRecord(service: wifi, original: manual, originalRaw: manualRaw)
    let result = plan(primary: nil, entry: nil, raw: nil, saved: saved)
    #expect(result.actions == [.restore(saved)])
    #expect(result.state == .failed(reason: "no primary network service"))
    #expect(plan(primary: nil, entry: nil, raw: nil).actions.isEmpty)
}

@Test func theRecordRoundTripsThroughJSON() throws {
    let record = ResolverOverrideRecord(service: wifi, original: manual, originalRaw: manualRaw)
    let data = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(ResolverOverrideRecord.self, from: data) == record)
    let absent = ResolverOverrideRecord(service: wifi, original: nil)
    let data2 = try JSONEncoder().encode(absent)
    #expect(try JSONDecoder().decode(ResolverOverrideRecord.self, from: data2) == absent)
}
