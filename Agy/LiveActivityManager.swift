import Foundation
import ActivityKit

/// 管理灵动岛 / 锁屏实时活动
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<AgyActivityAttributes>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date = Date()
    private var state = AgyActivityAttributes.ContentState(title: "", elapsed: 0, step: "正在启动…", running: true)

    private var available: Bool {
        if #available(iOS 16.1, *) { return ActivityAuthorizationInfo().areActivitiesEnabled }
        return false
    }

    /// 任务开始：没有活动就新建，有就更新
    func start(title: String, step: String = "正在思考…") {
        guard available, #available(iOS 16.1, *) else { return }

        if activity == nil {
            startedAt = Date()
            state = .init(title: title, elapsed: 0, step: step, running: true)
            let attrs = AgyActivityAttributes(sessionKey: UUID().uuidString)
            activity = try? Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil)
            )
        } else {
            update(title: title, step: step, running: true)
        }
        startTicker()
    }

    func update(title: String? = nil, step: String? = nil, running: Bool? = nil) {
        guard available, #available(iOS 16.1, *) else { return }
        guard let act = activity else { return }
        if let t = title, !t.isEmpty { state.title = t }
        if let s = step, !s.isEmpty { state.step = s }
        if let r = running { state.running = r }
        state.elapsed = Int(Date().timeIntervalSince(startedAt))
        Task { await act.update(.init(state: state, staleDate: nil)) }
    }

    /// 任务结束：显示一次完成态，随后自动消失
    func end(step: String = "已完成") {
        guard available, #available(iOS 16.1, *) else { return }
        guard let act = activity else { return }
        stopTicker()
        state.step = step
        state.running = false
        state.elapsed = Int(Date().timeIntervalSince(startedAt))
        Task {
            await act.update(.init(state: state, staleDate: nil))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await act.end(content: .init(state: state, staleDate: nil),
                          dismissalPolicy: .after(Date().addingTimeInterval(4)))
            await MainActor.run { self.activity = nil }
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let act = self.activity else { break }
                self.state.elapsed = Int(Date().timeIntervalSince(self.startedAt))
                await act.update(.init(state: self.state, staleDate: nil))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
