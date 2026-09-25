import Foundation
import Testing

@testable import WayforkCore

private struct RecordedProxyLinkError: Codable {
    var `case`: String
    var message: String

    var value: ProxyLinkError {
        `case` == "unsupported" ? .unsupported(message) : .invalid(message)
    }
}

private struct ShadowsocksLinks: Codable {
    struct Accepted: Codable {
        struct Result: Codable, Equatable {
            var password: String
            var meta: ShadowsocksMeta
            var name: String
        }

        var name: String
        var uri: String
        var expected: Result?
    }

    struct Rejected: Codable {
        var name: String
        var uri: String
        var error: RecordedProxyLinkError
    }

    var accepted: [Accepted]
    var rejected: [Rejected]
}

private struct TrojanLinks: Codable {
    struct Accepted: Codable {
        struct Result: Codable, Equatable {
            var password: String
            var meta: TrojanMeta
            var name: String
        }

        var name: String
        var uri: String
        var expected: Result?
    }

    struct Rejected: Codable {
        var name: String
        var uri: String
        var error: RecordedProxyLinkError
    }

    var accepted: [Accepted]
    var rejected: [Rejected]
}

private struct VMessLinks: Codable {
    struct Accepted: Codable {
        struct Result: Codable, Equatable {
            var uuid: String
            var meta: VMessMeta
            var name: String
        }

        var name: String
        var uri: String
        var expected: Result?
    }

    struct Rejected: Codable {
        var name: String
        var uri: String
        var error: RecordedProxyLinkError
    }

    var accepted: [Accepted]
    var rejected: [Rejected]
}

@Test func proxyLinkFixturesParseAsRecorded() throws {
    let update = ProcessInfo.processInfo.environment["WAYFORK_UPDATE_GOLDEN"] != nil
    try checkShadowsocksFixtures(update: update)
    try checkTrojanFixtures(update: update)
    try checkVMessFixtures(update: update)
}

@Test func proxyLinkFixturesThrowRecordedErrors() throws {
    let shadowsocks = try load(ShadowsocksLinks.self, from: "links/ss.json")
    for link in shadowsocks.rejected {
        #expect(throws: link.error.value, "\(link.name)") { try ProxyLinkParser.parse(link.uri) }
    }
    let trojan = try load(TrojanLinks.self, from: "links/trojan.json")
    for link in trojan.rejected {
        #expect(throws: link.error.value, "\(link.name)") { try ProxyLinkParser.parse(link.uri) }
    }
    let vmess = try load(VMessLinks.self, from: "links/vmess.json")
    for link in vmess.rejected {
        #expect(throws: link.error.value, "\(link.name)") { try ProxyLinkParser.parse(link.uri) }
    }
}

@Test func acceptedProxyLinkFixturesRoundTrip() throws {
    let shadowsocks = try load(ShadowsocksLinks.self, from: "links/ss.json")
    for link in shadowsocks.accepted {
        guard case .shadowsocks(let first) = try ProxyLinkParser.parse(link.uri) else {
            Issue.record("\(link.name) returned the wrong link kind")
            continue
        }
        let uri = ProxyLinkParser.uri(meta: first.meta, password: first.password, name: first.name)
        #expect(try ProxyLinkParser.parse(uri) == .shadowsocks(first), "\(link.name)")
    }

    let trojan = try load(TrojanLinks.self, from: "links/trojan.json")
    for link in trojan.accepted {
        guard case .trojan(let first) = try ProxyLinkParser.parse(link.uri) else {
            Issue.record("\(link.name) returned the wrong link kind")
            continue
        }
        let uri = ProxyLinkParser.uri(meta: first.meta, password: first.password, name: first.name)
        #expect(try ProxyLinkParser.parse(uri) == .trojan(first), "\(link.name)")
    }

    let vmess = try load(VMessLinks.self, from: "links/vmess.json")
    for link in vmess.accepted {
        guard case .vmess(let first) = try ProxyLinkParser.parse(link.uri) else {
            Issue.record("\(link.name) returned the wrong link kind")
            continue
        }
        let uri = ProxyLinkParser.uri(meta: first.meta, uuid: first.uuid, name: first.name)
        #expect(try ProxyLinkParser.parse(uri) == .vmess(first), "\(link.name)")
    }
}

@Test func shadowsocksAcceptsPaddedUnpaddedAndURLSafeBase64() throws {
    let userinfo = Data("aes-128-gcm:fake-😀-password".utf8).base64EncodedString()
    let variants = [
        userinfo,
        userinfo.trimmingCharacters(in: CharacterSet(charactersIn: "=")),
        userinfo.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "=")),
    ]
    for variant in variants {
        guard
            case .shadowsocks(let result) = try ProxyLinkParser.parse(
                "ss://\(variant)@base64.example.net:8388")
        else {
            Issue.record("expected a Shadowsocks result")
            continue
        }
        #expect(result.password == "fake-😀-password")
    }
}

