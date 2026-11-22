import SwiftUI
import UIKit
import WebKit
import SwiftMath

// MARK: - 1. 公式能力判断 + SwiftMath 字体修复（latinmodern-math）

enum MathCapability {
    static let sharedFontManager = MTFontManager()

    /// 统一加载 latinmodern-math 字体，避免旧版错名导致退回或字体为空崩溃
    static func mathFont(size: CGFloat) -> MTFont? {
        sharedFontManager.font(withName: "latinmodern-math", size: size)
            ?? sharedFontManager.font(withName: "Asana-Math", size: size)
            ?? sharedFontManager.termesFont(withSize: size)
    }

    static func canRenderNative(_ tex: String) -> Bool {
        let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 60 else { return false }
        if t.contains("\\") { return false }
        for sc in t.unicodeScalars {
            let v = sc.value
            if (0x4E00...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v) { return false }
        }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 +-*/=<>^_()[]{}.,:;!|'\"")
        let extra = CharacterSet(charactersIn: "±×÷≤≥≠≈∞∑∫√πθαβγΔΣΩ∅∩∪∈∉⊂⊆")
        for u in t.unicodeScalars {
            if !allowed.contains(u) && !extra.contains(u) { return false }
        }
        if t.filter({ $0 == "{" }).count != t.filter({ $0 == "}" }).count { return false }
        if t.filter({ $0 == "(" }).count != t.filter({ $0 == ")" }).count { return false }
        return MTMathListBuilder.build(fromString: t) != nil
    }
}

// MARK: - 2. 统一渲染调度器（参考 OpenMinis MathRenderScheduler：每帧最多 4 个并发渲染）

@MainActor
final class MathRenderScheduler {
    static let shared = MathRenderScheduler()

    private struct Job {
        let id: UUID
        let work: @MainActor () async -> Void
    }

    private var queue: [Job] = []
    private var running = 0
    private let maxConcurrent = 4

