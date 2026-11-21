import Foundation

/// 多任务 SSE 实时流、80ms 文本节流、断流自愈回放、工具事件处理与灵动岛同步
extension AppState {

    var isRunning: Bool { currentRunningTask != nil }
    var runningTaskId: String? { currentRunningTask?.taskId }

    var runningCount: Int {
        max(running.count, serverRunning.count)
    }

    var currentServerTask: ServerRunning? {
        let sid = activeSessionKey
        let cid = currentSession?.conversationId ?? conversationId
        return serverRunning[sid]
            ?? serverRunning.values.first(where: { $0.conversationId != nil && $0.conversationId == cid })
            ?? (currentSession.flatMap { s in serverRunning.values.first(where: { $0.taskId == s.latestTaskId }) })
    }

    var isCurrentTaskRunning: Bool {
        currentRunningTask != nil || currentServerTask != nil
    }

    var mergedRunning: [RunningTask] {
        var out = Array(running.values)
        for (sid, sr) in serverRunning {
            if let idx = out.firstIndex(where: { $0.taskId == sr.taskId }) {
                // 用服务端权威工具名与子代理数补齐本地状态
                if let tool = sr.latestTool, !tool.isEmpty {
                    out[idx].latestTool = tool
                }
                if let sc = sr.subagentCount {
                    out[idx].subagentCount = max(out[idx].subagentCount, sc)
                }
            } else {
                let start = sr.started.map { Date(timeIntervalSince1970: $0) }
                    ?? Date().addingTimeInterval(-Double(sr.elapsed ?? 0))
                out.append(RunningTask(
                    taskId: sr.taskId,
                    sessionId: sid,
                    conversationId: sr.conversationId,
                    title: sr.title ?? "",
                    startedAt: start,
                    latestTool: sr.latestTool,
                    subagentCount: sr.subagentCount ?? 0
                ))
            }
        }
        return out.sorted { $0.startedAt < $1.startedAt }
    }

    var currentRunningTask: RunningTask? {
        let sid = activeSessionKey
        if let local = running.values.first(where: { $0.sessionId == sid }) {
            return local
        }
        guard let sr = currentServerTask else { return nil }
        let start = sr.started.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(-Double(sr.elapsed ?? 0))
        return RunningTask(
            taskId: sr.taskId,
            sessionId: sid,
            conversationId: sr.conversationId,
            title: sr.title ?? "",
            startedAt: start,
            latestTool: sr.latestTool,
            subagentCount: sr.subagentCount ?? 0
        )
    }

    // MARK: - 后台轮询与前后台恢复

