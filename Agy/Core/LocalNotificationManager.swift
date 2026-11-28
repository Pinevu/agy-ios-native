import Foundation
import UIKit
import UserNotifications

/// 后台任务完成本地通知（支持证书授予的 Time-Sensitive 时效通知，点击直达对应会话）
@MainActor
final class LocalNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationManager()

    private static let enabledKey = "agy_local_task_notify_enabled_v1"

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: enabledKey) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private override init() {
        super.init()
    }

    func configureDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func setEnabled(_ wantOn: Bool) async -> Bool {
        if !wantOn {
            isEnabled = false
            return true
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            isEnabled = granted
            return granted
        } catch {
            isEnabled = false
            return false
        }
    }

    func notifyTaskFinished(title: String, sessionId: String?, isError: Bool = false) {
        guard isEnabled else { return }
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = isError ? "⚠️ 任务已中断" : "✅ 任务执行完成"
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = cleanTitle.isEmpty ? "点击返回 Antigravity 查看最新结果" : cleanTitle
        content.sound = .default
        if AgySharedStore.provisioningInfo.hasTimeSensitiveNotifications {
            content.interruptionLevel = .timeSensitive
        } else {
            content.interruptionLevel = .active
        }
        if let sid = sessionId, !sid.isEmpty, !sid.hasPrefix("draft-") {
            content.userInfo = ["session_id": sid]
        }

        let req = UNNotificationRequest(
            identifier: "agy-done-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sid = response.notification.request.content.userInfo["session_id"] as? String
        Task { @MainActor in
            if let sid, !sid.isEmpty {
                DeepLinkRouter.shared.enqueue(.session(id: sid))
            } else {
                DeepLinkRouter.shared.enqueue(.open)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
