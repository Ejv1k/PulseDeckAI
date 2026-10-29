import Foundation
import Security

/// Thread-safe storage for sensitive secrets such as Gemini API keys.
public protocol SecretStore: Sendable {
    func getSecret(forKey key: String) -> String?
    func setSecret(_ value: String?, forKey key: String)
}

/// In-memory secret store used in tests and isolated QA environments to avoid Keychain prompts.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(initialSecrets: [String: String] = [:]) {
        self.storage = initialSecrets
    }

    public func getSecret(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}

/// macOS Keychain backed secret store for production use.
/// Uses `kSecClassGenericPassword` with service identifier `com.pulsedeckai.secrets`.
public final class KeychainSecretStore: SecretStore, Sendable {
    public let service: String

    public init(service: String = "com.pulsedeckai.secrets") {
        self.service = service
    }

    public func getSecret(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }

    public func setSecret(_ value: String?, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        guard let value = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }
}
