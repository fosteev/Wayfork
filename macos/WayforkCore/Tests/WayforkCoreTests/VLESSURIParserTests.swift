import Foundation
import Testing

@testable import WayforkCore

private let vlessUUID = "00000000-0000-4000-8000-000000000001"

@Test func parsesSupportedVLESSLinks() throws {
    let reality = try VLESSURIParser.parse(
        "vless://\(vlessUUID.uppercased())@example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=example.com&fp=chrome&pbk=public-key&sid=short-id&type=tcp#Reality"
    )
    #expect(reality.uuid == vlessUUID)
    #expect(reality.name == "Reality")
    #expect(reality.meta.flow == "xtls-rprx-vision")
    #expect(reality.meta.security == .reality)
    #expect(reality.meta.realityPublicKey == "public-key")

    let ws = try VLESSURIParser.parse(
        "vless://\(vlessUUID)@example.com:8443?security=tls&type=ws&path=%2Fsocket%3Fx%3D1&host=example.com&alpn=h2%2C%20http%2F1.1&allowInsecure=true#%20Web%20Socket%20"
    )
    #expect(ws.name == "Web Socket")
    #expect(ws.meta.sni == "example.com")
    #expect(ws.meta.alpn == ["h2", "http/1.1"])
    #expect(ws.meta.transport == .ws(path: "/socket?x=1", host: "example.com"))
    #expect(ws.meta.allowInsecure)

    let grpc = try VLESSURIParser.parse(
        "vless://\(vlessUUID)@example.com:443?security=tls&type=grpc&serviceName=wayfork&insecure=1#gRPC"
    )
    #expect(grpc.meta.transport == .grpc(serviceName: "wayfork"))
    #expect(grpc.meta.sni == "example.com")
    #expect(grpc.meta.allowInsecure)

    let plain = try VLESSURIParser.parse(
        "VLESS://\(vlessUUID)@example.com:80?fp=first&fp=last#A+B")
    #expect(plain.meta.security == .none)
    #expect(plain.meta.sni == nil)
    #expect(plain.meta.fingerprint == "last")
    #expect(plain.name == "A+B")

    let ipv6 = try VLESSURIParser.parse(
        "vless://\(vlessUUID)@[2001:db8::1]:443?security=tls#IPv6")
    #expect(ipv6.meta.server == "2001:db8::1")
    #expect(ipv6.meta.sni == "2001:db8::1")
}

@Test(arguments: ["kcp", "http", "h2", "httpupgrade", "quic", "splithttp", "other"])
func rejectsUnsupportedTransports(_ transport: String) {
    #expect(
        throws: VLESSImportError.unsupported(
            "Transport \"\(transport)\" is not supported yet.")
    ) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?type=\(transport)")
    }
}

@Test func rejectsInvalidOptions() {
    #expect(throws: VLESSImportError.invalid("encryption must be none")) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?encryption=aes")
    }
    #expect(throws: VLESSImportError.invalid("security must be none, tls, or reality")) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?security=unknown")
    }
    #expect(throws: VLESSImportError.unsupported("Flow \"legacy\" is not supported yet.")) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?security=tls&flow=legacy")
    }
    #expect(throws: VLESSImportError.invalid("flow requires TLS/REALITY over TCP")) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?flow=xtls-rprx-vision")
    }
    #expect(throws: VLESSImportError.invalid("flow requires TLS/REALITY over TCP")) {
        try VLESSURIParser.parse(
            "vless://\(vlessUUID)@example.com:443?security=tls&type=ws&flow=xtls-rprx-vision")
    }
    #expect(throws: VLESSImportError.invalid("REALITY requires pbk")) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?security=reality")
    }
    #expect(throws: VLESSImportError.unsupported("REALITY over ws is not supported")) {
        try VLESSURIParser.parse(
            "vless://\(vlessUUID)@example.com:443?security=reality&pbk=public-key&type=ws")
    }
    #expect(
        throws: VLESSImportError.unsupported(
            "headerType \"http\" is not supported yet.")
    ) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?headerType=http")
    }
}

/// `fixtures/vless/links.json`: links every client must accept (with the parse result) or
/// reject. Regenerate the recorded results with `WAYFORK_UPDATE_GOLDEN=1 swift test` after an
/// intentional parser change and review the diff.
private struct VLESSLinks: Codable {
    struct Accepted: Codable {
        struct Result: Codable, Equatable {
            var uuid: String
            var name: String
            var meta: VLESSMeta
        }
        var name: String
        var uri: String
        var expected: Result?
    }
    var accepted: [Accepted]
    var rejected: [String]

