import SwiftUI
import UIKit
import Combine

enum FullScreenSubpage: Equatable {
    case settings
    case jobs
    case skills
    case mcp
    case env
    case memory
    case voice
    case usage
}

/// 原生全屏右侧滑入 + 左边缘跟手右滑返回容器（纯 GPU 位移合成，消除 .transition 卸载卡顿与全屏阴影离屏渲染）
struct SideSlideFullScreenContainer<Content: View>: View {
    var swipeBackEnabled: Bool = true
    let onDismissed: () -> Void
    @ViewBuilder let content: (@escaping () -> Void) -> Content

    @State private var offsetX: CGFloat = UIScreen.main.bounds.width
    @State private var isClosing: Bool = false

    private var screenWidth: CGFloat {
        max(320, UIScreen.main.bounds.width)
    }

    private func triggerClose() {
        guard !isClosing else { return }
        isClosing = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.98)) {
            offsetX = screenWidth
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                onDismissed()
            }
        }
    }

    var body: some View {
        let progress = max(0.0, min(1.0, 1.0 - Double(offsetX / screenWidth)))
        ZStack(alignment: .leading) {
            Color.black.opacity(0.16 * progress)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            content(triggerClose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.separator).opacity(0.32))
                        .frame(width: 0.5)
                        .ignoresSafeArea()
                }
                .background(alignment: .leading) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.09 * progress * min(1.0, Double(offsetX) / 12.0))],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 10)
                    .offset(x: -10)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
                .compositingGroup()
                .offset(x: offsetX)
                .allowsHitTesting(!isClosing)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { v in
                            guard swipeBackEnabled,
                                  !isClosing,
                                  v.startLocation.x < 48,
                                  v.translation.width > 0,
                                  abs(v.translation.width) > abs(v.translation.height) * 1.15 else { return }
                            offsetX = v.translation.width
                        }
                        .onEnded { v in
                            guard !isClosing, offsetX > 0 else { return }
                            if v.translation.width > 86 || v.predictedEndTranslation.width > 175 {
                                triggerClose()
                            } else {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.96)) {
                                    offsetX = 0
                                }
                            }
                        }
                )
        }
        .onAppear {
            offsetX = screenWidth
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.29, dampingFraction: 0.96)) {
                    offsetX = 0
                }
            }
        }
    }
}

