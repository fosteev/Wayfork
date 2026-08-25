import Foundation

/// One secret slot, mapped to a Keychain account name (docs/design/01-data-model.md, "Keychain").
public enum SecretKey: Sendable, Hashable {
    case ovpn(UUID)
    case credentials(UUID)
    case keyPassphrase(UUID)
    case uuid(UUID)

    public var tunnelID: UUID {
        switch self {
        case .ovpn(let id), .credentials(let id), .keyPassphrase(let id), .uuid(let id): id
        }
    }

    /// `tunnel/<id>/<kind>`
    public var account: String {
        let id = tunnelID.uuidString.lowercased()
        switch self {
        case .ovpn: return "tunnel/\(id)/ovpn"
        case .credentials: return "tunnel/\(id)/credentials"
        case .keyPassphrase: return "tunnel/\(id)/keyPassphrase"
        case .uuid: return "tunnel/\(id)/uuid"
        }
    }

    /// Inverse of `account`; nil for accounts that are not ours.
    public init?(account: String) {
        let parts = account.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "tunnel", let id = UUID(uuidString: String(parts[1]))
        else {
            return nil
        }
        switch parts[2] {
        case "ovpn": self = .ovpn(id)
        case "credentials": self = .credentials(id)
        case "keyPassphrase": self = .keyPassphrase(id)
        case "uuid": self = .uuid(id)
        default: return nil
        }
    }

    public static func all(for tunnelID: UUID) -> [SecretKey] {
        [.ovpn(tunnelID), .credentials(tunnelID), .keyPassphrase(tunnelID), .uuid(tunnelID)]
    }
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// Underlying `OSStatus` from the Security framework.
    case keychain(OSStatus)
    case notUTF8
}

/// Secret storage. The Keychain implementation is `KeychainSecretStore`; tests use
/// `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> String?
    func write(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
    /// Every account currently stored under our service.
    func allKeys() throws -> [SecretKey]
}

extension SecretStore {
    public func writeCredentials(_ credentials: Credentials, for tunnelID: UUID) throws {
        let data = try JSONCoding.compactEncoder.encode(credentials)
        try write(String(decoding: data, as: UTF8.self), for: .credentials(tunnelID))
    }

    public func readCredentials(for tunnelID: UUID) throws -> Credentials? {
        guard let json = try read(.credentials(tunnelID)) else { return nil }
        return try JSONCoding.decoder.decode(Credentials.self, from: Data(json.utf8))
    }

    /// Removes every item of a tunnel; used when the tunnel is deleted.
    public func deleteAll(for tunnelID: UUID) throws {
        for key in SecretKey.all(for: tunnelID) {
            try delete(key)
        }
    }

    /// Deletes items whose tunnel no longer exists in `store`. Returns what was removed.
    @discardableResult
    public func removeOrphans(keeping store: Store) throws -> [SecretKey] {
        let known = Set(store.tunnels.map(\.id))
        var removed: [SecretKey] = []
        for key in try allKeys() where !known.contains(key.tunnelID) {
            try delete(key)
            removed.append(key)
        }
        return removed
    }
}

/// Test double and preview backend.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SecretKey: String] = [:]

    public init(_ items: [SecretKey: String] = [:]) {
        self.items = items
    }

    public func read(_ key: SecretKey) throws -> String? {
        lock.withLock { items[key] }
    }

    public func write(_ value: String, for key: SecretKey) throws {
        lock.withLock { items[key] = value }
    }

    public func delete(_ key: SecretKey) throws {
        lock.withLock { _ = items.removeValue(forKey: key) }
    }

    public func allKeys() throws -> [SecretKey] {
        lock.withLock { Array(items.keys) }
    }
}
