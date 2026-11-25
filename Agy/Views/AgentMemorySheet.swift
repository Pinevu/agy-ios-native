import SwiftUI
import UIKit

/// Agent 人格设定（Soul）与全局持久记忆页（参考 OpenMinis SoulSettingsView + MemoryManagementView，原生写入 ~/.gemini/config/GEMINI.md）
struct AgentMemorySheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil

    @State private var tab = 0 // 0 = 核心记忆, 1 = 人格规则, 2 = 专题笔记
    @State private var loading = false
    @State private var saving = false

    @State private var enabled = true
    @State private var injectNotes = true
    @State private var soul = AgentSoulConfig.empty
    @State private var memoryText = ""
    @State private var dirty = false

    @State private var editingFile: MemoryNoteFile? = nil
    @State private var showNewNote = false

    private static let stylePresets = [
        "精炼直接，少寒暄多给可执行结论",
        "架构师视角，先给方案权衡再落地代码",
        "严谨详尽，关键改动附验证命令与结果",
        "温和清晰，复杂概念用通俗类比拆解"
    ]

    private static let langOptions = ["简体中文", "English", "繁體中文", "日本語", "跟随提问语言"]

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var usageRatio: Double {
        let lim = max(1, state.memoryCharLimit)
        return min(1.0, Double( livePreviewCount ) / Double(lim))
    }

    private var livePreviewCount: Int {
        guard enabled else { return 0 }
        let soulLen = soul.name.count + soul.role.count + soul.style.count + soul.rules.count
        let notesLen = injectNotes ? state.memoryFiles.reduce(0) { $0 + ($1.content?.count ?? 0) } : 0
        return soulLen + memoryText.count + notesLen
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("模块", selection: $tab) {
                    Text("核心记忆").tag(0)
                    Text("人格与规则").tag(1)
                    Text("专题笔记 (\(state.memoryFiles.count))").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                if tab == 0 {
                    coreMemoryTab
                } else if tab == 1 {
                    soulRulesTab
                } else {
                    notesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("记忆与设定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    if tab == 2 {
                        Button {
                            showNewNote = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    } else {
                        Button {
                            Task { await saveProfile() }
                        } label: {
                            if saving {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Text("保存")
                                    .fontWeight(dirty ? .bold : .semibold)
                            }
                        }
                        .disabled(saving)
                    }
                }
            }
            .task(id: state.currentInstanceId) {
                loading = true
                await state.refreshAgentMemory()
                syncFromState()
                loading = false
            }
            .sheet(isPresented: $showNewNote) {
                MemoryNoteEditorSheet(existing: nil)
            }
            .sheet(item: $editingFile) { file in
                MemoryNoteEditorSheet(existing: file)
            }
        }
    }

    private func syncFromState() {
        enabled = state.agentMemoryEnabled
        injectNotes = state.agentInjectNotes
        soul = state.agentSoul
        memoryText = state.globalMemory
        dirty = false
    }

    private func saveProfile() async {
        saving = true
        let err = await state.saveAgentProfile(
            enabled: enabled,
            injectNotes: injectNotes,
            soul: soul,
            globalMemoryText: memoryText
        )
        saving = false
        if let err {
            state.showToast(err)
        } else {
            dirty = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    // MARK: - Tab 0: 核心持久记忆

    private var coreMemoryTab: some View {
        Form {
            Section {
                Toggle("启用全局记忆与人格注入", isOn: $enabled)
                    .onChange(of: enabled) { _ in dirty = true }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("上下文占用预算")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(livePreviewCount) / \(state.memoryCharLimit) 字符")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(usageRatio > 0.85 ? Color.orange : .secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.tertiarySystemFill))
                                .frame(height: 6)
                            Capsule()
                                .fill(usageRatio > 0.85 ? Color.orange : Color.accentColor)
                                .frame(width: max(4, geo.size.width * usageRatio), height: 6)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.vertical, 2)
            } footer: {
                Text("保存后将同步写入服务端 ~/.gemini/config/GEMINI.md，Antigravity CLI 在每次对话中原生自动加载，不额外污染聊天标题。")
            }

            Section {
                TextEditor(text: $memoryText)
                    .font(.system(size: 14))
                    .frame(minHeight: 220)
                    .onChange(of: memoryText) { _ in dirty = true }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        snippetChip("+ 常用技术栈") {
                            appendMemory("- 常用开发栈：\n- 代码偏好：")
                        }
                        snippetChip("+ 服务器约定") {
                            appendMemory("- 主机环境与部署目录约定：\n- 禁止直接执行的高危操作：")
                        }
                        snippetChip("+ 个人偏好") {
                            appendMemory("- 回答格式与验证要求：")
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("长期核心记忆 (Markdown)")
            } footer: {
                Text("记录希望 Agent 跨所有会话始终记住的事实：如常用编程语言、仓库路径、服务器拓扑、命名规范或个人习惯。")
            }
        }
    }

    private func snippetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.11), in: Capsule())
        }
        .buttonStyle(.borderless)
    }

    private func appendMemory(_ snippet: String) {
        if memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memoryText = snippet
        } else {
            memoryText += "\n" + snippet
        }
        dirty = true
    }

    // MARK: - Tab 1: 人格与全局规则（Soul）

    private var soulRulesTab: some View {
        Form {
            Section("Agent 身份设定 (Soul)") {
                HStack {
                    Text("助手名称")
                        .frame(width: 76, alignment: .leading)
                    TextField("默认 Antigravity（可填 Jarvis 等）", text: $soul.name)
                        .onChange(of: soul.name) { _ in dirty = true }
                }
                HStack {
                    Text("角色定位")
                        .frame(width: 76, alignment: .leading)
                    TextField("例如：资深 iOS 与 Linux 全栈工程师", text: $soul.role)
                        .onChange(of: soul.role) { _ in dirty = true }
                }
                Picker("首选语言", selection: $soul.language) {
                    ForEach(Self.langOptions, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .onChange(of: soul.language) { _ in dirty = true }
            }

            Section {
                TextField("描述期望的沟通语气与风格…", text: $soul.style, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: soul.style) { _ in dirty = true }

                ForEach(Self.stylePresets, id: \.self) { preset in
                    Button {
                        soul.style = preset
                        dirty = true
                    } label: {
                        HStack {
                            Text(preset)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                            Spacer()
                            if soul.style == preset {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("沟通与回复风格")
            }

            Section {
                TextEditor(text: $soul.rules)
                    .font(.system(size: 13.5))
                    .frame(minHeight: 150)
                    .onChange(of: soul.rules) { _ in dirty = true }
            } header: {
                Text("全局行为准则 (Rules)")
            } footer: {
                Text("例如：「修改生产配置前先备份」「优先使用 Python 标准库而非引入重依赖」等。")
            }
        }
    }

    // MARK: - Tab 2: 专题记忆笔记库

    private var notesTab: some View {
        List {
            Section {
                Toggle("将专题笔记自动拼入全局上下文", isOn: Binding(
                    get: { injectNotes },
                    set: { val in
                        injectNotes = val
                        Task { await saveProfile() }
                    }
                ))
            } footer: {
                Text("按主题拆分管理多份 Markdown 记忆档案（如项目架构、API 备忘、部署清单），可随时新建或编辑。")
            }

            Section("记忆档案 (\(state.memoryFiles.count))") {
                if state.memoryFiles.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                        Text("还没有专题记忆笔记")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button {
                            showNewNote = true
                        } label: {
                            Text("新建第一篇笔记")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    ForEach(state.memoryFiles) { file in
                        Button {
                            editingFile = file
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.accentColor)
                                    Text(file.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if let sz = file.size {
                                        Text("\(sz) B")
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if let c = file.content?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                                    Text(c)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.borderless)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await state.deleteMemoryNoteFile(file) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await state.refreshAgentMemory()
            syncFromState()
        }
    }
}

// MARK: - 专题记忆笔记编辑器

private struct MemoryNoteEditorSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let existing: MemoryNoteFile?

    @State private var name = ""
    @State private var content = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if let err = errorText {
                    Section {
                        Text(err).font(.system(size: 13)).foregroundStyle(.red)
                    }
                }

                Section("笔记名称") {
                    TextField("例如：项目架构 / 常用域名", text: $name)
                        .disabled(existing != nil)
                }

                Section("Markdown 内容") {
                    TextEditor(text: $content)
                        .font(.system(size: 14))
                        .frame(minHeight: 240)
                }
            }
            .navigationTitle(existing == nil ? "新建记忆笔记" : existing!.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("保存").fontWeight(.semibold)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name.replacingOccurrences(of: ".md", with: "")
                    content = existing.content ?? ""
                }
            }
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        let err = await state.saveMemoryNoteFile(name: name, content: content)
        saving = false
        if let err {
            errorText = err
        } else {
            dismiss()
        }
    }
}
