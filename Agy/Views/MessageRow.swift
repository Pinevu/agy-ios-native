import SwiftUI
import UIKit

/// 一条消息能做的操作
struct MessageActions {
    var edit: ((ChatItem) -> Void)?
    var retry: ((ChatItem) -> Void)?
    var deleteFrom: ((ChatItem) -> Void)?
    var speak: ((ChatItem, String) -> Void)?
    var resumeContinue: (() -> Void)?
    var resumeSwitchModel: (() -> Void)?

    static let none = MessageActions()
}

struct MessageRow: View {
    let item: ChatItem
    /// 这条正在被流式写入：正文用 SwiftUI 渲染，保证贴底跟手
    var isLive: Bool = false
    /// 是否为当前空闲会话的最后一条消息（用于在错误/中断卡片上展示一键续接操作）
    var canRecover: Bool = false
    var actions: MessageActions = .none
    var isSpeaking: Bool = false
    var isLoadingTTS: Bool = false
    /// 点按弹出的消息菜单，挂在列表外层，避免每行一个 dialog
    @Binding var assistantMenu: ChatItem?

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments, let remotePaths):
            userBubble(text: text, attachments: attachments, remotePaths: remotePaths)

        case .note(let text):
            noteLine(text)

        case .assistant(let text):
            VStack(alignment: .leading, spacing: 6) {
                MarkdownView(text: text, isLive: isLive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if !isLive && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantActionBar(text: text)
                }
            }

        case .thought(let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "ellipsis.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .italic()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .tool(let name, let input, let output, let seconds, let running):
            ToolCardView(name: name, input: input, output: output, seconds: seconds, running: running)

        case .usage:
            EmptyView()

        case .error(let text):
            errorRecoveryCard(text: text)

        case .images(let paths):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paths, id: \.self) { p in
                    AuthImage(path: p, taskId: item.taskId, maxHeight: 420, corner: 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isQuotaStyleError(_ text: String) -> Bool {
        let low = text.lowercased()
        return low.contains("额度") || low.contains("quota") || low.contains("429")
            || low.contains("resource_exhausted") || low.contains("exit 3") || low.contains("rate limit")
    }

    private func errorRecoveryCard(text: String) -> some View {
        let quotaLike = isQuotaStyleError(text)
        let manualStop = text.contains("手动停止") || text.contains("已停止")
        let tint: Color = manualStop ? .orange : .red
        let headline: String = {
            if quotaLike { return "模型额度已用光或限流中断" }
            if manualStop { return "任务已暂停" }
            return "执行意外中断"
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: manualStop ? "pause.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .font(.system(size: 13.5))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    if canRecover {
                        Text(headline)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(canRecover ? Color.primary.opacity(0.82) : tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if canRecover {
                Text("上下文与已完成的文件修改均已保留，可直接续接或换模型接管：")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if quotaLike, let onSwitch = actions.resumeSwitchModel {
                        Button(action: onSwitch) {
                            Label("换模型续接", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.borderless)

                        if let onCont = actions.resumeContinue {
                            Button(action: onCont) {
                                Label("继续执行", systemImage: "play.fill")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        if let onCont = actions.resumeContinue {
                            Button(action: onCont) {
                                Label("继续执行", systemImage: "play.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor, in: Capsule())
                            }
                            .buttonStyle(.borderless)
                        }

                        if let onSwitch = actions.resumeSwitchModel {
                            Button(action: onSwitch) {
                                Label("换模型续接", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if let onRetry = actions.retry {
                        Button {
                            onRetry(item)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color(.tertiarySystemFill), in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("重试本轮")
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.7)
        )
    }

    private func assistantActionBar(text: String) -> some View {
        HStack(spacing: 14) {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)

            if let onSpeak = actions.speak {
                Button {
                    onSpeak(item, text)
                } label: {
                    if isLoadingTTS {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.62).frame(width: 12, height: 12)
                            Text("生成中")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Label(isSpeaking ? "停止" : "朗读",
                              systemImage: isSpeaking ? "stop.circle.fill" : "speaker.wave.2")
                            .font(.system(size: 11.5))
                            .foregroundStyle(isSpeaking ? Color.accentColor : Color(.tertiaryLabel))
                    }
                }
                .buttonStyle(.borderless)
            }

            Button {
                assistantMenu = item
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func noteLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: 5, height: 5)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 用户气泡

    @ViewBuilder
    private func userBubble(text: String, attachments: [Data], remotePaths: [String] = []) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            if !attachments.isEmpty {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, data in
                    if let img = ImageCache.shared.decoded(data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            if !remotePaths.isEmpty {
                ForEach(remotePaths, id: \.self) { p in
                    AuthImage(path: p, maxWidth: 190, maxHeight: 260, corner: 14)
                }
            }

            if !text.isEmpty {
                HStack(alignment: .bottom, spacing: 6) {
                    Spacer(minLength: 44)

                    Text(text)
                        .font(.system(size: 18))
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.accentColor.opacity(0.13))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.7)
                        )
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = text
                            } label: { Label("复制", systemImage: "doc.on.doc") }

                            if let e = actions.edit {
                                Button { e(item) } label: { Label("编辑", systemImage: "square.and.pencil") }
                            }
                            if let r = actions.retry {
                                Button { r(item) } label: { Label("重试", systemImage: "arrow.clockwise") }
                            }
                            if let d = actions.deleteFrom {
                                Button(role: .destructive) { d(item) } label: {
                                    Label("从此处删除", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - OpenMinis 风格连续工具折叠组

struct ToolGroupView: View {
    let items: [ChatItem]
    let isLiveGroup: Bool

    @State private var expanded = false

    private var toolStats: (count: Int, runningCount: Int, totalSeconds: Double, latestName: String) {
        var count = 0
        var running = 0
        var secs = 0.0
        var latest = ""
        for it in items {
            if case .tool(let name, _, _, let s, let r) = it.kind {
                count += 1
                if r { running += 1 }
                if let s { secs += s }
                latest = name
            }
        }
        return (count, running, secs, latest)
    }

    /// 运行中且未手动展开时，保留最近 3 个工具及其前置说明可见，折叠更早的步骤
    private var liveSplit: (hiddenToolCount: Int, visibleItems: [ChatItem]) {
        guard isLiveGroup, !expanded else { return (0, items) }
        var seenTools = 0
        var splitIdx = 0
        for i in stride(from: items.count - 1, through: 0, by: -1) {
            if case .tool = items[i].kind {
                seenTools += 1
                if seenTools == 3 {
                    // 连同紧邻前一条 .note 一起保留
                    if i > 0, case .note = items[i - 1].kind {
                        splitIdx = i - 1
                    } else {
                        splitIdx = i
                    }
                    break
                }
            }
        }
        guard splitIdx > 0 else { return (0, items) }
        let hiddenTools = items[..<splitIdx].reduce(0) { acc, it in
            if case .tool = it.kind { return acc + 1 }
            return acc
        }
        return (hiddenTools, Array(items[splitIdx...]))
    }

    var body: some View {
        let stats = toolStats
        VStack(alignment: .leading, spacing: 8) {
            if !isLiveGroup && !expanded {
                // 已完成折叠态：单行摘要胶囊
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded = true }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("已执行 \(stats.count) 个步骤")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        if stats.totalSeconds > 0.05 {
                            Text(String(format: "· %.1fs", stats.totalSeconds))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text("展开")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(.separator).opacity(0.28), lineWidth: 0.6)
                    )
                }
                .buttonStyle(.borderless)
            } else {
                // 运行中（折叠过早步骤）或已手动展开
                let split = liveSplit
                if isLiveGroup && split.hiddenToolCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down.circle")
                                .font(.system(size: 12))
                            Text("已折叠前面 \(split.hiddenToolCount) 个步骤 · 点击展开全部")
                                .font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color(.secondarySystemBackground).opacity(0.75),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.borderless)
                } else if expanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                            Text("收起 \(stats.count) 个步骤")
                                .font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(split.visibleItems) { child in
                    switch child.kind {
                    case .note(let t):
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.85))
                                .frame(width: 5, height: 5)
                            Text(t)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    case .tool(let name, let input, let output, let seconds, let running):
                        ToolCardView(name: name, input: input, output: output, seconds: seconds, running: running)
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }
}

// MARK: - 单个工具调用卡片

struct ToolCardView: View {
    let name: String
    let input: String
    let output: String?
    let seconds: Double?
    let running: Bool

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if running {
                        ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    Text(ToolDescribe.title(name))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(ToolDescribe.detail(name: name, input: input))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let s = seconds {
                        Text(String(format: "%.2fs", s))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            if expanded {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(name)
                    if !input.isEmpty {
                        sectionLabel("参数")
                        Text(input)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let o = output, !o.isEmpty {
                        sectionLabel("输出")
                        Text(o)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
            }
        }
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.28), lineWidth: 0.6)
        )
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}
