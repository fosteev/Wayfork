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

// F12: while the daemon overrides the system resolver, nothing else is effective — a manual
// entry is replaced (and restored later) just like the DHCP one.

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
    #expect(manual.effectiveServers(override: tun) == [tun])
    #expect(manual.effectiveServers(override: nil) == ["8.8.8.8"])

    let manualGateway = SystemDNS.Snapshot(
        servers: ["192.168.31.1"], router: "192.168.31.1", manualServers: ["192.168.31.1"])
    #expect(manualGateway.routable(override: tun) == [tun])
    #expect(manualGateway.unroutable(override: nil) == ["192.168.31.1"])
}

// The network's own resolvers are what `dns-direct` names explicitly; the override never
// touches them (they live in `State:`, the override in `Setup:`).

@Test func networkResolversAreKeptApartFromTheEffectiveOnes() {
    let tun = "172.19.0.2"
    let on = SystemDNS.Snapshot(
        servers: [tun], router: "192.168.31.1", manualServers: [tun],
        networkServers: ["192.168.31.1"])
    #expect(on.effectiveServers(override: tun) == [tun])
    #expect(on.networkServers == ["192.168.31.1"])
    #expect(SystemDNS.Snapshot(servers: [], router: nil).networkServers.isEmpty)
}
