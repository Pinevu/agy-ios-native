import SwiftUI
import UIKit

// MARK: - 富文本渲染

struct MarkdownView: View {
    let text: String

    private var blocks: [MDBlock] { MarkdownParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .font(.system(size: level <= 2 ? 19 : 16, weight: .semibold))
                .padding(.top, 2)

        case .paragraph(let t):
            ParagraphView(text: t)

        case .bullets(let arr):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(arr.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.secondary)
                        ParagraphView(text: item)
                    }
                }
            }

        case .numbered(let arr):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(arr.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(idx + 1).").font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        ParagraphView(text: item)
                    }
                }
            }

        case .quote(let t):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: 3)
                ParagraphView(text: t)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

        case .code(let lang, let code):
            CodeBlockView(lang: lang, code: code)

        case .math(let tex):
            MathView(latex: tex, display: true, fontSize: 18)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

/// 段落：文字 + 行内公式 + 图片混排
struct ParagraphView: View {
    let text: String

    private var segs: [InlineSeg] { InlineParser.parse(text) }

    var body: some View {
        if segs.contains(where: { if case .math = $0 { return true }; return false }) {
            FlowLayout(spacing: 3, lineSpacing: 7) {
                ForEach(segs) { seg in
                    segView(seg)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(segs) { seg in
                    segView(seg)
                }
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
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Text(t).fontWeight(bold ? .semibold : .regular)
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
                Text(lang.isEmpty ? "code" : lang.uppercased())
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