    static let path = Fixtures.url("vless/links.json")
    /// Swift-only until the Windows twin of the XHTTP stage reads it.
    static let xhttpPath = Fixtures.url("vless/xhttp-links.json")

    static func load(_ path: URL = VLESSLinks.path) throws -> VLESSLinks {
        try JSONCoding.decoder.decode(VLESSLinks.self, from: Data(contentsOf: path))
    }
}

@Test func fixtureLinksParseAsRecorded() throws {
    try checkAcceptedFixture(at: VLESSLinks.path)
}

@Test func xhttpFixtureLinksParseAsRecorded() throws {
    try checkAcceptedFixture(at: VLESSLinks.xhttpPath)
}

private func checkAcceptedFixture(at path: URL) throws {
    var links = try VLESSLinks.load(path)
    let update = ProcessInfo.processInfo.environment["WAYFORK_UPDATE_GOLDEN"] != nil
    #expect(!links.accepted.isEmpty)
    for index in links.accepted.indices {
        let link = links.accepted[index]
        let parsed = try VLESSURIParser.parse(link.uri)
        let result = VLESSLinks.Accepted.Result(
            uuid: parsed.uuid, name: parsed.name, meta: parsed.meta)
        if update {
            links.accepted[index].expected = result
        } else {
            #expect(result == link.expected, "\(link.name) differs from the recorded result")
        }
    }
    if update {
        let data = try JSONCoding.prettyEncoder.encode(links)
        try (String(decoding: data, as: UTF8.self) + "\n").write(
            to: path, atomically: true, encoding: .utf8)
    }
}

@Test func fixtureLinksAreRejected() throws {
    try checkRejectedFixture(at: VLESSLinks.path)
}

@Test func xhttpFixtureLinksAreRejected() throws {
    try checkRejectedFixture(at: VLESSLinks.xhttpPath)
}

private func checkRejectedFixture(at path: URL) throws {
    let links = try VLESSLinks.load(path)
    #expect(!links.rejected.isEmpty)
    for uri in links.rejected {
        #expect(throws: VLESSImportError.self, "\(uri)") { try VLESSURIParser.parse(uri) }
    }
}

@Test func sharingURIRoundTripsAndUsesStableOrder() throws {
    let cases = [
        VLESSMeta(server: "example.com", port: 80, security: .none),
        VLESSMeta(
            server: "example.com", port: 443, security: .tls, sni: "example.com",
            fingerprint: "chrome", alpn: ["h2", "http/1.1"],
            transport: .ws(path: "/socket", host: "example.com"), allowInsecure: true),
        VLESSMeta(
            server: "example.com", port: 443, security: .tls, sni: "example.com",
            transport: .grpc(serviceName: "wayfork")),
        VLESSMeta(
            server: "2001:db8::1", port: 443, flow: "xtls-rprx-vision",
            security: .reality, sni: "example.com", fingerprint: "chrome",
            realityPublicKey: "public-key", realityShortID: "short-id"),
    ]
    for meta in cases {
        let result = try VLESSURIParser.parse(
            VLESSURIParser.uri(meta: meta, uuid: vlessUUID, name: "Wayfork Test"))
        #expect(result == VLESSImportResult(uuid: vlessUUID, meta: meta, name: "Wayfork Test"))
    }

    let uri = VLESSURIParser.uri(meta: cases[1], uuid: "<uuid>", name: "A B")
    #expect(
        uri
            == "vless://<uuid>@example.com:443?encryption=none&security=tls&sni=example.com&fp=chrome&alpn=h2%2Chttp%2F1.1&type=ws&path=%2Fsocket&host=example.com&allowInsecure=1#A%20B"
    )
}

@Test func fragmentFallsBackAndNameIsTruncated() throws {
    let fallback = try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443#%20")
    #expect(fallback.name == "example.com")

    let longName = String(repeating: "é", count: 41)
    let result = try VLESSURIParser.parse(
        VLESSURIParser.uri(
            meta: VLESSMeta(server: "example.com", port: 443, security: .none),
            uuid: vlessUUID, name: longName))
    #expect(result.name == String(repeating: "é", count: 40))
}

// MARK: - XHTTP

private func xhttpLink(_ query: String) -> String {
    "vless://\(vlessUUID)@example.com:443?\(query)"
}

