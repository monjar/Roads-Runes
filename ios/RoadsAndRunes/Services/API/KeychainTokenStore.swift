import Foundation
import RoadsAndRunesCore
import Security

/// Keychain-backed token store shared with the Watch through the app group.
final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account = "tokens"
    private let lock = NSLock()

    init(service: String = Config.keychainService) {
        self.service = service
    }

    func load() -> AuthTokens? {
        lock.lock(); defer { lock.unlock() }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONCoding.decode(AuthTokens.self, from: data)
    }

    func save(_ tokens: AuthTokens) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONCoding.encode(tokens) else { return }
        var query = baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
