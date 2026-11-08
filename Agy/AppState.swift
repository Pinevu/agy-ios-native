import UIKit
import Foundation
import SwiftUI
import Combine

struct RunningTask {
    let taskId: String
    let sessionId: String
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
    /// 后台任务的条目缓冲（不参与 @Published，避免流式时狂刷 UI）
    private var taskBuffers: [String: [ChatItem]] = [:]
    /// 流式文本节流缓冲
    private var pendingText: [String: String] = [:]
    private var flushScheduled: Set<String> = []
    /// 任务运行中追加的提示词，等当前任务结束后自动发送
    @Published var pendingPrompts: [String: String] = [:]

    /// 当前会话是否在跑
    var isRunning: Bool { currentRunningTask != nil }
    var runningTaskId: String? { currentRunningTask?.taskId }
    /// 全局在跑的任务数
    var runningCount: Int { running.count }

    /// 新会话（还没落库）用的临时 key，初值就有，保证任何时刻都有归属
    private var draftSessionKey = "draft-\(UUID().uuidString)"

    /// 当前会话自己的 key（永不为 nil）
    var activeSessionKey: String {
        currentSession?.id ?? draftSessionKey
    }

    var currentRunningTask: RunningTask? {
        let sid = activeSessionKey
        return running.values.first { $0.sessionId == sid }
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
        guard api.isLoggedIn else { isLoggedIn = false; return }
        let ok = await api.checkSession()
        if ok {
            isLoggedIn = true
            await refreshSessions()
            if currentSession == nil, let first = sessions.first {
                await open(first)
            }
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
        draftSessionKey = nil
        currentSession = session
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
        // 都没 → 从服务端回放
        items = []
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
        draftSessionKey = UUID().uuidString
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
            Task { @MainActor in self?.finish(taskId: taskId) }
        })
        running[taskId]?.stream = task
    }

    /// 任务收尾：落盘缓冲、清理运行态、检查排队提示词
    private func finish(taskId: String) {
        guard let rt = running[taskId] else { return }
        let sid = rt.sessionId
        let buf = taskBuffers[taskId] ?? items
        sessionItems[sid] = buf
        if activeSessionKey == sid {
            items = buf
        }
        taskBuffers.removeValue(forKey: taskId)
        running.removeValue(forKey: taskId)

        // 有排队的追加提示词 → 自动发出
        if let queued = pendingPrompts[sid], !queued.isEmpty {
            pendingPrompts.removeValue(forKey: sid)
            draft = queued
            Task { await self.send() }
        }
        Task { await refreshSessions() }
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
        guard running[taskId] != nil else { return }

        let isCurrent = activeSessionKey == running[taskId]?.sessionId
        if isCurrent {
            if let idx = assistantIndex, idx < items.count,
               case .assistant(let old) = items[idx].kind {
                items[idx].kind = .assistant(text: old + chunk)
            } else {
                items.append(ChatItem(kind: .assistant(text: chunk)))
                assistantIndex = items.count - 1
            }
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
                buf.append(ChatItem(kind: .images(imgs), taskId: ev.taskId))
            }
            if let e = ev.error, !e.isEmpty {
                buf.append(ChatItem(kind: .error(text: e)))
            }
        default:
            break
        }
        taskBuffers[taskId] = buf
        if let c = ev.conversationId, !c.isEmpty { rt.conversationId = c }
        running[taskId] = rt
        sessionItems[rt.sessionId] = buf
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
            if let idx = assistantIndex, idx < items.count {
                if case .assistant(let old) = items[idx].kind {
                    items[idx].kind = .assistant(text: old + t)
                    return
                }
            }
            items.append(ChatItem(kind: .assistant(text: t)))
            assistantIndex = items.count - 1

        case "thought":
            guard let t = ev.text, !t.isEmpty else { return }
            items.append(ChatItem(kind: .thought(text: t)))

        case "tool":
            assistantIndex = nil
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
                items.append(ChatItem(kind: .images(imgs), taskId: ev.taskId))
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

    private func apply(_ events: [ChatEvent], live: Bool) {
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
                let shown = body.isEmpty ? "已发送图片" : body.joined(separator: "\n")
                items.append(ChatItem(kind: .user(text: shown, attachments: [], remotePaths: paths),
                                      taskId: ev.taskId,
                                      rawText: shown))
                assistantIndex = nil
            case "text":
                guard let t = ev.text, !t.isEmpty else { continue }
                if let idx = assistantIndex, idx < items.count,
                   case .assistant(let old) = items[idx].kind {
                    items[idx].kind = .assistant(text: old + t)
                } else {
                    items.append(ChatItem(kind: .assistant(text: t)))
                    assistantIndex = items.count - 1
                }
            case "tool":
                assistantIndex = nil
                items.append(ChatItem(kind: .tool(name: ev.name ?? "tool",
                                                  input: ev.params ?? ev.text ?? "",
                                                  output: nil, seconds: nil, running: true)))
            case "tool_done":
                for i in stride(from: items.count - 1, through: 0, by: -1) {
                    if case .tool(let n, let inp, _, _, true) = items[i].kind {
                        items[i].kind = .tool(name: n, input: inp, output: ev.output, seconds: ev.secs, running: false)
                        break
                    }
                }
            case "usage":
                if let u = ev.usage { items.append(ChatItem(kind: .usage(text: u.summary))) }
            case "error":
                items.append(ChatItem(kind: .error(text: ev.error ?? ev.text ?? "错误")))
            case "end":
                assistantIndex = nil
                if let imgs = ev.images, !imgs.isEmpty {
                    items.append(ChatItem(kind: .images(imgs), taskId: ev.taskId))
                }
            default:
                break
            }
        }
    }

    // MARK: - 工具

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == s { toast = nil }
        }
    }

    func setModel(_ id: String) {
        model = id
        UserDefaults.standard.set(id, forKey: "agy_model")
    }

    func deleteSession(_ s: Session) async {
        await api.deleteSession(s.id)
        sessions.removeAll { $0.id == s.id }
        if currentSession?.id == s.id { newSession() }
    }
}
