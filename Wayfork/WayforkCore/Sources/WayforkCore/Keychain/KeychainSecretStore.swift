import Foundation
import Security

/// Generic-password items in the login keychain, service `com.wayfork`, one item per
/// secret (docs/design/01-data-model.md, "Keychain"). Default ACL: readable by the signed
/// app only. Never used by the daemon.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = WayforkIdentifiers.keychainService) {
        self.service = service
    }

    public func read(_ key: SecretKey) throws -> String? {
        var query = baseQuery(key.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            guard let string = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.notUTF8
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func write(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let query = baseQuery(key.account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Wayfork \(key.account)"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(key.account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }

    public func allKeys() throws -> [SecretKey] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecUseDataProtectionKeychain as String] = false
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { item in
                (item[kSecAttrAccount as String] as? String).flatMap(SecretKey.init(account:))
            }
        case errSecItemNotFound:
            return []
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
