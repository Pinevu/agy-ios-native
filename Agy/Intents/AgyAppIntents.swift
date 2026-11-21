import Foundation
import AppIntents

/// iOS 16.2+ 安全的 Siri 与快捷指令集成（严格遵循无参短语规范，避开 iOS 16 AppEntity 初始化崩溃）

struct AskAgyIntent: AppIntent {
    static var title: LocalizedStringResource = "向 Antigravity 提问"
    static var description = IntentDescription("打开 Antigravity 并自动发送一条提示词")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "提问内容")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.enqueue(.newChat(prompt: prompt, autoSend: true))
        return .result()
    }
}

struct OpenAgyNewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "发起新对话"
    static var description = IntentDescription("直接打开 Antigravity 新对话界面")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.enqueue(.newChat(prompt: nil, autoSend: false))
        return .result()
    }
}

struct OpenAgyVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "语音提问 Antigravity"
    static var description = IntentDescription("打开 Antigravity 并立即开始语音输入")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.enqueue(.voice)
        return .result()
    }
}

struct OpenAgyJobsIntent: AppIntent {
    static var title: LocalizedStringResource = "打开定时任务中心"
    static var description = IntentDescription("查看并管理 Antigravity 定时 Cron 任务")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.enqueue(.jobs)
        return .result()
    }
}

struct GetAgyRunningStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "查询运行中任务"
    static var description = IntentDescription("不打开 App，直接通过 Siri 播报当前运行中的任务状态")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snap = AgySharedStore.load()
        if snap.runningCount > 0 {
            let title = snap.activeTaskTitle ?? "后台任务"
            let tool = snap.activeTaskTool.map { "，正在执行 \($0)" } ?? ""
            let msg = "当前有 \(snap.runningCount) 个任务运行中：\(title)\(tool)。"
            return .result(dialog: IntentDialog(stringLiteral: msg))
        }
        return .result(dialog: IntentDialog(stringLiteral: "Antigravity 当前没有正在运行的任务。"))
    }
}

@available(iOS 17.0, *)
struct AgyShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAgyNewChatIntent(),
            phrases: [
                "在 \(.applicationName) 发起新对话",
                "打开 \(.applicationName) 新对话"
            ],
            shortTitle: "新对话",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenAgyVoiceIntent(),
            phrases: [
                "用 \(.applicationName) 语音提问",
                "对 \(.applicationName) 说话"
            ],
            shortTitle: "语音提问",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: GetAgyRunningStatusIntent(),
            phrases: [
                "查看 \(.applicationName) 任务状态",
                "\(.applicationName) 还在跑吗"
            ],
            shortTitle: "任务状态",
            systemImageName: "bolt.circle"
        )
        AppShortcut(
            intent: OpenAgyJobsIntent(),
            phrases: [
                "打开 \(.applicationName) 定时任务"
            ],
            shortTitle: "定时任务",
            systemImageName: "clock.badge.checkmark"
        )
    }
}
