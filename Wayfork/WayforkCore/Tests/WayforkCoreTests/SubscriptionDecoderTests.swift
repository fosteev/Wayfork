import Foundation
import Testing

@testable import WayforkCore

/// `fixtures/links/subscription.json`: bodies every client decodes into the same links and
/// skipped lines, or refuses with the same error. Regenerate the recorded results with
/// `WAYFORK_UPDATE_GOLDEN=1 swift test` after an intentional change.
private struct SubscriptionFixtures: Codable {
    struct Link: Codable, Equatable {
        var line: Int
        var kind: String
        var name: String
        var server: String
        var port: Int
    }

    struct Skipped: Codable, Equatable {
        var line: Int
        var reason: String
    }

    struct Expected: Codable, Equatable {
        var links: [Link]
        var skipped: [Skipped]
    }

    struct RecordedError: Codable, Equatable {
        var `case`: String
        var message: String
    }

    struct Case: Codable {
        var name: String
        var body: String
        var expected: Expected?
        var error: RecordedError?
    }

    var cases: [Case]
}

@Test func subscriptionFixturesDecodeAsRecorded() throws {
    let update = ProcessInfo.processInfo.environment["WAYFORK_UPDATE_GOLDEN"] != nil
    let url = Fixtures.url("links/subscription.json")
    var fixtures = try JSONCoding.decoder.decode(
        SubscriptionFixtures.self, from: Data(contentsOf: url))
    for index in fixtures.cases.indices {
        let testCase = fixtures.cases[index]
        var expected: SubscriptionFixtures.Expected?
        var error: SubscriptionFixtures.RecordedError?
        do {
            let entries = try SubscriptionDecoder.decode(testCase.body)
            expected = SubscriptionFixtures.Expected(
                links: entries.compactMap { entry in
                    guard case .link(let link, let line, _) = entry else { return nil }
                    return SubscriptionFixtures.Link(
                        line: line, kind: kindName(link), name: link.name,
                        server: link.server, port: link.port)
                },
                skipped: entries.compactMap { entry in
                    guard case .skipped(let line, let reason) = entry else { return nil }
                    return SubscriptionFixtures.Skipped(line: line, reason: reason)
                })
        } catch ProxyLinkError.invalid(let message) {
            error = SubscriptionFixtures.RecordedError(case: "invalid", message: message)
        } catch ProxyLinkError.unsupported(let message) {
            error = SubscriptionFixtures.RecordedError(case: "unsupported", message: message)
        }
        if update {
            fixtures.cases[index].expected = expected
            fixtures.cases[index].error = error
        } else {
            #expect(expected == testCase.expected, "\(testCase.name)")
            #expect(error == testCase.error, "\(testCase.name)")
            #expect(testCase.expected != nil || testCase.error != nil, "\(testCase.name)")
        }
    }
    if update {
        let data = try JSONCoding.prettyEncoder.encode(fixtures)
        try (String(decoding: data, as: UTF8.self) + "\n").write(
            to: url, atomically: true, encoding: .utf8)
    }
}

@Test func subscriptionEntriesKeepTheOriginalLine() throws {
    let uri = "trojan://fake-password@tls.example.net:443#DE"
    let entries = try SubscriptionDecoder.decode("  \(uri)  \n")
    #expect(entries.count == 1)
    guard case .link(.trojan(let result), let line, let recorded) = entries[0] else {
        Issue.record("expected a trojan link")
        return
    }
    #expect(line == 1)
    #expect(recorded == uri)
    #expect(result.name == "DE")
}

@Test func subscriptionURLDetection() {
    #expect(SubscriptionDecoder.isURL(" https://example.net/sub#Name "))
    #expect(SubscriptionDecoder.isURL("HTTP://example.net/sub"))
    #expect(!SubscriptionDecoder.isURL("vless://x@example.net:443"))
    #expect(!SubscriptionDecoder.isURL(""))
}

@Test func subscriptionFetcherRefusesPlainHTTP() async {
    await #expect(throws: ProxyLinkError.unsupported("subscriptions must use https")) {
        try await SubscriptionFetcher.fetch(URL(string: "http://example.net/sub")!)
    }
}

private func kindName(_ link: ProxyLink) -> String {
    switch link {
    case .vless: "vless"
    case .shadowsocks: "shadowsocks"
    case .trojan: "trojan"
    case .vmess: "vmess"
    }
}
