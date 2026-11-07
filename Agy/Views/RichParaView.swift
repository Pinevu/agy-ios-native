import SwiftUI
import WebKit

/// 含行内公式的段落：整段交给 KaTeX 渲染（WebView），保留粗体/代码样式
struct RichParaView: View {
    let segments: [InlineSeg]
    var fontSize: CGFloat = 16
    var align: TextAlignment = .leading

    @State private var height: CGFloat = 0
    @State private var failed = false

    var body: some View {
        if failed {
            plainFallback
        } else {
            ParaWebView(html: Self.html(segments: segments, fontSize: fontSize, align: align),
                        measuredHeight: $height, failed: $failed)
                .frame(height: height > 1 ? height : fontSize * 3)
                .opacity(height > 1 ? 1 : 0)
                .overlay(alignment: .topLeading) {
                    if height <= 1 { plainFallback.opacity(0.001) }
                }
        }
    }

    private var plainFallback: some View {
        Text(Self.rawText(segments))
            .font(.system(size: fontSize))
            .foregroundStyle(.primary)
            .multilineTextAlignment(align)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func rawText(_ segs: [InlineSeg]) -> String {
        segs.map { seg -> String in
            switch seg {
            case .text(let t, _, _): return t
            case .math(let m): return m
            case .image: return ""
            }
        }.joined()
    }

    static func html(segments: [InlineSeg], fontSize: CGFloat, align: TextAlignment) -> String {
        var parts: [String] = []
        for seg in segments {
            switch seg {
            case .text(let t, let bold, let code):
                var h = escape(t)
                if code { h = "<code>\(h)</code>" }
                if bold { h = "<b>\(h)</b>" }
                parts.append(h)
            case .math(let tex):
                parts.append("<span class=\"tex\" data-tex=\"\(escapeAttr(tex))\"></span>")
            case .image:
                break
            }
        }
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let color = dark ? "#E6E6E9" : "#1C1C1E"
        let codeBg = dark ? "#2C2C2E" : "#F2F2F7"
        let alignCss = align == .center ? "center" : "left"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>\(KaTeXAssets.css)</style>
        <style>
          html,body{margin:0;padding:0;background:transparent;color:\(color);}
          body{font-family:-apple-system,system-ui;font-size:\(Int(fontSize))px;
               line-height:1.55;text-align:\(alignCss);word-wrap:break-word;overflow:hidden;}
          b{font-weight:600;}
          code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.92em;
               background:\(codeBg);padding:1px 4px;border-radius:4px;color:#C05621;}
          .katex{font-size:1.06em;}
          .katex-display{margin:6px 0;text-align:center;}
          .err{font-family:ui-monospace,monospace;font-size:0.9em;color:#8E8E96;}
        </style>
        <script>\(KaTeXAssets.js)</script>
        <script>
        function post(){ window.webkit.messageHandlers.size.postMessage(
            Math.ceil(document.body.getBoundingClientRect().height)); }
        window.addEventListener('load', function(){
          document.querySelectorAll('.tex').forEach(function(el){
            var t = el.getAttribute('data-tex') || '';
            try {
              katex.render(t, el, { displayMode: false, throwOnError: true });
            } catch(e) {
              el.className = 'err';
              el.textContent = t;
            }
          });
          setTimeout(post, 30);
          setTimeout(post, 160);
          setTimeout(post, 400);
        });
        </script>
        </head><body>\(parts.joined())</body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
                 .replacingOccurrences(of: "\n", with: " ")
    }
}

private struct ParaWebView: UIViewRepresentable {
    let html: String
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
        v.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        context.coordinator.loaded = html
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        v.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: ParaWebView
        var loaded: String?
        init(_ p: ParaWebView) { parent = p }

        func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
            guard m.name == "size", let v = m.body as? NSNumber else { return }
            let h = CGFloat(truncating: v)
            guard h > 0, h < 6000 else { return }
            DispatchQueue.main.async {
                if abs(self.parent.measuredHeight - h) > 0.5 {
                    self.parent.measuredHeight = h
                }
            }
        }
    }
}
