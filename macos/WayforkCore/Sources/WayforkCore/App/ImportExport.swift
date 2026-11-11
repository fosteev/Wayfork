import Foundation

public enum ImportMode: Sendable, Hashable {
    case replace
    case merge
}

public struct ImportPreview: Sendable, Hashable {
    public var tunnels: Int
    public var rules: Int
    public var includesSecrets: Bool
    public var tunnelsWithSecrets: Int

    public init(tunnels: Int, rules: Int, includesSecrets: Bool, tunnelsWithSecrets: Int) {
        self.tunnels = tunnels
        self.rules = rules
        self.includesSecrets = includesSecrets
        self.tunnelsWithSecrets = tunnelsWithSecrets
    }
}

public struct ImportOutcome: Sendable, Equatable {
    public var store: Store
    public var secrets: [SecretKey: String]
    public var warnings: [String]
    public var tunnelsAdded: Int
    public var tunnelsUpdated: Int
    public var rulesAdded: Int
    public var rulesUpdated: Int
    public var rulesSkipped: Int
}

public enum StoreImporter {
    public static func preview(_ document: ExportDocument) -> ImportPreview {
        ImportPreview(
            tunnels: document.tunnels.count,
            rules: document.rules.count,
            includesSecrets: document.includesSecrets,
            tunnelsWithSecrets: document.tunnels.count { !$0.secrets.isEmpty })
    }

