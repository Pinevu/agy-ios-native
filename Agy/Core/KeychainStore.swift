import Foundation
import Security

/// iOS Keychain 凭证存储（自动静默迁移旧版明文 UserDefaults 令牌）
enum KeychainStore {
    private static let service = "app.lake9674.aquila8809.tokens"

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else {
            return nil
        }
        return str
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 优先读 Keychain；若仅在旧版 UserDefaults 中存在，自动迁移入 Keychain 并擦除明文副本
    static func loadOrMigrateToken(for legacyKey: String) -> String? {
        if let secure = load(account: legacyKey) {
            return secure
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
            save(legacy, account: legacyKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return legacy
        }
        return nil
    }
}