    func startRunningPoller() {
        runningPoller?.cancel()
        runningPoller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isLoggedIn {
                    await self.syncRunning()
                }
                let ns: UInt64 = self.running.isEmpty && self.serverRunning.isEmpty
                    ? 8_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func appBecameActive() async {
        guard isLoggedIn else { return }
        await syncRunning(forceCurrentRecovery: true)
        startRunningPoller()
    }

    func syncRunning(forceCurrentRecovery: Bool = false) async {
        guard let snap = try? await api.runningTasks() else { return }

        var map: [String: ServerRunning] = [:]
        for r in snap.running {
            map[r.sessionId ?? r.taskId] = r
        }
        let changed = !sameRunningMap(serverRunning, map)
        if changed {
            serverRunning = map
            syncWidgetSnapshot()
        }

        // 同步灵动岛（即使在别端发起的任务也能自动挂上灵动岛）
        if let first = snap.running.first {
            let start = first.started.map { Date(timeIntervalSince1970: $0) }
                ?? Date().addingTimeInterval(-Double(first.elapsed ?? 0))
            let step = first.latestTool.map { ToolDescribe.title($0) } ?? "正在思考…"
            let extra = max(0, (first.subagentCount ?? 0) + max(0, snap.running.count - 1))
            LiveActivityManager.shared.start(
                title: (first.title?.isEmpty == false ? first.title! : "Antigravity"),
                sessionKey: first.sessionId ?? first.taskId,
                step: step,
                startedAt: start,
                subagentCount: extra
            )
        } else if running.isEmpty {
            LiveActivityManager.shared.end()
        }

        let serverTaskIds = Set(snap.running.map(\.taskId))
        for tid in Array(running.keys) where !serverTaskIds.contains(tid) {
            finish(taskId: tid)
        }

        if let session = currentSession, let remote = currentServerTask {
            let local = running[remote.taskId]
            let last = lastStreamActivity[remote.taskId] ?? .distantPast
            let stale = Date().timeIntervalSince(last) > 18
            if forceCurrentRecovery || local == nil || stale {
                await reconcileRemote(sessionId: session.id, force: forceCurrentRecovery)
            }
        }

        let known = Set(running.values.map { $0.sessionId })
        for r in snap.recent {
            guard let sid = r.sessionId, !known.contains(sid) else { continue }
            guard lastReconciled[sid] == nil else { continue }
            lastReconciled[sid] = Date()
            await reconcile(sessionId: sid)
        }
    }

    private func sameRunningMap(_ a: [String: ServerRunning], _ b: [String: ServerRunning]) -> Bool {
        guard a.count == b.count else { return false }
        for (key, x) in a {
            guard let y = b[key],
                  x.taskId == y.taskId,
                  x.sessionId == y.sessionId,
                  x.conversationId == y.conversationId,
                  x.title == y.title,
                  x.latestTool == y.latestTool,
                  x.subagentCount == y.subagentCount else { return false }
        }
        return true
    }

    // MARK: - 发送 / 编辑 / 重试 / 删除 / 停止

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty { return }

        if let cur = currentRunningTask {
            let sid = cur.sessionId
            let existing = pendingPrompts[sid] ?? ""
            let merged = existing.isEmpty ? text : existing + "\n" + text
            pendingPrompts[sid] = merged
            draft = ""
            saveDraft("", for: currentSession?.id)
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
        saveDraft("", for: currentSession?.id)
        attachments = []

        let bubbleId = UUID()
        items.append(ChatItem(id: bubbleId,
                              kind: .user(text: text, attachments: localAttachments),
                              rawText: text))
        assistantIndex = nil

        do {
            let r = try await api.run(
                prompt: prompt,
                model: model,
                conversationId: conversationId,
                sessionId: currentSession?.id
            )
            if let c = r.conversationId { conversationId = c }
            if let idx = items.firstIndex(where: { $0.id == bubbleId }) {
                items[idx].taskId = r.id
            }
            let sid = activeSessionKey
            let now = Date()
            LiveActivityManager.shared.start(
                title: displayTitleForCurrent(fallback: text),
                sessionKey: sid,
                step: "正在思考…",
                startedAt: now,
                subagentCount: max(0, running.count)
            )
            running[r.id] = RunningTask(
                taskId: r.id,
                sessionId: sid,
                conversationId: conversationId,
                title: text.isEmpty ? "新任务" : String(text.prefix(18)),
                startedAt: now
            )
            taskBuffers[r.id] = items
            listen(taskId: r.id)
            syncWidgetSnapshot()
        } catch {
            items.append(ChatItem(kind: .error(text: error.localizedDescription)))
        }
    }

    private func turnIndex(for idx: Int) -> Int? {
        guard idx >= 0, idx < items.count else { return nil }
        var i = idx
        while i >= 0 {
            if case .user = items[i].kind { return i }
            i -= 1
        }
        return nil
    }

    func editAndResend(itemId: UUID, newText: String, keepPaths: [String] = []) async {
        guard currentRunningTask == nil else { showToast("当前会话有任务在跑，先等它结束"); return }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let turn = turnIndex(for: idx) ?? idx
        await truncateServer(from: turn)
        items.removeSubrange(turn..<items.count)
        assistantIndex = nil

        if keepPaths.isEmpty {
            draft = trimmed
        } else {
            let attach = keepPaths.map { "[附件] \($0)" }.joined(separator: "\n")
            draft = trimmed + "\n\n" + attach
        }
        await send()
    }

    func retry(itemId: UUID) async {
        guard currentRunningTask == nil else { showToast("当前会话有任务在跑，先等它结束"); return }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard let turn = turnIndex(for: idx) else { return }
        guard case .user(let text, _, _) = items[turn].kind else { return }

        let prompt = items[turn].rawText ?? text
        await truncateServer(from: turn)
        items.removeSubrange(turn..<items.count)
        assistantIndex = nil
        draft = prompt
        await send()
    }

    func deleteFrom(itemId: UUID) async {
        guard currentRunningTask == nil else { showToast("当前会话有任务在跑，先等它结束"); return }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        let turn = turnIndex(for: idx) ?? idx
        await truncateServer(from: turn)
        items.removeSubrange(turn..<items.count)
        assistantIndex = nil
        showToast("已删除")
    }

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
        guard let rt = currentRunningTask else { return }
        await stop(taskId: rt.taskId)
    }

