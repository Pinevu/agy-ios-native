import SwiftUI
import UIKit
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var state: AppState

    @State private var showDrawer = false
    @State private var showBackToBottom = false
    @State private var turnCursor: Int = -1
    @State private var showModelPicker = false
    @State private var showQuota = false
    @State private var showAttach = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @FocusState private var inputFocused: Bool
    @State private var editingItem: ChatItem?
    @State private var editingPaths: [String] = []
    @State private var editingText = ""

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                messageList
                composer
            }
            .background(Color(.systemBackground).ignoresSafeArea())

            // 全屏任务列表：从左侧平滑滑入
            if showDrawer {
                DrawerView(isPresented: $showDrawer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .transition(.move(edge: .leading))
                    .zIndex(3)
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
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.toast)
        .animation(.easeOut(duration: 0.24), value: showDrawer)
        .sheet(isPresented: $showModelPicker) { modelSheet }
        .sheet(isPresented: $showQuota) { QuotaSheet() }
        .confirmationDialog("添加附件", isPresented: $showAttach, titleVisibility: .visible) {
            Button("照片图库") { showPhotoPicker = true }
            Button("文件") { showFileImporter = true }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    state.attachments.append(.init(name: "photo_\(Int(Date().timeIntervalSince1970)).jpg",
                                                   data: data, isImage: true))
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let isImg = ["jpg", "jpeg", "png", "heic", "webp"].contains(url.pathExtension.lowercased())
                    state.attachments.append(.init(name: url.lastPathComponent, data: data, isImage: isImg))
                }
            }
        }
    }

    // MARK: - 顶栏

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
                    HStack(spacing: 3) {
                        Text(state.currentModelName)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            // 运行状态
            Button {
                // 点一下刷新会话列表
                Task { await state.refreshSessions() }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isRunning ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    if state.isRunning {
                        Text("运行中").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            headerButton("plus") {
                dismissKeyboard()
                state.newSession()
                inputFocused = false
            }

            headerButton(isDarkMode ? "moon.fill" : "sun.max.fill") {
                toggleAppearance()
            }

            headerButton("line.3.horizontal") {
                dismissKeyboard()
                withAnimation(.easeOut(duration: 0.24)) { showDrawer = true }
            }
        }
        .padding(.horizontal, 14)
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
        state.draft = raw
        editingItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { inputFocused = true }
    }

    /// 退出编辑态（保留还是清空输入交给调用方）
    private func cancelEditing(clearDraft: Bool = true) {
        editingItem = nil
        if clearDraft { state.draft = "" }
        inputFocused = false
    }

    private func editBannerText(_ item: ChatItem) -> String {
        let raw: String
        if case .user(let t, _, _) = item.kind { raw = item.rawText ?? t } else { raw = item.rawText ?? "" }
        let one = raw.replacingOccurrences(of: "\n", with: " ")
        let short = one.count > 24 ? String(one.prefix(24)) + "…" : one
        return "编辑中：\(short)"
    }

    /// 当前是否暗色（跟随系统时读 trait）
    private var isDarkMode: Bool {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let win = scene.windows.first else { return false }
        switch win.overrideUserInterfaceStyle {
        case .dark: return true
        case .light: return false
        default: return win.traitCollection.userInterfaceStyle == .dark
        }
    }

    /// 亮 / 暗两态切换
    private func toggleAppearance() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let win = scene.windows.first else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            win.overrideUserInterfaceStyle = isDarkMode ? .light : .dark
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.items.isEmpty {
                        emptyState
                    }
                    ForEach(state.items) { item in
                        MessageRow(item: item, actions: MessageActions(
                            edit: { openEditor(for: $0) },
                            retry: { it in
                                Task {
                                    inputFocused = false
                                    await state.retry(itemId: it.id)
                                }
                            },
                            deleteFrom: { it in
                                Task { await state.deleteFrom(itemId: it.id) }
                            }
                        ))
                        .id(item.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-sentinel")
                        .onAppear { if showBackToBottom { withAnimation { showBackToBottom = false } } }
                        .onDisappear { if !showBackToBottom { showBackToBottom = true } }
                    if state.isRunning {
                        HStack(spacing: 7) {
                            ProgressView().scaleEffect(0.7)
                            Text("正在思考与执行…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .id("running")
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                floatingButtons(proxy)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
            .onChange(of: state.items.count) { _ in
                if let last = state.items.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.isRunning) { running in
                if running {
                    withAnimation { proxy.scrollTo("running", anchor: .bottom) }
                    turnCursor = -1
                }
            }
            .onChange(of: state.currentSession?.id) { _ in
                turnCursor = -1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                }
            }
            .onChange(of: state.items.count) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !showBackToBottom {
                        proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                    }
                }
            }
        }
    }


    // MARK: - 悬浮滚动按钮

    @ViewBuilder
    private func floatingButtons(_ proxy: ScrollViewProxy) -> some View {
        if showBackToBottom {
            VStack(spacing: 8) {
                if let prev = previousUserItem() {
                    Button {
                        turnCursor = prev.0
                        withAnimation(.easeInOut(duration: 0.24)) {
                            proxy.scrollTo(prev.1.id, anchor: .top)
                        }
                    } label: {
                        fabIcon("chevron.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回上一轮")
                }
                Button {
                    turnCursor = -1
                    withAnimation(.easeOut(duration: 0.24)) {
                        proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                    }
                } label: {
                    fabIcon("arrow.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回到底部")
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private func fabIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }

    /// 返回（索引, 上一条用户消息），从当前游标往前找
    private func previousUserItem() -> (Int, ChatItem)? {
        let users = state.items.enumerated().filter {
            if case .user = $0.element.kind { return true }
            return false
        }
        guard !users.isEmpty else { return nil }
        let start = turnCursor < 0 ? users.count - 1 : turnCursor - 1
        guard start >= 0, start < users.count else { return nil }
        let pair = users[start]
        return (start, pair.element)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        inputFocused = false
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
            Text("有什么可以帮你的？")
                .font(.system(size: 19, weight: .semibold))
            Text("随时提问、执行命令或分析文件")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 输入栏

    private var composer: some View {
        VStack(spacing: 0) {
            // 编辑态提示条
            if let editing = editingItem {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                    Text(editBannerText(editing))
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button {
                        cancelEditing()
                    } label: {
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

            // 附件预览
            if !state.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(state.attachments) { att in
                            ZStack(alignment: .topTrailing) {
                                if att.isImage, let img = UIImage(data: att.data) {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button { showAttach = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                TextField("", text: $state.draft, axis: .vertical)
                    .font(.system(size: 16.5))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.vertical, 9)
                    .overlay(alignment: .leading) {
                        if state.draft.isEmpty {
                            Text("询问 Antigravity")
                                .font(.system(size: 16.5))
                                .foregroundStyle(Color(.placeholderText))
                                .allowsHitTesting(false)
                        }
                    }

                Button {
                    inputFocused = false
                    Task {
                        if state.isRunning {
                            await state.stop()
                        } else if let editing = editingItem {
                            let text = state.draft
                            editingItem = nil
                            state.draft = ""
                            inputFocused = false
                            let keep = editingPaths
                            editingPaths = []
                            await state.editAndResend(itemId: editing.id, newText: text, keepPaths: keep)
                        } else {
                            await state.send()
                        }
                    }
                } label: {
                    Image(systemName: state.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(buttonColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!state.isRunning && state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.attachments.isEmpty)
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
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)

        }
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider().opacity(0.18) }
    }

    private var buttonColor: Color {
        if state.isRunning { return .red }
        let empty = state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.attachments.isEmpty
        return empty ? Color(.systemGray3) : Color.accentColor
    }

    // MARK: - 模型选择

    private var modelSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择运行模型")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("完成") { showModelPicker = false }
                    .font(.system(size: 15))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(AppState.models, id: \.id) { m in
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

                        if m.id != AppState.models.last?.id {
                            Divider().opacity(0.35).padding(.leading, 18)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
    }
}
