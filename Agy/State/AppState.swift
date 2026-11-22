import UIKit
import Foundation
import SwiftUI
import Combine
import WidgetKit

struct RunningTask {
    let taskId: String
    var sessionId: String
    var conversationId: String?
    var stream: Task<Void, Never>?
    var title: String = ""
    var startedAt: Date = Date()
    var latestTool: String? = nil
    var subagentCount: Int = 0
}

struct DraftTransferUndo {
    let fromKey: String
    let toKey: String
    let prevFromDraft: String
    let prevToDraft: String
}

/// 核心全局状态（按职责拆分至 AppState+Sessions / AppState+Streaming / AppState+JobsAndSkills）
@MainActor
final class AppState: ObservableObject {
    // MARK: - 鉴权
    @Published var isLoggedIn = false
    @Published var isBooting = false
    @Published var loginError: String?
    @Published var isLoggingIn = false

    // MARK: - 会话 & 元数据
    @Published var sessions: [Session] = []
    @Published var currentSession: Session?
    @Published var items: [ChatItem] = []
    @Published var sessionMeta: SessionMeta = .empty
    @Published var searchResults: [SearchResultItem] = []
    @Published var isSearchingFullText = false

    // MARK: - 定时任务 & 技能
    @Published var jobs: [ScheduledJob] = []
    @Published var isLoadingJobs = false
    @Published var skills: [Skill] = []
    @Published var skillsCatalog: [SkillCatalogItem] = []

    // MARK: - 运行态
    @Published var running: [String: RunningTask] = [:]
    @Published var serverRunning: [String: ServerRunning] = [:]
    @Published var streamTick: Int = 0
    @Published var pendingPrompts: [String: String] = [:]
    @Published var conversationId: String?

