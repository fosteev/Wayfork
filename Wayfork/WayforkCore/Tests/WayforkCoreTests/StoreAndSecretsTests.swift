import Foundation
import Testing

@testable import WayforkCore

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wayfork-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func repositoryLoadsEmptyStoreWhenFileIsMissing() async throws {
    let repo = StoreRepository(directory: temporaryDirectory().appendingPathComponent("nested"))
    let result = try await repo.load()
    #expect(result.store == .empty)
    #expect(result.corruptBackup == nil)
}

@Test func repositoryWritesAtomicallyAndReloads() async throws {
    let dir = temporaryDirectory()
    let repo = StoreRepository(directory: dir, debounce: .milliseconds(20))
    let store = Fixtures.store(rules: [Rule(pattern: "example.com", tunnelID: Fixtures.workID)])

    await repo.save(store)
    #expect(await repo.hasPendingChanges)
    try await repo.flush()
    #expect(await !repo.hasPendingChanges)

    let reloaded = try await StoreRepository(directory: dir).load()
    #expect(reloaded.store == store)

    let attributes = try FileManager.default.attributesOfItem(atPath: await repo.fileURL.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
}

@Test func repositoryDebouncesSaves() async throws {
    let dir = temporaryDirectory()
    let repo = StoreRepository(directory: dir, debounce: .milliseconds(30))
    var store = Store()
    for i in 0..<5 {
        store.settings.logRetentionDays = i
        await repo.save(store)
    }
    try await Task.sleep(for: .milliseconds(200))
    let reloaded = try await repo.load()
    #expect(reloaded.store.settings.logRetentionDays == 4)
}

@Test func repositoryMovesCorruptFileAside() async throws {
    let dir = temporaryDirectory()
    let file = dir.appendingPathComponent(StoreRepository.fileName)
    try Data("{not json".utf8).write(to: file)
    let result = try await StoreRepository(directory: dir).load()
    #expect(result.store == .empty)
    let backup = try #require(result.corruptBackup)
    #expect(backup.lastPathComponent.hasPrefix("store.json.corrupt-"))
    #expect(FileManager.default.fileExists(atPath: backup.path))
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func repositoryRefusesNewerSchema() async throws {
    let dir = temporaryDirectory()
    let file = dir.appendingPathComponent(StoreRepository.fileName)
    try Data("{\"schemaVersion\": 7, \"tunnels\": [], \"rules\": [], \"settings\": {}}".utf8).write(
        to: file)
    await #expect(throws: StoreRepository.Error.self) {
        try await StoreRepository(directory: dir).load()
    }
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func secretKeysMapToAccounts() {
    let id = Fixtures.workID
    #expect(SecretKey.ovpn(id).account == "tunnel/00000000-0000-4000-8000-000000000001/ovpn")
    #expect(
        SecretKey.credentials(id).account
            == "tunnel/00000000-0000-4000-8000-000000000001/credentials")
    #expect(
        SecretKey.keyPassphrase(id).account
            == "tunnel/00000000-0000-4000-8000-000000000001/keyPassphrase")
    #expect(SecretKey.uuid(id).account == "tunnel/00000000-0000-4000-8000-000000000001/uuid")
    #expect(
        SecretKey.privateKey(id).account
            == "tunnel/00000000-0000-4000-8000-000000000001/privateKey")
    #expect(
        SecretKey.presharedKey(id).account
            == "tunnel/00000000-0000-4000-8000-000000000001/presharedKey")
    #expect(
        SecretKey.password(id).account
            == "tunnel/00000000-0000-4000-8000-000000000001/password")
    for key in SecretKey.all(for: id) {
        #expect(SecretKey(account: key.account) == key)
    }
    #expect(SecretKey(account: "other/thing") == nil)
    #expect(SecretKey(account: "tunnel/not-a-uuid/ovpn") == nil)
}

@Test func secretStoreHelpersAndOrphanCleanup() throws {
    let store = InMemorySecretStore()
    let credentials = Credentials(username: "u", password: "p")
    try store.writeCredentials(credentials, for: Fixtures.workID)
    #expect(try store.readCredentials(for: Fixtures.workID) == credentials)
    #expect(try store.readCredentials(for: Fixtures.homeID) == nil)

    let orphan = UUID()
    try store.write("body", for: .ovpn(orphan))
    try store.write("uuid", for: .uuid(Fixtures.homeID))
    let removed = try store.removeOrphans(keeping: Fixtures.store())
    #expect(removed == [.ovpn(orphan)])
    #expect(try store.read(.uuid(Fixtures.homeID)) == "uuid")

    try store.deleteAll(for: Fixtures.workID)
    #expect(try store.read(.credentials(Fixtures.workID)) == nil)
}