    func stop(taskId: String) async {
        await api.stop(taskId)
        showToast("已停止")
    }

    // MARK: - SSE 监听与重连

    func listen(taskId: String) {
        let from = received[taskId] ?? 0
        let epoch = (streamEpoch[taskId] ?? 0) + 1
        streamEpoch[taskId] = epoch
        lastStreamActivity[taskId] = Date()
        let task = api.stream(taskId: taskId, from: from, onActivity: { [weak self] in
            Task { @MainActor in
                guard self?.streamEpoch[taskId] == epoch else { return }
                self?.lastStreamActivity[taskId] = Date()
            }
        }, onEvent: { [weak self] ev in
            Task { @MainActor in
                guard self?.streamEpoch[taskId] == epoch else { return }
                self?.received[taskId, default: 0] += 1
                self?.handle(ev, taskId: taskId)
            }
        }, onClose: { [weak self] in
            Task { @MainActor in
                guard self?.streamEpoch[taskId] == epoch else { return }
                await self?.streamClosed(taskId: taskId)
            }
        })
        running[taskId]?.stream = task
    }

    private func streamClosed(taskId: String) async {
        guard running[taskId] != nil else { return }
        await syncRunning()
        guard running[taskId] != nil else { return }

        let still = serverRunning.values.contains { $0.taskId == taskId }
        if still {
            let n = (reconnects[taskId] ?? 0) + 1
            reconnects[taskId] = n
            let delay = UInt64(min(1 << min(n - 1, 3), 8)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard running[taskId] != nil else { return }
            listen(taskId: taskId)
        } else {
            reconnects.removeValue(forKey: taskId)
            finish(taskId: taskId)
        }
    }

    func finish(taskId: String) {
        guard let rt = running[taskId] else { return }
        let sid = rt.sessionId
        if running.count <= 1 {
            LiveActivityManager.shared.end()
        }

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
        received.removeValue(forKey: taskId)
        lastStreamActivity.removeValue(forKey: taskId)
        streamEpoch.removeValue(forKey: taskId)
        running.removeValue(forKey: taskId)
        lastRemoteReconcile.removeValue(forKey: sid)
        syncWidgetSnapshot()

        if let queued = pendingPrompts[sid], !queued.isEmpty {
            pendingPrompts.removeValue(forKey: sid)
            draft = queued
            Task { await self.send() }
        }
        Task { await refreshSessions() }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            guard self.running[taskId] == nil else { return }
            await self.reconcile(sessionId: sid)
        }
    }

    // MARK: - 回放自愈

    @discardableResult
    func reconcile(sessionId sid: String) async -> [ChatEvent]? {
        guard let events = try? await api.replay(sid) else { return nil }
        var snapshot = buildItems(events)
        let previous = activeSessionKey == sid ? items : (sessionItems[sid] ?? [])
        snapshot = reuseIdentity(snapshot, like: previous)
        sessionItems[sid] = snapshot
        if activeSessionKey == sid {
            items = snapshot
            if let i = items.indices.last, case .assistant = items[i].kind {
                assistantIndex = i
            } else {
                assistantIndex = nil
            }
            streamTick &+= 1
        }
        return events
    }

    func replayedEventCount(_ events: [ChatEvent], taskId: String) -> Int {
        var inTask = false
        var count = 0
        for event in events {
            if event.type == "user_input" {
                if inTask { break }
                inTask = event.taskId == taskId
                continue
            }
            if inTask { count += 1 }
        }
        return count
    }

