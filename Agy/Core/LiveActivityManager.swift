import Foundation
import ActivityKit

/// 零轮询灵动岛 / 锁屏实时活动管理器
/// Widget 侧通过 Text(startedAt, style: .timer) 原生每秒跳动，App 仅在状态/步骤变更时推送更新，
/// 彻底省掉 5 秒轮询定时器的耗电与 ActivityKit 配额消耗。
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<AgyActivityAttributes>?
    private var startedAt: Date = Date()
    private var lastStepPush: Date = .distantPast
    private var state = AgyActivityAttributes.ContentState(
        title: "",
        startedAt: Date(),
        step: "正在启动…",
        running: true,
        subagentCount: 0,
        privacyMode: AgySharedStore.liveActivityPrivacyMode,
        finalElapsed: nil
    )

    private var available: Bool {
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    func start(
        title: String,
        sessionKey: String,
        step: String = "正在思考…",
        startedAt: Date = Date(),
        subagentCount: Int = 0
    ) {
        guard available, #available(iOS 16.2, *) else { return }

        let privacy = AgySharedStore.liveActivityPrivacyMode
        if activity == nil {
            self.startedAt = startedAt
            state = .init(
                title: title,
                startedAt: startedAt,
                step: step,
                running: true,
                subagentCount: subagentCount,
                privacyMode: privacy,
                finalElapsed: nil
            )
            let attrs = AgyActivityAttributes(sessionKey: sessionKey)
            activity = try? Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil)
            )
        } else {
            update(title: title, step: step, running: true, subagentCount: subagentCount)
        }
    }

    func update(
        title: String? = nil,
        step: String? = nil,
        running: Bool? = nil,
        subagentCount: Int? = nil
    ) {
        guard available, #available(iOS 16.2, *) else { return }
        guard let act = activity else { return }

        // 纯步骤更新 1.5 秒节流，避免高频工具事件拖慢主线程
        if title == nil, running == nil, subagentCount == nil {
            let now = Date()
            guard now.timeIntervalSince(lastStepPush) > 1.5 else { return }
            lastStepPush = now
        }

        let prev = state
        if let t = title, !t.isEmpty { state.title = t }
        if let s = step, !s.isEmpty { state.step = s }
        if let r = running { state.running = r }
        if let c = subagentCount { state.subagentCount = max(0, c) }
        state.privacyMode = AgySharedStore.liveActivityPrivacyMode

        guard state != prev else { return }
        let snapshot = state
        Task { await act.update(.init(state: snapshot, staleDate: nil)) }
    }

    func refreshPrivacyMode() {
        guard available, #available(iOS 16.2, *), let act = activity else { return }
        state.privacyMode = AgySharedStore.liveActivityPrivacyMode
        let snapshot = state
        Task { await act.update(.init(state: snapshot, staleDate: nil)) }
    }

    func end(step: String = "已完成") {
        guard available, #available(iOS 16.2, *) else { return }
        guard let act = activity else { return }
        state.step = step
        state.running = false
        state.subagentCount = 0
        state.finalElapsed = max(1, Int(Date().timeIntervalSince(startedAt)))
        let finalState = state
        activity = nil
        Task {
            await act.update(.init(state: finalState, staleDate: nil))
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await act.end(.init(state: finalState, staleDate: nil),
                          dismissalPolicy: .after(Date().addingTimeInterval(4)))
        }
    }
}
