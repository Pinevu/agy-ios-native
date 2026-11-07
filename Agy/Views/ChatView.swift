import SwiftUI
import UIKit
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var state: AppState

    @State private var showDrawer = false
    @State private var showModelPicker = false
    @State private var showQuota = false
    @State private var showAttach = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @FocusState private var inputFocused: Bool
    @State private var editingItem: ChatItem?
    @State private var editingText = ""

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                messageList
                composer
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())

            if showDrawer {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showDrawer = false } }
                    .transition(.opacity)

                DrawerView(isPresented: $showDrawer)
                    .frame(width: 310)
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
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
        .sheet(isPresented: $showModelPicker) { modelSheet }
        .sheet(isPresented: $showQuota) { QuotaSheet() }
        .sheet(item: $editingItem) { it in
            EditMessageSheet(
                original: it.rawText ?? {
                    if case .user(let t, _) = it.kind { return t }
                    return ""
                }(),
                onCancel: { editingItem = nil },
                onSubmit: { newText in
                    editingItem = nil
                    Task {
                        inputFocused = false
                        await state.editAndResend(itemId: it.id, newText: newText)
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
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

            Text("Antigravity")
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1)

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
                state.newSession()
                inputFocused = false
            }

            headerButton("circle.lefthalf.filled") {
                toggleAppearance()
            }

            headerButton("line.3.horizontal") {
                withAnimation(.easeInOut(duration: 0.2)) { showDrawer = true }
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
        editingText = item.rawText ?? ""
        editingItem = item
    }

    private func toggleAppearance() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let win = scene.windows.first else { return }
        switch win.overrideUserInterfaceStyle {
        case .dark: win.overrideUserInterfaceStyle = .light
        case .light: win.overrideUserInterfaceStyle = .unspecified
        default: win.overrideUserInterfaceStyle = .dark
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
                }
            }
        }
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

            // 工具条
            HStack(spacing: 8) {
                Button { showModelPicker = true } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text(state.currentModelName)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { showQuota = true } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("配额")
                            .font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            HStack(alignment: .bottom, spacing: 8) {
                Button { showAttach = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                TextField("让它干点什么…", text: $state.draft, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.vertical, 7)

                Button {
                    inputFocused = false
                    Task {
                        if state.isRunning { await state.stop() }
                        else { await state.send() }
                    }
                } label: {
                    Image(systemName: state.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(buttonColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!state.isRunning && state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.attachments.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(inputFocused ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

        }
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private var buttonColor: Color {
        if state.isRunning { return .red }
        let empty = state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.attachments.isEmpty
        return empty ? Color(.systemGray3) : Color.accentColor
    }

    // MARK: - 模型选择

    private var modelSheet: some View {
        NavigationStack {
            List {
                ForEach(AppState.models, id: \.id) { m in
                    Button {
                        state.setModel(m.id)
                        showModelPicker = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.system(size: 15))
                                Text(m.id)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.model == m.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("选择运行模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showModelPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