@Test func parsesXHTTPFields() throws {
    let minimal = try VLESSURIParser.parse(
        xhttpLink("type=xhttp&security=reality&pbk=k&sid=s&sni=a.com"))
    #expect(minimal.meta.transport == .xhttp(path: "/", host: nil, mode: nil, extra: nil))
    #expect(minimal.meta.security == .reality)

    let full = try VLESSURIParser.parse(
        xhttpLink(
            "type=xhttp&security=tls&path=%2Fx&host=cdn.example.com&mode=stream-one&extra=%7B%22a%22%3A1%7D"
        ))
    #expect(
        full.meta.transport
            == .xhttp(
                path: "/x", host: "cdn.example.com", mode: "stream-one", extra: "{\"a\":1}"))

    for mode in ["auto", "packet-up", "stream-up", "stream-one"] {
        let result = try VLESSURIParser.parse(xhttpLink("type=xhttp&mode=\(mode)"))
        #expect(result.meta.transport == .xhttp(path: "/", host: nil, mode: mode, extra: nil))
    }
}

@Test func rejectsInvalidXHTTPOptions() {
    #expect(
        throws: VLESSImportError.invalid("mode must be auto, packet-up, stream-up, or stream-one")
    ) {
        try VLESSURIParser.parse(xhttpLink("type=xhttp&mode=fast"))
    }
    #expect(throws: VLESSImportError.invalid("extra must be a JSON object")) {
        try VLESSURIParser.parse(xhttpLink("type=xhttp&extra=%5B1%5D"))
    }
    #expect(throws: VLESSImportError.invalid("extra must be a JSON object")) {
        try VLESSURIParser.parse(xhttpLink("type=xhttp&extra=not-json"))
    }
    #expect(throws: VLESSImportError.invalid("flow requires TLS/REALITY over TCP")) {
        try VLESSURIParser.parse(
            xhttpLink("type=xhttp&security=reality&pbk=k&flow=xtls-rprx-vision"))
    }
    for flag in ["allowInsecure=1", "insecure=true"] {
        #expect(
            throws: VLESSImportError.unsupported("allowInsecure is not supported with XHTTP.")
        ) {
            try VLESSURIParser.parse(xhttpLink("type=xhttp&security=tls&\(flag)"))
        }
    }
    #expect(
        throws: VLESSImportError.unsupported("Transport \"splithttp\" is not supported yet.")
    ) {
        try VLESSURIParser.parse(xhttpLink("type=splithttp"))
    }
}

@Test func xhttpWriterKeepsFieldOrderAndSkipsNilFields() {
    let meta = VLESSMeta(
        server: "example.com", port: 443, security: .tls, sni: "example.com",
        transport: .xhttp(
            path: "/x", host: "cdn.example.com", mode: "packet-up", extra: "{\"a\":1}"))
    #expect(
        VLESSURIParser.uri(meta: meta, uuid: "<uuid>", name: "N")
            == "vless://<uuid>@example.com:443?encryption=none&security=tls&sni=example.com&type=xhttp&path=%2Fx&host=cdn.example.com&mode=packet-up&extra=%7B%22a%22%3A1%7D#N"
    )

    var sparse = meta
    sparse.transport = .xhttp(path: "/x", host: nil, mode: "stream-one", extra: nil)
    #expect(
        VLESSURIParser.uri(meta: sparse, uuid: "<uuid>", name: "N")
            == "vless://<uuid>@example.com:443?encryption=none&security=tls&sni=example.com&type=xhttp&path=%2Fx&mode=stream-one#N"
    )
}

@Test func xhttpFixtureLinksRoundTrip() throws {
    let links = try VLESSLinks.load(VLESSLinks.xhttpPath)
    #expect(!links.accepted.isEmpty)
    for link in links.accepted {
        let first = try VLESSURIParser.parse(link.uri)
        guard case .xhttp = first.meta.transport else {
            Issue.record("\(link.name) is not an XHTTP link")
            continue
        }
        let rewritten = VLESSURIParser.uri(meta: first.meta, uuid: first.uuid, name: first.name)
        #expect(try VLESSURIParser.parse(rewritten) == first, "\(link.name)")
    }
}

@Test func xhttpMetaSurvivesStoreCoding() throws {
    let meta = VLESSMeta(
        server: "example.com", port: 443, security: .tls, sni: "example.com",
        transport: .xhttp(path: "/x", host: nil, mode: "auto", extra: "{\"a\":1}"))
    let data = try JSONCoding.compactEncoder.encode(meta)
    #expect(String(decoding: data, as: UTF8.self).contains("\"transport\":{\"xhttp\":{"))
    #expect(try JSONCoding.decoder.decode(VLESSMeta.self, from: data) == meta)
}
