import SwiftUI

/// 原生定时任务中心（Scheduled Cron Jobs，支持预设/自定义 5 段 Cron、手动触发、回放跳转与启停管理）
struct JobsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var editingJob: ScheduledJob?
    @State private var showCreate = false
    var onClose: (() -> Void)? = nil
    var onOpenSession: ((String) -> Void)?

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        NavigationStack {
            Group {
                if state.isLoadingJobs && state.jobs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.jobs.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(state.jobs) { job in
                            jobRow(job)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await state.deleteJob(job) }
                                    } label: { Label("删除", systemImage: "trash") }

                                    Button {
                                        editingJob = job
                                    } label: { Label("编辑", systemImage: "pencil") }
                                    .tint(.blue)
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await state.refreshJobs() }
                }
            }
            .navigationTitle("定时任务")
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
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .task {
                if !state.jobs.isEmpty {
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    guard !Task.isCancelled else { return }
                }
                await state.refreshJobs()
            }
            .sheet(isPresented: $showCreate) {
                JobEditorSheet(existing: nil)
            }
            .sheet(item: $editingJob) { job in
                JobEditorSheet(existing: job)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("还没有定时任务")
                .font(.system(size: 16, weight: .semibold))
            Text("按 Cron 计划自动巡检服务器、抓取日报或运行脚本")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                showCreate = true
            } label: {
                Label("新建定时任务", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Color.accentColor, in: Capsule())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func jobRow(_ job: ScheduledJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(job.enabled ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(job.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(job.cron)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }

            Text(job.prompt)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 10) {
                if let next = job.nextRun, job.enabled {
                    Label("下次 \(formatTS(next))", systemImage: "calendar.badge.clock")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else if !job.enabled {
                    Text("已暂停")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)

                if let tid = job.lastTaskId, !tid.isEmpty {
                    Button {
                        closeSelf()
                        onOpenSession?(tid)
                    } label: {
                        Text("看回放")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { _ = await state.runJobNow(job) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await state.toggleJob(job) }
                } label: {
                    Image(systemName: job.enabled ? "pause.fill" : "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { editingJob = job }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private func formatTS(_ ts: Double) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - 新建 / 编辑定时任务

struct JobEditorSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let existing: ScheduledJob?

    @State private var name: String = ""
    @State private var cron: String = "0 9 * * *"
    @State private var prompt: String = ""
    @State private var selectedModel: String = ""
    @State private var enabled: Bool = true
    @State private var saving = false
    @State private var errorText: String?

    private let presets: [(label: String, expr: String)] = [
        ("每天 09:00", "0 9 * * *"),
        ("工作日 08:30", "30 8 * * 1-5"),
        ("每小时", "0 * * * *"),
        ("每 6 小时", "0 */6 * * *"),
        ("每周一 10:00", "0 10 * * 1")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("任务名称，如：每日服务巡检", text: $name)
                    Toggle("启用调度", isOn: $enabled)
                }

                Section {
                    TextField("分 时 日 月 周（如 0 9 * * *）", text: $cron)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(presets, id: \.expr) { p in
                                Button {
                                    cron = p.expr
                                } label: {
                                    Text(p.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(cron == p.expr ? .white : .primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(cron == p.expr ? Color.accentColor : Color(.secondarySystemBackground),
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Cron 计划（5 段式）")
                }

                Section("执行模型") {
                    Picker("模型", selection: $selectedModel) {
                        Text("跟随默认").tag("")
                        ForEach(state.modelOptions) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                }

                Section("提示词（Prompt）") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .font(.system(size: 15))
                }

                if let err = errorText {
                    Section {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "新建定时任务" : "编辑定时任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let j = existing {
                    name = j.name
                    cron = j.cron
                    prompt = j.prompt
                    selectedModel = j.model ?? ""
                    enabled = j.enabled
                }
            }
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        let err = await state.saveJob(
            id: existing?.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            cron: cron.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            model: selectedModel.isEmpty ? nil : selectedModel,
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
