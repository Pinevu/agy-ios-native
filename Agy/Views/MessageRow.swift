import SwiftUI
import UIKit

/// 一条消息能做的操作，对齐 Minis 的会话机制
struct MessageActions {
    var edit: ((ChatItem) -> Void)?
    var retry: ((ChatItem) -> Void)?
    var deleteFrom: ((ChatItem) -> Void)?

    static let none = MessageActions()
}

struct MessageRow: View {
    let item: ChatItem
    var actions: MessageActions = .none

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments, let remotePaths):
            userBubble(text: text, attachments: attachments, remotePaths: remotePaths)

        case .note(let text):
            noteLine(text)

        case .assistant(let text):
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = text
                    } label: { Label("复制", systemImage: "doc.on.doc") }

                    if let r = actions.retry {
                        Button { r(item) } label: { Label("重试", systemImage: "arrow.clockwise") }
                    }
                    if let d = actions.deleteFrom {
                        Button(role: .destructive) { d(item) } label: {
                            Label("从此处删除", systemImage: "trash")
                        }
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

        case .usage(let text):
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .error(let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .images(let paths):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paths, id: \.self) { p in
                    AuthImage(path: p, taskId: item.taskId, maxHeight: 420, corner: 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 工具前的一句说明：小字号、次要色、圆点开头，和正文拉开差距
    private func noteLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: 5, height: 5)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 用户气泡

    @ViewBuilder
    private func userBubble(text: String, attachments: [Data], remotePaths: [String] = []) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            if !attachments.isEmpty {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, data in
                    if let img = UIImage(data: data) {
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
                        .font(.system(size: 15.5))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
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

struct ToolCardView: View {
    let name: String
    let input: String
    let output: String?
    let seconds: Double?
    let running: Bool

    @State private var expanded = false

    private var summary: String {
        let s = input.replacingOccurrences(of: "\n", with: " ")
        return s.count > 90 ? String(s.prefix(90)) + "…" : s
    }

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
                        .font(.system(size: 13, weight: .medium))
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
            .buttonStyle(.plain)

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
