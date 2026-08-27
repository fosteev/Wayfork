import Foundation
import Testing

@testable import WayforkCore

@Test func importsFullInlineProfile() throws {
    let source = try fixture(named: "full-inline")
    let expected = try fixture(named: "full-inline.expected")

    let result = try OpenVPNConfigParser.parse(source, readFile: { _ in nil })

    #expect(result.sanitizedConfig == expected)
    #expect(
        result.strippedDirectives == [
            "dev", "redirect-gateway", "dhcp-option", "up", "script-security", "verb",
        ])
    #expect(
        result.meta.remotes == [
            Remote(host: "vpn.example.org", port: 443, proto: "udp"),
            Remote(host: "vpn.example.org", port: 8443, proto: "tcp"),
        ])
    #expect(result.meta.needsCredentials)
    #expect(!result.meta.needsKeyPassphrase)
    #expect(result.meta.dns == .auto)
    #expect(result.meta.discoveredDNS == [])
    #expect(result.meta.configHash == Hashing.sha256Hex(expected))
    #expect(result.credentials == nil)
}

@Test func inlinesReferencedFilesAndReadsCredentials() throws {
    let files = [
        "ca.crt": data(
            """
            -----BEGIN CERTIFICATE-----
            PLACEHOLDER
            -----END CERTIFICATE-----

            """),
        "client.key": data(
            """
            -----BEGIN PRIVATE KEY-----
            PLACEHOLDER
            -----END PRIVATE KEY-----

            """),
        "ta.key": data(
            """
            -----BEGIN OpenVPN Static key V1-----
            PLACEHOLDER
            -----END OpenVPN Static key V1-----

            """),
        "creds.txt": data(" alice \n secret \n"),
    ]
    let source = """
        remote vpn.example.org
        ca ca.crt
        key client.key
        tls-auth ta.key 1
        auth-user-pass creds.txt
        """

    let result = try OpenVPNConfigParser.parse(source) { files[$0] }

    #expect(
        result.sanitizedConfig == """
            remote vpn.example.org
            <ca>
            -----BEGIN CERTIFICATE-----
            PLACEHOLDER
            -----END CERTIFICATE-----
            </ca>
            <key>
            -----BEGIN PRIVATE KEY-----
            PLACEHOLDER
            -----END PRIVATE KEY-----
            </key>
            <tls-auth>
            -----BEGIN OpenVPN Static key V1-----
            PLACEHOLDER
            -----END OpenVPN Static key V1-----
            </tls-auth>
            key-direction 1
            auth-user-pass

            """)
    #expect(result.credentials == Credentials(username: "alice", password: "secret"))
    #expect(result.meta.needsCredentials)
    #expect(!result.meta.needsKeyPassphrase)
}

@Test func resolvesFilesRelativeToBaseDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "wayfork-ovpn-parser-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true
    )
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try data("PLACEHOLDER\n").write(to: directory.appendingPathComponent("ca.crt"))

    let result = try OpenVPNConfigParser.parse(
        "remote vpn.example.org\nca ca.crt\n",
        baseDirectory: directory
    )

    #expect(result.sanitizedConfig == "remote vpn.example.org\n<ca>\nPLACEHOLDER\n</ca>\n")
}

@Test func existingKeyDirectionSuppressesGeneratedDirection() throws {
    let source = """
        remote vpn.example.org
        tls-auth ta.key 1
        key-direction 0
        """
    let result = try OpenVPNConfigParser.parse(source) { name in
        name == "ta.key" ? data("PLACEHOLDER\n") : nil
    }

    #expect(!result.sanitizedConfig.contains("key-direction 1"))
    #expect(result.sanitizedConfig.contains("key-direction 0\n"))
}

@Test func reportsAllMissingFiles() {
    let source = """
        remote vpn.example.org
        ca ca.crt
        key client.key
        auth-user-pass creds.txt
        ca ca.crt
        """

    #expect(throws: OpenVPNImportError.missingFiles(["ca.crt", "client.key", "creds.txt"])) {
        try OpenVPNConfigParser.parse(source, readFile: { _ in nil })
    }
}

@Test func detectsEncryptedInlineKey() throws {
    let source = """
        remote vpn.example.org
        <key>
        -----BEGIN ENCRYPTED PRIVATE KEY-----
        PLACEHOLDER
        -----END ENCRYPTED PRIVATE KEY-----
        </key>
        """

    let result = try OpenVPNConfigParser.parse(source, readFile: { _ in nil })

    #expect(result.meta.needsKeyPassphrase)
}

@Test func encodesPKCS12AndUsesAskpassAsPassphraseSignal() throws {
    let bundle = Data(repeating: 0x41, count: 60)
    let source = """
        remote vpn.example.org
        pkcs12 client.p12
        askpass
        """

    let result = try OpenVPNConfigParser.parse(source) { name in
        name == "client.p12" ? bundle : nil
    }
    let bodyLines = result.sanitizedConfig.split(separator: "\n").dropFirst(2).dropLast()

    #expect(result.strippedDirectives == ["askpass"])
    #expect(result.meta.needsKeyPassphrase)
    #expect(bodyLines.map(\.count) == [64, 16])
}

@Test func rejectsTapDevice() {
    let source = """
        remote vpn.example.org
        dev tap
        """

    #expect(throws: OpenVPNImportError.unsupported("dev tap")) {
        try OpenVPNConfigParser.parse(source, readFile: { _ in nil })
    }
}

@Test func rejectsProfileWithoutRemote() {
    #expect(throws: OpenVPNImportError.noRemote) {
        try OpenVPNConfigParser.parse("client\n", readFile: { _ in nil })
    }
}

@Test func rejectsUnterminatedInlineBlock() {
    let source = """
        remote vpn.example.org
        <ca>
        PLACEHOLDER
        """

    #expect(
        throws: OpenVPNImportError.malformed(
            line: 2,
            reason: "unterminated inline block <ca>"
        )
    ) {
        try OpenVPNConfigParser.parse(source, readFile: { _ in nil })
    }
}

@Test func rejectsUnbalancedQuotes() {
    #expect(
        throws: OpenVPNImportError.malformed(
            line: 1,
            reason: "unbalanced quotes"
        )
    ) {
        try OpenVPNConfigParser.parse("remote \"vpn.example.org\n", readFile: { _ in nil })
    }
}

@Test func processesConnectionBlocks() throws {
    let source = """
        proto tcp4-client
        <connection>
          remote vpn.example.org 443
          route 10.0.0.1
          management-hold
        </connection>
        remote vpn.example.org
        """

    let result = try OpenVPNConfigParser.parse(source, readFile: { _ in nil })

    #expect(
        result.sanitizedConfig == """
            proto tcp4-client
            <connection>
            remote vpn.example.org 443
            </connection>
            remote vpn.example.org

            """)
    #expect(result.strippedDirectives == ["route", "management-hold"])
    #expect(
        result.meta.remotes == [
            Remote(host: "vpn.example.org", port: 443, proto: "tcp"),
            Remote(host: "vpn.example.org", port: 1194, proto: "tcp"),
        ])
}

@Test func sanitizedProfileIsStableOnRoundTrip() throws {
    let imported = try OpenVPNConfigParser.parse(try fixture(named: "full-inline")) { _ in nil }
    let reparsed = try OpenVPNConfigParser.parse(imported.sanitizedConfig) { _ in nil }

    #expect(reparsed.sanitizedConfig == imported.sanitizedConfig)
}

private func fixture(named name: String) throws -> String {
    try Fixtures.text("ovpn/\(name).ovpn")
}

private func data(_ string: String) -> Data {
    Data(string.utf8)
}