@Test func vmessAcceptsPaddedUnpaddedAndURLSafeBase64() throws {
    let json: [String: Any] = [
        "ps": "😀",
        "add": "base64.example.net",
        "port": 443,
        "id": "00000000-0000-4000-8000-000000000031",
        "aid": 0,
        "net": "tcp",
        "tls": "",
    ]
    let encoded = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
    let variants = [
        encoded,
        encoded.trimmingCharacters(in: CharacterSet(charactersIn: "=")),
        encoded.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "=")),
    ]
    for variant in variants {
        guard case .vmess(let result) = try ProxyLinkParser.parse("vmess://\(variant)") else {
            Issue.record("expected a VMess result")
            continue
        }
        #expect(result.meta.server == "base64.example.net")
    }
}

@Test func vmessAcceptsNumericAndStringPortAndAlterID() throws {
    let cases: [(Any, Any)] = [(443, 0), ("443", "0")]
    for (port, aid) in cases {
        let json: [String: Any] = [
            "add": "numbers.example.net",
            "port": port,
            "id": "00000000-0000-4000-8000-000000000032",
            "aid": aid,
            "net": "tcp",
            "tls": "",
        ]
        let body = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
        guard case .vmess(let result) = try ProxyLinkParser.parse("vmess://\(body)") else {
            Issue.record("expected a VMess result")
            continue
        }
        #expect(result.meta.port == 443)
    }
}

@Test func parserTrimsInputAndWrapsVLESSErrors() throws {
    guard
        case .vless(let result) = try ProxyLinkParser.parse(
            "  vless://00000000-0000-4000-8000-000000000033@trimmed.example.net:443  \n")
    else {
        Issue.record("expected a VLESS result")
        return
    }
    #expect(result.meta.server == "trimmed.example.net")
    #expect(throws: ProxyLinkError.invalid("UUID is invalid")) {
        try ProxyLinkParser.parse("vless://bad@invalid.example.net:443")
    }
    #expect(throws: ProxyLinkError.invalid("unsupported link scheme")) {
        try ProxyLinkParser.parse("missing scheme")
    }
}

private func checkShadowsocksFixtures(update: Bool) throws {
    let path = Fixtures.url("links/ss.json")
    var links = try load(ShadowsocksLinks.self, from: "links/ss.json")
    for index in links.accepted.indices {
        let link = links.accepted[index]
        guard case .shadowsocks(let parsed) = try ProxyLinkParser.parse(link.uri) else {
            Issue.record("\(link.name) returned the wrong link kind")
            continue
        }
        let result = ShadowsocksLinks.Accepted.Result(
            password: parsed.password, meta: parsed.meta, name: parsed.name)
        if update {
            links.accepted[index].expected = result
        } else {
            #expect(result == link.expected)
        }
    }
    if update { try write(links, to: path) }
}

private func checkTrojanFixtures(update: Bool) throws {
    let path = Fixtures.url("links/trojan.json")
    var links = try load(TrojanLinks.self, from: "links/trojan.json")
    for index in links.accepted.indices {
        let link = links.accepted[index]
        guard case .trojan(let parsed) = try ProxyLinkParser.parse(link.uri) else {
            Issue.record("\(link.name) returned the wrong link kind")
            continue
        }
        let result = TrojanLinks.Accepted.Result(
            password: parsed.password, meta: parsed.meta, name: parsed.name)
        if update {
            links.accepted[index].expected = result
        } else {
            #expect(result == link.expected)
        }
    }
    if update { try write(links, to: path) }
}

private func checkVMessFixtures(update: Bool) throws {
    let path = Fixtures.url("links/vmess.json")
    var links = try load(VMessLinks.self, from: "links/vmess.json")
    for index in links.accepted.indices {
        let link = links.accepted[index]
        guard case .vmess(let parsed) = try ProxyLinkParser.parse(link.uri) else {
            Issue.record("\(link.name) returned the wrong link kind")
            continue
        }
        let result = VMessLinks.Accepted.Result(
            uuid: parsed.uuid, meta: parsed.meta, name: parsed.name)
        if update {
            links.accepted[index].expected = result
        } else {
            #expect(result == link.expected)
        }
    }
    if update { try write(links, to: path) }
}

private func load<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: Data(contentsOf: Fixtures.url(path)))
}

private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let data = try JSONCoding.prettyEncoder.encode(value)
    try (String(decoding: data, as: UTF8.self) + "\n").write(
        to: url, atomically: true, encoding: .utf8)
}
