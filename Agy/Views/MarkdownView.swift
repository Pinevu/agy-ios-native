import SwiftUI
import UIKit

// MARK: - 富文本渲染

struct MarkdownView: View {
    let text: String

    /// 解析结果缓存：只在 text 变化时重算，滚动/父视图刷新不再重复解析
    @State private var blocks: [MDBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: text) {
            blocks = MarkdownParser.parse(text)
        }
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
            if LatexToUnicode.canSimplify(tex) {
                Text(LatexToUnicode.convert(tex))
                    .font(.system(size: 18, design: .serif))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                MathView(latex: tex, display: true, fontSize: 18)
                    .frame(maxWidth: .infinity)
            }

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

        var rest: [String] = Array(lines.dropFirst())
        var title: String? = nil
        if let f = rest.first {
            let ft = f.trimmingCharacters(in: .whitespaces)
            if !ft.isEmpty, ft.hasSuffix("：") || ft.hasSuffix(":") {
                title = String(ft.dropLast())
                rest.removeFirst()
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

/// 段落：行内富文本（粗体 / 行内代码）连续排版，含公式或图片时才拆块
struct ParagraphView: View {
    let text: String

    private var segs: [InlineSeg] { InlineParser.parse(text) }

    private var needsFlow: Bool {
        segs.contains { seg in
            switch seg {
            case .math, .image: return true
            case .text: return false
            }
        }
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for seg in segs {
            guard case .text(let t, let bold, let code) = seg else { continue }
            var a = AttributedString(t)
            if code {
                a.font = .system(size: 14.5, design: .monospaced)
                a.foregroundColor = .accentColor
                a.backgroundColor = Color(.secondarySystemBackground)
            } else {
                a.font = .system(size: 16, weight: bold ? .semibold : .regular)
            }
            out.append(a)
        }
        return out
    }

    private var hasMath: Bool {
        segs.contains { if case .math = $0 { return true } else { return false } }
    }

    /// 行内公式统一转 Unicode 走原生 Text：零渲染风险，滚动跟手
    private var hasInlineMath: Bool { hasMath }

    /// 把公式转成 Unicode 后拼进 AttributedString，用系统字体排
    private var attributedWithMath: AttributedString {
        var out = AttributedString()
        for seg in segs {
            switch seg {
            case .text(let t, let bold, let code):
                var a = AttributedString(t)
                if code {
                    a.font = .system(size: 14.5, design: .monospaced)
                    a.foregroundColor = .accentColor
                } else {
                    a.font = .system(size: 16, weight: bold ? .semibold : .regular)
                }
                out.append(a)
            case .math(let tex):
                var a = AttributedString(LatexToUnicode.convert(tex))
                // 公式用衬线体，与正文区分开
                a.font = .system(size: 16.5, design: .serif)
                a.foregroundColor = .primary
                out.append(a)
            case .image:
                continue
            }
        }
        return out
    }

    var body: some View {
        if hasMath {
            // 行内公式转 Unicode 后同样走可选文本，复制跟手
            SelectableText(attributed: nsAttributed(attributedWithMath))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if needsFlow {
            FlowLayout(spacing: 3, lineSpacing: 7) {
                ForEach(segs) { seg in segView(seg) }
            }
        } else {
            // 纯文本走 UIKit：选择和复制跟手，不跟外层滚动抢手势
            SelectableText(attributed: nsAttributed(attributed))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// AttributedString → NSAttributedString，给 UIKit 文本视图用
    private func nsAttributed(_ a: AttributedString) -> NSAttributedString {
        (try? NSAttributedString(a, including: \.uiKit)) ?? NSAttributedString(string: String(a.characters))
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
            } else {
                Text(t)
                    .font(.system(size: 16, weight: bold ? .semibold : .regular))
            }

        case .math(let tex):
            MathView(latex: tex, display: false, fontSize: 17)

        case .image(let path):
            AuthImage(path: path, maxWidth: 220, maxHeight: 300, corner: 10)
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
    /// 只传了文件名时，用它拼 /api/files?id=&name=
    var taskId: String? = nil
    /// 最大展示宽度（默认铺满可用宽度）
    var maxWidth: CGFloat = .infinity
    /// 最大展示高度：长图压到这条线以下，防止一图占几屏空白
    var maxHeight: CGFloat = 460
    var corner: CGFloat = 12
    /// 列表里用缩略图，点开才拉原图
    var thumbWidth: Int = 600

    @State private var image: UIImage?
    @State private var loading = true
    @State private var showFull = false

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { showFull = true }
                    .contextMenu {
                        Button {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                        } label: {
                            Label("保存到相册", systemImage: "square.and.arrow.down")
                        }
                    }
            } else if loading {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(maxWidth: maxWidth == .infinity ? 220 : maxWidth, alignment: .leading)
                    .frame(height: 120)
                    .overlay(ProgressView().scaleEffect(0.85))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 46)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .task {
            guard image == nil else { return }
            // 内存缓存命中：同步取出，不闪 loading
            if let hit = ImageCache.shared.get(path, taskId: taskId) {
                image = hit
                loading = false
                return
            }
            loading = true
            let isBareName = !path.contains("/")
            let img: UIImage?
            if isBareName, let tid = taskId {
                img = await APIClient.shared.loadTaskImage(taskId: tid, name: path, width: thumbWidth)
            } else {
                img = await APIClient.shared.loadImage(path: path)
            }
            if let img { ImageCache.shared.set(img, for: path, taskId: taskId) }
            await MainActor.run {
                image = img
                loading = false
            }
        }
        .fullScreenCover(isPresented: $showFull) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = image {
                    Image(uiImage: img).resizable().scaledToFit()
                }
                VStack {
                    HStack {
                        Button {
                            if let img = image {
                                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                            }
                            showFull = false
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                        Spacer()
                        Button { showFull = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.trailing, 16)
                        .padding(.top, 10)
                    }
                    Spacer()
                }
            }
        }
    }
}
