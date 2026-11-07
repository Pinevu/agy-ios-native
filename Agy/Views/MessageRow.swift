import SwiftUI
import UIKit

struct MessageRow: View {
    let item: ChatItem
    /// 点击铅笔/长按「编辑后重发」
    var onEdit: ((ChatItem) -> Void)? = nil

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            userBubble(text: text, attachments: attachments)

        case .assistant(let text):
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                    AuthImage(path: p)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 用户气泡

    @ViewBuilder
    private func userBubble(text: String, attachments: [Data]) -> some View {
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
                                .fill(Color.accentColor.opacity(0.14))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.7)
                        )

                    if onEdit != nil {
                        Button {
                            onEdit?(item)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 2)
                    }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    if onEdit != nil {
                        Button {
                            onEdit?(item)
                        } label: {
                            Label("编辑后重发", systemImage: "pencil")
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
                    Text(name)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    Text(summary)
                        .font(.system(size: 12, design: .monospaced))
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
        .background(Color(.secondarySystemBackground))
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