    public static func apply(
        _ document: ExportDocument, to store: Store, mode: ImportMode
    ) -> ImportOutcome {
        var result =
            mode == .replace
            ? Store(schemaVersion: store.schemaVersion, settings: document.settings)
            : store
        var secrets: [SecretKey: String] = [:]
        var warnings: [String] = []
        var tunnelsAdded = 0
        var tunnelsUpdated = 0

        for exported in document.tunnels {
            if mode == .merge,
                let index = result.tunnels.firstIndex(where: { $0.id == exported.id })
            {
                let name = availableName(
                    exported.name, for: exported.id, in: result, warnings: &warnings)
                result.tunnels[index].name = name
                result.tunnels[index].isEnabled = exported.isEnabled
                result.tunnels[index].kind = exported.kind
                result.tunnels[index].createdAt = exported.createdAt
                result.tunnels[index].localProxy = importedProxy(
                    exported.localProxy, name: exported.name, id: exported.id, in: result,
                    warnings: &warnings)
                tunnelsUpdated += 1
                collect(exported.secrets, for: exported.id, into: &secrets)
                continue
            }

            guard let slot = result.nextFreeSlot() else {
                warnings.append("Tunnel \(exported.name) skipped: no free slots")
                continue
            }
            let name = availableName(
                exported.name, for: exported.id, in: result, warnings: &warnings)
            result.tunnels.append(
                Tunnel(
                    id: exported.id,
                    name: name,
                    isEnabled: exported.isEnabled,
                    slot: slot,
                    kind: exported.kind,
                    createdAt: exported.createdAt,
                    localProxy: importedProxy(
                        exported.localProxy, name: exported.name, id: exported.id, in: result,
                        warnings: &warnings)))
            tunnelsAdded += 1
            collect(exported.secrets, for: exported.id, into: &secrets)
        }

        // F16: a group comes in when at least two of its members did; a colliding name is
        // suffixed like a tunnel's. On Merge an existing group is replaced by id.
        let tunnelIDs = Set(result.tunnels.map(\.id))
        if mode == .replace {
            result.groups = []
        }
        for group in document.groups {
            let members = group.members.filter { tunnelIDs.contains($0) }
            guard members.count >= TunnelGroup.minimumMembers else {
                warnings.append(
                    "Group \(group.name) skipped: fewer than two of its tunnels made it in")
                continue
            }
            var imported = group
            imported.localProxy = importedProxy(
                group.localProxy, name: group.name, id: group.id, in: result, warnings: &warnings)
            imported.members = members
            if let index = result.groups.firstIndex(where: { $0.id == group.id }) {
                result.groups[index] = imported
            } else {
                imported.name = availableName(
                    group.name, for: group.id, in: result, warnings: &warnings)
                result.groups.append(imported)
            }
        }
        let exitIDs = tunnelIDs.union(result.groups.map(\.id))

        var rulesAdded = 0
        let rulesUpdated = 0
        let rulesSkipped = 0
        if mode == .replace {
            result.rules = []
            result.lists = document.lists
        }
        var listIDs: [UUID: UUID] = [:]
        if mode == .merge {
            if !document.lists.isEmpty && !result.lists.isEmpty {
                warnings.append("Existing earlier lists can take precedence over imported rules")
            }
            for source in document.lists {
                if result.lists.contains(source) {
                    listIDs[source.id] = source.id
                    continue
                }
                // Reuse a name disambiguated by the previous import, but preserve user renames.
                if let sameID = result.list(id: source.id) {
                    var comparable = source
                    comparable.name = sameID.name
                    var otherLists = result
                    otherLists.lists.removeAll { $0.id == source.id }
                    if comparable == sameID,
                        sameID.name == otherLists.availableListName(source.name)
                    {
                        listIDs[source.id] = source.id
                        continue
                    }
                }
                var imported = source
                if result.list(id: source.id) != nil {
                    imported.id = remappedID(source.id, content: source)
                    if let existing = result.list(id: imported.id) {
                        var comparable = imported
                        comparable.name = existing.name
                        if comparable == existing {
                            listIDs[source.id] = existing.id
                            continue
                        }
                        warnings.append("List identity collision: import left unchanged")
                        return ImportOutcome(
                            store: store, secrets: [:], warnings: warnings,
                            tunnelsAdded: 0, tunnelsUpdated: 0, rulesAdded: 0, rulesUpdated: 0,
                            rulesSkipped: document.rules.count)
                    }
                    warnings.append("List \(source.name) imported with a new ID")
                }
                imported.name = result.availableListName(source.name)
                if imported.name != source.name {
                    warnings.append("List \(source.name) renamed to \(imported.name)")
                }
                listIDs[source.id] = imported.id
                result.lists.append(imported)
            }
        }
        for source in document.rules {
            var rule = source
            if let id = rule.listID { rule.listID = listIDs[id] ?? id }
            if result.rules.contains(rule) { continue }
            if mode == .merge && result.rules.contains(where: { $0.id == rule.id }) {
                rule.id = remappedID(source.id, content: rule)
                if result.rules.contains(rule) { continue }
                if result.rules.contains(where: { $0.id == rule.id }) {
                    warnings.append("Rule identity collision: import left unchanged")
                    return ImportOutcome(
                        store: store, secrets: [:], warnings: warnings,
                        tunnelsAdded: 0, tunnelsUpdated: 0, rulesAdded: 0, rulesUpdated: 0,
                        rulesSkipped: document.rules.count)
                }
            }
            // Content idempotence is scoped to membership, never a similarly named list.
            if mode == .merge
                && result.rules.contains(where: {
                    $0.listID == rule.listID && $0.pattern == rule.pattern && $0.match == rule.match
                        && $0.network == rule.network && $0.target == rule.target
                        && $0.isEnabled == rule.isEnabled && $0.note == rule.note
                })
            {
                continue
            }
            result.rules.append(rule)
            rulesAdded += 1
        }
        do { try result.validateMembership() } catch {
            return ImportOutcome(
                store: store, secrets: [:], warnings: ["Invalid list membership: \(error)"],
                tunnelsAdded: 0, tunnelsUpdated: 0, rulesAdded: 0, rulesUpdated: 0,
                rulesSkipped: document.rules.count)
        }

        // F8: the file's default replaces the current one only when it names a tunnel that
        // made it in; on Replace the fresh store has none to begin with.
        if let wanted = document.defaultTunnelID {
            if exitIDs.contains(wanted) {
                result.defaultTunnelID = wanted
            } else {
                let shortID = wanted.uuidString.lowercased().prefix(4)
                warnings.append(
                    "Default tunnel \(shortID)… not found: everything else stays direct")
            }
        }

        return ImportOutcome(
            store: result,
            secrets: secrets,
            warnings: warnings,
            tunnelsAdded: tunnelsAdded,
            tunnelsUpdated: tunnelsUpdated,
            rulesAdded: rulesAdded,
            rulesUpdated: rulesUpdated,
            rulesSkipped: rulesSkipped)
    }

