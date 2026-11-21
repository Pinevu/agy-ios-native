import Foundation
import ActivityKit

/// 主 App 与灵动岛 / 锁屏 Widget 共享的实时活动定义（零轮询原生计时架构）
struct AgyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 当前会话标题
        var title: String
        /// 任务启动时间戳：Widget 侧用 Text(startedAt, style: .timer) 原生每秒跳动，无需后台轮询
        var startedAt: Date
        /// 最近一条动作说明（如「执行命令」「正在思考…」）
        var step: String
        /// 是否仍在运行
        var running: Bool
        /// 并行子代理 / 后台任务计数
        var subagentCount: Int
        /// 锁屏隐私模式：开启后隐藏具体标题与工具详情
        var privacyMode: Bool
        /// 结束时的定格耗时（秒），running == false 时显示
        var finalElapsed: Int?

        init(
            title: String,
            startedAt: Date = Date(),
            step: String = "正在思考…",
            running: Bool = true,
            subagentCount: Int = 0,
            privacyMode: Bool = false,
            finalElapsed: Int? = nil
        ) {
            self.title = title
            self.startedAt = startedAt
            self.step = step
            self.running = running
            self.subagentCount = subagentCount
            self.privacyMode = privacyMode
            self.finalElapsed = finalElapsed
        }
    }

    /// 会话 id（用于点击灵动岛 DeepLink 回跳）
    var sessionKey: String
}
