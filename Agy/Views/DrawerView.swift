import SwiftUI
import UIKit

/// Gemini 风格侧边栏
struct DrawerView: View {
    @EnvironmentObject var state: AppState
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var showSearch = false
    @State private var showSkills = false
    @State private var showQuota = false
    @State private var renaming: Session?
    @State private var showInstances = false
    /// 配额弹层高度：标题 + 方案 + 各组（每组约 92pt）+ 底部统计
    private var quotaSheetHeight: CGFloat {
        let groups = CGFloat(quotaGroupCount)
        return min(200 + groups * 96 + 60, 620)
    }

    @State private var quotaGroupCount = 2
    @State private var renameText = ""

    // MARK: - 数据

    private var sorted: [Session] {
        let kw = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = kw.isEmpty
            ? state.sessions
            : state.sessions.filter { state.title(of: $0).lowercased().contains(kw) }
        return all.sorted { a, b in
            let pa = state.isPinned(a), pb = state.isPinned(b)
            if pa != pb { return pa }
            return (a.updated ?? a.started) > (b.updated ?? b.started)
        }
    }

    private var pinned: [Session] { sorted.filter { state.isPinned($0) } }
    private var others: [Session] { sorted.filter { !state.isPinned($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSearch { searchBar }

            ScrollView {
                LazyVStack(spacing: 0) {
                    menuRow("发起新对话", icon: "square.and.pencil") {
                        state.newSession()
                        isPresented = false
                    }
                    menuRow("技能", icon: "square.grid.2x2") { showSkills = true }
                    menuRow("配额", icon: "gauge.with.needle") { showQuota = true }

                    if !pinned.isEmpty {
                        sectionHeader("已置顶")
                        ForEach(pinned) { sessionRow($0) }
                    }

                    sectionHeader("全部", trailingFilter: true)
                    if others.isEmpty {
                        Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.top, 14)
                    } else {
                        ForEach(others) { sessionRow($0) }
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)

            footer
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(.separator).opacity(0.3)).frame(width: 0.5)
        }
        .sheet(isPresented: $showSkills) {
            SkillsSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQuota) {
            QuotaSheet().presentationDetents([.height(quotaSheetHeight)]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showInstances) {
            InstancesSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
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
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 18) {
            Text("Antigravity")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSearch.toggle() }
                if !showSearch { query = "" }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("搜索对话", text: $query)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - 行

    private func menuRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 17))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, trailingFilter: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if trailingFilter {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    private func sessionRow(_ s: Session) -> some View {
        Button {
            Task { await state.open(s) }
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Text(state.title(of: s))
                    .font(.system(size: 16.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if !s.done {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
                if state.isPinned(s) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 22)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Divider()
            Button(role: .destructive) {
                Task { await state.deleteSession(s) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            HStack(spacing: 12) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.currentInstance.name)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Text(state.currentInstance.url.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Menu {
                    Button {
                        showInstances = true
                    } label: { Label("切换实例", systemImage: "server.rack") }
                    Button {
                        Task { await state.refreshSessions() }
                    } label: { Label("刷新对话", systemImage: "arrow.clockwise") }
                    Divider()
                    Button(role: .destructive) {
                        state.logout()
                        isPresented = false
                    } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

}

// MARK: - 技能面板

struct SkillsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var skills: [Skill] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if skills.isEmpty {
                    Text("还没有安装技能")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(skills) { sk in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sk.name)
                                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                                if let d = sk.desc, !d.isEmpty {
                                    Text(d)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 3)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        await APIClient.shared.deleteSkill(sk.name)
                                        await load()
                                    }
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        skills = (try? await APIClient.shared.skills()) ?? []
        loading = false
    }
}

// MARK: - 配额面板

struct QuotaSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var quota: QuotaResponse?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(.top, 50)
                } else if let q = quota {
                    VStack(alignment: .leading, spacing: 18) {
                        if let plan = q.plan {
                            HStack(spacing: 6) {
                                Image(systemName: "star.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(plan).font(.system(size: 14, weight: .semibold))
                            }
                        }

                        ForEach(q.groups ?? []) { g in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(g.name).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    if let c = g.count {
                                        Text("\(c) 个模型")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                ForEach(g.windows.filter { $0.remaining != nil || $0.resetAt != nil }) { w in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(w.label).font(.system(size: 12.5))
                                            Spacer()
                                            if let r = w.remaining {
                                                Text("\(Int(r * 100))%")
                                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(color(for: r))
                                            } else {
                                                Text("未提供")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        if let r = w.remaining {
                                            GeometryReader { geo in
                                                ZStack(alignment: .leading) {
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .fill(Color(.secondarySystemBackground))
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .fill(color(for: r))
                                                        .frame(width: max(2, geo.size.width * r))
                                                }
                                            }
                                            .frame(height: 6)
                                        }
                                        if let reset = resetText(w.resetAt) {
                                            Text(reset)
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        if let wk = q.week {
                            HStack(spacing: 14) {
                                Label("\(wk.calls ?? 0) 次任务", systemImage: "checklist")
                                Label("\(wk.tokens ?? 0) tok", systemImage: "text.alignleft")
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                } else {
                    Text("配额加载失败")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 50)
                }
            }
            .navigationTitle("配额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await load() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        quota = try? await APIClient.shared.quota()
        loading = false
    }

    private func color(for r: Double) -> Color {
        r < 0.2 ? .red : (r < 0.5 ? .orange : .green)
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
