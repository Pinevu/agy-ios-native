import SwiftUI
import UIKit

/// MCP 服务器集成与工具探测页（参考 OpenMinis MCPIntegrationsView + MCPFormSheet + MCPJSONImportSheet + MCPToolsSheet）
struct MCPSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil

    @State private var tab = 0 // 0 = 已配置, 1 = 精选预设
    @State private var loading = false
    @State private var editingServer: MCPServerItem? = nil
    @State private var showCreateForm = false
    @State private var showJSONImport = false
    @State private var probingServer: MCPServerItem? = nil
    @State private var addingPresetIds: Set<String> = []

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("视图", selection: $tab) {
                    Text("已配置 (\(state.mcpServers.count))").tag(0)
                    Text("精选预设").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                if tab == 0 {
                    installedList
                } else {
                    presetsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("MCP 服务器")
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
                            showCreateForm = true
                        } label: {
                            Label("手动配置服务器", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            showJSONImport = true
                        } label: {
                            Label("粘贴 JSON 导入", systemImage: "curlybraces")
                        }
                        if !state.mcpServers.isEmpty {
                            Divider()
                            Button {
                                exportAllJSON()
                            } label: {
                                Label("复制全部配置 JSON", systemImage: "doc.on.doc")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .task(id: state.currentInstanceId) {
                loading = true
                async let m: Void = state.refreshMCPServers()
                async let e: Void = state.refreshEnvVars()
                _ = await (m, e)
                loading = false
            }
            .sheet(isPresented: $showCreateForm) {
                MCPFormSheet(existing: nil)
            }
            .sheet(item: $editingServer) { srv in
                MCPFormSheet(existing: srv)
            }
            .sheet(isPresented: $showJSONImport) {
                MCPJSONImportSheet()
            }
            .sheet(item: $probingServer) { srv in
                MCPProbeSheet(server: srv)
            }
        }
    }

    // MARK: - 已配置列表

    @ViewBuilder
    private var installedList: some View {
        List {
            Section {
                if loading && state.mcpServers.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 26)
                } else if state.mcpServers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("尚未配置 MCP 服务器")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("通过标准 Model Context Protocol 为 Agent 接入外部文档、数据库、GitHub 或自定义工具。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 10) {
                            Button {
                                tab = 1
                            } label: {
                                Text("浏览精选预设")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.accentColor, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.borderless)

                            Button {
                                showJSONImport = true
                            } label: {
                                Text("粘贴 JSON 导入")
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(state.mcpServers) { srv in
                        serverRow(srv)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingServer = srv
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await state.deleteMCPServer(srv) }
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                                Button {
                                    Task { await state.toggleMCPServer(srv) }
                                } label: {
                                    Label(srv.enabled ? "停用" : "启用",
                                          systemImage: srv.enabled ? "pause.circle" : "play.circle")
                                }
                                .tint(srv.enabled ? .orange : .green)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    probingServer = srv
                                } label: {
                                    Label("探测工具", systemImage: "bolt.horizontal.circle")
                                }
                                .tint(.blue)
                            }
                    }
                }
            } header: {
                HStack {
                    Text("当前实例配置 (\(state.enabledMCPCount)/\(state.mcpServers.count) 已启用)")
                    Spacer()
                    Text(state.currentInstance.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            } footer: {
                Text("配置实时同步至服务端 ~/.gemini/config/mcp_config.json，Agent 在新轮次对话中自动发现并调用已启用的 MCP 工具。右滑或点闪电图标可实时测试握手与工具列表。")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await state.refreshMCPServers()
        }
    }

    private func serverRow(_ srv: MCPServerItem) -> some View {
        let dotColor: Color = {
            guard srv.enabled else { return Color.gray.opacity(0.45) }
            if srv.lastOk == false { return .red }
            return .green
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                Text(srv.id)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(srv.enabled ? .primary : .secondary)
                    .lineLimit(1)

                Text(srv.isHTTP ? "HTTP" : "STDIO")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(srv.isHTTP ? Color.blue : Color.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((srv.isHTTP ? Color.blue : Color.purple).opacity(0.12), in: Capsule())

                if let tc = srv.toolsCount, tc > 0 {
                    Text("\(tc) 工具")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                } else if !srv.enabled {
                    Text("已停用")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }

                Spacer(minLength: 4)

                Button {
                    probingServer = srv
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.horizontal.circle")
                            .font(.system(size: 14))
                        Text("测试")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.borderless)
            }

            Text(srv.summaryLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let note = srv.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .opacity(srv.enabled ? 1.0 : 0.65)
    }

    // MARK: - 精选预设列表

    private var presetsList: some View {
        List {
            Section {
                ForEach(state.mcpPresets) { preset in
                    let installed = state.mcpServers.contains(where: { $0.id == preset.id })
                    let busy = addingPresetIds.contains(preset.id)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(preset.displayTitle)
                                .font(.system(size: 15, weight: .semibold))
                            Text(preset.isHTTP ? "HTTP 免装" : "STDIO")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(preset.isHTTP ? Color.blue : Color.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((preset.isHTTP ? Color.blue : Color.purple).opacity(0.12), in: Capsule())
                            Spacer()
                            if installed {
                                Label("已添加", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.green)
                            } else {
                                Button {
                                    Task { await installPreset(preset) }
                                } label: {
                                    if busy {
                                        ProgressView().scaleEffect(0.75)
                                    } else {
                                        Text("一键添加")
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 5)
                                            .background(Color.accentColor, in: Capsule())
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(busy)
                            }
                        }

                        if let note = preset.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }

                        Text(preset.summaryLine)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("开箱即用 MCP 服务推荐")
            } footer: {
                Text("Context7 与 DeepWiki 为远程 Streamable HTTP 服务，无需额外 API Key 即可连接使用；GitHub 等服务可配合「环境变量」中的 ${GITHUB_TOKEN} 自动注入鉴权。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func installPreset(_ preset: MCPServerItem) async {
        addingPresetIds.insert(preset.id)
        var payload: [String: Any] = [
            "id": preset.id,
            "transport": preset.transport,
            "note": preset.note ?? "",
            "enabled": true
        ]
        if preset.isHTTP {
            payload["url"] = preset.url ?? ""
            payload["headers"] = preset.headers ?? [:]
        } else {
            payload["command"] = preset.command ?? ""
            payload["args"] = preset.args ?? []
            payload["env"] = preset.env ?? [:]
        }
        _ = await state.saveMCPServer(payload, isNew: true)
        addingPresetIds.remove(preset.id)
    }

    private func exportAllJSON() {
        var map: [String: Any] = [:]
        for s in state.mcpServers {
            if s.isHTTP {
                var obj: [String: Any] = ["serverUrl": s.url ?? ""]
                if let h = s.headers, !h.isEmpty { obj["headers"] = h }
                if !s.enabled { obj["disabled"] = true }
                map[s.id] = obj
            } else {
                var obj: [String: Any] = [
                    "command": s.command ?? "",
                    "args": s.args ?? []
                ]
                if let e = s.env, !e.isEmpty { obj["env"] = e }
                if !s.enabled { obj["disabled"] = true }
                map[s.id] = obj
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": map], options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = str
            state.showToast("已复制全部 MCP JSON 配置")
        }
    }
}

// MARK: - MCP 可视化创建/编辑表单（支持 $ENV_VAR 快捷插入）

private struct KVPairDraft: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

private struct MCPFormSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let existing: MCPServerItem?

    @State private var serverId = ""
    @State private var transport = "http" // "http" | "stdio"
    @State private var enabled = true
    @State private var note = ""

    // HTTP
    @State private var url = ""
    @State private var headers: [KVPairDraft] = []

    // STDIO
    @State private var command = "npx"
    @State private var argsText = ""
    @State private var envPairs: [KVPairDraft] = []

    @State private var saving = false
    @State private var errorText: String?

    private var canSave: Bool {
        let sid = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sid.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            return false
        }
        if transport == "http" {
            let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return u.hasPrefix("http://") || u.hasPrefix("https://")
        } else {
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
                    TextField("唯一标识，如 context7 / filesystem", text: $serverId)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("传输协议", selection: $transport) {
                        Text("HTTP 远程").tag("http")
                        Text("STDIO 命令").tag("stdio")
                    }
                    .pickerStyle(.segmented)

                    Toggle("启用该服务器", isOn: $enabled)
                    TextField("备注说明（可选）", text: $note)
                        .font(.system(size: 14.5))
                } header: {
                    Text("基本信息")
                }

                if transport == "http" {
                    Section {
                        HStack {
                            TextField("https://example.com/mcp", text: $url)
                                .font(.system(size: 14, design: .monospaced))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            envInsertMenu { ref in url += ref }
                        }
                    } header: {
                        Text("服务器地址 (Streamable HTTP / SSE)")
                    }

                    Section {
                        ForEach($headers) { $pair in
                            VStack(spacing: 6) {
                                HStack {
                                    TextField("Header 名 (如 Authorization)", text: $pair.key)
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                    Button(role: .destructive) {
                                        let pid = pair.id
                                        headers.removeAll { $0.id == pid }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                HStack {
                                    TextField("值 (如 Bearer ${API_KEY})", text: $pair.value)
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                    envInsertMenu { ref in pair.value += ref }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Button {
                            headers.append(KVPairDraft(key: "Authorization", value: "Bearer "))
                        } label: {
                            Label("添加请求头 (Header)", systemImage: "plus.circle")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text("自定义 HTTP 请求头")
                    } footer: {
                        Text("支持通过 ${VAR_NAME} 引用「环境变量」中配置的密钥。")
                    }
                } else {
                    Section {
                        HStack {
                            TextField("可执行程序，如 npx / node / python3", text: $command)
                                .font(.system(size: 14.5, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Menu {
                                ForEach(["npx", "node", "python3", "docker", "bash"], id: \.self) { c in
                                    Button(c) { command = c }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("启动参数（每行一个参数，或空格分隔）")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                envInsertMenu { ref in
                                    argsText += (argsText.isEmpty ? ref : "\n\(ref)")
                                }
                            }
                            TextEditor(text: $argsText)
                                .font(.system(size: 13.5, design: .monospaced))
                                .frame(minHeight: 84)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } header: {
                        Text("STDIO 启动命令")
                    }

                    Section {
                        ForEach($envPairs) { $pair in
                            VStack(spacing: 6) {
                                HStack {
                                    TextField("变量名 (KEY)", text: $pair.key)
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled()
                                    Button(role: .destructive) {
                                        let pid = pair.id
                                        envPairs.removeAll { $0.id == pid }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                HStack {
                                    TextField("变量值 或 ${ENV_VAR}", text: $pair.value)
                                        .font(.system(size: 13.5, design: .monospaced))
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                    envInsertMenu { ref in pair.value += ref }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Button {
                            envPairs.append(KVPairDraft(key: "", value: ""))
                        } label: {
                            Label("添加专属环境变量", systemImage: "plus.circle")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text("进程专属环境变量")
                    } footer: {
                        Text("全局「环境变量」中已启用的所有变量已默认对 STDIO 进程生效，此处可补充或覆盖特定键。")
                    }
                }

                if let existing {
                    Section {
                        Button {
                            copySingleJSON(existing)
                        } label: {
                            Label("复制此服务器 JSON", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            Task {
                                await state.deleteMCPServer(existing)
                                dismiss()
                            }
                        } label: {
                            Label("移除该 MCP 服务器", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "添加 MCP 服务器" : "编辑 MCP 服务器")
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
                    .disabled(!canSave || saving)
                }
            }
            .onAppear {
                guard let existing else { return }
                serverId = existing.id
                transport = existing.isHTTP ? "http" : "stdio"
                enabled = existing.enabled
                note = existing.note ?? ""
                url = existing.url ?? ""
                headers = (existing.headers ?? [:]).sorted(by: { $0.key < $1.key }).map {
                    KVPairDraft(key: $0.key, value: $0.value)
                }
                command = existing.command?.isEmpty == false ? existing.command! : "npx"
                argsText = (existing.args ?? []).joined(separator: "\n")
                envPairs = (existing.env ?? [:]).sorted(by: { $0.key < $1.key }).map {
                    KVPairDraft(key: $0.key, value: $0.value)
                }
            }
        }
    }

    @ViewBuilder
    private func envInsertMenu(onSelect: @escaping (String) -> Void) -> some View {
        if !state.envVars.isEmpty {
            Menu {
                ForEach(state.envVars) { item in
                    Button("${\(item.key)}") {
                        onSelect("${\(item.key)}")
                    }
                }
            } label: {
                Text("$变量")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.borderless)
        }
    }

    private func parseArgs(_ raw: String) -> [String] {
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count > 1 { return lines }
        guard let single = lines.first else { return [] }
        return single.split(separator: " ").map(String.init)
    }

    private func copySingleJSON(_ s: MCPServerItem) {
        var inner: [String: Any] = [:]
        if s.isHTTP {
            inner["serverUrl"] = s.url ?? ""
            if let h = s.headers, !h.isEmpty { inner["headers"] = h }
        } else {
            inner["command"] = s.command ?? ""
            inner["args"] = s.args ?? []
            if let e = s.env, !e.isEmpty { inner["env"] = e }
        }
        if let d = try? JSONSerialization.data(withJSONObject: ["mcpServers": [s.id: inner]], options: [.prettyPrinted, .sortedKeys]),
           let txt = String(data: d, encoding: .utf8) {
            UIPasteboard.general.string = txt
            state.showToast("已复制 JSON")
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        let sid = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "id": sid,
            "transport": transport,
            "enabled": enabled,
            "note": note.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let orig = existing?.id, orig != sid {
            payload["original_id"] = orig
        }
        if transport == "http" {
            payload["url"] = url.trimmingCharacters(in: .whitespacesAndNewlines)
            var hdrMap: [String: String] = [:]
            for p in headers {
                let k = p.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty { hdrMap[k] = p.value }
            }
            payload["headers"] = hdrMap
        } else {
            payload["command"] = command.trimmingCharacters(in: .whitespacesAndNewlines)
            payload["args"] = parseArgs(argsText)
            var evMap: [String: String] = [:]
            for p in envPairs {
                let k = p.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty { evMap[k] = p.value }
            }
            payload["env"] = evMap
        }

        let err = await state.saveMCPServer(payload, isNew: existing == nil)
        saving = false
        if let err {
            errorText = err
        } else {
            dismiss()
        }
    }
}

// MARK: - 粘贴 Claude Desktop / Cursor JSON 导入

private struct MCPJSONImportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var rawJSON = ""
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
                    TextEditor(text: $rawJSON)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 230)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            if let clip = UIPasteboard.general.string {
                                rawJSON = clip
                            }
                        } label: {
                            Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button("填入示例模板") {
                            rawJSON = """
                            {
                              "mcpServers": {
                                "context7": {
                                  "url": "https://mcp.context7.com/mcp"
                                },
                                "filesystem": {
                                  "command": "npx",
                                  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/root/workspace"]
                                }
                              }
                            }
                            """
                        }
                        .font(.system(size: 13))
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("MCP JSON 配置")
                } footer: {
                    Text("完全兼容 Claude Desktop、Cursor 与 Antigravity CLI 的 {\"mcpServers\": { ... }} 配置格式，支持一次粘贴导入多个 STDIO 或 HTTP 服务器。")
                }
            }
            .navigationTitle("粘贴 JSON 导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await doImport() }
                    } label: {
                        if importing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("导入").fontWeight(.semibold)
                        }
                    }
                    .disabled(rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing)
                }
            }
        }
    }

    private func doImport() async {
        importing = true
        errorText = nil
        let err = await state.importMCPFromJSON(rawJSON)
        importing = false
        if let err {
            errorText = err
        } else {
            dismiss()
        }
    }
}

// MARK: - 实时 MCP 握手与工具列表探测弹层（对齐 OpenMinis MCPToolsSheet）

private struct MCPProbeSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let server: MCPServerItem
    @State private var probing = true
    @State private var result: MCPProbeResponse?
    @State private var query = ""

    private var filteredTools: [MCPToolInfo] {
        let all = result?.tools ?? []
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(kw) || ($0.description?.lowercased().contains(kw) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if probing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在与「\(server.id)」进行 JSON-RPC 握手…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                        if !server.isHTTP {
                            Text("首次运行 npx 服务可能需要数秒拉取依赖包")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let res = result {
                    List {
                        Section("连接诊断") {
                            HStack {
                                Image(systemName: res.ok == true ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(res.ok == true ? Color.green : Color.red)
                                Text(res.ok == true ? "握手成功" : "连接异常")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                if let ms = res.latencyMs {
                                    Text("\(ms) ms")
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let err = res.error, !err.isEmpty {
                                Text(err)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }

                        if let tools = res.tools, !tools.isEmpty {
                            Section("发现可用工具 (\(filteredTools.count)/\(tools.count))") {
                                ForEach(filteredTools) { tool in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "wrench.and.screwdriver")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(Color.accentColor)
                                            Text(tool.name)
                                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                            Spacer()
                                            Button {
                                                UIPasteboard.general.string = tool.name
                                                state.showToast("已复制工具名 \(tool.name)")
                                            } label: {
                                                Image(systemName: "doc.on.doc")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        if let desc = tool.description, !desc.isEmpty {
                                            Text(desc)
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } else if res.ok == true {
                            Section {
                                Text("服务器握手正常，当前未暴露 tools 列表（可能仅提供 resources 或 prompts）。")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "筛选工具名称或说明")
                }
            }
            .navigationTitle("探测 · \(server.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await runProbe() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(probing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await runProbe()
            }
        }
    }

    private func runProbe() async {
        probing = true
        result = await state.probeMCPServer(server.id)
        probing = false
    }
}
