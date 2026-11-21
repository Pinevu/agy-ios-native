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
    var lastReconciled: [String: Date] = [:]
    var reconnects: [String: Int] = [:]
    var received: [String: Int] = [:]
    var lastStreamActivity: [String: Date] = [:]
    var streamEpoch: [String: Int] = [:]
    var lastRemoteReconcile: [String: Date] = [:]
    var remoteRecoveryInFlight: Set<String> = []
    var draftSessionKey = "draft-\(UUID().uuidString)"
    var assistantIndex: Int?
    var titleMemo: [String: (stamp: Double, text: String)] = [:]
    var lastQuotaSnapshot: QuotaResponse?

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

    // MARK: - 启动 / 登录 / 实例

    func bootstrap() async {
        loadModelForCurrentInstance()
        isBooting = api.isLoggedIn
        defer { isBooting = false }
        await refreshModels()
        guard api.isLoggedIn else { isLoggedIn = false; return }
        let ok = await api.checkSession()
        if ok {
            isLoggedIn = true
            async let sTask: Void = refreshSessions()
            async let mTask: Void = syncSessionMeta()
            async let qTask: Void = prefetchQuotaForWidget()
            _ = await (sTask, mTask, qTask)
            currentSession = nil
            conversationId = nil
            items = []
            syncWidgetSnapshot()
        } else {
            api.setToken(nil)
            isLoggedIn = false
        }
    }

    func login(_ password: String) async {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            _ = try await api.login(password: password)
            isLoggedIn = true
            await refreshModels()
            await syncSessionMeta()
            await refreshSessions()
            await prefetchQuotaForWidget()
            syncWidgetSnapshot()
            if let first = sessions.first { await open(first) }
        } catch {
            loginError = error.localizedDescription
        }
    }

    func logout() {
        api.setToken(nil)
        isLoggedIn = false
        sessions = []
        items = []
        currentSession = nil
        conversationId = nil
        jobs = []
        syncWidgetSnapshot()
    }

    func switchInstance(_ inst: Instance) async {
        if let cur = currentSession?.id { sessionItems[cur] = items }
        let willHaveToken = APIClient.hasStoredToken(for: inst.url)
        currentInstanceId = inst.id
        api.setBase(inst.url)
        loadModelForCurrentInstance()
        await refreshModels()

        sessions = []
        currentSession = nil
        conversationId = nil
        items = []
        assistantIndex = nil
        isLoggedIn = false
        if willHaveToken { isBooting = true }
        let ok = await api.checkSession()
        isBooting = false
        if ok {
            isLoggedIn = true
            await syncSessionMeta()
            await refreshSessions()
            await prefetchQuotaForWidget()
            syncWidgetSnapshot()
            if let first = sessions.first { await open(first) }
        } else {
            api.setToken(nil)
            isLoggedIn = false
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
        instances.removeAll { $0.id == inst.id }
        if currentInstanceId == inst.id {
            currentInstanceId = instances[0].id
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

    func refreshModels() async {
        guard let list = try? await api.models(), !list.isEmpty else { return }
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

    func prefetchQuotaForWidget() async {
        if let q = try? await api.quota() {
            lastQuotaSnapshot = q
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
