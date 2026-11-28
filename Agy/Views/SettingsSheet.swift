import SwiftUI

private enum SettingsRoute: Hashable {
    case usage
    case skills
    case mcp
    case env
    case memory
    case jobs
    case voice
}

/// 统一设置中心（收纳所有 AI Agent 扩展功能、用量配额、语音服务、外观与隐私安全设置）
struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var appLock: AppLockManager
    @ObservedObject private var speech = SpeechManager.shared
    @ObservedObject private var localNotify = LocalNotificationManager.shared
    @Environment(\.dismiss) private var dismiss

    var onClose: (() -> Void)? = nil
    var onNestedChanged: ((Bool) -> Void)? = nil
    var onOpenSession: ((String) -> Void)? = nil
    var onLogout: (() -> Void)? = nil

    @State private var path: [SettingsRoute] = []
    @State private var showInstances = false

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var memoryActiveBadge: String? {
        (!state.globalMemory.isEmpty || !state.memoryFiles.isEmpty || !state.agentSoul.rules.isEmpty) ? "已生效" : nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // 1. 当前实例与配额
                Section("实例与用量") {
                    Button {
                        showInstances = true
                    } label: {
                        HStack(spacing: 12) {
                            Image("AppLogo")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.currentInstance.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(state.currentInstance.url.replacingOccurrences(of: "https://", with: ""))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            Text("切换")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderless)

                    NavigationLink(value: SettingsRoute.usage) {
                        settingsRow(
                            title: "用量与配额",
                            icon: "gauge.with.needle",
                            tint: .green,
                            badge: state.lastQuotaSnapshot?.plan
                        )
                    }

                    Button {
                        Task {
                            await state.syncSessionMeta()
                            await state.refreshSessions()
                            state.showToast("已刷新对话列表")
                        }
                    } label: {
                        settingsRow(
                            title: "刷新对话列表",
                            icon: "arrow.clockwise",
                            tint: .blue
                        )
                    }
                    .buttonStyle(.borderless)
                }

                // 2. AI Agent 扩展功能
                Section("AI Agent 功能") {
                    NavigationLink(value: SettingsRoute.skills) {
                        settingsRow(
                            title: "技能商店",
                            icon: "square.grid.2x2",
                            tint: .teal,
                            badge: state.skills.isEmpty ? nil : "\(state.skills.count)"
                        )
                    }

                    NavigationLink(value: SettingsRoute.mcp) {
                        settingsRow(
                            title: "MCP 服务器",
                            icon: "point.3.connected.trianglepath.dotted",
                            tint: .blue,
                            badge: state.mcpServers.isEmpty ? nil : "\(state.enabledMCPCount)/\(state.mcpServers.count)"
                        )
                    }

                    NavigationLink(value: SettingsRoute.env) {
                        settingsRow(
                            title: "环境变量",
                            icon: "key.radiowaves.forward",
                            tint: .orange,
                            badge: state.envVars.isEmpty ? nil : "\(state.enabledEnvCount)"
                        )
                    }

                    NavigationLink(value: SettingsRoute.memory) {
                        settingsRow(
                            title: "记忆与设定",
                            icon: "brain.head.profile",
                            tint: .purple,
                            badge: memoryActiveBadge
                        )
                    }

                    NavigationLink(value: SettingsRoute.jobs) {
                        settingsRow(
                            title: "定时任务",
                            icon: "clock.badge.checkmark",
                            tint: .indigo,
                            badge: state.jobs.isEmpty ? nil : "\(state.jobs.count)"
                        )
                    }
                }

                // 3. 语音与外观
                Section("语音与外观") {
                    NavigationLink(value: SettingsRoute.voice) {
                        settingsRow(
                            title: "语音服务 (TTS / STT)",
                            icon: "waveform",
                            tint: .pink,
                            badge: speech.activeVoiceSummaryBadge ?? "系统"
                        )
                    }

                    Picker(selection: $state.appearanceMode) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    } label: {
                        settingsRow(
                            title: "外观主题",
                            icon: state.isDarkEffective ? "moon.fill" : "sun.max.fill",
                            tint: .orange
                        )
                    }
                }

                // 4. 灵动岛与隐私安全
                Section("灵动岛与隐私安全") {
                    Toggle(isOn: $state.liveActivityEnabled) {
                        settingsRow(
                            title: "任务灵动岛",
                            icon: "capsule.inset.filled",
                            tint: .blue
                        )
                    }

                    Toggle(isOn: $state.liveActivityPrivacyMode) {
                        settingsRow(
                            title: "锁屏隐私模式",
                            icon: "eye.slash.fill",
                            tint: .gray
                        )
                    }

                    Toggle(isOn: Binding(
                        get: { localNotify.isEnabled },
                        set: { target in
                            Task {
                                let ok = await localNotify.setEnabled(target)
                                if target && !ok {
                                    state.showToast("请在系统设置中允许通知权限")
                                } else {
                                    state.showToast(target ? "已开启任务完成通知" : "已关闭任务完成通知")
                                }
                            }
                        }
                    )) {
                        settingsRow(
                            title: AgySharedStore.provisioningInfo.hasTimeSensitiveNotifications
                                ? "任务完成通知（时效）"
                                : "任务完成通知",
                            icon: "bell.badge.fill",
                            tint: .red
                        )
                    }

                    Toggle(isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { target in
                            Task {
                                let ok = await appLock.setEnabled(target)
                                if ok {
                                    state.showToast(target ? "已开启 \(appLock.biometryTitle) 应用锁" : "已关闭应用锁")
                                } else if let e = appLock.errorText {
                                    state.showToast(e)
                                }
                            }
                        }
                    )) {
                        settingsRow(
                            title: "\(appLock.biometryTitle) 应用锁",
                            icon: appLock.biometryIcon,
                            tint: .green
                        )
                    }
                }

                // 5. 签名证书与权限状态诊断
                Section("签名与证书状态") {
                    let info = AgySharedStore.provisioningInfo
                    HStack {
                        Text("Bundle ID")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(info.bundleId)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    if let team = info.teamName ?? info.teamId {
                        HStack {
                            Text("签名团队")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(info.teamId != nil && info.teamName != nil ? "\(team) (\(info.teamId!))" : team)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }

                    if let exp = info.expirationDate {
                        HStack {
                            Text("证书到期")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(exp.formatted(date: .numeric, time: .omitted))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("共享容器")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(AgySharedStore.activeAppGroupDisplay)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AgySharedStore.resolvedAppGroupId != nil ? Color.green : Color.secondary)
                            .lineLimit(1)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            capTag("App Group", active: AgySharedStore.resolvedAppGroupId != nil)
                            capTag("大内存上限", active: info.hasIncreasedMemory)
                            capTag("时效通知", active: info.hasTimeSensitiveNotifications)
                            capTag("Siri", active: info.hasSiri)
                            capTag(info.isWildcard ? "通配符描述" : "显式描述", active: info.appIdentifier != nil)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 6. 账户操作
                Section {
                    Button(role: .destructive) {
                        state.logout()
                        closeSelf()
                        onLogout?()
                    } label: {
                        HStack {
                            Spacer()
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 15.5, weight: .medium))
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .listStyle(.insetGrouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .usage:
                    QuotaSheet(embedded: true)
                case .skills:
                    SkillsSheet(embedded: true)
                case .mcp:
                    MCPSheet(embedded: true)
                case .env:
                    EnvVarsSheet(embedded: true)
                case .memory:
                    AgentMemorySheet(embedded: true)
                case .jobs:
                    JobsSheet(embedded: true, onOpenSession: { sid in
                        onOpenSession?(sid)
                    })
                case .voice:
                    VoiceSettingsSheet(embedded: true)
                }
            }
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
            }
            .onChange(of: path.isEmpty) { empty in
                onNestedChanged?(!empty)
            }
            .onDisappear {
                onNestedChanged?(false)
            }
            .sheet(isPresented: $showInstances) {
                InstancesSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func capTag(_ title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private func settingsRow(title: String, icon: String, tint: Color, badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)
                .font(.system(size: 15.5))
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            if let badge, !badge.isEmpty, badge != "-" {
                Text(badge)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}
