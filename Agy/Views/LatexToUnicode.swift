import Foundation

/// 把常见 LaTeX 行内公式翻译成 Unicode，直接用原生 Text 显示。
/// 目的：不依赖任何渲染器 → 零崩溃、零卡顿，中文数学题的观感也够用。
enum LatexToUnicode {

    private static let symbols: [(String, String)] = [
        // 关系
        ("\\leqslant", "≤"), ("\\leq", "≤"), ("\\le ", "≤ "),
        ("\\geqslant", "≥"), ("\\geq", "≥"), ("\\ge ", "≥ "),
        ("\\neq", "≠"), ("\\ne ", "≠ "), ("\\approx", "≈"),
        ("\\equiv", "≡"), ("\\sim", "∼"), ("\\propto", "∝"),
        ("\\ll", "≪"), ("\\gg", "≫"),
        // 集合
        ("\\varnothing", "∅"), ("\\emptyset", "∅"),
        ("\\cap", "∩"), ("\\cup", "∪"),
        ("\\subseteq", "⊆"), ("\\subset", "⊂"),
        ("\\supseteq", "⊇"), ("\\supset", "⊃"),
        ("\\in ", "∈ "), ("\\notin", "∉"),
        ("\\setminus", "\\"), ("\\complement", "∁"),
        // 逻辑
        ("\\forall", "∀"), ("\\exists", "∃"), ("\\neg", "¬"),
        ("\\land", "∧"), ("\\lor", "∨"), ("\\Rightarrow", "⇒"),
        ("\\Leftarrow", "⇐"), ("\\Leftrightarrow", "⇔"),
        ("\\rightarrow", "→"), ("\\to ", "→ "), ("\\leftarrow", "←"),
        // 运算
        ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
        ("\\cdot", "·"), ("\\ast", "∗"), ("\\star", "⋆"),
        ("\\infty", "∞"), ("\\partial", "∂"), ("\\nabla", "∇"),
        ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"), ("\\oint", "∮"),
        ("\\sqrt", "√"), ("\\angle", "∠"), ("\\perp", "⊥"), ("\\parallel", "∥"),
        // 括号与省略
        ("\\{", "{"), ("\\}", "}"), ("\\langle", "⟨"), ("\\rangle", "⟩"),
        ("\\lvert", "|"), ("\\rvert", "|"),
        ("\\ldots", "…"), ("\\cdots", "⋯"), ("\\dots", "…"),
        ("\\quad", "  "), ("\\qquad", "    "),
        ("\\,", " "), ("\\;", " "), ("\\!", ""), ("\\ ", " "),
        // 希腊字母
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\epsilon", "ε"), ("\\varepsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"),
        ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"), ("\\nu", "ν"),
        ("\\xi", "ξ"), ("\\pi", "π"), ("\\rho", "ρ"), ("\\sigma", "σ"),
        ("\\tau", "τ"), ("\\phi", "φ"), ("\\varphi", "φ"), ("\\chi", "χ"),
        ("\\psi", "ψ"), ("\\omega", "ω"),
        ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
        ("\\Pi", "Π"), ("\\Sigma", "Σ"), ("\\Phi", "Φ"), ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
        // 字体标记：直接去掉，内容保留
        ("\\text{", ""), ("\\textbf{", ""), ("\\mathrm{", ""), ("\\mathbf{", ""),
        ("\\mathbb{R}", "ℝ"), ("\\mathbb{N}", "ℕ"), ("\\mathbb{Z}", "ℤ"),
        ("\\mathbb{Q}", "ℚ"), ("\\mathbb{C}", "ℂ"),
        ("\\displaystyle", ""), ("\\limits", ""),
        ("\\left", ""), ("\\right", ""),
        ("\\big", ""), ("\\Big", ""), ("\\bigg", ""), ("\\Bigg", ""),
    ]

    /// 是否适合走 Unicode 简化（复杂环境另外处理）
    static func canSimplify(_ tex: String) -> Bool {
        let t = tex
        if t.contains("\\begin") || t.contains("\\frac") || t.contains("\\dfrac")
            || t.contains("\\sqrt[") || t.contains("\\overline") || t.contains("\\vec")
            || t.contains("\\\\") { return false }
        return true
    }

    /// 主入口：翻译失败返回原文
    static func convert(_ tex: String) -> String {
        var s = tex
        // 先按长度倒序替换，避免 \le 吃掉 \leqslant
        let sorted = symbols.sorted { $0.0.count > $1.0.count }
        for (k, v) in sorted { s = s.replacingOccurrences(of: k, with: v) }

        // \frac{a}{b} → a/b（简单两层）
        s = replaceFrac(s)
        // 去掉残留反斜杠命令
        s = stripCommands(s)
        // 下标：x_1 → x₁
        s = convertSubscripts(s)
        // 上标：x^2 → x²
        s = convertSuperscripts(s)
        // 收尾空格
        s = s.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replaceFrac(_ input: String) -> String {
        var s = input
        var guardCount = 0
        while let r = s.range(of: "\\frac{"), guardCount < 12 {
            guardCount += 1
            let afterCmd = r.upperBound
            guard let close1 = matchingBrace(in: s, from: afterCmd) else { break }
            let num = String(s[afterCmd..<close1])
            let afterNum = s.index(close1, offsetBy: 1)
            guard afterNum < s.endIndex, s[afterNum] == "{" else { break }
            guard let close2 = matchingBrace(in: s, from: s.index(afterNum, offsetBy: 1)) else { break }
            let den = String(s[s.index(afterNum, offsetBy: 1)..<close2])
            let rep: String
            if num.count == 1 && den.count == 1 {
                rep = "\(num)/\(den)"
            } else {
                rep = "(\(num))/(\(den))"
            }
            s.replaceSubrange(r.lowerBound...close2, with: rep)
        }
        return s
    }

    private static func matchingBrace(in s: String, from idx: String.Index) -> String.Index? {
        var depth = 1
        var i = idx
        while i < s.endIndex {
            let c = s[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func stripCommands(_ input: String) -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "\\" {
                var j = input.index(after: i)
                while j < input.endIndex, input[j].isLetter { j = input.index(after: j) }
                // 跳过命令名
                i = j
                // 命令后面紧跟的 { } 保留内容（由后面的花括号清理处理）
                continue
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
    }

    private static let subs: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "n": "ₙ",
        "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "m": "ₘ", "p": "ₚ", "s": "ₛ", "t": "ₜ"
    ]

    private static let sups: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ"
    ]

    private static func convertSubscripts(_ input: String) -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "_" {
                var j = input.index(after: i)
                var group = ""
                var used = 0
                while j < input.endIndex, used < 4 {
                    let ch = input[j]
                    if let m = subs[ch] { group.append(m); used += 1; j = input.index(after: j) }
                    else { break }
                }
                if used > 0 { out += group; i = j; continue }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }

    private static func convertSuperscripts(_ input: String) -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "^" {
                var j = input.index(after: i)
                var group = ""
                var used = 0
                while j < input.endIndex, used < 4 {
                    let ch = input[j]
                    if let m = sups[ch] { group.append(m); used += 1; j = input.index(after: j) }
                    else { break }
                }
                if used > 0 { out += group; i = j; continue }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }
}
