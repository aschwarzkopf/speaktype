import Foundation
import Security

enum ClaudeAPIKeyStoreError: Error {
    case emptyKey
    case keychain(OSStatus)
}

/// Keychain-backed storage for the Anthropic API key.
///
/// Uses a generic-password Keychain item scoped to the app bundle and
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the key
/// survives reboots but never syncs to iCloud or another device.
///
/// Initializer accepts custom service+account values so tests can
/// scope themselves to disposable Keychain entries; production
/// callers go through `.shared`.
final class ClaudeAPIKeyStore {
    static let shared = ClaudeAPIKeyStore(
        service: "com.2048labs.speaktype.anthropic-api-key",
        account: "default"
    )

    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    var hasKey: Bool {
        load() != nil
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClaudeAPIKeyStoreError.emptyKey
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ClaudeAPIKeyStoreError.emptyKey
        }

        // Delete-then-add — SecItemAdd fails with errSecDuplicateItem
        // when an entry already exists, so an idempotent save needs an
        // explicit delete first. SecItemUpdate is an alternative but
        // adds a branch.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ClaudeAPIKeyStoreError.keychain(status)
        }
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
            let data = item as? Data,
            let key = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return key
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is fine — delete is a no-op when nothing
        // is stored. Any other failure surfaces.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeAPIKeyStoreError.keychain(status)
        }
    }
}
