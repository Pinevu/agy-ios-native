import SwiftUI
import UIKit

/// UIKit 文本视图：选择和复制由系统处理，不跟外层滚动手势抢。
/// SwiftUI 的 textSelection 在 ScrollView 里选区不跟手，所以纯文本段落走这里。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> SelectableLabel {
        let v = SelectableLabel()
        v.backgroundColor = .clear
        // 与正文一致的基础字号，属性缺失时也不会掉回 17pt
        v.font = .systemFont(ofSize: 18)
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
        // 关键：父视图每次重算 body 都会走到这里。如果每次都重建整段 NSAttributedString
        // 并赋给 UITextView，键盘输入/滚动时整屏的文字行都要重新排版，必卡。
        // 输入没变就直接返回；变了才归一化一次。
        if let cached = context.coordinator.cachedSource,
           cached.isEqual(to: attributed),
           context.coordinator.matchesLastApplied(uiView) {
            return
        }
        context.coordinator.cachedSource = attributed

        // attributedText 自带的 UIFont 会覆盖 UITextView.font。逐段强制归一到
        // 与用户气泡相同的 18pt，同时保留粗体/斜体/等宽等字形特征。
        let normalized = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: normalized.length)
        normalized.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let old = value as? UIFont else { return }
            if abs(old.pointSize - 18) < 0.01 { return }
            let font = UIFont(descriptor: old.fontDescriptor, size: 18)
            normalized.addAttribute(.font, value: font, range: range)
        }
        if uiView.attributedText.isEqual(to: normalized) { return }
        uiView.attributedText = normalized
        context.coordinator.applied = normalized
        context.coordinator.measuredWidth = nil
        context.coordinator.measuredHeight = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableLabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        // 同一段文字、同一宽度反复测量是滚动卡顿的主要来源之一，按结果缓存
        if context.coordinator.measuredWidth == width,
           let h = context.coordinator.measuredHeight {
            return CGSize(width: width, height: h)
        }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let h = ceil(size.height)
        context.coordinator.measuredWidth = width
        context.coordinator.measuredHeight = h
        return CGSize(width: width, height: h)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var cachedSource: NSAttributedString?
        var applied: NSAttributedString?
        var measuredWidth: CGFloat?
        var measuredHeight: CGFloat?

        /// 只做指针/内容一致性检查，避免每次 update 都重新排版
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
