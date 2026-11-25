import SwiftUI
import UIKit
import PhotosUI

// MARK: - 显示单元（支持 OpenMinis 连续工具折叠 + 行级 Equatable 记忆）

private enum ChatDisplayUnit: Identifiable {
    case single(ChatItem)
    case toolGroup(id: UUID, items: [ChatItem], isLiveGroup: Bool)

    var id: UUID {
        switch self {
        case .single(let item): return item.id
        case .toolGroup(let id, _, _): return id
        }
    }
}

private func sameChatKind(_ a: ChatItemKind, _ b: ChatItemKind) -> Bool {
    switch (a, b) {
    case (.user(let t1, let at1, let p1), .user(let t2, let at2, let p2)):
        return t1 == t2 && p1 == p2 && at1.count == at2.count
    case (.assistant(let x), .assistant(let y)): return x == y
    case (.note(let x), .note(let y)): return x == y
    case (.thought(let x), .thought(let y)): return x == y
    case (.tool(let n1, let i1, let o1, let sec1, let r1),
          .tool(let n2, let i2, let o2, let sec2, let r2)):
        return n1 == n2 && r1 == r2 && sec1 == sec2 && i1 == i2
            && (o1?.count ?? -1) == (o2?.count ?? -1) && o1 == o2
    case (.usage(let x), .usage(let y)): return x == y
    case (.error(let x), .error(let y)): return x == y
    case (.images(let x), .images(let y)): return x == y
    default: return false
    }
}

private struct ChatUnitRow: View, Equatable {
    let unit: ChatDisplayUnit
    let isLive: Bool
    let speakingItemId: UUID?
    let menu: ChatItem?
    let onMenu: (ChatItem?) -> Void
    let actions: MessageActions

    static func == (a: ChatUnitRow, b: ChatUnitRow) -> Bool {
        guard a.isLive == b.isLive, a.menu?.id == b.menu?.id else { return false }
        switch (a.unit, b.unit) {
        case (.single(let x), .single(let y)):
            let aSpeak = a.speakingItemId == x.id
            let bSpeak = b.speakingItemId == y.id
            return x.id == y.id && aSpeak == bSpeak && sameChatKind(x.kind, y.kind)
        case (.toolGroup(let id1, let xs, let l1), .toolGroup(let id2, let ys, let l2)):
            guard id1 == id2, l1 == l2, xs.count == ys.count else { return false }
            for i in xs.indices {
                if xs[i].id != ys[i].id || !sameChatKind(xs[i].kind, ys[i].kind) { return false }
            }
            return true
        default:
            return false
        }
    }

    var body: some View {
        switch unit {
        case .single(let item):
            MessageRow(
                item: item,
                isLive: isLive,
                actions: actions,
                isSpeaking: speakingItemId == item.id,
                assistantMenu: Binding(get: { menu }, set: { onMenu($0) })
            )
        case .toolGroup(_, let groupItems, let isLiveGroup):
            ToolGroupView(items: groupItems, isLiveGroup: isLiveGroup)
        }
    }
}

