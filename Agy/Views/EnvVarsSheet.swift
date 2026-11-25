import SwiftUI
import UIKit

/// 环境变量管理页（参考 OpenMinis EnvironmentVariablesView：掩码查看、复制、工具输出脱敏、批量 .env 导入）
struct EnvVarsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil

    @State private var query = ""
    @State private var loading = false
    @State private var revealedIds: Set<String> = []
    @State private var editingItem: EnvVarItem? = nil
    @State private var showCreateSheet = false
    @State private var presetKey = ""
    @State private var presetNote = ""
    @State private var showBatchImport = false

    private static let recommendedPresets: [(key: String, note: String)] = [
        ("GITHUB_TOKEN", "GitHub Personal Access Token（仓库 / PR / MCP 鉴权）"),
        ("OPENAI_API_KEY", "OpenAI 接口密钥"),
        ("ANTHROPIC_API_KEY", "Anthropic Claude 接口密钥"),
        ("TAVILY_API_KEY", "Tavily 联网检索 API 密钥"),
        ("CLOUDFLARE_API_TOKEN", "Cloudflare DNS 与 Workers 管理令牌")
    ]

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var filteredVars: [EnvVarItem] {
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return state.envVars }
        return state.envVars.filter {
            $0.key.lowercased().contains(kw) || ($0.note?.lowercased().contains(kw) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { state.envPrivacyMode },
                        set: { val in Task { await state.setEnvPrivacyMode(val) } }
                    )) {
                        HStack(spacing: 10) {
                            Image(systemName: "eye.trianglebadge.exclamationmark")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("隐私脱敏模式")
                                    .font(.system(size: 15.5, weight: .medium))
                                Text("工具执行输出自动隐藏密钥明文")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("已启用的环境变量会自动注入 Agent 终端子进程，并可在 MCP 服务器配置中通过 ${KEY} 引用。开启隐私脱敏后，工具结果中长度 ≥ 6 的密钥值会自动打码为 ab••••yz。")
                }

                Section {
                    if loading && state.envVars.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    } else if filteredVars.isEmpty {
                        emptyView
                    } else {
                        ForEach(filteredVars) { item in
                            envRow(item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingItem = item
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await state.deleteEnvVar(item) }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    Button {
                                        Task { await state.toggleEnvVar(item) }
                                    } label: {
                                        Label(item.enabled ? "停用" : "启用",
                                              systemImage: item.enabled ? "pause.circle" : "play.circle")
                                    }
                                    .tint(item.enabled ? .orange : .green)
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("实例环境变量 (\(state.enabledEnvCount)/\(state.envVars.count) 已启用)")
                        Spacer()
                        Text(state.currentInstance.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                if state.envVars.count < 8 && query.isEmpty {
                    Section("常用变量快捷添加") {
                        ForEach(Self.recommendedPresets, id: \.key) { preset in
                            let exists = state.envVars.contains(where: { $0.key == preset.key })
                            Button {
                                if let hit = state.envVars.first(where: { $0.key == preset.key }) {
                                    editingItem = hit
                                } else {
                                    presetKey = preset.key
                                    presetNote = preset.note
                                    showCreateSheet = true
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: exists ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(exists ? Color.green : Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.key)
                                            .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        Text(preset.note)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if exists {
                                        Text("已配置")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .searchable(text: $query, prompt: "搜索变量名或备注")
            .refreshable {
                await state.refreshEnvVars()
            }
            .navigationTitle("环境变量")
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
                    Menu {
                        Button {
                            presetKey = ""
                            presetNote = ""
                            showCreateSheet = true
                        } label: {
                            Label("新建环境变量", systemImage: "plus")
                        }
                        Button {
                            showBatchImport = true
                        } label: {
                            Label("批量导入 .env / JSON", systemImage: "square.and.arrow.down")
                        }
                        if !state.envVars.isEmpty {
                            Divider()
                            Button {
                                let dotenv = state.envVars
                                    .map { "\($0.key)=\($0.value)" }
                                    .joined(separator: "\n")
                                UIPasteboard.general.string = dotenv
                                state.showToast("已复制 \(state.envVars.count) 项为 .env 格式")
                            } label: {
                                Label("导出全部为 .env", systemImage: "doc.on.doc")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .task(id: state.currentInstanceId) {
                if state.envVars.isEmpty {
                    loading = true
                } else {
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    guard !Task.isCancelled else { return }
                }
                await state.refreshEnvVars()
                if loading { loading = false }
            }
            .sheet(isPresented: $showCreateSheet) {
                EnvVarFormSheet(existing: nil, initialKey: presetKey, initialNote: presetNote)
            }
            .sheet(item: $editingItem) { item in
                EnvVarFormSheet(existing: item, initialKey: item.key, initialNote: item.note ?? "")
            }
            .sheet(isPresented: $showBatchImport) {
                EnvBatchImportSheet()
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.radiowaves.forward")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "尚未配置环境变量" : "没有匹配的变量")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("添加 API Key 或 Token 后，Agent 执行命令与 MCP 服务可直接读取。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func envRow(_ item: EnvVarItem) -> some View {
        let isRevealed = revealedIds.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(item.enabled ? Color.green : Color.gray.opacity(0.45))
                    .frame(width: 7, height: 7)

                Text(item.key)
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.enabled ? .primary : .secondary)
                    .lineLimit(1)

                if !item.enabled {
                    Text("已停用")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }

                Spacer(minLength: 4)

                Button {
                    if isRevealed {
                        revealedIds.remove(item.id)
                    } else {
                        revealedIds.insert(item.id)
                    }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.borderless)

                Menu {
                    Button {
                        UIPasteboard.general.string = item.value
                        state.showToast("已复制 \(item.key) 的值")
                    } label: {
                        Label("仅复制值 (VALUE)", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        UIPasteboard.general.string = "\(item.key)=\(item.value)"
                        state.showToast("已复制 \(item.key)=VALUE")
                    } label: {
                        Label("复制 KEY=VALUE", systemImage: "terminal")
                    }
                    Button {
                        UIPasteboard.general.string = "${\(item.key)}"
                        state.showToast("已复制引用 ${\(item.key)}")
                    } label: {
                        Label("复制引用 ${\(item.key)}", systemImage: "curlybraces")
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.borderless)
            }

            Text(isRevealed ? (item.value.isEmpty ? "（空值）" : item.value) : maskedPreview(item.value))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(isRevealed ? 3 : 1)

            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .opacity(item.enabled ? 1.0 : 0.65)
    }

    private func maskedPreview(_ v: String) -> String {
        guard !v.isEmpty else { return "（空）" }
        if v.count <= 6 { return String(repeating: "•", count: max(6, v.count)) }
        return "\(v.prefix(2))••••••••\(v.suffix(2))"
    }
}

// MARK: - 新建 / 编辑环境变量表单

private struct EnvVarFormSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let existing: EnvVarItem?
    let initialKey: String
    let initialNote: String

    @State private var key = ""
    @State private var value = ""
    @State private var note = ""
    @State private var enabled = true
    @State private var showPlainValue = false
    @State private var saving = false
    @State private var errorText: String?

    private var isValidKey: Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let err = errorText {
                    Section {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    HStack {
                        TextField("例如 GITHUB_TOKEN", text: $key)
                            .font(.system(size: 15, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: key) { newVal in
                                let cleaned = newVal.replacingOccurrences(of: " ", with: "_")
                                if cleaned != newVal { key = cleaned }
                            }
                        if !key.isEmpty && key != key.uppercased() {
                            Button("转大写") {
                                key = key.uppercased()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("变量名 (KEY)")
                } footer: {
                    if !key.isEmpty && !isValidKey {
                        Text("需以字母或下划线开头，仅包含字母、数字和下划线")
                            .foregroundStyle(.red)
                    } else {
                        Text("建议使用大写字母与下划线，例如 OPENAI_API_KEY")
                    }
                }

                Section {
                    if showPlainValue {
                        TextField("输入变量值", text: $value, axis: .vertical)
                            .font(.system(size: 14, design: .monospaced))
                            .lineLimit(2...6)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("输入变量值（默认隐藏）", text: $value)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Button {
                            showPlainValue.toggle()
                        } label: {
                            Label(showPlainValue ? "隐藏明文" : "显示明文",
                                  systemImage: showPlainValue ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !clip.isEmpty {
                                value = clip
                            }
                        } label: {
                            Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("变量值 (VALUE)")
                }

                Section("备注与状态") {
                    TextField("用途说明（可选）", text: $note)
                        .font(.system(size: 14.5))
                    Toggle("启用该变量", isOn: $enabled)
                }

                if let existing {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await state.deleteEnvVar(existing)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text("删除该环境变量")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "新建环境变量" : "编辑环境变量")
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
                    .disabled(!isValidKey || saving)
                }
            }
            .onAppear {
                if let existing {
                    key = existing.key
                    value = existing.value
                    note = existing.note ?? ""
                    enabled = existing.enabled
                } else {
                    key = initialKey
                    note = initialNote
                }
            }
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        let err = await state.saveEnvVar(
            id: existing?.id,
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            value: value,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled
        )
        saving = false
        if let err {
            errorText = err
        } else {
            dismiss()
        }
    }
}

// MARK: - 批量导入 .env / JSON

private struct EnvBatchImportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var rawText = ""
    @State private var importing = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if let err = errorText {
                    Section {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextEditor(text: $rawText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 200)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            if let s = UIPasteboard.general.string {
                                rawText = s
                            }
                        } label: {
                            Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button("填入示例") {
                            rawText = """
                            # GitHub 访问令牌
                            GITHUB_TOKEN=ghp_your_token_here
                            OPENAI_API_KEY="sk-your-key"
                            """
                        }
                        .font(.system(size: 13))
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("粘贴 .env 或 JSON 内容")
                } footer: {
                    Text("支持标准 .env 格式（KEY=VALUE、export KEY=\"VALUE\"、# 注释自动识别为备注）以及 {\"KEY\": \"VALUE\"} JSON 对象。同名变量会自动更新。")
                }
            }
            .navigationTitle("批量导入环境变量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await runImport() }
                    } label: {
                        if importing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("导入").fontWeight(.semibold)
                        }
                    }
                    .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing)
                }
            }
        }
    }

    private func runImport() async {
        importing = true
        errorText = nil
        let err = await state.batchImportEnvVars(rawText)
        importing = false
        if let err {
            errorText = err
        } else {
            dismiss()
        }
    }
}
