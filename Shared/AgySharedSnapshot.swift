import Foundation

/// 主 App、桌面小组件与 Siri Shortcuts 共享的轻量状态快照
/// 优先使用 App Group；免签侧载环境无 App Group 权限时自动回退标准 UserDefaults，避免崩溃。
struct AgyWidgetSessionItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let updated: Double
    let running: Bool
    let unread: Bool
}

struct AgyWidgetQuotaItem: Codable, Hashable {
    let label: String
    let remaining: Double
}

struct AgySharedSnapshot: Codable {
    var instanceName: String
    var runningCount: Int
    var activeTaskTitle: String?
    var activeTaskTool: String?
    var recentSessions: [AgyWidgetSessionItem]
    var quotaPlan: String?
    var quotaPrimary: AgyWidgetQuotaItem?
    var updatedAt: Date

    static let empty = AgySharedSnapshot(
        instanceName: "Antigravity",
        runningCount: 0,
        activeTaskTitle: nil,
        activeTaskTool: nil,
        recentSessions: [],
        quotaPlan: nil,
        quotaPrimary: nil,
        updatedAt: Date()
    )
}

enum AgySharedStore {
    static let appGroupId = "group.app.lake9674.aquila8809"
    private static let snapshotKey = "agy_shared_snapshot_v2"
    private static let privacyKey = "agy_live_activity_privacy"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupId) ?? .standard
    }

    static func save(_ snapshot: AgySharedSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func load() -> AgySharedSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(AgySharedSnapshot.self, from: data) else {
            return .empty
        }
        return snap
    }

    static var liveActivityPrivacyMode: Bool {
        get { defaults.bool(forKey: privacyKey) }
        set { defaults.set(newValue, forKey: privacyKey) }
    }
}
