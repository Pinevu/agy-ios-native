import SwiftUI
import UIKit

/// UIKit 文本视图：选择和复制由系统处理，不跟外层滚动手势抢。
/// SwiftUI 的 textSelection 在 ScrollView 里选区不跟手，所以纯文本段落走这里。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString

    /// 正文基准字号。所有段落都归一到这个值，避免个别段落掉回更小的字号。
    private static let baseFontSize: CGFloat = 18

    func makeUIView(context: Context) -> SelectableLabel {
        let v = SelectableLabel()
        v.backgroundColor = .clear
        // 与正文一致的基础字号，属性缺失时也不会掉回 17pt
        v.font = .systemFont(ofSize: Self.baseFontSize)
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.textContainer.lineBreakMode = .byWordWrapping
        v.dataDetectorTypes = [.link]
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ uiView: SelectableLabel, context: Context) {
        // 父视图每次重算 body 都会走到这里。如果每次都重建整段 NSAttributedString
        // 并赋给 UITextView，键盘输入/滚动时整屏文字都要重新排版，必卡。
        if let cached = context.coordinator.cachedSource,
           cached.isEqual(to: attributed),
           context.coordinator.matchesLastApplied(uiView) {
            return
        }
        context.coordinator.cachedSource = attributed

        let normalized = Self.normalized(attributed)
        if uiView.attributedText.isEqual(to: normalized) { return }
        uiView.attributedText = normalized
        context.coordinator.applied = normalized
        // 文本变了，旧的测量结果立即作废，否则行高会沿用上一段文字的尺寸
        context.coordinator.invalidateMeasurement()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableLabel, context: Context) -> CGSize? {
        let fallbackWidth = max(200, UIScreen.main.bounds.width - 32)
        let width: CGFloat
        if let pw = proposal.width, pw.isFinite, pw > 20 {
            width = pw
        } else {
            width = fallbackWidth
        }
        let c = context.coordinator

        // 关键：测量必须和「当前这段文字」绑定。之前只按宽度缓存，
        // 一旦文本更新而宽度没变，就会返回上一段文字的高度 —— 行被压短，
        // 后面的行直接盖上来，看起来又像文字变小又像被裁切。
        if c.measuredWidth == width,
           let src = c.measuredSource,
           src.isEqual(to: attributed),
           let h = c.measuredHeight {
            return CGSize(width: width, height: h)
        }

        let rect = Self.normalized(attributed)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                          context: nil)
        let h = max(22, ceil(rect.height) + 4)
        c.measuredSource = attributed
        c.measuredWidth = width
        c.measuredHeight = h
        return CGSize(width: width, height: h)
    }

    /// assigned 字号与前景色归一：attributedText 自带的 UIFont 会覆盖 UITextView.font，
    /// 未显式设颜色的区间在深色模式下 UITextView 默认会落回黑色导致「黑底黑字白屏」。
    private static func normalized(_ src: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: src)
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let old = value as? UIFont else {
                out.addAttribute(.font, value: UIFont.systemFont(ofSize: baseFontSize), range: range)
                return
            }
            if abs(old.pointSize - baseFontSize) < 0.01 { return }
            out.addAttribute(.font, value: UIFont(descriptor: old.fontDescriptor, size: baseFontSize), range: range)
        }
        out.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if value == nil {
                out.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
        }
        return out
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var cachedSource: NSAttributedString?
        var applied: NSAttributedString?
        var measuredSource: NSAttributedString?
        var measuredWidth: CGFloat?
        var measuredHeight: CGFloat?

        func invalidateMeasurement() {
            measuredSource = nil
            measuredWidth = nil
            measuredHeight = nil
        }

        /// 只做内容一致性检查，避免每次 update 都重新排版
        func matchesLastApplied(_ view: UITextView) -> Bool {
            guard let applied else { return false }
            return view.attributedText.isEqual(to: applied)
        }
    }
}

/// 关闭自身滚动，把滚动交给外层 SwiftUI ScrollView
final class SelectableLabel: UITextView {
    override var canBecomeFirstResponder: Bool { true }
}
