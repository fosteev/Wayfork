import Foundation
import Testing

@testable import WayforkCore

// docs/design/03-routing.md, "Notes on specific choices": the system resolvers are routed
// into the TUN, except the default gateway.

@Test func gatewayResolverIsNeverRoutedIntoTheTUN() {
    let home = SystemDNS.Snapshot(servers: ["192.168.31.1", "8.8.8.8"], router: "192.168.31.1")
    #expect(home.routable() == ["8.8.8.8"])
    #expect(home.unroutable() == ["192.168.31.1"])

    let pihole = SystemDNS.Snapshot(servers: ["192.168.31.5"], router: "192.168.31.1")
    #expect(pihole.routable() == ["192.168.31.5"])
    #expect(pihole.unroutable().isEmpty)

    let offline = SystemDNS.Snapshot(servers: [], router: nil)
    #expect(offline.routable().isEmpty && offline.unroutable().isEmpty)
}

// F12: while the daemon overrides the system resolver, only a manual entry stays effective.

@Test func theOverrideReplacesTheSystemResolversUnlessManualOnesExist() {
    let tun = "172.19.0.1"
    let dhcp = SystemDNS.Snapshot(servers: ["192.168.31.1"], router: "192.168.31.1")
    #expect(dhcp.effectiveServers(override: tun) == [tun])
    #expect(dhcp.routable(override: tun) == [tun])
    #expect(dhcp.unroutable(override: tun).isEmpty)
    #expect(dhcp.effectiveServers(override: nil) == ["192.168.31.1"])

    let manual = SystemDNS.Snapshot(
        servers: ["8.8.8.8"], router: "192.168.31.1", primaryService: "wifi",
        manualServers: ["8.8.8.8"])
    #expect(manual.effectiveServers(override: tun) == ["8.8.8.8"])
    #expect(manual.routable(override: tun) == ["8.8.8.8"])

    let manualGateway = SystemDNS.Snapshot(
        servers: ["192.168.31.1"], router: "192.168.31.1", manualServers: ["192.168.31.1"])
    #expect(manualGateway.routable(override: tun).isEmpty)
    #expect(manualGateway.unroutable(override: tun) == ["192.168.31.1"])
}
