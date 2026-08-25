import Foundation
import Testing

@testable import WayforkCore

private let importDate = Date(timeIntervalSince1970: 1_787_659_200)
private let importedOpenVPNID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
private let importedVLESSID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!

private func openVPNTunnel(
    id: UUID = importedOpenVPNID, name: String = "Work", slot: Int = 17
) -> Tunnel {
    Tunnel(
        id: id,
        name: name,
        slot: slot,
        kind: .openVPN(
            OpenVPNMeta(
                remotes: [Remote(host: "vpn.example.com", port: 1194, proto: "udp")],
                needsCredentials: true,
                needsKeyPassphrase: true,
                configHash: "example-hash")),
        createdAt: importDate)
}

private func vlessTunnel(
    id: UUID = importedVLESSID, name: String = "Home", slot: Int = 23
) -> Tunnel {
    Tunnel(
        id: id,
        name: name,
        slot: slot,
        kind: .vless(
            VLESSMeta(server: "proxy.example.com", port: 443, security: .tls)),
        createdAt: importDate)
}

private func document(
    tunnels: [ExportedTunnel], rules: [Rule] = [], settings: Settings = Settings(),
    includesSecrets: Bool = false
) -> ExportDocument {
    ExportDocument(
        exportedAt: importDate,
        includesSecrets: includesSecrets,
        tunnels: tunnels,
        rules: rules,
        settings: settings)
}

@Test func importPreviewCountsContentsAndSecrets() {
    let export = document(
        tunnels: [
            ExportedTunnel(
                tunnel: openVPNTunnel(), secrets: TunnelSecrets(ovpn: "client\n")),
            ExportedTunnel(tunnel: vlessTunnel()),
        ],
        rules: [Rule(pattern: "example.com", tunnelID: importedOpenVPNID)],
        includesSecrets: true)

    #expect(
        StoreImporter.preview(export)
            == ImportPreview(tunnels: 2, rules: 1, includesSecrets: true, tunnelsWithSecrets: 1))
}

@Test func replaceReassignsSlotsSettingsRulesAndSecrets() throws {
    let unknownID = UUID(uuidString: "10000000-0000-4000-8000-000000000099")!
    let credentials = Credentials(username: "example-user", password: "example-password")
    let settings = Settings(connectOnLaunch: true, logLevel: .debug)
    let export = document(
        tunnels: [
            ExportedTunnel(
                tunnel: openVPNTunnel(),
                secrets: TunnelSecrets(
                    ovpn: "client\nremote vpn.example.com 1194\n",
                    credentials: credentials,
                    keyPassphrase: "example-passphrase")),
            ExportedTunnel(
                tunnel: vlessTunnel(), secrets: TunnelSecrets(uuid: "example-uuid")),
        ],
        rules: [
            Rule(pattern: "valid.example.com", tunnelID: importedOpenVPNID),
            Rule(pattern: "missing.example.com", tunnelID: unknownID),
        ],
        settings: settings,
        includesSecrets: true)
    let original = Store(schemaVersion: 7, tunnels: [Fixtures.work])

    let outcome = StoreImporter.apply(export, to: original, mode: .replace)

    #expect(outcome.store.schemaVersion == 7)
    #expect(outcome.store.tunnels.map(\.slot) == [0, 1])
    #expect(outcome.store.settings == settings)
    #expect(outcome.store.rules.map(\.pattern) == ["valid.example.com"])
    #expect(outcome.tunnelsAdded == 2)
    #expect(outcome.rulesAdded == 1)
    #expect(outcome.rulesSkipped == 1)
    #expect(outcome.warnings.count == 1)
    #expect(outcome.warnings[0].contains("missing.example.com"))
    #expect(outcome.secrets.count == 4)
    #expect(outcome.secrets[.ovpn(importedOpenVPNID)]?.hasPrefix("client") == true)
    #expect(outcome.secrets[.keyPassphrase(importedOpenVPNID)] == "example-passphrase")
    #expect(outcome.secrets[.uuid(importedVLESSID)] == "example-uuid")
    let credentialsJSON = try #require(outcome.secrets[.credentials(importedOpenVPNID)])
    #expect(
        try JSONCoding.decoder.decode(Credentials.self, from: Data(credentialsJSON.utf8))
            == credentials)
}

