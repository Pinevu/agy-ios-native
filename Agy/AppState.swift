import UIKit
import Foundation
import SwiftUI
import Combine

struct RunningTask {
    let taskId: String
    var sessionId: String
    var conversationId: String?
    var stream: Task<Void, Never>?
    /// 会话标题（用于「运行中」列表展示）
    var title: String = ""
    var startedAt: Date = Date()
}

@MainActor
final class AppState: ObservableObject {
    // 鉴权
    @Published var isLoggedIn = false
    @Published var loginError: String?
    @Published var isLoggingIn = false

    // 会话
    @Published var sessions: [Session] = []
    @Published var currentSession: Session?
    @Published var items: [ChatItem] = []

    // 运行状态
    /// 多任务并发：key = taskId
    @Published var running: [String: RunningTask] = [:]
    /// 每个会话的消息缓存（切走再切回不丢）
    private var sessionItems: [String: [ChatItem]] = [:]
    /// 服务端权威运行表：sessionId -> ServerRunning
    @Published var serverRunning: [String: ServerRunning] = [:]
    /// 流式文本落盘计数：界面据此跟随到底部（不依赖内容高度测量）
    @Published var streamTick: Int = 0
    /// 后台任务的条目缓冲（不参与 @Published，避免流式时狂刷 UI）
    private var taskBuffers: [String: [ChatItem]] = [:]
    /// 流式文本节流缓冲
    private var pendingText: [String: String] = [:]
    private var flushScheduled: Set<String> = []
    private var runningPoller: Task<Void, Never>?
    /// 任务运行中追加的提示词，等当前任务结束后自动发送
    @Published var pendingPrompts: [String: String] = [:]

    /// 当前会话是否在跑
    var isRunning: Bool { currentRunningTask != nil }
    var runningTaskId: String? { currentRunningTask?.taskId }
    /// 全局在跑的任务数
    var runningCount: Int {
        max(running.count, serverRunning.count)
    }

    /// 合并后的运行中列表（本地优先，服务端补齐）
    var mergedRunning: [RunningTask] {
        var out = Array(running.values)
        for (sid, sr) in serverRunning where !out.contains(where: { $0.taskId == sr.taskId }) {
            out.append(RunningTask(taskId: sr.taskId,
                                   sessionId: sid,
                                   conversationId: sr.conversationId,
                                   title: sr.title ?? "",
                                   startedAt: Date().addingTimeInterval(-Double(sr.elapsed ?? 0))))
        }
        return out.sorted { $0.startedAt < $1.startedAt }
    }

