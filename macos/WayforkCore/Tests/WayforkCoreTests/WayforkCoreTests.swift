import Testing

@testable import WayforkCore

@Test func identifiersMatchDaemonPlist() {
    #expect(WayforkIdentifiers.app == "com.wayfork.app")
    #expect(WayforkIdentifiers.daemon == "com.wayfork.daemon")
    #expect(WayforkIdentifiers.machService == "com.wayfork.daemon.xpc")
    #expect(WayforkIdentifiers.keychainService == "com.wayfork")
}

@Test func versionIsSemver() {
    let parts = WayforkCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
