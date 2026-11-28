import SwiftUI
import Combine
import SafariServices
import UIKit

/// Antigravity 同机多 Google 账号管理页（切换账号保留全部会话、上下文与运行中任务）
struct AccountsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var embedded: Bool = false
    var onClose: (() -> Void)? = nil

    @State private var showOAuthSheet = false
    @State private var showImportSheet = false
    @State private var renamingAccount: AgyAccountItem? = nil
    @State private var renameText = ""
    @State private var deletingAccount: AgyAccountItem? = nil
    @State private var switchingId: String? = nil

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    @ViewBuilder
    var body: some View {
        if embedded {
            accountsContent
        } else {
            NavigationStack {
                accountsContent
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { closeSelf() }
                        }
                    }
            }
        }
    }

    private var accountsContent: some View {
        List {
            // 顶部说明
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.indigo)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("无感切换，保留全部会话与任务")
                            .font(.system(size: 14, weight: .semibold))
                        Text("每个 Google 账号隔离独立凭证目录，软链共享全部对话历史、定时任务、技能、MCP 与记忆。正在后台执行的任务不会中断。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }

            // 账号列表
            Section {
                if state.accounts.isEmpty && state.isLoadingAccounts {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.85)
                        Text("正在加载账号与实时配额…")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else if state.accounts.isEmpty {
                    Text("当前服务器尚未检测到已登录的 Antigravity 账号，请点击下方登录或导入。")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(state.accounts) { acct in
                        accountRow(acct)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if state.accounts.count > 1 && (acct.runningTasks ?? 0) == 0 {
                                    Button(role: .destructive) {
                                        deletingAccount = acct
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                Button {
                                    renamingAccount = acct
                                    renameText = acct.displayLabel
                                } label: {
                                    Label("备注", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                if !acct.active {
                                    Button {
                                        Task { await performSwitch(acct) }
                                    } label: {
                                        Label("切换到此账号", systemImage: "checkmark.circle")
                                    }
                                }
                                Button {
                                    renamingAccount = acct
                                    renameText = acct.displayLabel
                                } label: {
                                    Label("修改备注名", systemImage: "pencil")
                                }
                                Button {
                                    UIPasteboard.general.string = acct.email
                                    state.showToast("已复制邮箱")
                                } label: {
                                    Label("复制邮箱", systemImage: "doc.on.doc")
                                }
                                if state.accounts.count > 1 && (acct.runningTasks ?? 0) == 0 {
                                    Divider()
                                    Button(role: .destructive) {
                                        deletingAccount = acct
                                    } label: {
                                        Label("移除账号", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("已绑定账号（\(state.currentInstance.name)）")
                    Spacer()
                    if state.isLoadingAccounts {
                        ProgressView().scaleEffect(0.65)
                    }
                }
            } footer: {
                Text("点击任意账号立即切换；左滑可修改备注或移除。当前若遇到 429 额度耗尽，也可在对话中断卡片里一键换号续接。")
                    .font(.system(size: 11.5))
            }

            // 添加新账号
            Section("添加 Google 账号") {
                Button {
                    showOAuthSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "safari.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("网页授权登录新账号")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("通过 Safari 登录 Google 并复制授权码，无需 SSH")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderless)

                Button {
                    showImportSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.teal, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("导入 Token JSON")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("粘贴其他机器的 antigravity-oauth-token，1 秒纳管")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Antigravity 账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await state.refreshAccounts(withQuota: true, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(state.isLoadingAccounts)
            }
        }
        .refreshable {
            await state.refreshAccounts(withQuota: true, force: true)
        }
        .task {
            // 延后 360ms 静默刷新实时配额，确保 NavigationStack 推入动画零掉帧
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard !Task.isCancelled else { return }
            await state.refreshAccounts(withQuota: true, force: false)
        }
        .sheet(isPresented: $showOAuthSheet) {
            OAuthLoginSheet()
        }
        .sheet(isPresented: $showImportSheet) {
            TokenImportSheet()
        }
        .alert("修改账号备注", isPresented: Binding(
            get: { renamingAccount != nil },
            set: { if !$0 { renamingAccount = nil } }
        )) {
            TextField("例如：主号 / 备用 Pro", text: $renameText)
            Button("取消", role: .cancel) { renamingAccount = nil }
            Button("保存") {
                if let target = renamingAccount {
                    let next = renameText
                    renamingAccount = nil
                    Task { await state.renameAccount(target, to: next) }
                }
            }
        } message: {
            if let a = renamingAccount {
                Text(a.email)
            }
        }
        .confirmationDialog(
            "移除此账号？",
            isPresented: Binding(
                get: { deletingAccount != nil },
                set: { if !$0 { deletingAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除账号（保留所有对话记录）", role: .destructive) {
                if let target = deletingAccount {
                    deletingAccount = nil
                    Task { await state.deleteAccount(target) }
                }
            }
            Button("取消", role: .cancel) { deletingAccount = nil }
        } message: {
            if let a = deletingAccount {
                Text("将删除 \(a.email) 在本服务器的 OAuth 凭证；历史会话、定时任务和工作区文件均不受影响。")
            }
        }
    }

    private func performSwitch(_ acct: AgyAccountItem) async {
        guard !acct.active, !state.isSwitchingAccount else { return }
        switchingId = acct.id
        _ = await state.switchAccount(to: acct)
        switchingId = nil
    }

    private func accountRow(_ acct: AgyAccountItem) -> some View {
        Button {
            Task { await performSwitch(acct) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(acct.active ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
                            .frame(width: 34, height: 34)
                        if switchingId == acct.id {
                            ProgressView().scaleEffect(0.75)
                        } else {
                            Image(systemName: acct.active ? "checkmark.circle.fill" : "person.crop.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(acct.active ? Color.accentColor : Color.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(acct.displayLabel)
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if acct.active {
                                Text("当前")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.accentColor, in: Capsule())
                            }

                            if let plan = acct.plan, !plan.isEmpty, plan != "-" {
                                Text(plan.replacingOccurrences(of: "Google AI ", with: "AI "))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }

                            if let run = acct.runningTasks, run > 0 {
                                Text("运行中 \(run)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.orange.opacity(0.14), in: Capsule())
                            }
                        }

                        Text(acct.email)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }

                // 实时配额紧凑概览
                if let groups = acct.quotaGroups, !groups.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(groups.prefix(3)) { g in
                            accountQuotaLine(g)
                        }
                    }
                    .padding(.leading, 44)
                } else if let err = acct.quotaError, !err.isEmpty {
                    Text("配额暂不可用：\(err)")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.leading, 44)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isSwitchingAccount)
    }

    private func accountQuotaLine(_ g: QuotaGroup) -> some View {
        let shortTitle: String = {
            let low = g.name.lowercased()
            if low.contains("argon") { return "Argon" }
            if low.contains("gemini") { return "Gemini" }
            if low.contains("claude") || low.contains("gpt") { return "Claude/GPT" }
            return g.name
        }()

        let valid = g.windows.filter { $0.remaining != nil }
        let worst = valid.compactMap(\.remaining).min() ?? 0
        let barColor: Color = worst > 0.45 ? .green : (worst > 0.15 ? .orange : .red)

        return HStack(spacing: 8) {
            Text(shortTitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(3, geo.size.width * CGFloat(max(0, min(1, worst)))))
                }
            }
            .frame(height: 5)

            Text(windowCompactText(valid))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(worst <= 0.01 ? Color.red : Color.secondary)
                .fixedSize()
        }
    }

    private func windowCompactText(_ windows: [QuotaWindow]) -> String {
        let parts: [String] = windows.compactMap { w in
            guard let r = w.remaining else { return nil }
            let pct = Int((r * 100).rounded())
            let tag = (w.window == "weekly") ? "周" : ((w.window == "5h") ? "5h" : "")
            return tag.isEmpty ? "\(pct)%" : "\(tag) \(pct)%"
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Safari 网页 OAuth 登录 Sheet

private struct OAuthLoginSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sessionId: String? = nil
    @State private var authURL: URL? = nil
    @State private var expiresAt: Date? = nil
    @State private var remainingSeconds: Int = 0
    @State private var isStarting = false
    @State private var isFinishing = false
    @State private var showSafari = false

    @State private var authCode = ""
    @State private var label = ""
    @State private var switchAfter = true
    @State private var errorMsg: String? = nil

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() >= exp
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isStarting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在生成官方 Google OAuth 授权链接…")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else if let url = authURL {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(
                                    isExpired ? "本次授权链接已超时（60 秒）" : "授权会话已就绪",
                                    systemImage: isExpired ? "clock.badge.exclamationmark" : "checkmark.circle.fill"
                                )
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isExpired ? .orange : .green)
                                Spacer()
                                if !isExpired {
                                    Text("\(remainingSeconds)s")
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(remainingSeconds <= 15 ? .red : .secondary)
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    showSafari = true
                                } label: {
                                    Label("在 App 内打开登录", systemImage: "safari.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isExpired)

                                Button {
                                    UIApplication.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 15, weight: .medium))
                                        .padding(.vertical, 9)
                                        .padding(.horizontal, 12)
                                }
                                .buttonStyle(.bordered)
                                .disabled(isExpired)
                            }

                            if isExpired {
                                Button {
                                    Task { await startNewSession() }
                                } label: {
                                    Label("重新生成 60 秒授权链接", systemImage: "arrow.clockwise")
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 2)
                    } else {
                        Button {
                            Task { await startNewSession() }
                        } label: {
                            Label("重新获取授权链接", systemImage: "arrow.clockwise")
                        }
                    }
                } header: {
                    Text("第一步：登录 Google")
                } footer: {
                    Text("在弹出的 Google 登录页完成授权后，页面会跳转到 antigravity.google/oauth-callback 并显示授权码，复制授权码（或复制整个回调网址）返回此处即可。")
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("粘贴授权码或完整回调链接", text: $authCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 13.5, design: .monospaced))
                        Button("粘贴") {
                            if let clip = UIPasteboard.general.string {
                                authCode = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .buttonStyle(.bordered)
                    }

                    TextField("备注名（可选，默认取邮箱前缀）", text: $label)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("绑定成功后立即切换为当前账号", isOn: $switchAfter)
                } header: {
                    Text("第二步：回填授权码")
                }

                if let err = errorMsg, !err.isEmpty {
                    Section {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submitCode() }
                    } label: {
                        HStack {
                            Spacer()
                            if isFinishing {
                                ProgressView().scaleEffect(0.85)
                                Text("正在验证并保存凭证…")
                                    .font(.system(size: 15, weight: .semibold))
                            } else {
                                Text("完成绑定")
                                    .font(.system(size: 15.5, weight: .semibold))
                            }
                            Spacer()
                        }
                    }
                    .disabled(
                        isFinishing
                        || isStarting
                        || sessionId == nil
                        || isExpired
                        || authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .navigationTitle("网页授权登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await startNewSession() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isStarting || isFinishing)
                }
            }
            .task {
                await startNewSession()
            }
            .onReceive(ticker) { now in
                guard let exp = expiresAt else { return }
                remainingSeconds = max(0, Int(exp.timeIntervalSince(now).rounded(.up)))
            }
            .onDisappear {
                if let sid = sessionId {
                    Task { await state.cancelOAuthAccountLogin(sessionId: sid) }
                }
            }
            .sheet(isPresented: $showSafari) {
                if let url = authURL {
                    InAppSafariView(url: url)
                        .ignoresSafeArea()
                }
            }
        }
    }

    private func startNewSession() async {
        if let old = sessionId {
            sessionId = nil
            await state.cancelOAuthAccountLogin(sessionId: old)
        }
        isStarting = true
        errorMsg = nil
        authURL = nil
        expiresAt = nil

        let res = await state.startOAuthAccountLogin()
        isStarting = false
        if res.ok != false, let sid = res.sessionId, let rawUrl = res.authUrl, let u = URL(string: rawUrl) {
            sessionId = sid
            authURL = u
            let ttl = max(15, res.expiresIn ?? 58)
            expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
            remainingSeconds = ttl
        } else {
            errorMsg = res.error ?? "获取 Google OAuth 链接失败"
        }
    }

    private func submitCode() async {
        guard let sid = sessionId else { return }
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        isFinishing = true
        errorMsg = nil
        let result = await state.finishOAuthAccountLogin(
            sessionId: sid,
            code: code,
            label: label,
            switchAfter: switchAfter
        )
        isFinishing = false
        if result.ok {
            sessionId = nil
            dismiss()
        } else {
            errorMsg = result.message
        }
    }
}

private struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        return vc
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - 导入 Token JSON Sheet

private struct TokenImportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var rawJSON = ""
    @State private var label = ""
    @State private var switchAfter = true
    @State private var isImporting = false
    @State private var errorMsg: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("OAuth 凭证内容")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("从剪贴板粘贴") {
                            if let clip = UIPasteboard.general.string {
                                rawJSON = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                    }

                    TextEditor(text: $rawJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("antigravity-oauth-token JSON")
                } footer: {
                    Text("可从其他 VPS 或电脑复制 ~/.gemini/antigravity-cli/antigravity-oauth-token 的完整 JSON 内容粘贴到此处，服务端会自动验证邮箱与刷新凭证。")
                }

                Section {
                    TextField("备注名（可选，默认取邮箱前缀）", text: $label)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("导入后立即切换为当前账号", isOn: $switchAfter)
                }

                if let err = errorMsg, !err.isEmpty {
                    Section {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await performImport() }
                    } label: {
                        HStack {
                            Spacer()
                            if isImporting {
                                ProgressView().scaleEffect(0.85)
                                Text("正在校验凭证…")
                                    .font(.system(size: 15, weight: .semibold))
                            } else {
                                Text("校验并导入")
                                    .font(.system(size: 15.5, weight: .semibold))
                            }
                            Spacer()
                        }
                    }
                    .disabled(isImporting || rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("导入 Token JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func performImport() async {
        isImporting = true
        errorMsg = nil
        let res = await state.importAccountToken(json: rawJSON, label: label, switchAfter: switchAfter)
        isImporting = false
        if res.ok {
            dismiss()
        } else {
            errorMsg = res.message
        }
    }
}