    /// 轮询服务端运行状态（3 秒一次，App 前台时）
    func startRunningPoller() {
        runningPoller?.cancel()
        runningPoller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isLoggedIn {
                    await self.syncRunning()
                }
                // 有任务在跑 → 2 秒一查；空闲 → 8 秒（省电、省请求）
                let ns: UInt64 = self.running.isEmpty && self.serverRunning.isEmpty
                    ? 8_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func syncRunning() async {
        guard let snap = try? await api.runningTasks() else { return }

        var map: [String: ServerRunning] = [:]
        for r in snap.running {
            map[r.sessionId ?? r.taskId] = r
        }
        serverRunning = map

        // 新建对话发出的任务，sessionId 先记的是 draft-xxx；
        // 会话落库后按 conversation_id 反查真实 id 更正，否则「运行中」面板点不进去
        for (tid, rt) in running where rt.sessionId.hasPrefix("draft-") {
            let cid = rt.conversationId
            if let s0 = sessions.first(where: { cid != nil && $0.conversationId == cid }) {
                running[tid]?.sessionId = s0.id
            }
        }

        // 服务端说结束、本地还挂着的 → 收尾（finish 内部会补拉一次）
        // draft- 开头的是新建对话还没落库的任务，服务端按真实 session 登记，
        // 这里对不上 key，绝不能当成「已结束」收掉，否则任务还在跑就被停掉
        for (tid, rt) in running
            where !rt.sessionId.hasPrefix("draft-") && map[rt.sessionId] == nil {
            finish(taskId: tid)
        }

        // 服务端刚刚结束、但本地根本没收到 end 的 → 直接补拉该会话
        let known = Set(running.values.map { $0.sessionId })
        for r in snap.recent {
            guard let sid = r.sessionId, !known.contains(sid) else { continue }
            guard lastReconciled[sid] == nil else { continue }
            lastReconciled[sid] = Date()
            await reconcile(sessionId: sid)
        }
    }

    /// 防止同一会话反复补拉
    private var lastReconciled: [String: Date] = [:]
    /// 每个任务的断流重连次数（退避用）
    private var reconnects: [String: Int] = [:]

    /// 新会话（还没落库）用的临时 key，初值就有，保证任何时刻都有归属
    private var draftSessionKey = "draft-\(UUID().uuidString)"

    /// 当前会话自己的 key（永不为 nil）
    var activeSessionKey: String {
        currentSession?.id ?? draftSessionKey
    }

    var currentRunningTask: RunningTask? {
        let sid = activeSessionKey
        if let local = running.values.first(where: { $0.sessionId == sid }) {
            return local
        }
        // 本地没有但服务端在跑 → 兜底显示停止键。
        // 按会话 id、conversationId、任务 id 三种都认，避免从灵动岛回来时 id 对不上导致键消失
        let cid = currentSession?.conversationId
        guard let sr = serverRunning[sid]
            ?? serverRunning.values.first(where: { $0.conversationId == cid && cid != nil })
            ?? serverRunning.values.first(where: { $0.taskId == sid })
            else { return nil }
        return RunningTask(taskId: sr.taskId,
                           sessionId: sid,
                           conversationId: sr.conversationId,
                           title: sr.title ?? "",
                           startedAt: Date().addingTimeInterval(-Double(sr.elapsed ?? 0)))
    }

    /// 正在跑的任务列表（供「运行中」面板）
    var runningList: [RunningTask] {
        running.values.sorted { $0.startedAt < $1.startedAt }
    }
    @Published var conversationId: String?

    // 输入
    @Published var draft: String = ""
    @Published var attachments: [Attachment] = []

    // 模型
    @Published var model = UserDefaults.standard.string(forKey: "agy_model") ?? "gemini-3.8-flash-high"

    // UI
    @Published var toast: String?
    /// 正在拉取回放的会话 id（用于显示加载骨架，避免白屏）
    @Published var loadingSession: String?

    /// 外观：system / light / dark
    @Published var appearanceMode: String =
        UserDefaults.standard.string(forKey: "agy_appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "agy_appearance") }
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

    /// 亮 / 暗两态切换（跟随系统时按当前系统状态取反）
    func toggleAppearance() {
        appearanceMode = isDarkEffective ? "light" : "dark"
    }

    // 会话列表偏好（本地）：置顶 + 重命名
    @Published var pinnedIds: [String] = UserDefaults.standard.stringArray(forKey: "agy_pinned") ?? [] {
        didSet { UserDefaults.standard.set(pinnedIds, forKey: "agy_pinned") }
    }
    @Published var customTitles: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "agy_titles") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(customTitles, forKey: "agy_titles") }
    }

    func togglePin(_ s: Session) {
        if let i = pinnedIds.firstIndex(of: s.id) {
            pinnedIds.remove(at: i)
            showToast("已取消置顶")
        } else {
            pinnedIds.insert(s.id, at: 0)
            showToast("已置顶")
        }
    }

    func isPinned(_ s: Session) -> Bool { pinnedIds.contains(s.id) }

    func rename(_ s: Session, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        customTitles[s.id] = t
        showToast("已重命名")
    }

    func title(of s: Session) -> String {
        customTitles[s.id] ?? s.displayTitle
    }

    private var assistantIndex: Int?

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

    /// 切换实例：换地址、清空当前会话状态、重新鉴权
    func switchInstance(_ inst: Instance) async {
        // 切实例前把当前会话落盘，后台任务保持运行
        if let cur = currentSession?.id { sessionItems[cur] = items }
        currentInstanceId = inst.id
        api.setBase(inst.url)
        loadModelForCurrentInstance()
        // 清空现场
        sessions = []
        currentSession = nil
        conversationId = nil
        items = []
        assistantIndex = nil
        isLoggedIn = false
        let ok = await api.checkSession()
        if ok {
            isLoggedIn = true
            await refreshSessions()
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
        // 探活
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

    /// 探测实例名（/api/info 免鉴权）
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

    struct ModelOption: Identifiable, Hashable {
        let id: String
        let name: String
        let short: String
    }

    static let models: [ModelOption] = [
        ModelOption(id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash · High", short: "Flash High"),
        ModelOption(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash · Medium", short: "Flash Med"),
        ModelOption(id: "gemini-3.8-flash-low", name: "Gemini 3.8 Flash · Low", short: "Flash Low"),
        ModelOption(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", short: "Sonnet 4.6"),
        ModelOption(id: "claude-opus-4-6-thinking", name: "Claude Opus 4.6 Thinking", short: "Opus 4.6"),
        ModelOption(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B", short: "GPT-OSS")
    ]

    var currentModelName: String {
        Self.models.first(where: { $0.id == model })?.name ?? model
    }

    // MARK: - 启动

    func bootstrap() async {
        loadModelForCurrentInstance()
        guard api.isLoggedIn else { isLoggedIn = false; return }
        let ok = await api.checkSession()
        if ok {
            isLoggedIn = true
            await refreshSessions()
            // 每次打开都停在新建对话页，历史任务从抽屉里点进去
            currentSession = nil
            conversationId = nil
            items = []
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
            await refreshSessions()
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
    }

    // MARK: - 会话

    func refreshSessions() async {
        do {
            sessions = try await api.tasks()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func open(_ session: Session) async {
        // 保存当前会话的现场
        if let cur = currentSession?.id, cur != session.id {
            sessionItems[cur] = items
        }
        draftSessionKey = "draft-\(UUID().uuidString)"
        currentSession = session
        UserDefaults.standard.set(session.id, forKey: "agy_last_session")
        conversationId = session.conversationId
        assistantIndex = nil

        // 后台正在跑这个会话 → 直接用它的实时缓冲
        if let rt = running.values.first(where: { $0.sessionId == session.id }),
           let buf = taskBuffers[rt.taskId], !buf.isEmpty {
            items = buf
            if let rtConv = rt.conversationId { conversationId = rtConv }
            return
        }
        // 之前看过 → 用缓存
        if let cached = sessionItems[session.id], !cached.isEmpty {
            items = cached
            return
        }
        // 都没 → 从服务端回放（保持旧内容 + 加载态，避免白屏）
        loadingSession = session.id
        items = []                 // 清旧内容，界面显示骨架而不是白屏
        defer { loadingSession = nil }
        do {
            let events = try await api.replay(session.id)
            apply(events, live: false)
            sessionItems[session.id] = items
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func newSession() {
        if let cur = currentSession?.id { sessionItems[cur] = items }
        draftSessionKey = "draft-\(UUID().uuidString)"
        UserDefaults.standard.set("draft", forKey: "agy_last_session")
        currentSession = nil
        conversationId = nil
        items = []
        assistantIndex = nil
    }

    // MARK: - 发送

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty { return }

        // 当前会话已有任务在跑 → 作为「追加提示词」排队
        if let cur = currentRunningTask {
            let sid = cur.sessionId
            let existing = pendingPrompts[sid] ?? ""
            let merged = existing.isEmpty ? text : existing + "\n" + text
            pendingPrompts[sid] = merged
            draft = ""
            showToast("已排队，当前任务结束后自动发送")
            return
        }

        var prompt = text
        var paths: [String] = []
        for att in attachments {
            if let p = try? await api.upload(name: att.name, data: att.data) {
                paths.append(p)
            }
        }
        if !paths.isEmpty {
            let attachText = paths.map { "[附件] \($0)" }.joined(separator: "\n")
            prompt = prompt.isEmpty ? attachText : prompt + "\n\n" + attachText
        }

        let localAttachments: [Data] = attachments.filter { $0.isImage }.map { $0.data }
        draft = ""
        attachments = []

        // 本地先插入用户气泡
        let bubbleId = UUID()
        items.append(ChatItem(id: bubbleId,
                              kind: .user(text: text, attachments: localAttachments),
                              rawText: text))
        assistantIndex = nil

        do {
            let r = try await api.run(prompt: prompt,
                                      model: model,
                                      conversationId: conversationId,
                                      sessionId: currentSession?.id)
            if let c = r.conversationId { conversationId = c }
            if let idx = items.firstIndex(where: { $0.id == bubbleId }) {
                items[idx].taskId = r.id
            }
            // 登记为并发任务
            let sid = activeSessionKey ?? r.id
            LiveActivityManager.shared.start(title: displayTitleForCurrent())
            running[r.id] = RunningTask(taskId: r.id,
                                        sessionId: sid,
                                        conversationId: conversationId,
                                        title: text.isEmpty ? "新任务" : String(text.prefix(18)),
                                        startedAt: Date())
            taskBuffers[r.id] = items
            listen(taskId: r.id)
        } catch {
            items.append(ChatItem(kind: .error(text: error.localizedDescription)))
        }
    }

    // MARK: - 编辑 / 重试 / 删除（对齐 Minis 的会话操作）

    /// 找到某条消息所属的「用户轮次」下标（从它往前找最近的用户消息）
    private func turnIndex(for idx: Int) -> Int? {
        guard idx >= 0, idx < items.count else { return nil }
        var i = idx
        while i >= 0 {
            if case .user = items[i].kind { return i }
            i -= 1
        }
        return nil
    }

    /// 编辑用户消息并覆盖重发
    func editAndResend(itemId: UUID, newText: String, keepPaths: [String] = []) async {
        guard currentRunningTask == nil else { showToast("当前会话有任务在跑，先等它结束"); return }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let turn = turnIndex(for: idx) ?? idx
        await truncateServer(from: turn)
        items.removeSubrange(turn..<items.count)
        assistantIndex = nil

        // 把原文里带的附件重新拼回去，避免图文消息编辑后丢图
        if keepPaths.isEmpty {
            draft = trimmed
            await send()
        } else {
            let attach = keepPaths.map { "[附件] \($0)" }.joined(separator: "\n")
            draft = trimmed + "\n\n" + attach
            await send()
        }
    }

    /// 重试：删掉这一轮及其之后的回复，用同样的提问重新生成
    func retry(itemId: UUID) async {
        guard currentRunningTask == nil else { showToast("当前会话有任务在跑，先等它结束"); return }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard let turn = turnIndex(for: idx) else { return }
        guard case .user(let text, let atts, _) = items[turn].kind else { return }

        let prompt = items[turn].rawText ?? text
        await truncateServer(from: turn)
        items.removeSubrange(turn..<items.count)
        assistantIndex = nil
        _ = atts
        draft = prompt
        await send()
    }

    /// 从此处删除：服务端截断 + 本地移除该轮及其之后
    func deleteFrom(itemId: UUID) async {
        guard currentRunningTask == nil else { showToast("当前会话有任务在跑，先等它结束"); return }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let turn = turnIndex(for: idx) ?? idx
        await truncateServer(from: turn)
        items.removeSubrange(turn..<items.count)
        assistantIndex = nil
        showToast("已删除")
    }

    /// 调服务端截断；首轮被删时整段 conversation 会被销毁，这里同步断开续接
    private func truncateServer(from turn: Int) async {
        guard turn >= 0, turn < items.count else { return }
        guard let tid = items[turn].taskId else { return }
        let dropped = await api.truncateFrom(tid)
        if dropped {
            conversationId = nil
            currentSession = nil
        }
    }

    /// 停止当前会话的任务
    func stop() async {
        guard let rt = currentRunningTask else { return }
        await stop(taskId: rt.taskId)
    }

    /// 停止指定的任务（运行中面板用）
    func stop(taskId: String) async {
        await api.stop(taskId)
        showToast("已停止")
    }

    private func listen(taskId: String) {
        let task = api.stream(taskId: taskId, onEvent: { [weak self] ev in
            Task { @MainActor in self?.handle(ev, taskId: taskId) }
        }, onClose: { [weak self] in
            // 连接断了不等于任务结束：代理/网络会掐掉长时间无数据的 SSE。
            // 先问服务端，还在跑就重连，确认结束才收尾。
            Task { @MainActor in await self?.streamClosed(taskId: taskId) }
        })
        running[taskId]?.stream = task
    }

    /// SSE 断开后的判定：任务还在服务端跑 → 退避重连；确实结束 → 收尾
    private func streamClosed(taskId: String) async {
        guard running[taskId] != nil else { return }
        await syncRunning()
        guard running[taskId] != nil else { return }

        // 只认「这个任务」还在跑。draft 会话对不上 session key，按任务 id 认
        let still = serverRunning.values.contains { $0.taskId == taskId }
        if still {
            let n = (reconnects[taskId] ?? 0) + 1
            reconnects[taskId] = n
            // 1s、2s、4s … 最多 8s，任务再长也不会放弃
            let delay = UInt64(min(1 << min(n - 1, 3), 8)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard running[taskId] != nil else { return }
            listen(taskId: taskId)
        } else {
            reconnects.removeValue(forKey: taskId)
            finish(taskId: taskId)
        }
    }

    /// 任务收尾：落盘缓冲、清理运行态、检查排队提示词
    private func finish(taskId: String) {
        guard let rt = running[taskId] else { return }
        let sid = rt.sessionId
        // 灵动岛：仅当没有其它任务在跑时收尾
        if running.count <= 1 {
            LiveActivityManager.shared.end()
        }

        // 收尾前把攒着的文本先落地，避免最后一段丢失
        if !(pendingText[taskId] ?? "").isEmpty {
            let chunk = pendingText[taskId] ?? ""
            pendingText[taskId] = ""
            var b = taskBuffers[taskId] ?? (activeSessionKey == sid ? items : [])
            if let last = b.indices.last, case .assistant(let old) = b[last].kind {
                b[last].kind = .assistant(text: old + chunk)
            } else {
                b.append(ChatItem(kind: .assistant(text: chunk)))
            }
            taskBuffers[taskId] = b
        }

        let buf = taskBuffers[taskId] ?? items
        sessionItems[sid] = buf
        if activeSessionKey == sid {
            items = buf
        }
        taskBuffers.removeValue(forKey: taskId)
        reconnects.removeValue(forKey: taskId)
        running.removeValue(forKey: taskId)

        // 有排队的追加提示词 → 自动发出
        if let queued = pendingPrompts[sid], !queued.isEmpty {
            pendingPrompts.removeValue(forKey: sid)
            draft = queued
            Task { await self.send() }
        }
        Task { await refreshSessions() }

        // 收尾后补拉一次：SSE 提前断开时，最后那段内容只有服务端有
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            guard self.running[taskId] == nil else { return }
            await self.reconcile(sessionId: sid)
        }
    }

    /// 用服务端权威数据校正某个会话（SSE 断流、丢事件时自愈）
    private func reconcile(sessionId sid: String) async {
        guard let events = try? await api.replay(sid) else { return }
        let snapshot = buildItems(events)
        sessionItems[sid] = snapshot
        if activeSessionKey == sid {
            // 只有内容确实变多/变完整时才替换，避免无谓闪烁
            if snapshot.count >= items.count {
                items = snapshot
                assistantIndex = nil
            }
        }
    }

    /// 当前会话标题（灵动岛用）
    func displayTitleForCurrent() -> String {
        if let s = currentSession { return title(of: s) }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Antigravity" : String(t.prefix(24))
    }


    /// 一句短说明：不换行、不超过 30 字、不是列表或标题。
    /// 用来把「工具前的那句中文」从正文里挑出来单独渲染。
    private func isNote(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 30, !s.contains("\n") else { return false }
        if s.hasPrefix("#") || s.hasPrefix("-") || s.hasPrefix("*") || s.hasPrefix("```") { return false }
        return true
    }

    // MARK: - 事件

    /// 非当前会话的事件：只追加到该任务的缓冲
    /// 把累积的流式文本落到 items（节流 80ms）
    private func scheduleFlush(taskId: String) {
        guard !flushScheduled.contains(taskId) else { return }
        flushScheduled.insert(taskId)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self else { return }
            self.flushScheduled.remove(taskId)
            self.flushText(taskId: taskId)
        }
    }

    private func flushText(taskId: String) {
        guard let chunk = pendingText[taskId], !chunk.isEmpty else { return }
        pendingText[taskId] = ""

        // 任务可能已经收尾（SSE 先断、end 后到），此时不能再丢文本，
        // 直接写进缓冲，随后由补拉或下次 replay 校正。
        if running[taskId] == nil {
            var buf = taskBuffers[taskId] ?? []
            if let last = buf.indices.last, case .assistant(let old) = buf[last].kind {
                buf[last].kind = .assistant(text: old + chunk)
            } else {
                buf.append(ChatItem(kind: .assistant(text: chunk)))
            }
            taskBuffers[taskId] = buf
            return
        }

        let isCurrent = activeSessionKey == running[taskId]?.sessionId
        if isCurrent {
            if let idx = assistantIndex, idx < items.count,
               case .assistant(let old) = items[idx].kind {
                items[idx].kind = .assistant(text: old + chunk)
            } else {
                items.append(ChatItem(kind: .assistant(text: chunk)))
                assistantIndex = items.count - 1
            }
            streamTick &+= 1
            taskBuffers[taskId] = items
        } else {
            var buf = taskBuffers[taskId] ?? []
            if let last = buf.indices.last, case .assistant(let old) = buf[last].kind {
                buf[last].kind = .assistant(text: old + chunk)
            } else {
                buf.append(ChatItem(kind: .assistant(text: chunk)))
            }
            taskBuffers[taskId] = buf
        }
    }

    private func applyToBuffer(_ ev: ChatEvent, taskId: String) {
        guard running[taskId] != nil else { return }
        var buf = taskBuffers[taskId] ?? []
        switch ev.type {
        case "text":
            if let t = ev.text, !t.isEmpty {
                if let last = buf.indices.last, case .assistant(let old) = buf[last].kind {
                    buf[last].kind = .assistant(text: old + t)
                } else {
                    buf.append(ChatItem(kind: .assistant(text: t)))
                }
            }
        case "tool":
            if let i = buf.indices.last, case .assistant(let t) = buf[i].kind, isNote(t) {
                buf[i].kind = .note(text: t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let n = ev.name { buf.append(ChatItem(kind: .tool(name: n, input: ev.text ?? "", output: nil, seconds: nil, running: true))) }
        case "tool_done":
            if let i = buf.indices.last, case .tool(let n, let inp, _, _, _) = buf[i].kind {
                buf[i].kind = .tool(name: n, input: inp, output: ev.output, seconds: ev.secs, running: false)
            }
        case "usage":
            if let u = ev.usage { buf.append(ChatItem(kind: .usage(text: u.summary))) }
        case "error":
            buf.append(ChatItem(kind: .error(text: ev.text ?? "未知错误")))
        case "end":
            if let imgs = ev.images, !imgs.isEmpty {
                var shown = Set<String>()
                for it in buf {
                    if case .assistant(let t) = it.kind {
                        for m in t.matches(of: /!\[[^\]]*\]\(([^)]+)\)/) {
                            shown.insert(baseName(String(m.output.1)))
                        }
                    }
                }
                let fresh = imgs.filter { !shown.contains(baseName($0)) }
                if !fresh.isEmpty {
                    buf.append(ChatItem(kind: .images(fresh), taskId: ev.taskId))
                }
            }
            if let e = ev.error, !e.isEmpty {
                buf.append(ChatItem(kind: .error(text: e)))
            }
        default:
            break
        }
        taskBuffers[taskId] = buf
        if let c = ev.conversationId, !c.isEmpty {
            running[taskId]?.conversationId = c
        }
        if let sid = running[taskId]?.sessionId {
            sessionItems[sid] = buf
        }
    }

    private func handle(_ ev: ChatEvent, taskId: String) {
        guard running[taskId] != nil else { return }

        let isCurrent = activeSessionKey == running[taskId]?.sessionId
        // 非当前会话：所有改动只落在该任务的缓冲里，回头切过去再还原
        if !isCurrent {
            applyToBuffer(ev, taskId: taskId)
            return
        }

        if let c = ev.conversationId, !c.isEmpty {
            conversationId = c
            running[taskId]?.conversationId = c
        }

        // 非文本事件（工具卡、用量、结束）之前，先把攒下的文本落地，避免顺序错乱
        if ev.type != "text", !(pendingText[taskId] ?? "").isEmpty {
            flushText(taskId: taskId)
        }

        switch ev.type {
        case "text":
            guard let t = ev.text, !t.isEmpty else { return }
            // 节流：先攒着，80ms 后统一落盘，避免每帧重排整张列表
            pendingText[taskId, default: ""] += t
            scheduleFlush(taskId: taskId)
            return

        case "thought":
            guard let t = ev.text, !t.isEmpty else { return }
            items.append(ChatItem(kind: .thought(text: t)))

        case "tool":
            // 工具前那句短说明从正文里剥离，单独渲染
            flushText(taskId: taskId)
            if let i = items.indices.last, case .assistant(let t) = items[i].kind, isNote(t) {
                items[i].kind = .note(text: t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            assistantIndex = nil
            if let n = ev.name { LiveActivityManager.shared.update(step: n) }
            items.append(ChatItem(kind: .tool(name: ev.name ?? "tool",
                                              input: ev.params ?? ev.text ?? "",
                                              output: nil,
                                              seconds: nil,
                                              running: true)))

        case "tool_done":
            for i in stride(from: items.count - 1, through: 0, by: -1) {
                if case .tool(let n, let inp, _, _, true) = items[i].kind {
                    items[i].kind = .tool(name: n, input: inp, output: ev.output, seconds: ev.secs, running: false)
                    break
                }
            }

        case "usage":
            if let u = ev.usage {
                items.append(ChatItem(kind: .usage(text: u.summary)))
            }

        case "error":
            items.append(ChatItem(kind: .error(text: ev.error ?? ev.text ?? "未知错误")))

        case "end":
            assistantIndex = nil
            if let imgs = ev.images, !imgs.isEmpty {
                // 正文里已经用 ![xxx](path) 配图展示过的，不再整批重复铺一遍
                var shown = Set<String>()
                for it in items {
                    if case .assistant(let t) = it.kind {
                        for m in t.matches(of: /!\[[^\]]*\]\(([^)]+)\)/) {
                            shown.insert(baseName(String(m.output.1)))
                        }
                    }
                }
                let fresh = imgs.filter { !shown.contains(baseName($0)) }
                if !fresh.isEmpty {
                    items.append(ChatItem(kind: .images(fresh), taskId: ev.taskId))
                }
            }
            if let e = ev.error, !e.isEmpty {
                items.append(ChatItem(kind: .error(text: e)))
            }
            taskBuffers[taskId] = items
            finish(taskId: taskId)

        default:
            break
        }

        // 关键：当前会话的改动也要回写任务缓冲，finish() 才不会拿旧副本覆盖
        taskBuffers[taskId] = items
        if let sid = running[taskId]?.sessionId {
            sessionItems[sid] = items
        }
    }

    /// 取路径最后一段：正文里是绝对路径、images 里是裸文件名，必须归一化才能比对
    private func baseName(_ p: String) -> String {
        if let i = p.lastIndex(of: "/") { return String(p[p.index(after: i)...]) }
        return p
    }

    private func apply(_ events: [ChatEvent], live: Bool) {
        items = buildItems(events)
        assistantIndex = nil
    }

    /// 纯函数：把事件流构建成消息列表（批量，只赋值一次）
    private func buildItems(_ events: [ChatEvent]) -> [ChatItem] {
        var out: [ChatItem] = []
        var assistant: Int? = nil

        func appendAssistant(_ t: String) {
            if let i = assistant, i < out.count, case .assistant(let old) = out[i].kind {
                out[i].kind = .assistant(text: old + t)
            } else {
                out.append(ChatItem(kind: .assistant(text: t)))
                assistant = out.count - 1
            }
        }

        for ev in events {
            switch ev.type {
            case "user_input":
                let raw = ev.prompt ?? ""
                var body: [String] = []
                var paths: [String] = []
                for line in raw.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("[附件]") {
                        let p = t.replacingOccurrences(of: "[附件]", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if !p.isEmpty { paths.append(p) }
                    } else if !t.isEmpty {
                        body.append(line)
                    }
                }
                var shown = body.isEmpty ? "已发送图片" : body.joined(separator: "\n")
                // 首轮注入的行为约定不展示给用户
                if let r = shown.range(of: "【行为约定】") {
                    let after = shown[r.lowerBound...]
                    if let end = after.range(of: "\n\n") {
                        shown = String(after[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                out.append(ChatItem(kind: .user(text: shown, attachments: [], remotePaths: paths),
                                    taskId: ev.taskId,
                                    rawText: shown))
                assistant = nil

            case "text":
                guard let t = ev.text, !t.isEmpty else { continue }
                appendAssistant(t)

            case "tool":
                if let i = out.indices.last, case .assistant(let t) = out[i].kind, isNote(t) {
                    out[i].kind = .note(text: t.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                assistant = nil
                out.append(ChatItem(kind: .tool(name: ev.name ?? "tool",
                                                input: ev.params ?? ev.text ?? "",
                                                output: nil, seconds: nil, running: true)))
            case "tool_done":
                for i in stride(from: out.count - 1, through: 0, by: -1) {
                    if case .tool(let n, let inp, _, _, true) = out[i].kind {
                        out[i].kind = .tool(name: n, input: inp, output: ev.output, seconds: ev.secs, running: false)
                        break
                    }
                }
            case "usage":
                if let u = ev.usage { out.append(ChatItem(kind: .usage(text: u.summary))) }
            case "error":
                out.append(ChatItem(kind: .error(text: ev.error ?? ev.text ?? "错误")))
            case "end":
                assistant = nil
                if let imgs = ev.images, !imgs.isEmpty {
                    var shown = Set<String>()
                    for it in out {
                        if case .assistant(let t) = it.kind {
                            for m in t.matches(of: /!\[[^\]]*\]\(([^)]+)\)/) {
                                shown.insert(baseName(String(m.output.1)))
                            }
                        }
                    }
                    let fresh = imgs.filter { !shown.contains(baseName($0)) }
                    if !fresh.isEmpty {
                        out.append(ChatItem(kind: .images(fresh), taskId: ev.taskId))
                    }
                }
            default:
                break
            }
        }

        return out
    }

    // MARK: - 工具

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == s { toast = nil }
        }
    }

    /// 每个实例各自记一个模型，切实例不串
    private func modelKey(for url: String) -> String { "agy_model::" + url }

    func setModel(_ id: String) {
        model = id
        UserDefaults.standard.set(id, forKey: modelKey(for: api.baseURLString))
    }

    /// 切到某实例时，读回它自己上次选的模型
    func loadModelForCurrentInstance() {
        let saved = UserDefaults.standard.string(forKey: modelKey(for: api.baseURLString))
        model = saved ?? "gemini-3.8-flash-high"
    }

    func deleteSession(_ s: Session) async {
        await api.deleteSession(s.id)
        sessions.removeAll { $0.id == s.id }
        if currentSession?.id == s.id { newSession() }
    }
}
