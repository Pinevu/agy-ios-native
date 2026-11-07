import SwiftUI
import WebKit

/// 用打包进 App 的 KaTeX 渲染公式（与 PWA 完全一致），失败自动降级为文本
struct MathView: View {
    let latex: String
    var display: Bool = false
    var fontSize: CGFloat = 17

    @State private var height: CGFloat = 0
    @State private var failed = false

    var body: some View {
        Group {
            if failed || !looksLikeMath(latex) {
                fallbackText
            } else {
                KaTeXWebView(latex: latex, display: display, fontSize: fontSize,
                             measuredHeight: $height, failed: $failed)
                    .frame(height: height > 1 ? height : (fontSize * 1.5))
                    .opacity(height > 1 ? 1 : 0)
            }
        }
    }

    private var fallbackText: some View {
        Text(latex)
            .font(.system(size: fontSize - 1, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: display ? .center : .leading)
            .padding(.vertical, 2)
    }
}

private struct KaTeXWebView: UIViewRepresentable {
    let latex: String
    let display: Bool
    let fontSize: CGFloat
    @Binding var measuredHeight: CGFloat
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
        v.loadHTMLString(Self.html(latex: latex, display: display, fontSize: fontSize),
                         baseURL: Bundle.main.resourceURL)
        context.coordinator.loaded = latex
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.loaded != latex else { return }
        context.coordinator.loaded = latex
        v.loadHTMLString(Self.html(latex: latex, display: display, fontSize: fontSize),
                         baseURL: Bundle.main.resourceURL)
    }

    /// 资源被拍平到 Bundle 根目录，这里读文件并修正字体相对路径
    static var css: String = {
        guard let url = Bundle.main.url(forResource: "katex.min", withExtension: "css"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return raw.replacingOccurrences(of: "fonts/", with: "")
    }()

    static var js: String = {
        guard let url = Bundle.main.url(forResource: "katex.min", withExtension: "js"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return raw
    }()

    static func html(latex: String, display: Bool, fontSize: CGFloat) -> String {
        let escaped = latex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let color = dark ? "#E6E6E9" : "#1C1C1E"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>\(Self.css)</style>
        <style>
          html,body{margin:0;padding:0;background:transparent;color:\(color);}
          body{font-size:\(Int(fontSize))px;line-height:1.45;
               display:flex;justify-content:\(display ? "center" : "flex-start");
               align-items:flex-start;overflow:hidden;}
          .katex{font-size:\(Int(fontSize))px;}
          .err{font-family:ui-monospace,monospace;font-size:\(Int(fontSize - 1))px;color:#8E8E96;white-space:pre-wrap;}
        </style>
        <script>\(Self.js)</script>
        <script>
        function post(){ window.webkit.messageHandlers.size.postMessage(
            Math.ceil(document.body.scrollHeight)); }
        window.addEventListener('load', function(){
          var el = document.getElementById('m');
          try {
            katex.render(`\(escaped)`, el, { displayMode: \(display ? "true" : "false"), throwOnError: true });
          } catch(e) {
            el.className = 'err';
            el.textContent = e && e.message ? e.message : 'math error';
          }
          setTimeout(post, 30);
          setTimeout(post, 150);
        });
        </script>
        </head><body><div id="m"></div></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: KaTeXWebView
        var loaded: String?
        init(_ p: KaTeXWebView) { parent = p }

        func userContentController(_ u: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "size", let v = message.body as? NSNumber else { return }
            let h = CGFloat(truncating: v)
            guard h > 0, h < 4000 else { return }
            DispatchQueue.main.async {
                if abs(self.parent.measuredHeight - h) > 0.5 {
                    self.parent.measuredHeight = h
                }
            }
        }
    }
}
