import SwiftUI

/// 原生技能管理与 OpenMinis/MinisSkills 社区技能商店
struct SkillsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0 // 0 = 已安装, 1 = 社区目录
    @State private var loadingInstalled = true
    @State private var loadingCatalog = false
    @State private var catalogQuery = ""
    @State private var installingNames: Set<String> = []
    @State private var banner: (text: String, isError: Bool)? = nil
    @State private var selectedSkill: Skill?
    @State private var showInstaller = false
    var onClose: (() -> Void)? = nil

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func showBanner(_ text: String, isError: Bool) {
        withAnimation(.easeOut(duration: 0.18)) {
            banner = (text, isError)
        }
        if !isError {
            Task {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                if banner?.text == text {
                    withAnimation(.easeOut(duration: 0.2)) { banner = nil }
                }
            }
        }
    }

    private var filteredCatalog: [SkillCatalogItem] {
        let kw = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return state.skillsCatalog }
        return state.skillsCatalog.filter {
            $0.name.lowercased().contains(kw) || ($0.desc?.lowercased().contains(kw) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("视图", selection: $tab) {
                    Text("已安装 (\(state.skills.count))").tag(0)
                    Text("社区商店").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if let b = banner {
                    HStack(spacing: 8) {
                        Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13))
                        Text(b.text)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(3)
                        Spacer(minLength: 4)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { banner = nil }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(b.isError ? Color.red : Color.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        (b.isError ? Color.red : Color.green).opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                if tab == 0 {
                    installedList
                } else {
                    catalogList
                }
            }
            .navigationTitle("技能商店")
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
                    Button {
                        showInstaller = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .task {
                loadingInstalled = true
                await state.refreshSkills()
                loadingInstalled = false
            }
            .onChange(of: tab) { newTab in
                if newTab == 1 && state.skillsCatalog.isEmpty {
                    Task {
                        loadingCatalog = true
                        await state.refreshSkillsCatalog()
                        loadingCatalog = false
                    }
                }
            }
            .sheet(item: $selectedSkill) { sk in
                SkillDetailSheet(skillName: sk.name)
            }
            .sheet(isPresented: $showInstaller) {
                SkillInstallSheet()
            }
        }
    }

    @ViewBuilder
    private var installedList: some View {
        if loadingInstalled && state.skills.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.skills.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("还没有安装技能")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                Button("去社区商店逛逛") { tab = 1 }
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(state.skills) { sk in
                    Button {
                        selectedSkill = sk
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(sk.name)
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                if sk.hasScripts == true {
                                    Text("scripts")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.12), in: Capsule())
                                }
                                Spacer(minLength: 4)
                                if let kb = sk.sizeKb {
                                    Text(String(format: "%.1f KB", kb))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if let d = sk.desc, !d.isEmpty {
                                Text(d)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                await APIClient.shared.deleteSkill(sk.name)
                                if let idx = state.skillsCatalog.firstIndex(where: { $0.name == sk.name }) {
                                    state.skillsCatalog[idx].installed = false
                                }
                                await state.refreshSkills()
                            }
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await state.refreshSkills() }
        }
    }

    private var catalogList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("搜索 OpenMinis/MinisSkills…", text: $catalogQuery)
                    .font(.system(size: 14.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !catalogQuery.isEmpty {
                    Button { catalogQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if loadingCatalog && state.skillsCatalog.isEmpty {
                ProgressView("正在拉取社区目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredCatalog.isEmpty {
                VStack(spacing: 10) {
                    Text(state.skillsCatalog.isEmpty ? "目录加载失败，请重试" : "没有匹配的技能")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                    if state.skillsCatalog.isEmpty {
                        Button("重新加载") {
                            Task {
                                loadingCatalog = true
                                await state.refreshSkillsCatalog(force: true)
                                loadingCatalog = false
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredCatalog) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                                if let d = item.desc, !d.isEmpty {
                                    Text(d)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                } else {
                                    Text("OpenMinis/MinisSkills")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 8)
                            if installingNames.contains(item.name) {
                                ProgressView().scaleEffect(0.8)
                            } else if item.installed {
                                Label("已安装", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.green)
                            } else {
                                Button {
                                    Task {
                                        installingNames.insert(item.name)
                                        let err = await state.installSkill(name: item.name, url: item.url)
                                        installingNames.remove(item.name)
                                        if let err {
                                            showBanner("\(item.name) 安装失败：\(err)", isError: true)
                                        } else {
                                            showBanner("已安装 \(item.name)", isError: false)
                                        }
                                    }
                                } label: {
                                    Text("安装")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor, in: Capsule())
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.plain)
                .refreshable { await state.refreshSkillsCatalog(force: true) }
            }
        }
    }
}

// MARK: - 技能详情（查看完整 SKILL.md 与文件清单）

struct SkillDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skillName: String

    @State private var detail: SkillDetail?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let d = detail {
                    VStack(alignment: .leading, spacing: 14) {
                        if let files = d.files, !files.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("文件清单（\(files.count)）")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(files) { f in
                                    HStack {
                                        Text(f.path)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        if let sz = f.size {
                                            Text("\(sz) B")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        if !d.content.isEmpty {
                            MarkdownView(text: d.content, isLive: false)
                        } else {
                            Text("该技能目录暂无 SKILL.md 内容")
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                } else {
                    Text("读取技能详情失败")
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
            }
            .navigationTitle(skillName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .task {
                detail = try? await APIClient.shared.skillDetail(skillName)
                loading = false
            }
        }
    }
}

// MARK: - 通过 GitHub 链接或粘贴 SKILL.md 安装技能

struct SkillInstallSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0 // 0 = URL, 1 = 粘贴内容
    @State private var name = ""
    @State private var url = ""
    @State private var content = ""
    @State private var installing = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("安装方式", selection: $mode) {
                        Text("GitHub / Raw 链接").tag(0)
                        Text("粘贴 SKILL.md").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                Section("技能名称（可选，留空自动解析）") {
                    TextField("如：my-custom-skill", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if mode == 0 {
                    Section("GitHub 目录或文件链接") {
                        TextField("https://github.com/owner/repo/tree/main/skill", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section("SKILL.md 正文") {
                        TextEditor(text: $content)
                            .font(.system(size: 13.5, design: .monospaced))
                            .frame(minHeight: 160)
                    }
                }

                if let err = errorText {
                    Section {
                        Text(err).font(.system(size: 13)).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("安装技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(installing ? "安装中…" : "安装") {
                        Task { await install() }
                    }
                    .disabled(installing || (mode == 0 ? url.trimmingCharacters(in: .whitespaces).isEmpty : content.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    private func install() async {
        installing = true
        errorText = nil
        let err = await state.installSkill(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: mode == 0 ? url.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            content: mode == 1 ? content : nil
        )
        installing = false
        if let err {
            errorText = err
        } else {
            dismiss()
        }
    }
}
