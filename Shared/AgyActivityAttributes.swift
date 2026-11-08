import Foundation
import ActivityKit

/// 主 App 与灵动岛 Widget 共享的活动定义
struct AgyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 当前会话标题
        var title: String
        /// 已运行秒数
        var elapsed: Int
        /// 最近一条动作（如 run_command / 正在思考）
        var step: String
        /// 是否仍在运行
        var running: Bool
    }

    /// 实例标识（会话 id），整个活动期内不变
    var sessionKey: String
}
