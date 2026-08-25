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
                    createdAt: exported.createdAt))
            tunnelsAdded += 1
            collect(exported.secrets, for: exported.id, into: &secrets)
        }

        var rulesAdded = 0
        var rulesUpdated = 0
        var rulesSkipped = 0
        if mode == .replace {
            result.rules = []
        }
        let tunnelIDs = Set(result.tunnels.map(\.id))
        for rule in document.rules {
            if let tunnelID = rule.tunnelID, !tunnelIDs.contains(tunnelID) {
                let shortID = tunnelID.uuidString.lowercased().prefix(4)
                warnings.append("Rule \(rule.pattern) skipped: tunnel \(shortID)… not found")
                rulesSkipped += 1
                continue
            }
            if mode == .merge,
                let index = result.rules.firstIndex(where: { $0.id == rule.id })
            {
                result.rules[index] = rule
                rulesUpdated += 1
            } else {
                result.rules.append(rule)
                rulesAdded += 1
            }
        }

        // F8: the file's default replaces the current one only when it names a tunnel that
        // made it in; on Replace the fresh store has none to begin with.
        if let wanted = document.defaultTunnelID {
            if tunnelIDs.contains(wanted) {
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
            }
            return ExportedTunnel(tunnel: tunnel, secrets: secrets)
        }
        return ExportDocument(
            exportedAt: exportedAt,
            includesSecrets: includeSecrets,
            tunnels: tunnels,
            rules: store.rules,
            settings: store.settings,
            defaultTunnelID: store.defaultTunnelID)
    }
}
