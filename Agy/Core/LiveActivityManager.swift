import Foundation
import ActivityKit

/// 零轮询灵动岛 / 锁屏实时活动管理器
/// Widget 侧通过 Text(startedAt, style: .timer) 原生每秒跳动，App 仅在状态/步骤变更时推送更新，
/// 彻底省掉 5 秒轮询定时器的耗电与 ActivityKit 配额消耗。
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// 每次刷新往后顺延 10 分钟；若 App 被系统挂起或划掉失联超过 10 分钟，灵动岛自动进入 stale 状态停止无止境走表
    private static let staleHorizon: TimeInterval = 600

    private var activity: Activity<AgyActivityAttributes>?
    private var startedAt: Date = Date()
    private var lastStepPush: Date = .distantPast
    private var lastHeartbeatPush: Date = .distantPast
    private var state = AgyActivityAttributes.ContentState(
        title: "",
        startedAt: Date(),
        step: "正在启动…",
        running: true,
        subagentCount: 0,
        privacyMode: AgySharedStore.liveActivityPrivacyMode,
        finalElapsed: nil
    )

    private var isEnabledByUser: Bool {
        (UserDefaults.standard.object(forKey: "agy_live_activity_enabled") as? Bool) ?? true
    }

    private var available: Bool {
        if #available(iOS 16.2, *) {
            return isEnabledByUser && ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    private func nextStaleDate() -> Date {
        Date().addingTimeInterval(Self.staleHorizon)
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

        // 优先收编系统里已存活的实时活动（如划掉重进后的残留实例），绝不重复创建多条灵动岛
        if activity == nil {
            let existing = Activity<AgyActivityAttributes>.activities
            if let first = existing.first {
                activity = first
                let emptyContent: ActivityContent<AgyActivityAttributes.ContentState>? = nil
                for dup in existing.dropFirst() {
                    Task { await dup.end(emptyContent, dismissalPolicy: .immediate) }
                }
            }
        }

        if let act = activity {
            self.startedAt = startedAt
            let next = AgyActivityAttributes.ContentState(
                title: title.isEmpty ? state.title : title,
                startedAt: startedAt,
                step: step.isEmpty ? state.step : step,
                running: true,
                subagentCount: max(0, subagentCount),
                privacyMode: privacy,
                finalElapsed: nil
            )
            let now = Date()
            let needHeartbeat = now.timeIntervalSince(lastHeartbeatPush) > 120
            guard next != state || needHeartbeat else { return }
            state = next
            lastHeartbeatPush = now
            let staleAt = nextStaleDate()
            Task { await act.update(.init(state: next, staleDate: staleAt)) }
        } else {
            self.startedAt = startedAt
            state = .init(
                title: title,
                startedAt: startedAt,
                step: step,
                running: true,
                subagentCount: max(0, subagentCount),
                privacyMode: privacy,
                finalElapsed: nil
            )
            lastHeartbeatPush = Date()
            let attrs = AgyActivityAttributes(sessionKey: sessionKey)
            activity = try? Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nextStaleDate())
            )
        }
    }

    func update(
        title: String? = nil,
        step: String? = nil,
        running: Bool? = nil,
        subagentCount: Int? = nil
    ) {
        guard available, #available(iOS 16.2, *) else { return }
        if activity == nil {
            activity = Activity<AgyActivityAttributes>.activities.first
        }
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

        let now = Date()
        let needHeartbeat = now.timeIntervalSince(lastHeartbeatPush) > 120
        guard state != prev || needHeartbeat else { return }
        lastHeartbeatPush = now
        let snapshot = state
        let staleAt = nextStaleDate()
        Task { await act.update(.init(state: snapshot, staleDate: staleAt)) }
    }

    func refreshPrivacyMode() {
        guard available, #available(iOS 16.2, *) else { return }
        if activity == nil {
            activity = Activity<AgyActivityAttributes>.activities.first
        }
        guard let act = activity else { return }
        state.privacyMode = AgySharedStore.liveActivityPrivacyMode
        let snapshot = state
        let staleAt = nextStaleDate()
        Task { await act.update(.init(state: snapshot, staleDate: staleAt)) }
    }

    /// 结束当前以及所有系统残留的灵动岛（修复划掉重进后 self.activity == nil 导致孤儿灵动岛永不消失的 Bug）
    func end(step: String = "已完成", immediate: Bool = false) {
        guard #available(iOS 16.2, *) else { return }
        let localAct = activity
        activity = nil

        var all = Activity<AgyActivityAttributes>.activities
        if let localAct, !all.contains(where: { $0.id == localAct.id }) {
            all.insert(localAct, at: 0)
        }
        guard !all.isEmpty else { return }

        let emptyContent: ActivityContent<AgyActivityAttributes.ContentState>? = nil

        // 孤儿残留（本次进程没有持有 localAct）或显式要求 immediate 时，直接 0 延迟销毁
        if immediate || localAct == nil {
            Task {
                for act in all {
                    await act.end(emptyContent, dismissalPolicy: .immediate)
                }
            }
            return
        }

        state.step = step
        state.running = false
        state.subagentCount = 0
        state.finalElapsed = max(1, Int(Date().timeIntervalSince(startedAt)))
        let finalState = state
        let primaryId = localAct?.id

        Task {
            for act in all where act.id != primaryId {
                await act.end(emptyContent, dismissalPolicy: .immediate)
            }
            if let primary = localAct {
                await primary.update(.init(state: finalState, staleDate: nil))
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await primary.end(.init(state: finalState, staleDate: nil),
                                  dismissalPolicy: .after(Date().addingTimeInterval(3)))
            }
        }
    }

    func endAllImmediately() {
        end(immediate: true)
    }

    /// 供 applicationWillTerminate 调用：在非主线程同步冲刷 XPC，划掉 App 时立即撤销灵动岛（绝不阻塞主线程死锁）
    nonisolated static func terminateAllActivitiesSync() {
        guard #available(iOS 16.2, *) else { return }
        let activities = Activity<AgyActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let emptyContent: ActivityContent<AgyActivityAttributes.ContentState>? = nil
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            for act in activities {
                await act.end(emptyContent, dismissalPolicy: .immediate)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.2)
    }
}
