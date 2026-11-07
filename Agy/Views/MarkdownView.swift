import SwiftUI
import UIKit

// MARK: - 富文本渲染

struct MarkdownView: View {
    let text: String

    private var blocks: [MDBlock] { MarkdownParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            ParagraphView(text: t)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 8 : 4)

        case .paragraph(let t):
            if let callout = Callout.parse(t) {
                CalloutView(callout: callout)
            } else {
                ParagraphView(text: t)
            }

        case .bullets(let arr):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(arr.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: 5, height: 5)
                            .offset(y: -3)
                        ParagraphView(text: item)
                    }
                }
            }

        case .numbered(let arr):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(arr.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(idx + 1).")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .leading)
                        ParagraphView(text: item)
                    }
                }
            }

        case .quote(let t):
            if let callout = Callout.parse(t) {
                CalloutView(callout: callout)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 3)
                    ParagraphView(text: t)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
            }

        case .code(let lang, let code):
            CodeBlockView(lang: lang, code: code)

        case .math(let tex):
            MathView(latex: tex, display: true, fontSize: 18)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

        case .rule:
            Divider().opacity(0.4).padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 17
        default: return 15.5
        }
    }
}

// MARK: - 提示块（[!TIP] / [!NOTE] / [!WARNING]）

struct Callout {
    let kind: String
    let title: String?
    let body: String
    let color: Color
    let icon: String

    static func parse(_ raw: String) -> Callout? {
        let lines = raw.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard first.hasPrefix("[!") , first.hasSuffix("]") else { return nil }
        let kind = String(first.dropFirst(2).dropLast()).uppercased()
        guard ["TIP", "NOTE", "WARNING", "IMPORTANT", "CAUTION"].contains(kind) else { return nil }

        var rest = lines.dropFirst().map { $0 }
        var title: String? = nil
        if let f = rest.first {
            let ft = f.trimmingCharacters(in: .whitespaces)
            if !ft.isEmpty, ft.hasSuffix("：") || ft.hasSuffix(":") {
                title = String(ft.dropLast())
                rest = rest.dropFirst()
            }
        }
        let body = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case "TIP":
            return Callout(kind: kind, title: title, body: body, color: .accentColor, icon: "lightbulb")
        case "WARNING", "CAUTION":
            return Callout(kind: kind, title: title, body: body, color: .orange, icon: "exclamationmark.triangle")
        case "IMPORTANT":
            return Callout(kind: kind, title: title, body: body, color: .red, icon: "exclamationmark.circle")
        default:
            return Callout(kind: kind, title: title, body: body, color: .blue, icon: "info.circle")
        }
    }
}

struct CalloutView: View {
    let callout: Callout

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(callout.color.opacity(0.75))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: callout.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(callout.title ?? callout.kind.capitalized)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(callout.color)

                if !callout.body.isEmpty {
                    ParagraphView(text: callout.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 段落：文字 + 行内公式 + 图片混排
struct ParagraphView: View {
    let text: String

    private var segs: [InlineSeg] { InlineParser.parse(text) }

    var body: some View {
        if segs.contains(where: { if case .math = $0 { return true }; return false }) {
            FlowLayout(spacing: 3, lineSpacing: 7) {
                ForEach(segs) { seg in segView(seg) }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(segs) { seg in segView(seg) }
            }
        }
    }

    @ViewBuilder
    private func segView(_ seg: InlineSeg) -> some View {
        switch seg {
        case .text(let t, let bold, let code):
            if code {
                Text(t)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
                    )
            } else {
                Text(t)
                    .font(.system(size: 16))
                    .fontWeight(bold ? .semibold : .regular)
                    .lineSpacing(4)
            }

        case .math(let tex):
            MathView(latex: tex, display: false, fontSize: 17)

        case .image(let path):
            AuthImage(path: path)
                .frame(maxWidth: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - 代码块

struct CodeBlockView: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "CODE" : lang.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(11)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - 带鉴权的图片

struct AuthImage: View {
    let path: String
    @State private var image: UIImage?
    @State private var loading = true
    @State private var showFull = false

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .onTapGesture { showFull = true }
            } else if loading {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 120)
                    .overlay(ProgressView())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .task {
            guard image == nil else { return }
            loading = true
            image = await APIClient.shared.loadImage(path: path)
            loading = false
        }
        .fullScreenCover(isPresented: $showFull) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = image {
                    Image(uiImage: img).resizable().scaledToFit()
                }
                VStack {
                    HStack {
                        Spacer()
                        Button { showFull = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding()
                    }
                    Spacer()
                }
            }
        }
    }
}
