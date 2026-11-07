import SwiftUI

/// Gemini 风格侧边栏：新建对话 + 搜索 + 按时间分组的会话列表
struct DrawerView: View {
    @EnvironmentObject var state: AppState
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var showSkills = false

    private var filtered: [Session] {
        let kw = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !kw.isEmpty else { return state.sessions }
        return state.sessions.filter { $0.displayTitle.lowercased().contains(kw) }
    }

    /// 今天 / 昨天 / 前 7 天 / 前 30 天 / 更早
    private var grouped: [(String, [Session])] {
        let cal = Calendar.current
        var buckets: [(String, [Session])] = [
            ("今天", []), ("昨天", []), ("前 7 天", []), ("前 30 天", []), ("更早", [])
        ]
        let now = Date()
        for s in filtered {
            let d = Date(timeIntervalSince1970: s.updated ?? s.started)
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: d),
                                          to: cal.startOfDay(for: now)).day ?? 999
            let idx: Int
            if days <= 0 { idx = 0 }
            else if days == 1 { idx = 1 }
            else if days <= 7 { idx = 2 }
            else if days <= 30 { idx = 3 }
            else { idx = 4 }
            buckets[idx].1.append(s)
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            newChatButton
            searchBar
            content
            footer
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(.separator).opacity(0.35)).frame(width: 0.5)
        }
        .sheet(isPresented: $showSkills) {
            SkillsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 9) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("Antigravity")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private var newChatButton: some View {
        Button {
            state.newSession()
            isPresented = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                Text("新建对话")
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 15)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("搜索对话", text: $query)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 列表

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }

                ForEach(grouped, id: \.0) { title, items in
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                    ForEach(items) { s in
                        sessionRow(s)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func sessionRow(_ s: Session) -> some View {
        Button {
            Task { await state.open(s) }
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Text(s.displayTitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if !s.done {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }

                Button {
                    // 单独的三点菜单占位，交给 contextMenu 处理
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await state.deleteSession(s) }
                    } label: { Label("删除对话", systemImage: "trash") }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await state.deleteSession(s) }
            } label: { Label("删除对话", systemImage: "trash") }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                Button {
                    showSkills = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.horizontal")
                            .font(.system(size: 14))
                        Text("技能")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle().fill(Color(.separator).opacity(0.35)).frame(width: 0.5, height: 22)

                Button {
                    state.logout()
                    isPresented = false
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 14))
                        Text("退出")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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

                                ForEach(g.windows) { w in
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