@Test func mergeUpdatesAndAppendsWithoutReplacingSettings() {
    let existingRuleID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    let newRuleID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    let existing = openVPNTunnel(name: "Office", slot: 5)
    let collision = vlessTunnel(
        id: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!, name: "Work", slot: 0)
    let oldRule = Rule(
        id: existingRuleID, pattern: "old.example.com", tunnelID: existing.id)
    let originalSettings = Settings(launchAtLogin: true, logRetentionDays: 30)
    let original = Store(
        tunnels: [existing, collision], rules: [oldRule], settings: originalSettings)
    var updated = existing
    updated.name = "Work"
    updated.isEnabled = false
    updated.kind = vlessTunnel().kind
    let added = vlessTunnel(name: "Personal")
    let export = document(
        tunnels: [ExportedTunnel(tunnel: updated), ExportedTunnel(tunnel: added)],
        rules: [
            Rule(
                id: existingRuleID, pattern: "updated.example.com", match: .exact,
                tunnelID: existing.id, isEnabled: false, note: "updated"),
            Rule(id: newRuleID, pattern: "new.example.com", tunnelID: added.id),
        ],
        settings: Settings(connectOnLaunch: true))

    let outcome = StoreImporter.apply(export, to: original, mode: .merge)

    #expect(outcome.store.tunnels.map(\.id) == [existing.id, collision.id, added.id])
    #expect(outcome.store.tunnels[0].slot == 5)
    #expect(outcome.store.tunnels[0].name == "Work (2)")
    #expect(outcome.store.tunnels[0].isEnabled == false)
    #expect(outcome.store.tunnels[0].kind == updated.kind)
    #expect(outcome.store.tunnels[2].slot == 1)
    #expect(outcome.store.rules.map(\.id) == [existingRuleID, newRuleID])
    #expect(outcome.store.rules[0].pattern == "updated.example.com")
    #expect(outcome.store.settings == originalSettings)
    #expect(outcome.tunnelsAdded == 1)
    #expect(outcome.tunnelsUpdated == 1)
    #expect(outcome.rulesAdded == 1)
    #expect(outcome.rulesUpdated == 1)
    #expect(outcome.warnings == ["Tunnel Work renamed to Work (2)"])
}

@Test func mergeSkipsNewTunnelWhenAllSlotsAreTaken() {
    let tunnels = (0..<Tunnel.maxSlots).map { slot in
        vlessTunnel(id: UUID(), name: "Tunnel \(slot)", slot: slot)
    }
    let export = document(tunnels: [ExportedTunnel(tunnel: openVPNTunnel())])

    let outcome = StoreImporter.apply(export, to: Store(tunnels: tunnels), mode: .merge)

    #expect(outcome.store.tunnels.count == Tunnel.maxSlots)
    #expect(outcome.tunnelsAdded == 0)
    #expect(outcome.warnings == ["Tunnel Work skipped: no free slots"])
}

@Test func exporterRoundTripsWithAndWithoutSecrets() throws {
    let rules = [
        Rule(pattern: "work.example.com", tunnelID: importedOpenVPNID),
        Rule(pattern: "home.example.com", tunnelID: importedVLESSID),
    ]
    let store = Store(tunnels: [openVPNTunnel(), vlessTunnel()], rules: rules)
    let credentials = Credentials(username: "example-user", password: "example-password")
    let secretStore = InMemorySecretStore([
        .ovpn(importedOpenVPNID): "client\nremote vpn.example.com 1194\n",
        .keyPassphrase(importedOpenVPNID): "example-passphrase",
        .uuid(importedVLESSID): "example-uuid",
    ])
    try secretStore.writeCredentials(credentials, for: importedOpenVPNID)

    let exported = try StoreExporter.document(
        store: store, secretStore: secretStore, includeSecrets: true, exportedAt: importDate)
    let decoded = try ExportDocument.decode(exported.encode())
    let imported = StoreImporter.apply(decoded, to: .empty, mode: .replace)

    #expect(
        imported.store.tunnels.map { ExportedTunnel(tunnel: $0) }
            == store.tunnels.map { ExportedTunnel(tunnel: $0) })
    #expect(imported.store.rules == store.rules)
    #expect(imported.secrets.count == 4)
    let originalOVPN = try secretStore.read(.ovpn(importedOpenVPNID))
    let originalCredentials = try secretStore.read(.credentials(importedOpenVPNID))
    let originalPassphrase = try secretStore.read(.keyPassphrase(importedOpenVPNID))
    let originalUUID = try secretStore.read(.uuid(importedVLESSID))
    #expect(imported.secrets[.ovpn(importedOpenVPNID)] == originalOVPN)
    #expect(imported.secrets[.credentials(importedOpenVPNID)] == originalCredentials)
    #expect(imported.secrets[.keyPassphrase(importedOpenVPNID)] == originalPassphrase)
    #expect(imported.secrets[.uuid(importedVLESSID)] == originalUUID)

    let sanitized = try StoreExporter.document(
        store: store, secretStore: secretStore, includeSecrets: false, exportedAt: importDate)
    #expect(sanitized.includesSecrets == false)
    #expect(sanitized.tunnels.map(\.secrets.isEmpty) == [true, true])
}
