import Foundation

/// 主 App、桌面小组件与 Siri Shortcuts 共享的轻量状态快照
/// 自动探测当前签名描述文件授予的真实 App Group 容器（支持定制个人证书多槽位避冲突），无权限时静默回退标准 UserDefaults。
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

/// 运行时解析 embedded.mobileprovision 的证书与权限诊断信息
struct AgyProvisioningInfo {
    let bundleId: String
    let teamName: String?
    let teamId: String?
    let appIdentifier: String?
    let expirationDate: Date?
    let isWildcard: Bool
    let grantedAppGroups: [String]
    let hasIncreasedMemory: Bool
    let hasTimeSensitiveNotifications: Bool
    let hasPush: Bool
    let hasSiri: Bool
}

enum AgySharedStore {
    private static let snapshotKey = "agy_antigravity_snapshot_v3"
    private static let privacyKey = "agy_antigravity_live_privacy_v2"

    /// 优先按高槽位倒序探测（例如 .5 -> .4 -> ... -> .1），避免与同证书其他 IPA 抢占 .1 槽位
    private static let knownFallbackGroups: [String] = [
        "group.8e0bc870a21520b9.5",
        "group.8e0bc870a21520b9.4",
        "group.8e0bc870a21520b9.3",
        "group.8e0bc870a21520b9.2",
        "group.8e0bc870a21520b9.1",
        "group.cc.nooh.antigravity"
    ]

    static let provisioningInfo: AgyProvisioningInfo = inspectEmbeddedProvisioning()

    static let resolvedAppGroupId: String? = detectUsableAppGroup()

    static var activeAppGroupDisplay: String {
        resolvedAppGroupId ?? "独立沙盒（未授予 App Group）"
    }

    private static var defaults: UserDefaults {
        if let gid = resolvedAppGroupId, let suite = UserDefaults(suiteName: gid) {
            return suite
        }
        return .standard
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

    // MARK: - 动态证书与 App Group 探测

    private static func detectUsableAppGroup() -> String? {
        var candidates: [String] = []
        // 1. 优先从当前签名描述文件授予的 App Group 倒序挑选（.5 优先，避开其他 IPA 常用的 .1）
        let profileGroups = provisioningInfo.grantedAppGroups.sorted(by: >)
        candidates.append(contentsOf: profileGroups)

        // 2. 补充基于当前主包名的标准命名与已知证书槽位
        let mainBid = normalizedMainBundleId()
        if !mainBid.isEmpty {
            candidates.append("group.\(mainBid)")
        }
        candidates.append(contentsOf: knownFallbackGroups)

        var seen = Set<String>()
        for gid in candidates {
            guard !gid.isEmpty, seen.insert(gid).inserted else { continue }
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: gid) != nil {
                return gid
            }
        }
        return nil
    }

    private static func normalizedMainBundleId() -> String {
        let bid = Bundle.main.bundleIdentifier ?? ""
        if bid.hasSuffix(".widget") {
            return String(bid.dropLast(".widget".count))
        }
        return bid
    }

    private static func inspectEmbeddedProvisioning() -> AgyProvisioningInfo {
        let bid = Bundle.main.bundleIdentifier ?? "cc.nooh.antigravity"
        let empty = AgyProvisioningInfo(
            bundleId: bid,
            teamName: nil,
            teamId: nil,
            appIdentifier: nil,
            expirationDate: nil,
            isWildcard: false,
            grantedAppGroups: [],
            hasIncreasedMemory: false,
            hasTimeSensitiveNotifications: false,
            hasPush: false,
            hasSiri: false
        )

        var probeURLs: [URL] = []
        if let u = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            probeURLs.append(u)
        }
        // Widget Extension 可回退检查主 App 包内描述文件
        let parentApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let parentProv = parentApp.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: parentProv.path) {
            probeURLs.append(parentProv)
        }

        for url in probeURLs {
            guard let raw = try? Data(contentsOf: url),
                  let startRange = raw.range(of: Data("<?xml".utf8)),
                  let endRange = raw.range(of: Data("</plist>".utf8), in: startRange.lowerBound..<raw.endIndex) else {
                continue
            }
            let xmlData = raw.subdata(in: startRange.lowerBound..<endRange.upperBound)
            guard let plist = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil) as? [String: Any] else {
                continue
            }
            let ent = (plist["Entitlements"] as? [String: Any]) ?? [:]
            let teamName = plist["TeamName"] as? String
            let teamId = (plist["TeamIdentifier"] as? [String])?.first ?? (ent["com.apple.developer.team-identifier"] as? String)
            let appId = ent["application-identifier"] as? String
            let exp = plist["ExpirationDate"] as? Date
            let groups = (ent["com.apple.security.application-groups"] as? [String]) ?? []
            let increasedMem = (ent["com.apple.developer.kernel.increased-memory-limit"] as? Bool) == true
            let timeSens = (ent["com.apple.developer.usernotifications.time-sensitive"] as? Bool) == true
            let push = (ent["aps-environment"] as? String)?.isEmpty == false
            let siri = (ent["com.apple.developer.siri"] as? Bool) == true
            return AgyProvisioningInfo(
                bundleId: bid,
                teamName: teamName,
                teamId: teamId,
                appIdentifier: appId,
                expirationDate: exp,
                isWildcard: (appId?.hasSuffix(".*") == true),
                grantedAppGroups: groups,
                hasIncreasedMemory: increasedMem,
                hasTimeSensitiveNotifications: timeSens,
                hasPush: push,
                hasSiri: siri
            )
        }
        return empty
    }
}
