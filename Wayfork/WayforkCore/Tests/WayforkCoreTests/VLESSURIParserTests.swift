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

@Test(arguments: ["kcp", "http", "h2", "httpupgrade", "xhttp", "quic", "splithttp", "other"])
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
    #expect(throws: VLESSImportError.unsupported("REALITY over ws/grpc is not supported")) {
        try VLESSURIParser.parse(
            "vless://\(vlessUUID)@example.com:443?security=reality&pbk=public-key&type=grpc")
    }
    #expect(
        throws: VLESSImportError.unsupported(
            "headerType \"http\" is not supported yet.")
    ) {
        try VLESSURIParser.parse("vless://\(vlessUUID)@example.com:443?headerType=http")
    }
}

@Test(arguments: [
    "https://\(vlessUUID)@example.com:443", "vless://@example.com:443",
    "vless://invalid@example.com:443", "vless://\(vlessUUID)@:443",
    "vless://{\(vlessUUID)}@example.com:443", "vless://\(vlessUUID)@bad_host:443",
    "vless://\(vlessUUID)@999.999.999.999:443", "vless://\(vlessUUID)@example.com",
    "vless://\(vlessUUID)@example.com:+443",
    "vless://\(vlessUUID)@example.com:0", "vless://\(vlessUUID)@example.com:65536",
    "vless://\(vlessUUID)@2001:db8::1:443", "vless://\(vlessUUID)@[2001:db8::1:443",
    "vless://\(vlessUUID)@example.com:443?fp=%ZZ",
    "vless://\(vlessUUID)@example.com:443#%ZZ",
])
func rejectsMalformedLinks(_ uri: String) {
    #expect(throws: VLESSImportError.self) { try VLESSURIParser.parse(uri) }
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