    func adoptRemoteTask(_ remote: ServerRunning, sessionId sid: String,
                         receivedCount: Int, replacing: Bool = false) {
        if running[remote.taskId] != nil, !replacing { return }
        let start = remote.started.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(-Double(remote.elapsed ?? 0))
        running[remote.taskId] = RunningTask(
            taskId: remote.taskId,
            sessionId: sid,
            conversationId: remote.conversationId,
            title: remote.title ?? "",
            startedAt: start,
            latestTool: remote.latestTool,
            subagentCount: remote.subagentCount ?? 0
        )
        taskBuffers[remote.taskId] = items
        received[remote.taskId] = receivedCount
        reconnects.removeValue(forKey: remote.taskId)
        listen(taskId: remote.taskId)
    }

    private func reconcileRemote(sessionId sid: String, force: Bool = false) async {
        let now = Date()
        if !force, let last = lastRemoteReconcile[sid], now.timeIntervalSince(last) < 1.5 { return }
        guard !remoteRecoveryInFlight.contains(sid) else { return }
        lastRemoteReconcile[sid] = now
        remoteRecoveryInFlight.insert(sid)
        defer { remoteRecoveryInFlight.remove(sid) }

        guard let events = await reconcile(sessionId: sid),
              currentSession?.id == sid,
              let remote = currentServerTask else { return }

        running[remote.taskId]?.stream?.cancel()
        adoptRemoteTask(remote, sessionId: sid,
                        receivedCount: replayedEventCount(events, taskId: remote.taskId),
                        replacing: true)
    }

    func displayTitleForCurrent(fallback: String = "") -> String {
        if let s = currentSession { return title(of: s) }
        let t = (fallback.isEmpty ? draft : fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Antigravity" : String(t.prefix(24))
    }

    // MARK: - 文本节流与事件分发

    private func noteIndex(in arr: [ChatItem]) -> Int? {
        var i = arr.count - 1
        while i >= 0 {
            switch arr[i].kind {
            case .usage:
                i -= 1
                continue
            case .assistant(let t):
                return isNote(t) ? i : nil
            default:
                return nil
            }
        }
        return nil
    }

    private func isNote(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 30, !s.contains("\n") else { return false }
        if s.hasPrefix("#") || s.hasPrefix("-") || s.hasPrefix("*") || s.hasPrefix("```") { return false }
        return true
    }

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
            if let i = noteIndex(in: buf), case .assistant(let t) = buf[i].kind {
                buf[i].kind = .note(text: t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let n = ev.name {
                running[taskId]?.latestTool = n
                if n.contains("subagent") || n == "swarm" || n == "run_workflow" {
                    running[taskId]?.subagentCount += 1
                }
                buf.append(ChatItem(kind: .tool(name: n, input: ev.params ?? ev.text ?? "", output: nil, seconds: nil, running: true)))
            }
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
                let fresh = filterUnshownImages(imgs, in: buf)
                if !fresh.isEmpty { buf.append(ChatItem(kind: .images(fresh), taskId: ev.taskId)) }
            }
            if let e = ev.error, !e.isEmpty { buf.append(ChatItem(kind: .error(text: e))) }
        default:
            break
        }
        taskBuffers[taskId] = buf
        if let c = ev.conversationId, !c.isEmpty { running[taskId]?.conversationId = c }
        if let sid = running[taskId]?.sessionId { sessionItems[sid] = buf }
    }