    private static func remappedID<T: Encodable>(_ id: UUID, content: T) -> UUID {
        let data = (try? JSONCoding.compactEncoder.encode(content)) ?? Data()
        let hash = Hashing.sha256Hex(id.uuidString + String(decoding: data, as: UTF8.self))
        let chars = Array(hash.prefix(32))
        let text = [
            String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]),
            String(chars[16..<20]), String(chars[20..<32]),
        ].joined(separator: "-")
        return UUID(uuidString: text)!
    }

    /// F17: a port that another tunnel or group already holds is dropped with a warning
    /// (the address is machine-local anyway); an invalid one too.
    private static func importedProxy(
        _ proxy: LocalProxy?, name: String, id: UUID, in store: Store, warnings: inout [String]
    ) -> LocalProxy? {
        guard let proxy else { return nil }
        guard LocalProxy.portRange.contains(proxy.port) else {
            warnings.append("Local proxy port \(proxy.port) of \(name) dropped: outside 1024–65535")
            return nil
        }
        if let owner = store.localProxyPortOwner(proxy.port, excluding: id) {
            warnings.append(
                "Local proxy port \(proxy.port) of \(name) dropped: already used by \(owner)")
            return nil
        }
        return proxy
    }

    private static func availableName(
        _ requested: String, for id: UUID, in store: Store, warnings: inout [String]
    ) -> String {
        guard !store.isNameAvailable(requested, excluding: id) else { return requested }
        var number = 2
        while true {
            let suffix = " (\(number))"
            let base = String(requested.prefix(Tunnel.nameMaxLength - suffix.count))
            let candidate = base + suffix
            if store.isNameAvailable(candidate, excluding: id) {
                warnings.append("Tunnel \(requested) renamed to \(candidate)")
                return candidate
            }
            number += 1
        }
    }

    private static func collect(
        _ tunnelSecrets: TunnelSecrets, for id: UUID, into secrets: inout [SecretKey: String]
    ) {
        if let ovpn = tunnelSecrets.ovpn { secrets[.ovpn(id)] = ovpn }
        if let credentials = tunnelSecrets.credentials,
            let data = try? JSONCoding.compactEncoder.encode(credentials)
        {
            secrets[.credentials(id)] = String(decoding: data, as: UTF8.self)
        }
        if let passphrase = tunnelSecrets.keyPassphrase {
            secrets[.keyPassphrase(id)] = passphrase
        }
        if let uuid = tunnelSecrets.uuid { secrets[.uuid(id)] = uuid }
        if let password = tunnelSecrets.password { secrets[.password(id)] = password }
        if let privateKey = tunnelSecrets.privateKey { secrets[.privateKey(id)] = privateKey }
        if let presharedKey = tunnelSecrets.presharedKey {
            secrets[.presharedKey(id)] = presharedKey
        }
    }
}

public enum StoreExporter {
    public static func document(
        store: Store,
        secretStore: any SecretStore,
        includeSecrets: Bool,
        exportedAt: Date = Date()
    ) throws -> ExportDocument {
        let tunnels = try store.tunnels.map { tunnel in
            guard includeSecrets else { return ExportedTunnel(tunnel: tunnel) }
            let secrets: TunnelSecrets
            switch tunnel.kind {
            case .openVPN:
                secrets = try TunnelSecrets(
                    ovpn: secretStore.read(.ovpn(tunnel.id)),
                    credentials: secretStore.readCredentials(for: tunnel.id),
                    keyPassphrase: secretStore.read(.keyPassphrase(tunnel.id)))
            case .vless:
                secrets = try TunnelSecrets(uuid: secretStore.read(.uuid(tunnel.id)))
            case .wireGuard:
                secrets = try TunnelSecrets(
                    privateKey: secretStore.read(.privateKey(tunnel.id)),
                    presharedKey: secretStore.read(.presharedKey(tunnel.id)))
            case .shadowsocks, .trojan:
                secrets = try TunnelSecrets(password: secretStore.read(.password(tunnel.id)))
            case .vmess:
                secrets = try TunnelSecrets(uuid: secretStore.read(.uuid(tunnel.id)))
            }
            return ExportedTunnel(tunnel: tunnel, secrets: secrets)
        }
        return ExportDocument(
            exportedAt: exportedAt,
            includesSecrets: includeSecrets,
            tunnels: tunnels,
            rules: store.rules,
            settings: store.settings,
            defaultTunnelID: store.defaultTunnelID,
            groups: store.groups, lists: store.lists)
    }
}
