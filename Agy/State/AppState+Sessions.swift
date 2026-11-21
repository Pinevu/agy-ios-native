import Foundation

/// 会话管理、服务端元数据同步（置顶 / 分组 / 重命名 / 已读）、全文搜索、批量操作、导出与跨会话草稿转移
extension AppState {

    // MARK: - 刷新与元数据同步

    func refreshSessions() async {
        do {
            sessions = try await api.tasks()
            syncWidgetSnapshot()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func syncSessionMeta() async {
        guard let remote = try? await api.getSessionsMeta() else { return }
        sessionMeta = remote
        pinnedIds = remote.pinned
        customTitles = remote.customTitles
        titleMemo.removeAll()
    }

    // MARK: - 置顶 / 重命名 / 分组 / 已读

    func isPinned(_ s: Session) -> Bool {
        pinnedIds.contains(s.id) || (s.pinned == true)
    }

    func togglePin(_ s: Session) {
        let wasPinned = isPinned(s)
        if let i = pinnedIds.firstIndex(of: s.id) {
            pinnedIds.remove(at: i)
            showToast("已取消置顶")
        } else {
            pinnedIds.insert(s.id, at: 0)
            showToast("已置顶")
        }
        sessionMeta.pinned = pinnedIds
        Task {
            if let updated = try? await api.updateSessionMeta([
                "action": wasPinned ? "unpin" : "pin",
                "id": s.id
            ]) {
                sessionMeta = updated
                pinnedIds = updated.pinned
            }
        }
    }

    func togglePinnedCollapsed() {
        sessionMeta.collapsedPinned.toggle()
        let val = sessionMeta.collapsedPinned
        Task {
            _ = try? await api.updateSessionMeta(["action": "collapsed_pinned", "value": val])
        }
    }

    func rename(_ s: Session, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        customTitles[s.id] = t
        sessionMeta.customTitles[s.id] = t
        titleMemo.removeValue(forKey: s.id)
        showToast("已重命名")
        Task {
            if let updated = try? await api.updateSessionMeta([
                "action": "rename",
                "id": s.id,
                "title": t
            ]) {
                sessionMeta = updated
                customTitles = updated.customTitles
            }
        }
    }

    func title(of s: Session) -> String {
        if let c = customTitles[s.id], !c.isEmpty { return c }
        let stamp = s.updated ?? s.started
        if let m = titleMemo[s.id], m.stamp == stamp { return m.text }
        let t = s.displayTitle
        titleMemo[s.id] = (stamp, t)
        return t
    }

    func isUnread(_ s: Session) -> Bool {
        if currentSession?.id == s.id { return false }
        if let readTs = sessionMeta.lastRead[s.id] {
            return (s.updated ?? s.started) > readTs + 1
        }
        return s.unread == true
    }

    func markRead(_ sessionId: String) {
        let now = Date().timeIntervalSince1970
        sessionMeta.lastRead[sessionId] = now
        Task {
            _ = try? await api.updateSessionMeta([
                "action": "mark_read",
                "id": sessionId,
                "ts": now
            ])
        }
    }

    func groupId(for s: Session) -> String? {
        sessionMeta.sessionGroups[s.id] ?? s.groupId
    }

    func group(for s: Session) -> SessionGroup? {
        guard let gid = groupId(for: s) else { return nil }
        return sessionMeta.groups.first(where: { $0.id == gid })
    }

    func createGroup(name: String, color: String = "#FF7A45") async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let updated = try? await api.updateSessionMeta([
            "action": "create_group",
            "name": trimmed,
            "color": color
        ]) {
            sessionMeta = updated
            showToast("已创建分组「\(trimmed)」")
        }
    }

    func deleteGroup(_ group: SessionGroup) async {
        if let updated = try? await api.updateSessionMeta([
            "action": "delete_group",
            "id": group.id
        ]) {
            sessionMeta = updated
            showToast("已删除分组")
        }
    }

    func assignGroup(_ groupId: String?, to sessionIds: [String]) async {
        guard !sessionIds.isEmpty else { return }
        var payload: [String: Any] = ["action": "set_group", "ids": sessionIds]
        if let groupId { payload["group_id"] = groupId }
        if let updated = try? await api.updateSessionMeta(payload) {
            sessionMeta = updated
            showToast(groupId == nil ? "已移出分组" : "已归入分组")
        }
    }

    // MARK: - 全文搜索 & 批量删除 & 导出

    func searchFullText(_ query: String) async {
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            searchResults = []
            isSearchingFullText = false
            return
        }
        isSearchingFullText = true
        defer { isSearchingFullText = false }
        if let list = try? await api.searchSessions(query: kw, limit: 40) {
            searchResults = list
        }
    }

    func deleteSession(_ s: Session) async {
        await api.deleteSession(s.id)
        sessions.removeAll { $0.id == s.id }
        sessionDrafts.removeValue(forKey: s.id)
        if currentSession?.id == s.id { newSession() }
        syncWidgetSnapshot()
    }

