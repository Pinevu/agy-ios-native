import Foundation
import SwiftUI
import Combine

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
    @Published var isRunning = false
    @Published var runningTaskId: String?
    @Published var conversationId: String?

    // 输入
    @Published var draft: String = ""
    @Published var attachments: [Attachment] = []

    // 模型
    @Published var model = UserDefaults.standard.string(forKey: "agy_model") ?? "gemini-3.8-flash-high"

    // UI
    @Published var toast: String?

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

    private var streamTask: Task<Void, Never>?
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
        guard !isRunning else { showToast("请先等当前任务结束或停止"); return }
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
        guard !isRunning else {
            showToast("请先等当前任务结束或停止")
            return
        }
        currentSession = session
        conversationId = session.conversationId
        items = []
        assistantIndex = nil
        do {
            let events = try await api.replay(session.id)
            apply(events, live: false)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func newSession() {
        guard !isRunning else { showToast("请先等当前任务结束或停止"); return }
        currentSession = nil
        conversationId = nil
        items = []
        assistantIndex = nil
    }

    // MARK: - 发送

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty { return }
        if isRunning { await stop(); return }

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
            runningTaskId = r.id
            if let c = r.conversationId { conversationId = c }
            // 回填任务 id，编辑重发时才知道从哪截断
            if let idx = items.firstIndex(where: { $0.id == bubbleId }) {
                items[idx].taskId = r.id
            }
            isRunning = true
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
    func editAndResend(itemId: UUID, newText: String) async {
        guard !isRunning else { showToast("请先等当前任务结束或停止"); return }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let turn = turnIndex(for: idx) ?? idx
        await truncateServer(from: turn)
        items.removeSubrange(turn..<items.count)
        assistantIndex = nil
        draft = trimmed
        await send()
    }

    /// 重试：删掉这一轮及其之后的回复，用同样的提问重新生成
    func retry(itemId: UUID) async {
        guard !isRunning else { showToast("请先等当前任务结束或停止"); return }
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
        guard !isRunning else { showToast("请先等当前任务结束或停止"); return }
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

    func stop() async {
        guard let id = runningTaskId else { return }
        await api.stop(id)
        showToast("已停止")
    }

    private func listen(taskId: String) {
        streamTask?.cancel()
        streamTask = api.stream(taskId: taskId, onEvent: { [weak self] ev in
            Task { @MainActor in self?.handle(ev, taskId: taskId) }
        }, onClose: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.runningTaskId = nil
            }
        })
    }

    // MARK: - 事件

    private func handle(_ ev: ChatEvent, taskId: String) {
        if let c = ev.conversationId, !c.isEmpty {
            conversationId = c
        }

        switch ev.type {
        case "text":
            guard let t = ev.text, !t.isEmpty else { return }
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
                items.append(ChatItem(kind: .images(imgs)))
            }
            if let e = ev.error, !e.isEmpty {
                items.append(ChatItem(kind: .error(text: e)))
            }
            isRunning = false
            runningTaskId = nil
            Task { await refreshSessions() }

        default:
            break
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
                    items.append(ChatItem(kind: .images(imgs)))
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
