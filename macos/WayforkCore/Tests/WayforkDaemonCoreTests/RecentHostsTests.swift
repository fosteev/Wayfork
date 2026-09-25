import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private func connection(
    _ id: String, chains: [String], host: String, process: String = ""
) -> ClashConnection {
    ClashConnection(
        id: id, chains: chains, upload: 1, download: 1, network: "tcp", host: host,
        processPath: process)
}

@Test func recentHostsListOnlyTheDefaultRoute() {
    var ring = RecentHosts()
    let t0 = Date(timeIntervalSince1970: 1_000)
    ring.ingest(
        [
            connection(
                "1", chains: ["t-work"], host: "news.example.com",
                process: "/A/Safari.app/Contents/MacOS/Safari"),
            connection("2", chains: ["t-home"], host: "video.example.com"),  // a rule sent it elsewhere
            connection("3", chains: ["direct"], host: "bank.example"),  // an exception
            connection("4", chains: ["t-work"], host: ""),  // bare IP: no name to list
            connection("5", chains: ["t-work"], host: "203.0.113.7"),
            connection("6", chains: ["t-work"], host: "printer.local"),
            connection("7", chains: ["t-work"], host: "registry.npmjs.org"),
        ],
        defaultExit: .tunnel("work"), at: t0)
    #expect(ring.snapshot.map(\.host) == ["registry.npmjs.org", "news.example.com"])
    #expect(ring.snapshot.map(\.exit) == ["work", "work"])
    #expect(ring.snapshot[1].processPath == "/A/Safari.app/Contents/MacOS/Safari")
    #expect(ring.snapshot[0].processPath == nil)

    // A later sighting moves the host up and keeps the process when the new one is unknown.
    let t1 = t0.addingTimeInterval(30)
    ring.ingest(
        [connection("8", chains: ["t-work"], host: "News.Example.com")],
        defaultExit: .tunnel("work"), at: t1)
    #expect(ring.snapshot.map(\.host) == ["news.example.com", "registry.npmjs.org"])
    #expect(ring.snapshot[0].lastSeen == t1)
    #expect(ring.snapshot[0].processPath == "/A/Safari.app/Contents/MacOS/Safari")

    // Without a default tunnel the default route is direct.
    var direct = RecentHosts()
    direct.ingest(
        [
            connection("1", chains: ["direct"], host: "example.org"),
            connection("2", chains: ["t-work"], host: "routed.example"),
        ], defaultExit: .direct, at: t0)
    #expect(direct.snapshot.map(\.host) == ["example.org"])
    #expect(direct.snapshot[0].exit == "direct")
    direct.clear()
    #expect(direct.snapshot.isEmpty)
}

@Test func recentHostsEvictTheOldestBeyondCapacity() {
    var ring = RecentHosts()
    let t0 = Date(timeIntervalSince1970: 1_000)
    for i in 0..<(RecentHost.capacity + 20) {
        ring.ingest(
            [connection("\(i)", chains: ["direct"], host: "h\(i).example.com")],
            defaultExit: .direct, at: t0.addingTimeInterval(Double(i)))
    }
    let hosts = ring.snapshot
    #expect(hosts.count == RecentHost.capacity)
    #expect(hosts.first?.host == "h\(RecentHost.capacity + 19).example.com")
    #expect(!hosts.contains { $0.host == "h19.example.com" })
    #expect(hosts.contains { $0.host == "h20.example.com" })
}

@Test func listableHostsAreNamesOnly() {
    #expect(RecentHosts.isListable("example.com"))
    #expect(!RecentHosts.isListable(""))
    #expect(!RecentHosts.isListable("localhost"))
    #expect(!RecentHosts.isListable("nas.lan"))
    #expect(!RecentHosts.isListable("host.home.arpa"))
    #expect(!RecentHosts.isListable("10.0.0.1"))
    #expect(!RecentHosts.isListable("2001:db8::1"))
    #expect(!RecentHosts.isListable("intranet"))  // single label: never a public site
}
