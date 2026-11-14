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
        // attributedText 自带的 UIFont 会覆盖 UITextView.font。逐段强制归一到
        // 与用户气泡相同的 18pt，同时保留粗体/斜体/等宽等字形特征。
        let normalized = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: normalized.length)
        normalized.enumerateAttribute(.font, in: full) { value, range, _ in
            let old = value as? UIFont
            let descriptor = old?.fontDescriptor ?? UIFont.systemFont(ofSize: 18).fontDescriptor
            let font = UIFont(descriptor: descriptor, size: 18)
            normalized.addAttribute(.font, value: font, range: range)
        }
        if uiView.attributedText != normalized {
            uiView.attributedText = normalized
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableLabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

/// 关闭自身滚动，把滚动交给外层 SwiftUI ScrollView
final class SelectableLabel: UITextView {
    override var canBecomeFirstResponder: Bool { true }
}
