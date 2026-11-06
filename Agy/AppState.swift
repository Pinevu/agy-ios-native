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

    private var streamTask: Task<Void, Never>?
    private var assistantIndex: Int?

    let api = APIClient.shared

    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let data: Data
        let isImage: Bool
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

        let localAttachments = attachments.filter { $0.isImage }.map { $0.data }
        draft = ""
        attachments = []

        // 本地先插入用户气泡
        items.append(ChatItem(kind: .user(text: text, attachments: localAttachments)))
        assistantIndex = nil

        do {
            let r = try await api.run(prompt: prompt,
                                      model: model,
                                      conversationId: conversationId,
                                      sessionId: currentSession?.id)
            runningTaskId = r.id
            if let c = r.conversationId { conversationId = c }
            isRunning = true
            listen(taskId: r.id)
        } catch {
            items.append(ChatItem(kind: .error(text: error.localizedDescription)))
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
                items.append(ChatItem(kind: .user(text: ev.prompt ?? "", attachments: [])))
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
