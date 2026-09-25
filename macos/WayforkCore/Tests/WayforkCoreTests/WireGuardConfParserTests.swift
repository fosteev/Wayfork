import Foundation
import Testing

@testable import WayforkCore

private let acceptedWireGuardFixtures = ["basic", "split", "preshared", "two-peers"]

private struct RejectedWireGuardFixture: Codable {
    var `case`: String
    var message: String

    var error: WireGuardImportError {
        switch `case` {
        case "unsupported": .unsupported(message)
        default: .invalid(message)
        }
    }
}

@Test func wireGuardFixturesParseAsRecorded() throws {
    let update = ProcessInfo.processInfo.environment["WAYFORK_UPDATE_GOLDEN"] != nil
    for name in acceptedWireGuardFixtures {
        let parsed = try WireGuardConfParser.parse(Fixtures.text("wireguard/\(name).conf"))
        let expectedURL = Fixtures.url("wireguard/\(name).expected.json")
        if update {
            let data = try JSONCoding.prettyEncoder.encode(parsed)
            try (String(decoding: data, as: UTF8.self) + "\n").write(
                to: expectedURL, atomically: true, encoding: .utf8)
        } else {
            let expected = try JSONCoding.decoder.decode(
                WireGuardImportResult.self, from: Data(contentsOf: expectedURL))
            #expect(parsed == expected, "\(name) differs from the recorded result")
        }
    }
}

@Test func rejectedWireGuardFixturesThrowRecordedErrors() throws {
    let fixtures = try JSONCoding.decoder.decode(
        [String: RejectedWireGuardFixture].self,
        from: Data(contentsOf: Fixtures.url("wireguard/rejected.json")))
    for (name, expected) in fixtures {
        #expect(throws: expected.error, "\(name)") {
            try WireGuardConfParser.parse(Fixtures.text("wireguard/\(name).conf"))
        }
    }
}

@Test func wireGuardCommentsAreStrippedMidLine() throws {
    let parsed = try WireGuardConfParser.parse(
        """
        [INTERFACE] # comment
        PRIVATEKEY = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8= ; comment
        ADDRESS = 10.1.0.2/32 # comment
        [peer]
        publickey = ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=
        endpoint = comments.example.net:51820 ; comment
        allowedips = 0.0.0.0/0 # comment
        """)
    #expect(parsed.meta.peers[0].host == "comments.example.net")
}

@Test func wireGuardBareAddressIsNormalized() throws {
    let parsed = try WireGuardConfParser.parse(Fixtures.text("wireguard/preshared.conf"))
    #expect(parsed.meta.addresses == ["10.9.0.2/32"])
}

@Test func wireGuardIPv6ValuesAreFiltered() throws {
    let parsed = try WireGuardConfParser.parse(
        """
        [Interface]
        PrivateKey = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=
        Address = 2001:db8::2/64, 10.2.0.2/32
        DNS = 2001:db8::53, 192.0.2.53
        [Peer]
        PublicKey = ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=
        Endpoint = filtering.example.net:51820
        AllowedIPs = ::/0, 10.0.0.0/8
        """)
    #expect(parsed.meta.addresses == ["10.2.0.2/32"])
    #expect(parsed.meta.discoveredDNS == ["192.0.2.53"])
    #expect(parsed.meta.peers[0].allowedIPs == ["10.0.0.0/8"])
}

@Test func wireGuardRejectsASecondInterfaceAndLaterPresharedKey() {
    let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    #expect(throws: WireGuardImportError.invalid("multiple Interface sections")) {
        try WireGuardConfParser.parse("[Interface]\n[Interface]")
    }

    #expect(
        throws: WireGuardImportError.unsupported(
            "preshared keys are supported on the first peer only")
    ) {
        try WireGuardConfParser.parse(
            """
            [Interface]
            PrivateKey = \(key)
            Address = 10.2.0.2/32
            [Peer]
            PublicKey = \(key)
            Endpoint = first.example.net:51820
            AllowedIPs = 10.0.0.0/8
            [Peer]
            PublicKey = \(key)
            PresharedKey = \(key)
            Endpoint = second.example.net:51820
            AllowedIPs = 192.168.0.0/16
            """)
    }
}
