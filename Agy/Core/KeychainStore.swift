import Foundation
import Security

/// iOS Keychain 凭证存储（按当前 Bundle ID 动态隔离，避免与同证书其他 IPA 冲突；并兼容旧版令牌自动迁移）
enum KeychainStore {
    private static let legacyService = "app.lake9674.aquila8809.tokens"

    private static var service: String {
        let bid = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (bid?.isEmpty == false) ? bid! : "cc.nooh.antigravity"
        return "\(base).tokens"
    }

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
        if let hit = loadFromService(service, account: account) {
            return hit
        }
        // 同团队证书换独立包名后，仅对 Antigravity 自有键前缀做一次只读迁移，绝不触碰其他 IPA 数据
        if service != legacyService,
           (account.hasPrefix("agy_token::") || account.hasPrefix("agy_custom_")),
           let migrated = loadFromService(legacyService, account: account) {
            save(migrated, account: account)
            return migrated
        }
        return nil
    }

    private static func loadFromService(_ svc: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
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