@Test func planSecretsLoadOnlyWhatEnabledTunnelsNeed() throws {
    let secrets = InMemorySecretStore()
    try secrets.write("client\nremote vpn.example.org 1194\n", for: .ovpn(Fixtures.workID))
    try secrets.writeCredentials(Credentials(username: "u", password: "p"), for: Fixtures.workID)
    try secrets.write("passphrase", for: .keyPassphrase(Fixtures.workID))
    try secrets.write("00000000-0000-4000-8000-0000000000aa", for: .uuid(Fixtures.homeID))

    var store = Fixtures.store()
    let loaded = try PlanSecrets.load(for: store, from: secrets)
    #expect(loaded.openVPNConfigs[Fixtures.workID] != nil)
    #expect(loaded.credentials[Fixtures.workID]?.username == "u")
    #expect(loaded.keyPassphrases[Fixtures.workID] == nil)  // needsKeyPassphrase is false
    #expect(loaded.vlessUUIDs[Fixtures.homeID] == "00000000-0000-4000-8000-0000000000aa")

    store.tunnels[1].isEnabled = false
    let partial = try PlanSecrets.load(for: store, from: secrets)
    #expect(partial.vlessUUIDs.isEmpty)
}

@Test func planSecretsLoadWireGuardKeys() throws {
    var store = Fixtures.store()
    store.tunnels = [
        Tunnel(
            id: Fixtures.homeID, name: "WireGuard", slot: 1,
            kind: .wireGuard(
                WireGuardMeta(
                    addresses: ["10.9.0.2/32"],
                    peers: [
                        WireGuardPeer(
                            host: "wg.example.net", port: 51820,
                            publicKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=",
                            hasPresharedKey: true, allowedIPs: ["0.0.0.0/0"])
                    ])))
    ]
    let secrets = InMemorySecretStore([
        .privateKey(Fixtures.homeID): "private",
        .presharedKey(Fixtures.homeID): "preshared",
    ])

    let loaded = try PlanSecrets.load(for: store, from: secrets)
    #expect(
        loaded.wireGuardKeys[Fixtures.homeID]
            == WireGuardSecrets(privateKey: "private", presharedKey: "preshared"))

    let plan = RuntimePlanBuilder.build(store: store, secrets: loaded, bundlePath: "/App")
    #expect(plan.plan.openVPN.isEmpty)
    #expect(plan.routedTunnels.map(\.id) == [Fixtures.homeID])
}

@Test func planSecretsLoadProxyPasswordsAndVMessUUIDSeparately() throws {
    let shadowsocksID = UUID(uuidString: "00000000-0000-4000-8000-000000000041")!
    let trojanID = UUID(uuidString: "00000000-0000-4000-8000-000000000042")!
    let vmessID = UUID(uuidString: "00000000-0000-4000-8000-000000000043")!
    let store = Store(tunnels: [
        Tunnel(
            id: shadowsocksID, name: "SS", slot: 0,
            kind: .shadowsocks(
                ShadowsocksMeta(server: "ss.example.net", port: 8388, method: "aes-256-gcm"))),
        Tunnel(
            id: trojanID, name: "Trojan", slot: 1,
            kind: .trojan(
                TrojanMeta(server: "trojan.example.net", port: 443, security: .tls))),
        Tunnel(
            id: vmessID, name: "VMess", slot: 2,
            kind: .vmess(
                VMessMeta(
                    server: "vmess.example.net", port: 443, security: "auto",
                    tlsSecurity: .tls))),
    ])
    let secretStore = InMemorySecretStore([
        .password(shadowsocksID): "fake-ss-password",
        .password(trojanID): "fake-trojan-password",
        .uuid(vmessID): "00000000-0000-4000-8000-000000000044",
    ])

    let loaded = try PlanSecrets.load(for: store, from: secretStore)
    #expect(loaded.passwords[shadowsocksID] == "fake-ss-password")
    #expect(loaded.passwords[trojanID] == "fake-trojan-password")
    #expect(loaded.vmessUUIDs[vmessID] == "00000000-0000-4000-8000-000000000044")
    #expect(loaded.vlessUUIDs.isEmpty)
}
