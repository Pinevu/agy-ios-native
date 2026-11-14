import SwiftUI
import UIKit

/// UIKit 文本视图：选择和复制由系统处理，不跟外层滚动手势抢。
/// SwiftUI 的 textSelection 在 ScrollView 里选区不跟手，所以纯文本段落走这里。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> SelectableLabel {
        let v = SelectableLabel()
        v.backgroundColor = .clear
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
        if uiView.attributedText != attributed {
            uiView.attributedText = attributed
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
