import SwiftUI
import UIKit
import WebKit

// MARK: - 公式能力判断

enum MathCapability {
    /// SwiftMath 能否解析；能就原生渲染（快、排版贴合），不能则回退 KaTeX
    static func canRenderNative(_ tex: String) -> Bool {
        let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 240 else { return false }
        for sc in t.unicodeScalars {
            let v = sc.value
            if (0x4E00...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v) { return false }
        }
        return MTMathListBuilder.build(from: t) != nil
    }
}

// MARK: - 统一入口

struct MathView: View {
    let latex: String
    var display: Bool = false
    var fontSize: CGFloat = 17

    @State private var nativeOK: Bool = true
    @State private var measured: CGFloat = 0
    @State private var katexFailed = false

    var body: some View {
        Group {
            if nativeOK {
                SwiftMathLabel(latex: latex, display: display, fontSize: fontSize) {
                    nativeOK = false      // SwiftMath 解析失败 → 切 KaTeX
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if !katexFailed {
                KaTeXBlock(latex: latex, display: display, fontSize: fontSize,
                           height: $measured, failed: $katexFailed)
                    .frame(height: measured > 1 ? measured : fontSize * 1.6)
                    .opacity(measured > 1 ? 1 : 0)
            } else {
                Text(latex)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            nativeOK = MathCapability.canRenderNative(latex)
        }
        .onChange(of: latex) { _ in
            nativeOK = MathCapability.canRenderNative(latex)
        }
    }
}

// MARK: - 原生渲染（SwiftMath）

private struct SwiftMathLabel: UIViewRepresentable {
    let latex: String
    let display: Bool
    let fontSize: CGFloat
    let onFail: () -> Void

    func makeUIView(context: Context) -> MTMathUILabel {
        let v = MTMathUILabel()
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: MTMathUILabel, context: Context) {
        let t = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let list = MTMathListBuilder.build(from: t) else {
            DispatchQueue.main.async { onFail() }
            return
        }
        // 直接塞 mathList，绕开会抛异常的 latex setter
        v.font = MTFontManager().font(withName: "LatinModernMath", size: fontSize)
        v.textColor = UIColor.label
        v.mathList = list
        v.labelMode = .display
        v.textAlignment = display ? .center : .left
        v.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        if size.height < 2 { return CGSize(width: w, height: fontSize * 1.4) }
        return size
    }
}

// MARK: - KaTeX 兜底（复杂环境如 cases / aligned）

private struct KaTeXBlock: UIViewRepresentable {
    let latex: String
    let display: Bool
    let fontSize: CGFloat
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "size")
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.isScrollEnabled = false
        v.scrollView.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.loadHTMLString(html(), baseURL: Bundle.main.resourceURL)
        context.coordinator.loaded = latex
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.loaded != latex else { return }
        context.coordinator.loaded = latex
        v.loadHTMLString(html(), baseURL: Bundle.main.resourceURL)
    }

    private func html() -> String {
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let color = dark ? "#E6E6E9" : "#1C1C1E"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>\(KaTeXAssets.css)</style>
        <style>
          html,body{margin:0;padding:0;background:transparent;color:\(color);}
          body{font-size:\(Int(fontSize))px;text-align:\(display ? "center" : "left");overflow:hidden;}
          .err{font-family:ui-monospace,monospace;color:#8E8E96;}
        </style>
        <script>\(KaTeXAssets.js)</script>
        <script>
        function post(){ window.webkit.messageHandlers.size.postMessage(
            Math.ceil(document.body.getBoundingClientRect().height)); }
        window.addEventListener('load', function(){
          var el = document.getElementById('m');
          try {
            katex.render(\(jsString(latex)), el, { displayMode: \(display ? "true" : "false"), throwOnError: true });
          } catch(e) {
            el.className = 'err';
            el.textContent = \(jsString(latex));
          }
          setTimeout(post, 30); setTimeout(post, 160); setTimeout(post, 400);
        });
        </script>
        </head><body><div id="m"></div></body></html>
        """
    }

    private func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return "'\(escaped)'"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: KaTeXBlock
        var loaded: String?
        init(_ p: KaTeXBlock) { parent = p }

        func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
            guard m.name == "size", let v = m.body as? NSNumber else { return }
            let h = CGFloat(truncating: v)
            guard h > 0, h < 4000 else { return }
            DispatchQueue.main.async {
                if abs(self.parent.height - h) > 0.5 { self.parent.height = h }
            }
        }
    }
}

/// KaTeX 资源（bundle 内被拍平）
enum KaTeXAssets {
    static let css: String = {
        guard let u = Bundle.main.url(forResource: "katex.min", withExtension: "css"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s.replacingOccurrences(of: "fonts/", with: "")
    }()

    static let js: String = {
        guard let u = Bundle.main.url(forResource: "katex.min", withExtension: "js"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }()
}