    // 内部缓存（供扩展文件访问，不触发视图刷屏）
    var sessionItems: [String: [ChatItem]] = [:]
    var taskBuffers: [String: [ChatItem]] = [:]
    var pendingText: [String: String] = [:]
    var flushScheduled: Set<String> = []
    var runningPoller: Task<Void, Never>?
    var reconciledTaskIds: Set<String> = []
    var lastActiveTaskId: String?
    var reconnects: [String: Int] = [:]
    var received: [String: Int] = [:]
    var lastStreamActivity: [String: Date] = [:]
    var streamEpoch: [String: Int] = [:]
    var lastRemoteReconcile: [String: Date] = [:]
    var remoteRecoveryInFlight: Set<String> = []
    var draftSessionKey = "draft-\(UUID().uuidString)"
    var assistantIndex: Int?
    var titleMemo: [String: (stamp: Double, text: String)] = [:]
    /// 切换实例世代号：所有异步响应返回时必须比对世代号，杜绝旧实例的延迟回包污染新实例
    var instanceEpoch: Int = 0
    @Published var lastQuotaSnapshot: QuotaResponse?
    @Published var isLoadingModels = false
    var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    // MARK: - 输入与跨会话草稿
    @Published var draft: String = ""
    @Published var attachments: [Attachment] = []
    @Published var sessionDrafts: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "agy_session_drafts_v1") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(sessionDrafts, forKey: "agy_session_drafts_v1") }
    }
    @Published var pendingUndoTransfer: DraftTransferUndo?

    // MARK: - 模型 & 外观 & 隐私设置
    @Published var model = UserDefaults.standard.string(forKey: "agy_model") ?? "gemini-3.8-flash-high"
    @Published var modelOptions: [ModelOption] = AppState.models
    @Published var toast: String?
    @Published var loadingSession: String?

    @Published var appearanceMode: String =
        UserDefaults.standard.string(forKey: "agy_appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "agy_appearance") }
    }

    @Published var liveActivityEnabled: Bool =
        (UserDefaults.standard.object(forKey: "agy_live_activity_enabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: "agy_live_activity_enabled")
            if !liveActivityEnabled {
                LiveActivityManager.shared.endAllImmediately()
            }
        }
    }

    @Published var liveActivityPrivacyMode: Bool = AgySharedStore.liveActivityPrivacyMode {
        didSet {
            AgySharedStore.liveActivityPrivacyMode = liveActivityPrivacyMode
            LiveActivityManager.shared.refreshPrivacyMode()
        }
    }

    // 本地偏好兜底（与服务端 /api/sessions/meta 双向同步）
    @Published var pinnedIds: [String] = UserDefaults.standard.stringArray(forKey: "agy_pinned") ?? [] {
        didSet { UserDefaults.standard.set(pinnedIds, forKey: "agy_pinned") }
    }
    @Published var customTitles: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "agy_titles") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(customTitles, forKey: "agy_titles") }
    }

    let api = APIClient.shared

    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let data: Data
        let isImage: Bool
    }

    struct Instance: Identifiable, Codable, Hashable {
        var id: String
        var name: String
        var url: String
    }

    struct ModelOption: Identifiable, Hashable {
        let id: String
        let name: String
        let short: String
    }

    @Published var instances: [Instance] =
        (UserDefaults.standard.data(forKey: "agy_instances_v1").flatMap {
            try? JSONDecoder().decode([Instance].self, from: $0)
        }) ?? [Instance(id: "default", name: "chuncheon", url: "https://agy.nooh.cc")] {
        didSet {
            if let d = try? JSONEncoder().encode(instances) {
                UserDefaults.standard.set(d, forKey: "agy_instances_v1")
            }
        }
    }

    @Published var currentInstanceId: String =
        UserDefaults.standard.string(forKey: "agy_instance_id") ?? "default" {
        didSet { UserDefaults.standard.set(currentInstanceId, forKey: "agy_instance_id") }
    }

    var currentInstance: Instance {
        instances.first { $0.id == currentInstanceId } ?? instances[0]
    }

    static let models: [ModelOption] = [
        ModelOption(id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash · High", short: "Flash High"),
        ModelOption(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash · Medium", short: "Flash Med"),
        ModelOption(id: "gemini-3.8-flash-low", name: "Gemini 3.8 Flash · Low", short: "Flash Low"),
        ModelOption(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", short: "Sonnet 4.6"),
        ModelOption(id: "claude-opus-4-6-thinking", name: "Claude Opus 4.6 Thinking", short: "Opus 4.6"),
        ModelOption(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B", short: "GPT-OSS")
    ]

    /// 优先查服务端拉取的实时模型表，修复旧版只查静态兜底表导致新模型显示原始 id 的问题
    var currentModelName: String {
        modelOptions.first(where: { $0.id == model })?.name
            ?? Self.models.first(where: { $0.id == model })?.name
            ?? model
    }

    var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var isDarkEffective: Bool {
        if let c = colorScheme { return c == .dark }
        return UITraitCollection.current.userInterfaceStyle == .dark
    }

    func toggleAppearance() {
        appearanceMode = isDarkEffective ? "light" : "dark"
    }

    var activeSessionKey: String {
        currentSession?.id ?? draftSessionKey
    }

    var lastSessionStorageKey: String {
        "agy_last_session::" + api.baseURLString
    }

    // MARK: - 启动 / 登录 / 实例

    func bootstrap() async {
        // 确保 APIClient 地址与当前选中实例严格对齐
        if api.baseURLString != currentInstance.url {
            api.setBase(currentInstance.url)
        }
        loadModelForCurrentInstance()
        isBooting = api.isLoggedIn
        defer { isBooting = false }

        guard api.isLoggedIn else {
            isLoggedIn = false
            LiveActivityManager.shared.endAllImmediately()
            return
        }

        let epoch = instanceEpoch
        let status = await api.checkSessionStatus(timeout: 8)
        guard epoch == instanceEpoch else { return }

        switch status {
        case .valid:
            isLoggedIn = true
            async let mdlTask: Void = refreshModels(force: false, forEpoch: epoch)
            async let sTask: Void = refreshSessions()
            async let mTask: Void = syncSessionMeta()
            async let rTask: Void = syncRunning()
            async let qTask: Void = prefetchQuotaForWidget(force: false, forEpoch: epoch)
            async let jTask: Void = refreshJobs()
            _ = await (mdlTask, sTask, mTask, rTask, qTask, jTask)
            guard epoch == instanceEpoch else { return }

            // 若服务端有正在执行的任务，冷启动（划掉 App 重进）直接自动续接该会话并挂上实时 SSE
            if await resumeActiveRunningSessionIfNeeded() {
                syncWidgetSnapshot()
                return
            }

            currentSession = nil
            conversationId = nil
            items = []
            syncWidgetSnapshot()

        case .unauthorized:
            api.setToken(nil)
            isLoggedIn = false
            LiveActivityManager.shared.endAllImmediately()

        case .unreachable:
            // 网络短暂不可达时不误删有效 Keychain Token，保留登录态等待切回前台/轮询自动恢复
            isLoggedIn = true
            showToast("网络暂时不可用，恢复后自动同步")
        }
    }

    /// 划掉 App 重进或点灵动岛回跳时，自动找到服务端正在跑的会话并打开续接 SSE 流
    @discardableResult
    func resumeActiveRunningSessionIfNeeded() async -> Bool {
        guard !serverRunning.isEmpty else { return false }
        let lastSid = UserDefaults.standard.string(forKey: lastSessionStorageKey)
            ?? UserDefaults.standard.string(forKey: "agy_last_session")
        let sortedRunning = serverRunning.values.sorted { ($0.started ?? 0) > ($1.started ?? 0) }

        // 优先续接划掉 App 前正在看的那个运行中会话，其次取最新启动的运行中任务
        let preferred: ServerRunning? = {
            if let lastSid, !lastSid.isEmpty, lastSid != "draft",
               let hit = sortedRunning.first(where: {
                   $0.sessionId == lastSid || $0.conversationId == lastSid || $0.taskId == lastSid
               }) {
                return hit
            }
            return sortedRunning.first
        }()

        guard let target = preferred else { return false }
        if let matched = matchSession(for: target) {
            await open(matched)
            return true
        }
        // 新会话刚启动还未出现在初次 /api/tasks 时，补刷一次再匹配
        await refreshSessions()
        if let matched = matchSession(for: target) {
            await open(matched)
            return true
        }
        return false
    }

    func matchSession(for sr: ServerRunning) -> Session? {
        if let sid = sr.sessionId,
           let s = sessions.first(where: { $0.id == sid || $0.conversationId == sid }) {
            return s
        }
        if let cid = sr.conversationId,
           let s = sessions.first(where: { $0.id == cid || $0.conversationId == cid }) {
            return s
        }
        return sessions.first(where: { $0.latestTaskId == sr.taskId || $0.id == sr.taskId })
    }

    func login(_ password: String) async {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        let epoch = instanceEpoch
        do {
            _ = try await api.login(password: password)
            guard epoch == instanceEpoch else { return }
            isLoggedIn = true
            async let mdlTask: Void = refreshModels(force: true, forEpoch: epoch)
            async let mTask: Void = syncSessionMeta()
            async let sTask: Void = refreshSessions()
            async let rTask: Void = syncRunning()
            async let qTask: Void = prefetchQuotaForWidget(force: true, forEpoch: epoch)
            async let jTask: Void = refreshJobs()
            _ = await (mdlTask, mTask, sTask, rTask, qTask, jTask)
            guard epoch == instanceEpoch else { return }
            syncWidgetSnapshot()
            startRunningPoller()
            if !(await resumeActiveRunningSessionIfNeeded()), let first = sessions.first {
                await open(first)
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// 彻底清空与当前实例绑定的全部运行态、流连接、会话、模型与用量缓存
    private func resetInstanceScopedState() {
        for rt in running.values {
            rt.stream?.cancel()
        }
        runningPoller?.cancel()
        runningPoller = nil

        running = [:]
        serverRunning = [:]
        taskBuffers = [:]
        pendingText = [:]
        flushScheduled = []
        reconnects = [:]
        received = [:]
        lastStreamActivity = [:]
        streamEpoch = [:]
        lastRemoteReconcile = [:]
        remoteRecoveryInFlight = []
        reconciledTaskIds = []
        lastActiveTaskId = nil
        draftSessionKey = "draft-\(UUID().uuidString)"

        sessions = []
        currentSession = nil
        conversationId = nil
        items = []
        assistantIndex = nil
        loadingSession = nil
        sessionItems = [:]
        sessionMeta = .empty
        pinnedIds = []
        customTitles = [:]
        titleMemo = [:]
        searchResults = []
        isSearchingFullText = false
        pendingPrompts = [:]
        pendingUndoTransfer = nil

        jobs = []
        skills = []
        skillsCatalog = []
        lastQuotaSnapshot = nil
        modelOptions = AppState.models

        endBackgroundGraceTask()
        LiveActivityManager.shared.endAllImmediately()
    }

    func logout() {
        instanceEpoch &+= 1
        api.setToken(nil)
        isLoggedIn = false
        resetInstanceScopedState()
        syncWidgetSnapshot()
    }

    /// 切到后台时，若仍有任务在跑，向系统申请短暂后台保活窗口（~25s），让短/中任务完成时可自动收起灵动岛
    func appEnteredBackground() {
        syncWidgetSnapshot()
        guard isLoggedIn, runningCount > 0 else {
            endBackgroundGraceTask()
            return
        }
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "agy-live-sync") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundGraceTask()
            }
        }
    }

    func endBackgroundGraceTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    func switchInstance(_ inst: Instance) async {
        // 点击当前已在线实例时，直接强制刷新模型、用量与会话，不做闪烁重置
        if inst.id == currentInstanceId && api.baseURLString == inst.url && isLoggedIn {
            let epoch = instanceEpoch
            async let mdlTask: Void = refreshModels(force: true, forEpoch: epoch)
            async let qTask: Void = prefetchQuotaForWidget(force: true, forEpoch: epoch)
            async let sTask: Void = refreshSessions()
            async let rTask: Void = syncRunning()
            _ = await (mdlTask, qTask, sTask, rTask)
            syncWidgetSnapshot()
            showToast("已刷新 \(inst.name)")
            return
        }

        let prevToken = api.token
        instanceEpoch &+= 1
        let epoch = instanceEpoch

        resetInstanceScopedState()
        currentInstanceId = inst.id
        api.setBase(inst.url)
        loadModelForCurrentInstance()

        // 若目标实例暂无独立 Token，先尝试复用前实例 Token（兼容共用同一 JWT 密钥的多机无缝切换）
        var status: SessionCheckResult
        if api.isLoggedIn {
            status = await api.checkSessionStatus(timeout: 8)
        } else if let prevToken, !prevToken.isEmpty {
            let probe = await api.checkSessionStatus(timeout: 8, overrideToken: prevToken)
            if probe == .valid {
                api.setToken(prevToken)
            }
            status = probe
        } else {
            status = .unauthorized
        }

        guard epoch == instanceEpoch else { return }

        switch status {
        case .valid:
            isLoggedIn = true
            async let mdlTask: Void = refreshModels(force: true, forEpoch: epoch)
            async let mTask: Void = syncSessionMeta()
            async let sTask: Void = refreshSessions()
            async let rTask: Void = syncRunning()
            async let qTask: Void = prefetchQuotaForWidget(force: true, forEpoch: epoch)
            async let jTask: Void = refreshJobs()
            _ = await (mdlTask, mTask, sTask, rTask, qTask, jTask)
            guard epoch == instanceEpoch else { return }
            syncWidgetSnapshot()
            startRunningPoller()
            if !(await resumeActiveRunningSessionIfNeeded()), let first = sessions.first {
                await open(first)
            }
            showToast("已切换至 \(inst.name)")

        case .unauthorized:
            api.setToken(nil)
            isLoggedIn = false
            syncWidgetSnapshot()

        case .unreachable:
            isLoggedIn = api.isLoggedIn
            syncWidgetSnapshot()
            showToast("无法连接到 \(inst.name)，请检查网络")
        }
    }

    func addInstance(name: String, url: String) async {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !clean.isEmpty, let u = URL(string: clean), u.host != nil else {
            showToast("地址格式不对"); return
        }
        if instances.contains(where: { $0.url == clean }) {
            showToast("这个实例已经加过了"); return
        }
        var infoName = name
        if let n = await Self.probe(clean), !n.isEmpty, name.isEmpty {
            infoName = n
        }
        let inst = Instance(id: UUID().uuidString, name: infoName.isEmpty ? clean : infoName, url: clean)
        instances.append(inst)
        showToast("已添加 \(inst.name)")
    }

    func removeInstance(_ inst: Instance) {
        guard instances.count > 1 else { showToast("至少保留一个实例"); return }
        let wasCurrent = (currentInstanceId == inst.id)
        instances.removeAll { $0.id == inst.id }
        if wasCurrent, let next = instances.first {
            Task { await switchInstance(next) }
        }
    }

    static func probe(_ base: String) async -> String? {
        guard let url = URL(string: base + "/api/info") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return obj["name"] as? String
    }

    // MARK: - 模型管理

    private func modelKey(for url: String) -> String { "agy_model::" + url }

    func setModel(_ id: String) {
        model = id
        UserDefaults.standard.set(id, forKey: modelKey(for: api.baseURLString))
    }

    func loadModelForCurrentInstance() {
        let saved = UserDefaults.standard.string(forKey: modelKey(for: api.baseURLString))
        model = saved ?? "gemini-3.8-flash-high"
    }

    func refreshModels(force: Bool = false, forEpoch: Int? = nil) async {
        let epoch = forEpoch ?? instanceEpoch
        isLoadingModels = true
        defer {
            if epoch == instanceEpoch { isLoadingModels = false }
        }
        guard let list = try? await api.models(force: force), !list.isEmpty else { return }
        guard epoch == instanceEpoch else { return }
        let opts = list.map { m in
            ModelOption(id: m.id, name: Self.prettyName(m.name), short: Self.shortName(m.name))
        }
        modelOptions = opts
        if !opts.contains(where: { $0.id == model }) {
            setModel(opts[0].id)
        }
    }

    private static func prettyName(_ raw: String) -> String {
        raw.replacingOccurrences(of: " (", with: " · ")
           .replacingOccurrences(of: ")", with: "")
    }

    private static func shortName(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: ")", with: "")
        let parts = t.components(separatedBy: " (")
        guard parts.count == 2 else { return String(t.prefix(18)) }
        let head = parts[0].replacingOccurrences(of: "Gemini ", with: "")
        return "\(head) \(parts[1])"
    }

    // MARK: - 提示与小组件快照同步

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toast == s { toast = nil }
        }
    }

    func prefetchQuotaForWidget(force: Bool = false, forEpoch: Int? = nil) async {
        let epoch = forEpoch ?? instanceEpoch
        if let q = try? await api.quota(force: force) {
            guard epoch == instanceEpoch else { return }
            lastQuotaSnapshot = q
            syncWidgetSnapshot()
        }
    }

    func syncWidgetSnapshot() {
        let active = mergedRunning.first
        let recentItems = sessions.prefix(5).map { s in
            AgyWidgetSessionItem(
                id: s.id,
                title: title(of: s),
                updated: s.updated ?? s.started,
                running: !s.done || serverRunning[s.id] != nil,
                unread: isUnread(s)
            )
        }
        let primaryWindow = lastQuotaSnapshot?.groups?.first?.windows.first(where: { $0.remaining != nil })
        let quotaItem: AgyWidgetQuotaItem? = primaryWindow.flatMap { w in
            w.remaining.map { AgyWidgetQuotaItem(label: w.label, remaining: $0) }
        } ?? lastQuotaSnapshot?.buckets?.first(where: { $0.remaining != nil }).flatMap { b in
            b.remaining.map { AgyWidgetQuotaItem(label: b.label, remaining: $0) }
        }

        let snap = AgySharedSnapshot(
            instanceName: currentInstance.name,
            runningCount: runningCount,
            activeTaskTitle: active?.title,
            activeTaskTool: active?.latestTool.map { ToolDescribe.title($0) },
            recentSessions: recentItems,
            quotaPlan: lastQuotaSnapshot?.plan,
            quotaPrimary: quotaItem,
            updatedAt: Date()
        )
        AgySharedStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