    func enqueue(_ work: @escaping @MainActor () async -> Void) -> UUID {
        let id = UUID()
        queue.append(Job(id: id, work: work))
        pump()
        return id
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    private func pump() {
        while running < maxConcurrent, !queue.isEmpty {
            let job = queue.removeFirst()
            running += 1
            Task { @MainActor [weak self] in
                await job.work()
                guard let self else { return }
                self.running = max(0, self.running - 1)
                self.pump()
            }
        }
    }
}

// MARK: - 3. 全局单实例离屏 KaTeX 引擎（参考 OpenMinis KaTeXRenderer：零内存泄漏、深浅色自适应）

private final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ d: WKScriptMessageHandler) { delegate = d }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class KaTeXSnapshotEngine: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = KaTeXSnapshotEngine()

    private struct Request {
        let key: String
        let latex: String
        let display: Bool
        let fontSize: CGFloat
        let maxWidth: CGFloat
        let isDark: Bool
        let completion: (UIImage?) -> Void
    }

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 180
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()

    private var webView: WKWebView?
    private var isBooted = false
    private var pending: [Request] = []
    private var active: Request?
    private var activeWatchdog: Task<Void, Never>?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cache.removeAllObjects()
            }
        }
    }

    static func cacheKey(latex: String, display: Bool, fontSize: CGFloat, maxWidth: CGFloat, isDark: Bool) -> String {
        let wBucket = Int((maxWidth / 16).rounded()) * 16
        return "\(display ? "D" : "I")|\(Int(fontSize))|\(wBucket)|\(isDark ? "dk" : "lt")|\(latex)"
    }

    func cached(latex: String, display: Bool, fontSize: CGFloat, maxWidth: CGFloat, isDark: Bool) -> UIImage? {
        let key = Self.cacheKey(latex: latex, display: display, fontSize: fontSize, maxWidth: maxWidth, isDark: isDark)
        return cache.object(forKey: key as NSString)
    }

    func render(latex: String, display: Bool, fontSize: CGFloat, maxWidth: CGFloat, isDark: Bool) async -> UIImage? {
        let key = Self.cacheKey(latex: latex, display: display, fontSize: fontSize, maxWidth: maxWidth, isDark: isDark)
        if let hit = cache.object(forKey: key as NSString) { return hit }

        return await withCheckedContinuation { cont in
            let req = Request(
                key: key,
                latex: latex,
                display: display,
                fontSize: fontSize,
                maxWidth: max(160, maxWidth),
                isDark: isDark
            ) { img in
                cont.resume(returning: img)
            }
            pending.append(req)
            ensureWebView()
            processNext()
        }
    }

    private func ensureWebView() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakScriptProxy(self), name: "katexReady")
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 380, height: 120), configuration: cfg)
        wv.navigationDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        webView = wv

        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>\(KaTeXAssets.css)</style>
        <style>
          html,body{margin:0;padding:0;background:transparent;}
          #box{display:inline-block;padding:4px 2px;box-sizing:border-box;max-width:100%;overflow:hidden;}
          .katex-display{margin:2px 0;}
        </style>
        <script>\(KaTeXAssets.js)</script>
        <script>
        window.__renderMath = function(tex, displayMode, fontSize, color, maxW) {
          var box = document.getElementById('box');
          box.style.fontSize = fontSize + 'px';
          box.style.color = color;
          box.style.width = displayMode ? (maxW + 'px') : 'auto';
          box.style.textAlign = displayMode ? 'center' : 'left';
          box.innerHTML = '';
          try {
            katex.render(tex, box, { displayMode: displayMode, throwOnError: true, strict: false });
            var r = box.getBoundingClientRect();
            window.webkit.messageHandlers.katexReady.postMessage({ ok: true, w: Math.ceil(r.width) + 2, h: Math.ceil(r.height) + 2 });
          } catch(e) {
            window.webkit.messageHandlers.katexReady.postMessage({ ok: false, w: 0, h: 0 });
          }
        };
        </script>
        </head><body><div id="box"></div></body></html>
        """
        wv.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isBooted = true
        processNext()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.webView = nil
        isBooted = false
        finishActive(with: nil)
        if !pending.isEmpty {
            ensureWebView()
        }
    }

    private func processNext() {
        guard isBooted, active == nil, !pending.isEmpty, let wv = webView else { return }
        let req = pending.removeFirst()
        if let hit = cache.object(forKey: req.key as NSString) {
            req.completion(hit)
            processNext()
            return
        }
        active = req
        activeWatchdog?.cancel()
        let reqKey = req.key
        activeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.active?.key == reqKey else { return }
            self.finishActive(with: nil)
        }
        wv.frame = CGRect(x: 0, y: 0, width: req.maxWidth, height: 600)
        let color = req.isDark ? "#F2F2F7" : "#1C1C1E"
        let jsTex = jsString(req.latex)
        let js = "window.__renderMath(\(jsTex), \(req.display ? "true" : "false"), \(Int(req.fontSize)), '\(color)', \(Int(req.maxWidth)));"
        wv.evaluateJavaScript(js) { [weak self] _, err in
            if err != nil {
                Task { @MainActor in
                    self?.finishActive(with: nil)
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "katexReady",
              let dict = message.body as? [String: Any],
              let ok = dict["ok"] as? Bool, ok,
              let w = dict["w"] as? CGFloat,
              let h = dict["h"] as? CGFloat,
              w > 1, h > 1, h < 1200,
              let wv = webView else {
            finishActive(with: nil)
            return
        }

        let targetW = min(max(w, 8), active?.maxWidth ?? w)
        let targetH = min(max(h, 12), 1200)
        let snapCfg = WKSnapshotConfiguration()
        snapCfg.rect = CGRect(x: 0, y: 0, width: targetW, height: targetH)
        snapCfg.afterScreenUpdates = true

        wv.takeSnapshot(with: snapCfg) { [weak self] image, _ in
            Task { @MainActor in
                self?.finishActive(with: image)
            }
        }
    }

    private func finishActive(with image: UIImage?) {
        activeWatchdog?.cancel()
        activeWatchdog = nil
        guard let req = active else { return }
        active = nil
        if let img = image {
            let cost = (img.cgImage?.bytesPerRow ?? 1024) * (img.cgImage?.height ?? 64)
            cache.setObject(img, forKey: req.key as NSString, cost: cost)
        }
        req.completion(image)
        processNext()
    }

    private func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8),
              arr.count >= 2 else {
            return "''"
        }
        return String(arr.dropFirst().dropLast())
    }
}

// MARK: - 4. 统一对外 MathView（原生 SwiftMath 优先 → 单例 KaTeX 快照 → 文本兜底）

struct MathView: View {
    let latex: String
    var display: Bool = false
    var fontSize: CGFloat = 17

    @Environment(\.colorScheme) private var colorScheme
    @State private var nativeOK: Bool = false
    @State private var renderedImage: UIImage?
    @State private var failed = false
    @State private var jobId: UUID?

    private var isDark: Bool { colorScheme == .dark }
    private var renderWidth: CGFloat { max(240, UIScreen.main.bounds.width - 36) }

    var body: some View {
        Group {
            if nativeOK {
                SwiftMathLabel(latex: latex, display: display, fontSize: fontSize) {
                    nativeOK = false
                    scheduleKaTeX()
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let img = renderedImage {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: img.size.width, height: img.size.height)
                }
                .frame(maxWidth: .infinity, alignment: display ? .center : .leading)
            } else if failed {
                Text(LatexToUnicode.convert(latex))
                    .font(.system(size: fontSize, design: .serif))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: display ? .center : .leading)
            } else {
                Text(LatexToUnicode.convert(latex))
                    .font(.system(size: fontSize, design: .serif))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: display ? .center : .leading)
                    .padding(.vertical, 4)
            }
        }
        .onAppear { prepare() }
        .onChange(of: latex) { _ in prepare() }
        .onChange(of: colorScheme) { _ in
            if !nativeOK { scheduleKaTeX() }
        }
        .onDisappear {
            if let id = jobId {
                MathRenderScheduler.shared.cancel(id)
                jobId = nil
            }
        }
    }

    private func prepare() {
        failed = false
        if MathCapability.canRenderNative(latex) {
            nativeOK = true
            return
        }
        nativeOK = false
        if let hit = KaTeXSnapshotEngine.shared.cached(
            latex: latex, display: display, fontSize: fontSize, maxWidth: renderWidth, isDark: isDark
        ) {
            renderedImage = hit
            return
        }
        scheduleKaTeX()
    }

    private func scheduleKaTeX() {
        if let id = jobId { MathRenderScheduler.shared.cancel(id) }
        let tex = latex
        let disp = display
        let fz = fontSize
        let mw = renderWidth
        let dk = isDark
        jobId = MathRenderScheduler.shared.enqueue {
            let img = await KaTeXSnapshotEngine.shared.render(
                latex: tex, display: disp, fontSize: fz, maxWidth: mw, isDark: dk
            )
            if let img {
                renderedImage = img
            } else {
                failed = true
            }
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
        guard let list = MTMathListBuilder.build(fromString: t),
              let font = MathCapability.mathFont(size: fontSize) else {
            DispatchQueue.main.async { onFail() }
            return
        }
        v.font = font
        v.textColor = UIColor.label
        v.mathList = list
        v.labelMode = .display
        v.textAlignment = display ? .center : .left
        v.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        guard let w = proposal.width, w.isFinite, w > 1 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        guard size.height.isFinite, size.height > 1 else {
            return CGSize(width: w, height: fontSize * 1.5)
        }
        return CGSize(width: w, height: min(size.height, 320))
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