    private func handle(_ ev: ChatEvent, taskId: String) {
        guard running[taskId] != nil else { return }

        let isCurrent = activeSessionKey == running[taskId]?.sessionId
        if !isCurrent {
            applyToBuffer(ev, taskId: taskId)
            return
        }

        if let c = ev.conversationId, !c.isEmpty {
            conversationId = c
            running[taskId]?.conversationId = c
        }

        if ev.type != "text", !(pendingText[taskId] ?? "").isEmpty {
            flushText(taskId: taskId)
        }

        switch ev.type {
        case "text":
            guard let t = ev.text, !t.isEmpty else { return }
            pendingText[taskId, default: ""] += t
            scheduleFlush(taskId: taskId)
            return

        case "thought":
            guard let t = ev.text, !t.isEmpty else { return }
            items.append(ChatItem(kind: .thought(text: t)))

        case "tool":
            flushText(taskId: taskId)
            if let i = noteIndex(in: items), case .assistant(let t) = items[i].kind {
                items[i].kind = .note(text: t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            assistantIndex = nil
            if let n = ev.name {
                running[taskId]?.latestTool = n
                if n.contains("subagent") || n == "swarm" || n == "run_workflow" {
                    running[taskId]?.subagentCount += 1
                }
                LiveActivityManager.shared.update(
                    step: ToolDescribe.title(n),
                    subagentCount: running[taskId]?.subagentCount ?? 0
                )
            }
            items.append(ChatItem(kind: .tool(
                name: ev.name ?? "tool",
                input: ev.params ?? ev.text ?? "",
                output: nil,
                seconds: nil,
                running: true
            )))

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
            items.append(ChatItem(kind: .error(text: ev.error ?? ev.text ?? "未知错误")))

        case "end":
            assistantIndex = nil
            if let imgs = ev.images, !imgs.isEmpty {
                let fresh = filterUnshownImages(imgs, in: items)
                if !fresh.isEmpty { items.append(ChatItem(kind: .images(fresh), taskId: ev.taskId)) }
            }
            if let e = ev.error, !e.isEmpty { items.append(ChatItem(kind: .error(text: e))) }
            taskBuffers[taskId] = items
            finish(taskId: taskId)

        default:
            break
        }

        streamTick &+= 1
        taskBuffers[taskId] = items
        if let sid = running[taskId]?.sessionId { sessionItems[sid] = items }
    }

    private static let markdownImageRegex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)

    private func filterUnshownImages(_ imgs: [String], in list: [ChatItem]) -> [String] {
        var shown = Set<String>()
        if let regex = Self.markdownImageRegex {
            for it in list {
                if case .assistant(let t) = it.kind {
                    let ns = t as NSString
                    let range = NSRange(location: 0, length: ns.length)
                    for m in regex.matches(in: t, range: range) where m.numberOfRanges > 1 {
                        let url = ns.substring(with: m.range(at: 1))
                        shown.insert(baseName(url))
                    }
                }
            }
        }
        return imgs.filter { !shown.contains(baseName($0)) }
    }

    private func baseName(_ p: String) -> String {
        if let i = p.lastIndex(of: "/") { return String(p[p.index(after: i)...]) }
        return p
    }

    func apply(_ events: [ChatEvent], live: Bool) {
        items = reuseIdentity(buildItems(events), like: items)
        assistantIndex = nil
    }

    private func kindTag(_ k: ChatItemKind) -> Int {
        switch k {
        case .user: return 0
        case .assistant: return 1
        case .note: return 2
        case .thought: return 3
        case .tool: return 4
        case .usage: return 5
        case .error: return 6
        case .images: return 7
        }
    }

    func reuseIdentity(_ fresh: [ChatItem], like old: [ChatItem]) -> [ChatItem] {
        guard !fresh.isEmpty, !old.isEmpty else { return fresh }
        var out = fresh
        for i in out.indices where i < old.count {
            if kindTag(out[i].kind) == kindTag(old[i].kind) {
                out[i].id = old[i].id
            }
        }
        return out
    }

    func buildItems(_ events: [ChatEvent]) -> [ChatItem] {
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
                if let i = noteIndex(in: out), case .assistant(let t) = out[i].kind {
                    out[i].kind = .note(text: t.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                assistant = nil
                out.append(ChatItem(kind: .tool(
                    name: ev.name ?? "tool",
                    input: ev.params ?? ev.text ?? "",
                    output: nil,
                    seconds: nil,
                    running: true
                )))

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
                    let fresh = filterUnshownImages(imgs, in: out)
                    if !fresh.isEmpty { out.append(ChatItem(kind: .images(fresh), taskId: ev.taskId)) }
                }

            default:
                break
            }
        }

        return out
    }
}
