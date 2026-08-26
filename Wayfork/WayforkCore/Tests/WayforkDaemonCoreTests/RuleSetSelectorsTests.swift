import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let tunnel = UUID()
private let file = "rules-t-x.json"

private func render(_ rules: [Rule]) -> String {
    RuleSetGenerator.render(rules: rules)
}

private func change(_ before: String, _ after: String) -> RuleSetSelectors? {
    RuleSetSelectors.change(from: [file: before], to: [file: after], files: [file])
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func changeCoversOnlyTheMatchersThatDiffer() throws {
    let before = render([Rule(pattern: "example.com", tunnelID: tunnel)])
    let after = render([
        Rule(pattern: "example.com", tunnelID: tunnel), Rule(pattern: "2ip.io", tunnelID: tunnel),
    ])
    let added = try #require(change(before, after))
    #expect(added.domain == ["2ip.io"])
    #expect(added.domainSuffix == [".2ip.io"])
    #expect(added.matches(host: "2ip.io", destinationIP: "188.40.167.81", processPath: ""))
    #expect(added.matches(host: "www.2IP.io", destinationIP: "", processPath: ""))
    #expect(!added.matches(host: "example.com", destinationIP: "", processPath: ""))
    #expect(!added.matches(host: "my2ip.io", destinationIP: "", processPath: ""))
    #expect(!added.matches(host: "", destinationIP: "188.40.167.81", processPath: ""))
    // Removing is a change too; same file twice is none.
    #expect(try #require(change(after, before)) == added)
    #expect(try #require(change(after, after)).isEmpty)
}

@Test func appWildcardAndIPMatchersCoverTheirConnections() throws {
    let empty = render([])
    let app = try #require(
        change(empty, render([Rule(pattern: "/Applications/Telegram.app", match: .app, tunnelID: tunnel)])))
    #expect(
        app.matches(
            host: "", destinationIP: "194.221.250.50",
            processPath: "/Applications/Telegram.app/Contents/MacOS/Telegram"))
    #expect(!app.matches(host: "", destinationIP: "", processPath: "/Applications/Safari.app/x"))

    let wildcard = try #require(
        change(empty, render([Rule(pattern: "*.cdn.example.com", match: .wildcard, tunnelID: tunnel)])))
    #expect(wildcard.matches(host: "a.cdn.example.com", destinationIP: "", processPath: ""))
    #expect(!wildcard.matches(host: "cdn.example.com", destinationIP: "", processPath: ""))

    let ip = try #require(
        RuleSetSelectors.change(
            from: [file: RuleSetGenerator.renderIP(rules: [])],
            to: [
                file: RuleSetGenerator.renderIP(rules: [
                    Rule(pattern: "93.184.216.0/24", match: .ip, tunnelID: tunnel)
                ])
            ],
            files: [file]))
    #expect(ip.matches(host: "", destinationIP: "93.184.216.34", processPath: ""))
    #expect(!ip.matches(host: "", destinationIP: "93.184.217.1", processPath: ""))
    #expect(!ip.matches(host: "", destinationIP: "2606:2800::1", processPath: ""))
}

@Test func onlyTheListedFilesCount() throws {
    let a = render([Rule(pattern: "a.example", tunnelID: tunnel)])
    let b = render([Rule(pattern: "b.example", tunnelID: tunnel)])
    let selectors = try #require(
        RuleSetSelectors.change(
            from: ["a.json": render([]), "b.json": render([])], to: ["a.json": a, "b.json": b],
            files: ["a.json"]))
    #expect(selectors.domain == ["a.example"])
    // A file that did not exist before counts as empty.
    let created = try #require(
        RuleSetSelectors.change(from: [:], to: ["a.json": a], files: ["a.json"]))
    #expect(created.domain == ["a.example"])
}

@Test func unexpectedFileShapesAreUnknown() {
    #expect(change("{}", render([])) == nil)
    #expect(change(render([]), #"{"version": 3, "rules": [{"port": 53}]}"#) == nil)
    #expect(change(render([]), #"{"version": 3, "rules": [{"network": "udp"}]}"#) == nil)
    #expect(change(render([]), "not json") == nil)
}

@Test func connectionMetadataIsDecoded() throws {
    let decoded = try ClashConnections.decode(fixture("clash-connections.json")).connections
    let first = try #require(decoded.first)
    #expect(first.host == "example.com")
    #expect(first.destinationIP == "198.18.0.5")
    #expect(first.processPath == "")
    #expect(decoded.contains { $0.processPath == "/Applications/Safari.app/Contents/MacOS/Safari" })
    let bare = try ClashConnections.decode(Data(#"{"connections": [{"id": "x"}]}"#.utf8))
    #expect(bare.connections.first?.host == "")
}
