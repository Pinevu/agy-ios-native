import SwiftUI
import SwiftMath

/// SwiftMath 渲染 LaTeX；渲染为空时降级成等宽文本
struct MathView: View {
    let latex: String
    var display: Bool = false
    var fontSize: CGFloat = 17

    var body: some View {
        MathLabel(latex: latex, fontSize: fontSize, display: display)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MathLabel: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let display: Bool

    func makeUIView(context: Context) -> MTMathUILabel {
        let v = MTMathUILabel()
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: MTMathUILabel, context: Context) {
        v.font = MTFontManager().font(withName: "LatinModernMath", size: fontSize)
        v.textColor = UIColor.label
        v.latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        v.labelMode = .display
        v.textAlignment = display ? .center : .left
        v.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        // 渲染失败时高度接近 0，给个最小高度避免塌陷
        if size.height < 2 {
            return CGSize(width: w, height: fontSize * 1.4)
        }
        return size
    }
}
