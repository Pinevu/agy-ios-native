import SwiftUI

struct DrawerView: View {
    @EnvironmentObject var state: AppState
    @Binding var isPresented: Bool

    @State private var tab = 0
    @State private var query = ""
    @State private var skills: [Skill] = []
    @State private var loadingSkills = false

    private var filtered: [Session] {
        let kw = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !kw.isEmpty else { return state.sessions }
        return state.sessions.filter { $0.displayTitle.lowercased().contains(kw) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab
            HStack(spacing: 8) {
                tabButton("最近任务", index: 0)
                tabButton("技能", index: 1)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if tab == 0 {
                searchBar
                sessionList
            } else {
                skillList
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(.separator).opacity(0.4)).frame(width: 0.6)
        }
        .task { await loadSkillsIfNeeded() }
        .onChange(of: tab) { t in
            if t == 1 { Task { await loadSkillsIfNeeded() } }
        }
    }

    private func tabButton(_ title: String, index: Int) -> some View {
        Button {
            tab = index
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(tab == index ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(tab == index ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索会话…", text: $query)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "还没有任务" : "没有匹配的会话")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 30)
                }

                ForEach(filtered) { s in
                    Button {
                        Task { await state.open(s) }
                        isPresented = false
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Text(s.displayTitle)
                                    .font(.system(size: 13.5, weight: .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if let tc = s.turnCount, tc > 1 {
                                    Text("\(tc) 轮")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.accentColor.opacity(0.14))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }

                                Spacer(minLength: 4)

                                Text(s.displayDate)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)

                                if !s.done {
                                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 42)

                            Divider().opacity(0.35).padding(.leading, 14)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await state.deleteSession(s) }
                        } label: { Label("删除会话", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if loadingSkills {
                    ProgressView().padding(.top, 30)
                } else if skills.isEmpty {
                    Text("还没有安装技能")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 30)
                }

                ForEach(skills) { sk in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sk.name)
                            .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                        if let d = sk.desc, !d.isEmpty {
                            Text(d)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task {
                                await APIClient.shared.deleteSkill(sk.name)
                                await loadSkills(force: true)
                            }
                        } label: { Label("删除技能", systemImage: "trash") }
                    }

                    Divider().opacity(0.35).padding(.leading, 14)
                }
            }
        }
    }

    private func loadSkillsIfNeeded() async {
        if skills.isEmpty { await loadSkills(force: false) }
    }

    private func loadSkills(force: Bool) async {
        if loadingSkills { return }
        loadingSkills = true
        defer { loadingSkills = false }
        if let s = try? await APIClient.shared.skills() {
            skills = s
        } else if force {
            state.showToast("技能列表加载失败")
        }
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