// MARK: - 主聊天视图

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var router: DeepLinkRouter
    @ObservedObject private var speech = SpeechManager.shared

    @State private var showDrawer = false
    @State private var drawerSubpageOpen = false
    @State private var chatSubpage: FullScreenSubpage? = nil
    @State private var showRunningList = false
    @State private var showBackToBottom = false
    @State private var stickBottom = true
    @State private var lastStreamScroll = Date.distantPast
    @State private var trailingScrollTask: Task<Void, Never>?
    @State private var turnCursor: Int = -1
    @State private var showModelPicker = false
    @State private var showAttach = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var showTransferSheet = false
    @State private var exportFileURL: URL?

    /// 孤立本地输入草稿，避免打字时整张消息列表重算
    @State private var input: String = ""
    @State private var draftBeforeVoice: String = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var assistantMenu: ChatItem? = nil
    @State private var capturedImage: UIImage?
    @FocusState private var inputFocused: Bool
    @State private var editingItem: ChatItem?
    @State private var editingPaths: [String] = []

    /// 仅折叠「已完成历史轮次」（最后一条用户消息之前）的连续 {.note, .tool} 链。
    /// 当前轮次（尤其任务执行中）绝不中途合并或收缩高度，彻底杜绝 LazyVStack 高度塌陷导致的白屏。
    private var displayUnits: [ChatDisplayUnit] {
        let items = state.items.filter {
            if case .usage = $0.kind { return false }
            return true
        }
        let foldBoundary = items.lastIndex(where: {
            if case .user = $0.kind { return true }
            return false
        }) ?? 0

        var out: [ChatDisplayUnit] = []
        var i = 0
        while i < items.count {
            if i < foldBoundary && isToolOrNote(items[i].kind) {
                var j = i
                var toolCount = 0
                while j < foldBoundary && isToolOrNote(items[j].kind) {
                    if case .tool = items[j].kind { toolCount += 1 }
                    j += 1
                }
                if toolCount >= 2 {
                    let slice = Array(items[i..<j])
                    out.append(.toolGroup(id: slice[0].id, items: slice, isLiveGroup: false))
                    i = j
                    continue
                }
            }
            out.append(.single(items[i]))
            i += 1
        }
        return out
    }

    private func isToolOrNote(_ kind: ChatItemKind) -> Bool {
        switch kind {
        case .tool, .note: return true
        default: return false
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                header
                if let active = activeBannerTask {
                    activeTaskBar(active)
                }
                Divider().opacity(0.4)
                messageList
                if state.pendingUndoTransfer != nil {
                    undoTransferBar
                }
                composer
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { v in
                        guard !showDrawer else { return }
                        let dx = v.translation.width
                        let dy = v.translation.height
                        guard v.startLocation.x < 44,
                              dx > 60,
                              abs(dx) > abs(dy) * 1.5 else { return }
                        dismissKeyboard()
                        withAnimation(.easeOut(duration: 0.26)) { showDrawer = true }
                    }
            )

            if showDrawer {
                DrawerView(isPresented: $showDrawer, subpageOpen: $drawerSubpageOpen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .transition(.move(edge: .leading))
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { v in
                                guard !drawerSubpageOpen else { return }
                                let dx = v.translation.width
                                let dy = v.translation.height
                                guard dx < -60, abs(dx) > abs(dy) * 1.5 else { return }
                                dismissKeyboard()
                                withAnimation(.easeIn(duration: 0.2)) { showDrawer = false }
                            }
                    )
                    .zIndex(3)
            }

            if let page = chatSubpage {
                SideSlideFullScreenContainer(onDismissed: closeChatSubpageImmediate) { closeSlide in
                    switch page {
                    case .jobs:
                        JobsSheet(onClose: closeSlide) { sid in
                            closeChatSubpageImmediate()
                            Task { await state.openSessionById(sid) }
                        }
                    case .skills:
                        SkillsSheet(onClose: closeSlide)
                    case .mcp:
                        MCPSheet(onClose: closeSlide)
                    case .env:
                        EnvVarsSheet(onClose: closeSlide)
                    case .memory:
                        AgentMemorySheet(onClose: closeSlide)
                    case .usage:
                        QuotaSheet(onClose: closeSlide)
                    }
                }
                .id(page)
                .zIndex(5)
            }

            if let t = state.toast {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.system(size: 13))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(999)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.toast)
        .animation(.easeOut(duration: 0.24), value: showDrawer)
        .onAppear {
            input = state.savedDraft(for: state.currentSession?.id)
            consumePendingDeepLink()
        }
        .onChange(of: state.currentSession?.id) { newSid in
            editingItem = nil
            input = state.savedDraft(for: newSid)
        }
        .onChange(of: router.pending) { _ in
            consumePendingDeepLink()
        }
        .onChange(of: speech.errorMessage) { err in
            if let err, !err.isEmpty { state.showToast(err) }
        }
        .confirmationDialog("消息", isPresented: Binding(
            get: { assistantMenu != nil },
            set: { if !$0 { assistantMenu = nil } }
        ), titleVisibility: .hidden) {
            if let item = assistantMenu {
                Button("复制全文") {
                    if case .assistant(let x) = item.kind {
                        UIPasteboard.general.string = x
                        state.showToast("已复制")
                    }
                }
                Button(speech.speakingItemId == item.id ? "停止朗读" : "朗读这段") {
                    if case .assistant(let x) = item.kind {
                        speech.toggleSpeak(text: x, itemId: item.id)
                    }
                }
                if let s = state.currentSession {
                    Button("导出本会话 Markdown") {
                        Task {
                            exportFileURL = await state.exportSession(s, format: "md")
                        }
                    }
                }
                Button("重试") {
                    let it = item
                    Task { inputFocused = false; await state.retry(itemId: it.id) }
                }
                Button("从此处删除", role: .destructive) {
                    let it = item
                    Task { await state.deleteFrom(itemId: it.id) }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showRunningList) { runningSheet }
        .sheet(isPresented: $showModelPicker) { modelSheet }
        .sheet(isPresented: $showTransferSheet) {
            DraftTransferSheet(draftText: input) { target, replace in
                let textToMove = input
                input = ""
                Task {
                    await state.transferDraft(text: textToMove, to: target, replace: replace)
                    input = state.savedDraft(for: target.id)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { exportFileURL != nil },
            set: { if !$0 { exportFileURL = nil } }
        )) {
            if let url = exportFileURL {
                ActivityShareSheet(items: [url])
            }
        }
        .confirmationDialog("添加附件", isPresented: $showAttach, titleVisibility: .visible) {
            Button("拍照") { showCamera = true }
            Button("照片图库") { showPhotoPicker = true }
            Button("文件") { showFileImporter = true }
            Button("取消", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .onChange(of: capturedImage) { img in
            guard let img else { return }
            if let data = img.jpegData(compressionQuality: 0.85) {
                state.attachments.append(.init(name: "photo_\(Int(Date().timeIntervalSince1970)).jpg",
                                               data: data, isImage: true))
            }
            capturedImage = nil
        }
        .photosPicker(isPresented: $showPhotoPicker,
                      selection: $photoItems,
                      maxSelectionCount: 9,
                      matching: .images,
                      photoLibrary: .shared())
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task {
                for (offset, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ts = Int(Date().timeIntervalSince1970)
                        state.attachments.append(.init(name: "photo_\(ts)_\(offset).jpg",
                                                       data: data, isImage: true))
                    }
                }
                photoItems = []
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let isImg = ["jpg", "jpeg", "png", "heic", "webp"].contains(url.pathExtension.lowercased())
                    state.attachments.append(.init(name: url.lastPathComponent, data: data, isImage: isImg))
                }
            }
        }
    }

    private func openChatSubpage(_ page: FullScreenSubpage) {
        dismissKeyboard()
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            chatSubpage = page
        }
    }

    private func closeChatSubpageImmediate() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            chatSubpage = nil
        }
    }

    // MARK: - DeepLink 分发

    private func consumePendingDeepLink() {
        guard state.isLoggedIn, let route = router.consume() else { return }
        showDrawer = false
        switch route {
        case .open:
            if state.currentSession == nil {
                Task { await state.resumeActiveRunningSessionIfNeeded() }
            }
        case .session(let sid):
            Task { await state.openSessionById(sid) }
        case .newChat(let prompt, let autoSend):
            state.saveDraft(input, for: state.currentSession?.id)
            state.newSession()
            editingItem = nil
            if let p = prompt, !p.isEmpty {
                if autoSend {
                    input = ""
                    state.draft = p
                    Task { await state.send() }
                } else {
                    input = p
                    inputFocused = true
                }
            } else {
                input = ""
                inputFocused = true
            }
        case .voice:
            startVoiceInput()
        case .jobs:
            openChatSubpage(.jobs)
        case .skills:
            openChatSubpage(.skills)
        case .mcp:
            openChatSubpage(.mcp)
        case .env:
            openChatSubpage(.env)
        case .memory:
            openChatSubpage(.memory)
        case .quota:
            openChatSubpage(.usage)
        }
    }

    // MARK: - 顶栏 + 悬浮运行条

    private var activeBannerTask: RunningTask? {
        state.currentRunningTask ?? state.mergedRunning.first
    }

    private func activeTaskBar(_ rt: RunningTask) -> some View {
        let isHere = state.currentRunningTask?.taskId == rt.taskId
        let extraCount = max(0, rt.subagentCount + max(0, state.runningCount - 1))
        return HStack(spacing: 8) {
            ProgressView().scaleEffect(0.68).frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(isHere ? "当前运行中" : (rt.title.isEmpty ? "后台运行中" : rt.title))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let tool = rt.latestTool, !tool.isEmpty {
                        Text(ToolDescribe.title(tool))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                    if extraCount > 0 {
                        Text("+\(extraCount)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
                }
            }

            Spacer(minLength: 4)

            Text(rt.startedAt, style: .timer)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !isHere {
                Button("查看") {
                    jumpToRunning(rt)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }

            Button {
                Task { await state.stop(taskId: rt.taskId) }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground).opacity(0.9))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.6)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Antigravity")
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)

                Button { showModelPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(state.currentModelName)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if state.agentMode == "plan" {
                            Text("Plan")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.indigo.opacity(0.14), in: Capsule())
                        }
                        if let eff = state.effortDisplayBadge {
                            Text(eff)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.13), in: Capsule())
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            Button {
                if state.runningCount > 0 {
                    showRunningList = true
                } else {
                    Task { await state.refreshSessions() }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.runningCount > 0 ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    if state.runningCount > 0 {
                        Text(state.runningCount > 1 ? "运行中 \(state.runningCount)" : "运行中")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            headerButton("plus") {
                dismissKeyboard()
                state.saveDraft(input, for: state.currentSession?.id)
                state.newSession()
                input = state.savedDraft(for: nil)
                editingItem = nil
                inputFocused = false
            }

            headerButton(state.isDarkEffective ? "moon.fill" : "sun.max.fill") {
                state.toggleAppearance()
            }

            headerButton("line.3.horizontal") {
                dismissKeyboard()
                state.saveDraft(input, for: state.currentSession?.id)
                withAnimation(.easeOut(duration: 0.24)) { showDrawer = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private func headerButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openEditor(for item: ChatItem) {
        guard !state.isRunning else {
            state.showToast("请先等当前任务结束或停止")
            return
        }
        let raw: String
        if case .user(let t, _, _) = item.kind { raw = item.rawText ?? t } else { raw = item.rawText ?? "" }
        if case .user(_, _, let paths) = item.kind { editingPaths = paths } else { editingPaths = [] }
        input = raw
        editingItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { inputFocused = true }
    }

    private func cancelEditing(clearDraft: Bool = true) {
        editingItem = nil
        if clearDraft { input = "" }
        inputFocused = false
    }

    private func editBannerText(_ item: ChatItem) -> String {
        let raw: String
        if case .user(let t, _, _) = item.kind { raw = item.rawText ?? t } else { raw = item.rawText ?? "" }
        let one = raw.replacingOccurrences(of: "\n", with: " ")
        let short = one.count > 24 ? String(one.prefix(24)) + "…" : one
        return "编辑中：\(short)"
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            List {
                if state.items.isEmpty {
                    Group {
                        if state.loadingSession != nil {
                            loadingState
                        } else {
                            emptyState
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                }

                let units = displayUnits
                let lastId = units.last?.id
                ForEach(units) { unit in
                    ChatUnitRow(
                        unit: unit,
                        isLive: state.isCurrentTaskRunning && lastId == unit.id,
                        speakingItemId: speech.speakingItemId,
                        menu: assistantMenu,
                        onMenu: { assistantMenu = $0 },
                        actions: rowActions
                    )
                    .equatable()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }

                if state.isCurrentTaskRunning {
                    HStack(spacing: 7) {
                        ProgressView().scaleEffect(0.7)
                        Text(state.items.isEmpty ? "正在准备…" : "正在思考与执行…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .id("running")
                }

                Color.clear
                    .frame(height: 12)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    .id("bottom-sentinel")
                    .onAppear {
                        if showBackToBottom { withAnimation(.easeOut(duration: 0.18)) { showBackToBottom = false } }
                        stickBottom = true
                    }
                    .onDisappear {
                        if !stickBottom && !showBackToBottom {
                            withAnimation(.easeOut(duration: 0.18)) { showBackToBottom = true }
                        }
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 8)
            .background(Color(.systemBackground))
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        // 手指向下拉（translation.height > 0）= 页面向上翻看历史，解除自动贴底
                        if value.translation.height > 28 {
                            withAnimation(.easeOut(duration: 0.18)) { showBackToBottom = true }
                            stickBottom = false
                        } else if value.translation.height < -28 {
                            turnCursor = -1
                        }
                    }
            )
            .id(state.currentSession?.id ?? "draft")
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if state.loadingSession != nil && state.items.isEmpty {
                    loadingState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                floatingButtons(proxy)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .animation(.easeOut(duration: 0.18), value: showBackToBottom)
            }
            .onChange(of: state.isCurrentTaskRunning) { running in
                if running {
                    stickBottom = true
                    showBackToBottom = false
                    DispatchQueue.main.async {
                        withAnimation(nil) { proxy.scrollTo("bottom-sentinel", anchor: .bottom) }
                    }
                    turnCursor = -1
                } else if stickBottom {
                    forceScrollToBottom(proxy)
                }
            }
            .onChange(of: state.streamTick) { _ in
                guard stickBottom else { return }
                let now = Date()
                trailingScrollTask?.cancel()
                if now.timeIntervalSince(lastStreamScroll) > 0.12 {
                    lastStreamScroll = now
                    DispatchQueue.main.async {
                        withAnimation(nil) { proxy.scrollTo("bottom-sentinel", anchor: .bottom) }
                    }
                } else {
                    // 尾部补滚：绝不丢掉最后一段输出或回放结束时的滚底事件
                    trailingScrollTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 140_000_000)
                        guard !Task.isCancelled, stickBottom else { return }
                        lastStreamScroll = Date()
                        withAnimation(nil) { proxy.scrollTo("bottom-sentinel", anchor: .bottom) }
                    }
                }
            }
            .onChange(of: state.currentSession?.id) { _ in
                turnCursor = -1
                forceScrollToBottom(proxy)
            }
            .onChange(of: state.loadingSession) { loading in
                if loading == nil { forceScrollToBottom(proxy) }
            }
            .onAppear {
                forceScrollToBottom(proxy)
            }
        }
    }

    private var rowActions: MessageActions {
        MessageActions(
            edit: { openEditor(for: $0) },
            retry: { it in
                Task {
                    inputFocused = false
                    await state.retry(itemId: it.id)
                }
            },
            deleteFrom: { it in
                Task { await state.deleteFrom(itemId: it.id) }
            },
            speak: { it, text in
                speech.toggleSpeak(text: text, itemId: it.id)
            }
        )
    }

    // MARK: - 悬浮滚动按钮

    private func forceScrollToBottom(_ proxy: ScrollViewProxy, immediate: Bool = false) {
        showBackToBottom = false
        stickBottom = true
        let delays = immediate ? [0.02] : [0.02, 0.16, 0.42]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(nil) { proxy.scrollTo("bottom-sentinel", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func floatingButtons(_ proxy: ScrollViewProxy) -> some View {
        if showBackToBottom {
            VStack(spacing: 8) {
                if !userTurns.isEmpty {
                    let canUp = prevIndex() != nil
                    Button {
                        guard let i = prevIndex() else { return }
                        turnCursor = i
                        stickBottom = false
                        withAnimation(.easeInOut(duration: 0.24)) {
                            proxy.scrollTo(userTurns[i].1.id, anchor: .top)
                        }
                    } label: {
                        fabIcon("chevron.up", disabled: !canUp)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!canUp)
                    .accessibilityLabel("回上一轮")
                }
                if turnCursor >= 0 {
                    let canDown = nextIndex() != nil
                    Button {
                        guard let i = nextIndex() else { return }
                        turnCursor = i
                        withAnimation(.easeInOut(duration: 0.24)) {
                            proxy.scrollTo(userTurns[i].1.id, anchor: .top)
                        }
                    } label: {
                        fabIcon("chevron.down", disabled: !canDown)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(!canDown)
                    .accessibilityLabel("回下一轮")
                }
                Button {
                    turnCursor = -1
                    stickBottom = true
                    forceScrollToBottom(proxy)
                } label: {
                    fabIcon("arrow.down.to.line")
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("回到底部")
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private func fabIcon(_ name: String, disabled: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(disabled ? Color.secondary.opacity(0.45) : Color.primary)
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            )
            .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.8))
    }

    private var userTurns: [(Int, ChatItem)] {
        state.items.enumerated().compactMap { idx, item in
            if case .user = item.kind { return (idx, item) }
            return nil
        }
    }

    private func prevIndex() -> Int? {
        let users = userTurns
        guard !users.isEmpty else { return nil }
        let start = turnCursor < 0 ? users.count - 1 : turnCursor - 1
        guard start >= 0, start < users.count else { return nil }
        return start
    }

    private func nextIndex() -> Int? {
        let users = userTurns
        guard !users.isEmpty, turnCursor >= 0 else { return nil }
        let start = turnCursor + 1
        guard start >= 0, start < users.count else { return nil }
        return start
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        inputFocused = false
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 120)
            ProgressView()
            Text("正在载入会话…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 120)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 52)
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
            Text("有什么可以帮你的？")
                .font(.system(size: 19, weight: .semibold))
            Text("输入 / 唤出快捷指令、技能与 MCP 工具")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                emptyQuickPill("MCP (\(state.enabledMCPCount))", icon: "point.3.connected.trianglepath.dotted") {
                    openChatSubpage(.mcp)
                }
                emptyQuickPill("环境变量 (\(state.enabledEnvCount))", icon: "key.radiowaves.forward") {
                    openChatSubpage(.env)
                }
                emptyQuickPill("记忆设定", icon: "brain.head.profile") {
                    openChatSubpage(.memory)
                }
                emptyQuickPill("/ 指令", icon: "terminal") {
                    input = "/"
                    inputFocused = true
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 52)
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyQuickPill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.borderless)
    }

    // MARK: - 撤回草稿转移条

    private var undoTransferBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("草稿已转移到此会话")
                .font(.system(size: 12.5))
            Spacer()
            Button("撤回") {
                if let restored = state.undoLastDraftTransfer() {
                    input = restored
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.09))
    }

    // MARK: - 输入栏（支持原生语音波形 + 草稿转移 + 下滑收键盘）

    private func startVoiceInput() {
        dismissKeyboard()
        draftBeforeVoice = input
        Task {
            await speech.startRecording { partial in
                if draftBeforeVoice.isEmpty {
                    input = partial
                } else {
                    input = draftBeforeVoice + (draftBeforeVoice.hasSuffix(" ") ? "" : " ") + partial
                }
            }
        }
    }

    // MARK: - 斜杠指令面板（参考 OpenMinis SlashCommandPicker：内置命令 + 已装技能 + 已启用 MCP）

    private struct SlashMenuItem: Identifiable {
        let id: String
        let trigger: String
        let title: String
        let subtitle: String
        let icon: String
        let tag: String?
        let tagColor: Color
        let run: () -> Void
    }

    private var activeSlashQuery: String? {
        guard editingItem == nil else { return nil }
        guard input.hasPrefix("/"), !input.contains("\n") else { return nil }
        let after = String(input.dropFirst())
        guard !after.contains(" ") else { return nil }
        return after.lowercased()
    }

    private var slashMenuItems: [SlashMenuItem] {
        guard let q = activeSlashQuery else { return [] }
        var all: [SlashMenuItem] = [
            SlashMenuItem(
                id: "cmd-plan",
                trigger: "/plan",
                title: state.agentMode == "plan" ? "切回自动执行模式" : "切换为规划模式 (Plan)",
                subtitle: "让 Agent 先输出结构化方案与推理步骤",
                icon: "map",
                tag: state.agentMode == "plan" ? "已开启" : "模式",
                tagColor: .indigo
            ) {
                let next = state.agentMode == "plan" ? "auto" : "plan"
                state.setAgentMode(next)
                input = ""
                state.showToast(next == "plan" ? "已开启 Plan 规划模式" : "已切回 Auto 自动执行模式")
            },
            SlashMenuItem(
                id: "cmd-mcp",
                trigger: "/mcp",
                title: "管理 MCP 服务器",
                subtitle: "已启用 \(state.enabledMCPCount) 个 · 支持 JSON 导入与握手探测",
                icon: "point.3.connected.trianglepath.dotted",
                tag: "面板",
                tagColor: .blue
            ) {
                input = ""
                openChatSubpage(.mcp)
            },
            SlashMenuItem(
                id: "cmd-env",
                trigger: "/env",
                title: "管理环境变量",
                subtitle: "已启用 \(state.enabledEnvCount) 项 · 自动注入命令与 MCP",
                icon: "key.radiowaves.forward",
                tag: "面板",
                tagColor: .orange
            ) {
                input = ""
                openChatSubpage(.env)
            },
            SlashMenuItem(
                id: "cmd-memory",
                trigger: "/memory",
                title: "Agent 记忆与人格设定",
                subtitle: "编辑全局 GEMINI.md 长期记忆与角色准则",
                icon: "brain.head.profile",
                tag: "面板",
                tagColor: .purple
            ) {
                input = ""
                openChatSubpage(.memory)
            },
            SlashMenuItem(
                id: "cmd-skills",
                trigger: "/skills",
                title: "打开技能商店",
                subtitle: "已安装 \(state.skills.count) 个技能",
                icon: "square.grid.2x2",
                tag: "面板",
                tagColor: .teal
            ) {
                input = ""
                openChatSubpage(.skills)
            },
            SlashMenuItem(
                id: "cmd-new",
                trigger: "/new",
                title: "发起新对话",
                subtitle: "清空当前上下文并开启新会话",
                icon: "square.and.pencil",
                tag: "会话",
                tagColor: .secondary
            ) {
                input = ""
                state.newSession()
            },
            SlashMenuItem(
                id: "cmd-goal",
                trigger: "/goal",
                title: "长程目标深入执行",
                subtitle: "插入 /goal 指令，让 Agent 持续推进直至达标",
                icon: "flag.checkered",
                tag: "CLI",
                tagColor: .green
            ) {
                input = "/goal "
                inputFocused = true
            },
            SlashMenuItem(
                id: "cmd-boost",
                trigger: "/boost",
                title: "多维深度思考与验证",
                subtitle: "插入 /boost 指令，启用严密方案推演与自检",
                icon: "bolt.fill",
                tag: "CLI",
                tagColor: .orange
            ) {
                input = "/boost "
                inputFocused = true
            },
            SlashMenuItem(
                id: "cmd-compact",
                trigger: "/compact",
                title: "压缩会话上下文",
                subtitle: "总结精简长对话历史，释放上下文窗口",
                icon: "arrow.down.right.and.arrow.up.left",
                tag: "CLI",
                tagColor: .secondary
            ) {
                input = "/compact"
                inputFocused = true
            }
        ]

        for sk in state.skills {
            all.append(SlashMenuItem(
                id: "skill-\(sk.name)",
                trigger: "/\(sk.name)",
                title: sk.name,
                subtitle: (sk.desc?.isEmpty == false) ? sk.desc! : "调用已安装技能 \(sk.name)",
                icon: "sparkles",
                tag: "技能",
                tagColor: .teal
            ) {
                input = "/\(sk.name) "
                inputFocused = true
            })
        }

        for srv in state.mcpServers where srv.enabled {
            all.append(SlashMenuItem(
                id: "mcp-\(srv.id)",
                trigger: "/\(srv.id)",
                title: srv.id,
                subtitle: srv.note?.isEmpty == false ? srv.note! : srv.summaryLine,
                icon: "network",
                tag: "MCP",
                tagColor: .blue
            ) {
                input = "请使用 MCP 服务器「\(srv.id)」"
                inputFocused = true
            })
        }

        guard !q.isEmpty else { return Array(all.prefix(24)) }
        return all.filter {
            $0.trigger.dropFirst().lowercased().contains(q)
            || $0.title.lowercased().contains(q)
            || $0.subtitle.lowercased().contains(q)
        }
    }

    @ViewBuilder
    private var slashCommandBar: some View {
        let items = slashMenuItems
        if !items.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            item.run()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(item.tagColor)
                                    .frame(width: 24, height: 24)
                                    .background(item.tagColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(item.trigger)
                                            .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        Text(item.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(item.subtitle)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                if let tag = item.tag {
                                    Text(tag)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(item.tagColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(item.tagColor.opacity(0.12), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if item.id != items.last?.id {
                            Divider().opacity(0.3).padding(.leading, 48)
                        }
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(items.count) * 52, 224))
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.08), radius: 10, y: -2)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            slashCommandBar

            // 编辑态提示条
            if let editing = editingItem {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                    Text(editBannerText(editing))
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button { cancelEditing() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }

            // 排队中的追加提示词
            if let sid = state.currentSession?.id,
               let queued = state.pendingPrompts[sid], !queued.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("排队中：\(queued)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button {
                        state.pendingPrompts.removeValue(forKey: sid)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
            }

            // 录音实时波形条
            if speech.isRecording {
                voiceWaveformBar
            }

            // 附件预览
            if !state.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(state.attachments) { att in
                            ZStack(alignment: .topTrailing) {
                                if att.isImage, let img = ImageCache.shared.decoded(att.data) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                } else {
                                    VStack(spacing: 3) {
                                        Image(systemName: "doc")
                                        Text(att.name)
                                            .font(.system(size: 8))
                                            .lineLimit(1)
                                    }
                                    .frame(width: 56, height: 56)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                Button {
                                    state.attachments.removeAll { $0.id == att.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                Button { showAttach = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                TextField("", text: $input, axis: .vertical)
                    .font(.system(size: 16.5))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.vertical, 9)
                    .overlay(alignment: .leading) {
                        if input.isEmpty {
                            Text("询问 Antigravity")
                                .font(.system(size: 16.5))
                                .foregroundStyle(Color(.placeholderText))
                                .allowsHitTesting(false)
                        }
                    }

                // 转移草稿按钮（有文字且存在历史会话时显示）
                if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.sessions.isEmpty && editingItem == nil {
                    Button {
                        dismissKeyboard()
                        showTransferSheet = true
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("转移草稿到其它会话")
                }

                // 原生语音输入键
                Button {
                    if speech.isRecording {
                        _ = speech.stopRecording()
                    } else {
                        startVoiceInput()
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "waveform.circle.fill" : "mic")
                        .font(.system(size: speech.isRecording ? 20 : 17, weight: .medium))
                        .foregroundStyle(speech.isRecording ? Color.red : Color.secondary)
                        .frame(width: 30, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("语音输入")

                // 发送 / 排队 / 停止键
                Button {
                    if speech.isRecording { _ = speech.stopRecording() }
                    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    let empty = trimmed.isEmpty && state.attachments.isEmpty
                    if empty && !state.isCurrentTaskRunning {
                        inputFocused = true
                        return
                    }
                    inputFocused = false
                    Task {
                        if state.isCurrentTaskRunning && empty {
                            await state.stop()
                        } else if let editing = editingItem {
                            editingItem = nil
                            state.draft = ""
                            input = ""
                            let keep = editingPaths
                            editingPaths = []
                            await state.editAndResend(itemId: editing.id, newText: trimmed, keepPaths: keep)
                        } else {
                            state.draft = input
                            input = ""
                            await state.send()
                        }
                    }
                } label: {
                    Image(systemName: isQueueMode ? "arrow.up.to.line" : (state.isCurrentTaskRunning ? "stop.fill" : "arrow.up"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(buttonColor)
                        .clipShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(inputFocused ? Color.accentColor.opacity(0.75)
                                         : Color.primary.opacity(0.18),
                            lineWidth: inputFocused ? 1.6 : 1.2)
            )
            .shadow(color: .black.opacity(inputFocused ? 0.05 : 0.03), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { v in
                        if v.translation.height > 32 && abs(v.translation.height) > abs(v.translation.width) * 1.4 {
                            dismissKeyboard()
                        }
                    }
            )
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider().opacity(0.18) }
    }

    private var voiceWaveformBar: some View {
        HStack(spacing: 10) {
            Button {
                speech.toggleLocale()
                startVoiceInput()
            } label: {
                Text(speech.shortLocaleLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(Array(speech.levels.enumerated()), id: \.offset) { _, lvl in
                    Capsule()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 2.5, height: max(4, lvl * 22))
                }
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.08), value: speech.levels)

            Button("取消") {
                _ = speech.stopRecording()
                input = draftBeforeVoice
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)

            Button("完成") {
                _ = speech.stopRecording()
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
    }

    private var isQueueMode: Bool {
        state.isCurrentTaskRunning &&
        (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.attachments.isEmpty)
    }

    private var buttonColor: Color {
        if isQueueMode { return Color.accentColor }
        if state.isCurrentTaskRunning { return .red }
        let empty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.attachments.isEmpty
        return empty ? Color(.systemGray3) : Color.accentColor
    }

    // MARK: - 运行中弹层 & 模型弹层

    private static let effortChoices: [(id: String, label: String)] = [
        ("", "默认"),
        ("low", "Low"),
        ("medium", "Med"),
        ("high", "High"),
        ("xhigh", "XHigh"),
        ("max", "Max")
    ]

    private var modelSheetHeight: CGFloat {
        let rows = CGFloat(state.modelOptions.count)
        return min(168 + rows * 54 + 24, 620)
    }

    private var runningSheet: some View {
        NavigationStack {
            Group {
                if state.mergedRunning.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("没有正在运行的任务")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(state.mergedRunning, id: \.taskId) { rt in
                                runningRow(rt)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .navigationTitle("运行中")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showRunningList = false }
                }
            }
        }
        .presentationDetents([.height(min(120 + CGFloat(max(1, state.runningCount)) * 66, 460))])
        .presentationDragIndicator(.visible)
    }

    private func runningRow(_ rt: RunningTask) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                jumpToRunning(rt)
            } label: {
                HStack(spacing: 11) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(rt.title.isEmpty ? "新任务" : rt.title)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(rt.startedAt, style: .timer)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            if let tool = rt.latestTool, !tool.isEmpty {
                                Text("· \(ToolDescribe.title(tool))")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 44)
                }
                .padding(.horizontal, 18)
                .frame(height: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                Task { await state.stop(taskId: rt.taskId) }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
        }
        .overlay(alignment: .bottom) {
            if rt.taskId != state.mergedRunning.last?.taskId {
                Divider().opacity(0.35).padding(.leading, 47)
            }
        }
    }

    private func findSession(for rt: RunningTask) -> Session? {
        if let t = state.sessions.first(where: { $0.id == rt.sessionId || $0.latestTaskId == rt.taskId || $0.id == rt.taskId }) {
            return t
        }
        if let cid = rt.conversationId, !cid.isEmpty,
           let t = state.sessions.first(where: { $0.id == cid || $0.conversationId == cid }) {
            return t
        }
        if !rt.title.isEmpty,
           let t = state.sessions.first(where: { state.title(of: $0) == rt.title }) {
            return t
        }
        return nil
    }

    private func jumpToRunning(_ rt: RunningTask) {
        showRunningList = false
        if let t = findSession(for: rt) {
            Task { await state.open(t) }
            return
        }
        Task {
            await state.refreshSessions()
            if let t = findSession(for: rt) {
                await state.open(t)
            } else {
                state.showToast("找不到对应会话，请下拉刷新列表")
            }
        }
    }

    private var modelSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("选择运行模型")
                        .font(.system(size: 16, weight: .semibold))
                    Text(state.currentInstance.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await state.refreshModels(force: true) }
                } label: {
                    if state.isLoadingModels {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(state.isLoadingModels)
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                Button("完成") { showModelPicker = false }
                    .font(.system(size: 15))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("执行模式")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("执行模式", selection: Binding(
                        get: { state.agentMode },
                        set: { state.setAgentMode($0) }
                    )) {
                        Text("Auto 自动").tag("auto")
                        Text("Plan 规划").tag("plan")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("推理强度 (--effort)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.effortChoices, id: \.id) { opt in
                                let selected = state.reasoningEffort == opt.id
                                Button {
                                    state.setReasoningEffort(opt.id)
                                } label: {
                                    Text(opt.label)
                                        .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
                                        .foregroundStyle(selected ? .white : .primary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 5)
                                        .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Divider().opacity(0.35)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(state.modelOptions, id: \.id) { m in
                        Button {
                            state.setModel(m.id)
                            showModelPicker = false
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.name)
                                        .font(.system(size: 15.5))
                                        .foregroundStyle(.primary)
                                    Text(m.id)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if state.model == m.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if m.id != state.modelOptions.last?.id {
                            Divider().opacity(0.35).padding(.leading, 18)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .task(id: state.currentInstanceId) {
            await state.refreshModels(force: false)
        }
        .presentationDetents([.height(modelSheetHeight)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 转移草稿选择器

private struct DraftTransferSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let draftText: String
    let onTransfer: (Session, Bool) -> Void

    @State private var replaceExisting = false
    @State private var query = ""

    private var targets: [Session] {
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.sessions.filter { s in
            if s.id == state.currentSession?.id { return false }
            if kw.isEmpty { return true }
            return state.title(of: s).lowercased().contains(kw)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("目标已有草稿时", selection: $replaceExisting) {
                        Text("追加到末尾").tag(false)
                        Text("替换原草稿").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section("选择目标会话") {
                    ForEach(targets) { s in
                        Button {
                            dismiss()
                            onTransfer(s, replaceExisting)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(state.title(of: s))
                                        .font(.system(size: 15))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(s.displayDate)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "筛选会话")
            .navigationTitle("转移草稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