    func batchDeleteSessions(ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            let count = try await api.batchDeleteSessions(ids: ids)
            let set = Set(ids)
            sessions.removeAll { set.contains($0.id) }
            for sid in ids { sessionDrafts.removeValue(forKey: sid) }
            if let cur = currentSession?.id, set.contains(cur) { newSession() }
            showToast("已删除 \(count) 个对话")
            syncWidgetSnapshot()
        } catch {
            showToast("批量删除失败：\(error.localizedDescription)")
        }
    }

    func exportSession(_ s: Session, format: String = "md") async -> URL? {
        do {
            return try await api.exportSessionToTempFile(
                sessionId: s.id,
                format: format,
                suggestedTitle: title(of: s)
            )
        } catch {
            showToast("导出失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 打开 / 新建会话

    func open(_ session: Session) async {
        if let cur = currentSession?.id, cur != session.id {
            sessionItems[cur] = items
        }
        draftSessionKey = "draft-\(UUID().uuidString)"
        currentSession = session
        UserDefaults.standard.set(session.id, forKey: "agy_last_session")
        conversationId = session.conversationId
        assistantIndex = nil
        markRead(session.id)

        // 正式会话落库后，把仍在跑的 draft 任务显式重绑定到此会话
        if let i = running.first(where: { _, rt in
            rt.sessionId.hasPrefix("draft-") &&
            rt.conversationId != nil && rt.conversationId == session.conversationId
        })?.key {
            running[i]?.sessionId = session.id
            if let buf = taskBuffers[i] { sessionItems[session.id] = buf }
        }

        if let rt = running.values.first(where: { $0.sessionId == session.id }),
           let buf = taskBuffers[rt.taskId], !buf.isEmpty {
            items = buf
            if let rtConv = rt.conversationId { conversationId = rtConv }
            return
        }

        if let remote = currentServerTask {
            if let cached = sessionItems[session.id], !cached.isEmpty {
                items = cached
            } else {
                loadingSession = session.id
                items = []
            }
            defer { loadingSession = nil }
            if let events = await reconcile(sessionId: session.id) {
                adoptRemoteTask(remote, sessionId: session.id,
                                receivedCount: replayedEventCount(events, taskId: remote.taskId))
            }
            return
        }

        if let cached = sessionItems[session.id], !cached.isEmpty {
            items = cached
            return
        }

        loadingSession = session.id
        items = []
        defer { loadingSession = nil }
        do {
            let events = try await api.replay(session.id)
            apply(events, live: false)
            sessionItems[session.id] = items
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func openSessionById(_ sessionId: String) async {
        if let s = sessions.first(where: { $0.id == sessionId || $0.latestTaskId == sessionId }) {
            await open(s)
            return
        }
        await refreshSessions()
        if let s = sessions.first(where: { $0.id == sessionId || $0.latestTaskId == sessionId }) {
            await open(s)
        } else {
            showToast("未找到该会话")
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

    // MARK: - 跨会话草稿持久化 & 转移（含 5 秒撤回）

    func draftStorageKey(for sessionId: String?) -> String {
        sessionId ?? "__new__"
    }

    func savedDraft(for sessionId: String?) -> String {
        sessionDrafts[draftStorageKey(for: sessionId)] ?? ""
    }

    func saveDraft(_ text: String, for sessionId: String?) {
        let key = draftStorageKey(for: sessionId)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sessionDrafts.removeValue(forKey: key)
        } else {
            sessionDrafts[key] = text
        }
    }

    func transferDraft(text: String, to targetSession: Session, replace: Bool) async {
        let fromKey = draftStorageKey(for: currentSession?.id)
        let toKey = draftStorageKey(for: targetSession.id)
        let prevFrom = text
        let prevTo = sessionDrafts[toKey] ?? ""

        let nextTo: String
        if replace || prevTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextTo = text
        } else {
            nextTo = prevTo + "\n\n" + text
        }

        sessionDrafts.removeValue(forKey: fromKey)
        sessionDrafts[toKey] = nextTo
        pendingUndoTransfer = DraftTransferUndo(
            fromKey: fromKey,
            toKey: toKey,
            prevFromDraft: prevFrom,
            prevToDraft: prevTo
        )
        await open(targetSession)
        showToast("草稿已转移至「\(title(of: targetSession))」")

        // 5 秒后自动清除撤回窗口
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.pendingUndoTransfer = nil
        }
    }

    func undoLastDraftTransfer() -> String? {
        guard let u = pendingUndoTransfer else { return nil }
        pendingUndoTransfer = nil
        if u.prevToDraft.isEmpty {
            sessionDrafts.removeValue(forKey: u.toKey)
        } else {
            sessionDrafts[u.toKey] = u.prevToDraft
        }
        sessionDrafts[u.fromKey] = u.prevFromDraft
        showToast("已撤回草稿转移")
        return u.prevToDraft
    }
}