/// 增强版侧边栏：最近活跃、可折叠置顶、自定义分组、标题/全文搜索、多选批量操作、导出与侧滑全屏功能页
struct DrawerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var appLock: AppLockManager
    @ObservedObject private var speech = SpeechManager.shared
    @Binding var isPresented: Bool
    @Binding var subpageOpen: Bool

    @State private var query = ""
    @State private var showSearch = false
    @State private var fullTextMode = false
    @State private var searchDebounce: Task<Void, Never>?

    @State private var selectedGroupId: String? = nil
    @State private var batchMode = false
    @State private var selectedIds: Set<String> = []
    @State private var showBatchGroupPicker = false

    @State private var activeSubpage: FullScreenSubpage? = nil
    @State private var settingsNested = false
    @State private var showInstances = false
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var renaming: Session?
    @State private var renameText = ""
    @State private var exportURL: URL?

    // MARK: - 过滤与分组数据

    private var filteredSessions: [Session] {
        let kw = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = state.sessions.filter { s in
            if let gid = selectedGroupId, state.groupId(for: s) != gid { return false }
            if !fullTextMode && !kw.isEmpty {
                return state.title(of: s).lowercased().contains(kw)
            }
            return true
        }
        return base.sorted { a, b in
            let pa = state.isPinned(a), pb = state.isPinned(b)
            if pa != pb { return pa }
            return (a.updated ?? a.started) > (b.updated ?? b.started)
        }
    }

    private var recentActive: [Session] {
        guard query.isEmpty && selectedGroupId == nil && !batchMode else { return [] }
        let cutoff = Date().timeIntervalSince1970 - 3600
        return state.sessions.filter { s in
            !state.isPinned(s) && (state.isSessionRunning(s) || state.isUnread(s) || (s.updated ?? s.started) > cutoff)
        }
        .sorted { ($0.updated ?? $0.started) > ($1.updated ?? $1.started) }
        .prefix(5)
        .map { $0 }
    }

    private var pinned: [Session] { filteredSessions.filter { state.isPinned($0) } }
    private var others: [Session] {
        let recentIds = Set(recentActive.map(\.id))
        return filteredSessions.filter { !state.isPinned($0) && !recentIds.contains($0.id) }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                if showSearch { searchBar }
                if !state.sessionMeta.groups.isEmpty || showNewGroup {
                    groupChipsBar
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if fullTextMode && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            fullTextResultList
                        } else {
                            if !batchMode {
                                menuRow("发起新对话", icon: "square.and.pencil") {
                                    state.newSession()
                                    isPresented = false
                                }
                            }

                        if !recentActive.isEmpty && !batchMode {
                            sectionHeader("⚡ 最近活跃")
                            ForEach(recentActive) { s in
                                sessionRow(s).id("recent-\(s.id)")
                            }
                        }

                        if !pinned.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) { state.togglePinnedCollapsed() }
                            } label: {
                                HStack(spacing: 6) {
                                    Text("📌 已置顶 (\(pinned.count))")
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: state.sessionMeta.collapsedPinned ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .padding(.horizontal, 22)
                                .padding(.top, 20)
                                .padding(.bottom, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if !state.sessionMeta.collapsedPinned {
                                ForEach(pinned) { s in
                                    sessionRow(s).id("pin-\(s.id)")
                                }
                            }
                        }

                        if !others.isEmpty || (recentActive.isEmpty && pinned.isEmpty) {
                            allSectionHeader
                            if others.isEmpty {
                                Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 22)
                                    .padding(.top, 14)
                            } else {
                                ForEach(others) { s in
                                    sessionRow(s).id("all-\(s.id)")
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)

            if batchMode {
                batchToolbar
            } else {
                footer
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .allowsHitTesting(activeSubpage == nil)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(.separator).opacity(0.3)).frame(width: 0.5)
        }

            if let page = activeSubpage {
                SideSlideFullScreenContainer(
                    swipeBackEnabled: !(page == .settings && settingsNested),
                    onDismissed: closeSubpageImmediate
                ) { closeSlide in
                    switch page {
                    case .settings:
                        SettingsSheet(
                            onClose: closeSlide,
                            onNestedChanged: { nested in
                                settingsNested = nested
                            },
                            onOpenSession: { sid in
                                closeSubpageImmediate()
                                Task { await state.openSessionById(sid) }
                                isPresented = false
                            },
                            onLogout: {
                                closeSubpageImmediate()
                                isPresented = false
                            }
                        )
                    case .jobs:
                        JobsSheet(onClose: closeSlide) { sid in
                            closeSubpageImmediate()
                            Task { await state.openSessionById(sid) }
                            isPresented = false
                        }
                    case .skills:
                        SkillsSheet(onClose: closeSlide)
                    case .mcp:
                        MCPSheet(onClose: closeSlide)
                    case .env:
                        EnvVarsSheet(onClose: closeSlide)
                    case .memory:
                        AgentMemorySheet(onClose: closeSlide)
                    case .voice:
                        VoiceSettingsSheet(onClose: closeSlide)
                    case .usage:
                        QuotaSheet(onClose: closeSlide)
                    }
                }
                .id(page)
                .zIndex(10)
            }
        }
        .onChange(of: state.currentInstanceId) { _ in
            selectedGroupId = nil
            query = ""
            batchMode = false
            selectedIds.removeAll()
            activeSubpage = nil
            subpageOpen = false
        }
        .onDisappear {
            subpageOpen = false
        }
        .sheet(isPresented: $showInstances) {
            InstancesSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let url = exportURL {
                ActivityShareSheet(items: [url])
            }
        }
        .confirmationDialog("归入分组", isPresented: $showBatchGroupPicker, titleVisibility: .visible) {
            ForEach(state.sessionMeta.groups) { g in
                Button(g.name) {
                    let ids = Array(selectedIds)
                    Task {
                        await state.assignGroup(g.id, to: ids)
                        batchMode = false
                        selectedIds.removeAll()
                    }
                }
            }
            Button("移出分组") {
                let ids = Array(selectedIds)
                Task {
                    await state.assignGroup(nil, to: ids)
                    batchMode = false
                    selectedIds.removeAll()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名对话", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let s = renaming { state.rename(s, to: renameText) }
                renaming = nil
            }
        }
        .alert("新建分组", isPresented: $showNewGroup) {
            TextField("分组名称，如：开发 / 运维", text: $newGroupName)
            Button("取消", role: .cancel) { newGroupName = "" }
            Button("创建") {
                let n = newGroupName
                newGroupName = ""
                let palette = ["#FF7A45", "#1677FF", "#52C41A", "#722ED1", "#EB2F96", "#13C2C2"]
                let color = palette[state.sessionMeta.groups.count % palette.count]
                Task { await state.createGroup(name: n, color: color) }
            }
        }
    }

    // MARK: - 顶部 & 搜索栏 & 分组条

    private var header: some View {
        HStack(spacing: 14) {
            Text("Antigravity")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSearch.toggle() }
                if !showSearch {
                    query = ""
                    state.searchResults = []
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(showSearch ? Color.accentColor : .primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            Button {
                showNewGroup = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField(fullTextMode ? "全文搜索历史对话内容…" : "搜索对话标题", text: $query)
                    .font(.system(size: 15.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: query) { val in
                        if fullTextMode { triggerFullTextSearch(val) }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        state.searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Picker("搜索范围", selection: $fullTextMode) {
                Text("标题").tag(false)
                Text("全文内容").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: fullTextMode) { on in
                if on && !query.isEmpty { triggerFullTextSearch(query) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func triggerFullTextSearch(_ text: String) {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            await state.searchFullText(text)
        }
    }

    private var groupChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                groupChip(title: "全部", colorHex: nil, selected: selectedGroupId == nil) {
                    selectedGroupId = nil
                }
                ForEach(state.sessionMeta.groups) { g in
                    groupChip(title: g.name, colorHex: g.color, selected: selectedGroupId == g.id) {
                        selectedGroupId = (selectedGroupId == g.id) ? nil : g.id
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            if selectedGroupId == g.id { selectedGroupId = nil }
                            Task { await state.deleteGroup(g) }
                        } label: { Label("删除分组", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func groupChip(title: String, colorHex: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let hex = colorHex {
                    Circle()
                        .fill(Color(agyHex: hex))
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 全文搜索结果列表

    @ViewBuilder
    private var fullTextResultList: some View {
        if state.isSearchingFullText {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("正在检索对话内容…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
        } else if state.searchResults.isEmpty {
            Text("未在历史内容中找到「\(query)」")
                .font(.system(size: 14.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 24)
        } else {
            ForEach(state.searchResults) { res in
                Button {
                    Task { await state.openSessionById(res.id) }
                    isPresented = false
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(res.title)
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            if let c = res.matchCount {
                                Text("\(c) 处命中")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        if let sn = res.snippet, !sn.isEmpty {
                            Text(sn)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.3).padding(.leading, 20)
            }
        }
    }

    private func openSubpage(_ page: FullScreenSubpage) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            subpageOpen = true
            activeSubpage = page
        }
    }

    private func closeSubpageImmediate() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            settingsNested = false
            activeSubpage = nil
            subpageOpen = false
        }
    }

    // MARK: - 常规行与会话行

    private func menuRow(_ title: String, icon: String, badge: String? = nil, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16.5))
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var allSectionHeader: some View {
        HStack(spacing: 8) {
            Text(selectedGroupId == nil ? "全部" : "分组内会话")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    batchMode.toggle()
                    selectedIds.removeAll()
                }
            } label: {
                Text(batchMode ? "完成" : "多选")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(batchMode ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private func sessionRow(_ s: Session) -> some View {
        let isSelected = selectedIds.contains(s.id)
        let grp = state.group(for: s)
        let runningNow = state.isSessionRunning(s)
        let unread = state.isUnread(s)

        return Button {
            if batchMode {
                if isSelected { selectedIds.remove(s.id) } else { selectedIds.insert(s.id) }
            } else {
                Task { await state.open(s) }
                isPresented = false
            }
        } label: {
            HStack(spacing: 9) {
                if batchMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }

                if let g = grp {
                    Circle()
                        .fill(Color(agyHex: g.color))
                        .frame(width: 7, height: 7)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title(of: s))
                        .font(.system(size: 16, weight: state.currentSession?.id == s.id ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if runningNow {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                } else if unread {
                    Circle().fill(Color.blue).frame(width: 7, height: 7)
                }

                if state.isPinned(s) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Text(s.displayDate)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 22)
            .frame(height: 50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.currentSession?.id == s.id && !batchMode
                        ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                state.togglePin(s)
            } label: {
                Label(state.isPinned(s) ? "取消置顶" : "置顶",
                      systemImage: state.isPinned(s) ? "pin.slash" : "pin")
            }
            Button {
                renameText = state.title(of: s)
                renaming = s
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            if !state.sessionMeta.groups.isEmpty {
                Menu {
                    ForEach(state.sessionMeta.groups) { g in
                        Button(g.name) {
                            Task { await state.assignGroup(g.id, to: [s.id]) }
                        }
                    }
                    if grp != nil {
                        Divider()
                        Button("移出分组") {
                            Task { await state.assignGroup(nil, to: [s.id]) }
                        }
                    }
                } label: {
                    Label("归入分组", systemImage: "folder")
                }
            }
            Menu {
                Button("导出 Markdown (.md)") {
                    Task { exportURL = await state.exportSession(s, format: "md") }
                }
                Button("导出 JSON (.json)") {
                    Task { exportURL = await state.exportSession(s, format: "json") }
                }
            } label: {
                Label("导出会话", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                Task { await state.deleteSession(s) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 多选批量操作底栏

    private var batchToolbar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            HStack(spacing: 14) {
                Text("已选 \(selectedIds.count) 项")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.sessionMeta.groups.isEmpty {
                    Button {
                        showBatchGroupPicker = true
                    } label: {
                        Label("分组", systemImage: "folder")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .disabled(selectedIds.isEmpty)
                }
                Button(role: .destructive) {
                    let ids = Array(selectedIds)
                    Task {
                        await state.batchDeleteSessions(ids: ids)
                        batchMode = false
                        selectedIds.removeAll()
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(selectedIds.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 底部实例与设置入口

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            HStack(spacing: 12) {
                Button {
                    showInstances = true
                } label: {
                    HStack(spacing: 12) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 38, height: 38)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(state.currentInstance.name)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(state.currentInstance.url.replacingOccurrences(of: "https://", with: ""))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    openSubpage(.settings)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                        Text("设置")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - 十六进制颜色辅助

private extension Color {
    init(agyHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        } else {
            r = 1.0; g = 0.48; b = 0.27
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - 配额面板（对齐官方 antigravity.google.com Usage 环形卡片风格：含周限额 + 5h + Argon）

struct QuotaSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var embedded: Bool = false
    var onClose: (() -> Void)? = nil
    @State private var quota: QuotaResponse?
    @State private var loading = false
    @State private var refreshing = false
    @State private var loadError: String?

    private var displayedQuota: QuotaResponse? {
        quota ?? state.lastQuotaSnapshot
    }

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    @ViewBuilder
    var body: some View {
        if embedded {
            quotaBody
        } else {
            NavigationStack {
                quotaBody
            }
        }
    }

    private var quotaBody: some View {
            ScrollView {
                if let q = displayedQuota, hasQuotaContent(q) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 6) {
                            if let plan = q.plan, !plan.isEmpty, plan != "-" {
                                Image(systemName: "star.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(plan)
                                    .font(.system(size: 14.5, weight: .semibold))
                            }
                            Text(state.currentInstance.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                            Spacer()
                            if let wk = q.week, (wk.calls ?? 0) > 0 {
                                Text("近 7 天 \(wk.calls ?? 0) 次任务")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 2)

                        if let accEmail = q.accountEmail ?? state.activeAccount?.email, !accEmail.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.indigo)
                                Text(accEmail)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 2)
                            .padding(.top, -8)
                        }

                        if let groups = q.groups, !groups.isEmpty {
                            ForEach(groups) { g in
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(localizedGroupName(g.name))
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if let c = g.count, c > 0 {
                                            Text("\(c) 个模型")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.top, 12)
                                    .padding(.bottom, 8)

                                    let validWins = g.windows.filter { $0.remaining != nil || $0.resetAt != nil }
                                    ForEach(Array(validWins.enumerated()), id: \.element.id) { idx, w in
                                        if idx > 0 {
                                            Divider().opacity(0.35).padding(.leading, 14)
                                        }
                                        quotaWindowRow(w)
                                    }

                                    if let desc = g.desc, !desc.isEmpty {
                                        Text(shortGroupDesc(desc))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 14)
                                            .padding(.top, 2)
                                            .padding(.bottom, 10)
                                    }
                                }
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color(.separator).opacity(0.22), lineWidth: 0.6)
                                )
                            }
                        } else if let buckets = q.buckets, !buckets.isEmpty {
                            // 兼容旧版后端实例（仅返回 buckets 未返回 groups）
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("模型 5 小时配额")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(buckets.count) 个模型")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                                .padding(.bottom, 8)

                                ForEach(Array(buckets.enumerated()), id: \.element.id) { idx, b in
                                    if idx > 0 {
                                        Divider().opacity(0.35).padding(.leading, 14)
                                    }
                                    quotaWindowRow(QuotaWindow(
                                        window: "5h",
                                        label: b.label,
                                        remaining: b.remaining,
                                        resetAt: b.resetAt,
                                        desc: nil
                                    ))
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color(.separator).opacity(0.22), lineWidth: 0.6)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                } else if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在获取 \(state.currentInstance.name) 用量…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    VStack(spacing: 10) {
                        Text(loadError ?? displayedQuota?.error ?? "当前实例暂未返回用量数据")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await load(force: true) }
                        }
                        .font(.system(size: 14, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .refreshable { await load(force: true) }
            .navigationTitle("用量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            closeSelf()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("返回")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        if refreshing {
                            ProgressView().scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(refreshing)
                }
            }
            .task(id: state.currentInstanceId) {
                quota = nil
                loadError = nil
                if state.lastQuotaSnapshot != nil {
                    try? await Task.sleep(nanoseconds: 360_000_000)
                    guard !Task.isCancelled else { return }
                }
                await load(force: false)
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                Task { await load(force: false) }
            }
    }

    private func hasQuotaContent(_ q: QuotaResponse) -> Bool {
        if let g = q.groups, !g.isEmpty { return true }
        if let b = q.buckets, !b.isEmpty { return true }
        return false
    }

    private func quotaWindowRow(_ w: QuotaWindow) -> some View {
        let frac = max(0, min(1, w.remaining ?? 0))
        let pct = Int((frac * 100).rounded())
        let ringColor = color(for: frac)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(w.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                if let reset = resetText(w.resetAt), pct < 100 {
                    Text(reset)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if let reset = resetText(w.resetAt) {
                    Text("满额 · \(reset)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if w.remaining != nil {
                HStack(spacing: 8) {
                    Text("\(pct)%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    QuotaRingView(progress: frac, color: ringColor)
                        .frame(width: 22, height: 22)
                }
            } else {
                Text("未提供")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func localizedGroupName(_ raw: String) -> String {
        switch raw {
        case "Gemini Models": return "Gemini 模型"
        case "Claude and GPT models": return "Claude 与 GPT 模型"
        default: return raw
        }
    }

    private func shortGroupDesc(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Models within this group: ", with: "包含模型：")
    }

    private func load(force: Bool = false) async {
        let targetEpoch = state.instanceEpoch
        if displayedQuota == nil || !hasQuotaContent(displayedQuota!) { loading = true }
        refreshing = true
        loadError = nil
        defer {
            if targetEpoch == state.instanceEpoch {
                loading = false
                refreshing = false
            }
        }
        do {
            let q = try await APIClient.shared.quota(force: force)
            guard targetEpoch == state.instanceEpoch else { return }
            if hasQuotaContent(q) {
                quota = q
                state.lastQuotaSnapshot = q
                state.syncWidgetSnapshot()
            } else {
                quota = q
                loadError = q.error ?? "当前实例暂未返回用量数据"
            }
        } catch {
            guard targetEpoch == state.instanceEpoch else { return }
            if displayedQuota == nil || !hasQuotaContent(displayedQuota!) {
                loadError = error.localizedDescription
            } else if force {
                state.showToast("刷新失败：\(error.localizedDescription)")
            }
        }
    }

    private func color(for r: Double) -> Color {
        r < 0.2 ? .red : (r < 0.5 ? .orange : Color(red: 0.27, green: 0.68, blue: 0.32))
    }

    private func resetText(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: iso)
        if date == nil {
            let f2 = ISO8601DateFormatter()
            date = f2.date(from: iso)
        }
        guard let d = date else { return nil }
        let diff = d.timeIntervalSinceNow
        if diff <= 0 { return "即将重置" }
        let days = Int(diff) / 86400
        let hours = (Int(diff) % 86400) / 3600
        let mins = (Int(diff) % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时后重置" }
        if hours > 0 { return "\(hours) 小时 \(mins) 分后重置" }
        return "\(mins) 分钟后重置"
    }
}

private struct QuotaRingView: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
