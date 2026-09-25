import Foundation
import Testing

@testable import WayforkCore

// docs/design/02-ux.md, "Rules": a pasted fake IP becomes the wildcard rule of its name.

private let answer =
    "[\u{1B}[38;5;116m55455588\u{1B}[0m 29ms] dns: exchanged A jira.example.com. 600 IN A 198.18.0.57"

@Test func theIndexLearnsNamesFromSingBoxAnswers() {
    var index = FakeIPIndex()
    let first = index.ingest(answer)
    #expect(first)
    #expect(index.name(for: "198.18.0.57") == "jira.example.com")
    let cached = index.ingest("dns: cached A GitLab.Example.com. 12 IN A 198.19.255.254")
    #expect(cached)
    #expect(index.name(for: "198.19.255.254") == "gitlab.example.com")
    // Real answers, AAAA answers and unrelated lines are not fake IPs.
    for line in [
        "dns: exchanged A vpn.example.org. 300 IN A 203.0.113.9",
        "dns: exchanged AAAA jira.example.com. 600 IN AAAA 2001:db8::1",
        "outbound/direct[t-1]: outbound connection to 198.18.0.57:443",
    ] {
        let recorded = index.ingest(line)
        #expect(!recorded, "\(line)")
    }
    #expect(index.count == 2)
    #expect(index.name(for: "198.18.0.1") == nil)
}

@Test func onlySingleAddressesInsideTheFakeRangeCount() {
    #expect(FakeIPIndex.isFakeIP("198.18.0.118"))
    #expect(FakeIPIndex.isFakeIP(" 198.19.0.1 "))
    #expect(!FakeIPIndex.isFakeIP("198.18.0.0/24"))
    #expect(!FakeIPIndex.isFakeIP("198.20.0.1"))
    #expect(!FakeIPIndex.isFakeIP("example.com"))
}

@Test func siblingWildcardDropsTheHostLabelOnly() {
    #expect(RulePattern.wildcardForSiblings(of: "gitlab.example.com") == "*.example.com")
    #expect(RulePattern.wildcardForSiblings(of: "a.b.example.com") == "*.b.example.com")
    #expect(RulePattern.wildcardForSiblings(of: "Example.COM") == "example.com")
    #expect(RulePattern.wildcardForSiblings(of: "shop.example.co.uk") == "*.example.co.uk")
    #expect(RulePattern.wildcardForSiblings(of: "example.co.uk") == "example.co.uk")
    #expect(RulePattern.wildcardForSiblings(of: "www.shop.example.co.uk") == "*.shop.example.co.uk")
}

@Test func aPastedFakeIPBecomesTheWildcardOfItsName() throws {
    var index = FakeIPIndex()
    index.ingest(answer)
    #expect(
        FakeIP.translate("198.18.0.57", index: index)
            == .pattern("*.example.com", name: "jira.example.com"))
    #expect(FakeIP.translate("198.18.0.58", index: index) == .unknown("198.18.0.58"))
    #expect(FakeIP.translate("jira.example.com", index: index) == nil)
    #expect(FakeIP.translate("198.18.0.0/15", index: index) == nil)
    #expect(FakeIP.translate("10.0.0.1", index: index) == nil)
    // The wildcard passes the normal pattern rules as a wildcard rule.
    let pattern = "*.example.com"
    #expect(RulePattern.inferMatch(pattern) == .wildcard)
    let normalized = try RulePattern.normalize(pattern, match: .wildcard)
    #expect(normalized == pattern)
}
