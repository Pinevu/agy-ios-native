import SwiftUI

// MARK: - 块级解析

enum MDBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case code(lang: String, code: String)
    case math(String)
    case rule

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l)-\(t.hashValue)"
        case .paragraph(let t): return "p-\(t.hashValue)"
        case .bullets(let a): return "ul-\(a.joined().hashValue)"
        case .numbered(let a): return "ol-\(a.joined().hashValue)"
        case .quote(let t): return "q-\(t.hashValue)"
        case .code(let l, let c): return "c-\(l)-\(c.hashValue)"
        case .math(let t): return "m-\(t.hashValue)"
        case .rule: return "hr"
        }
    }
}

/// 判断一段 $...$ 是否真的像公式，避免把价格、普通美元符号喂给渲染器（会崩）
func looksLikeMath(_ tex: String) -> Bool {
    let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty || t.count > 240 { return false }
    // 中文/日文出现在公式里几乎都是误判
    for sc in t.unicodeScalars {
        let v = sc.value
        if (0x4E00...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v) { return false }
    }
    // 括号必须配对，否则渲染器可能直接崩
    if t.filter({ $0 == "{" }).count != t.filter({ $0 == "}" }).count { return false }
    if t.contains("\\begin") && !t.contains("\\end") { return false }
    if t.range(of: "\\\\[a-zA-Z]{2,}", options: .regularExpression) != nil { return true }
    if t.range(of: "[\\^_=<>±×÷≤≥≠∞∑∫√]", options: .regularExpression) != nil { return true }
    if t.range(of: "^[a-zA-Z]$", options: .regularExpression) != nil { return true }
    if t.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil { return true }
    return false
}

enum MarkdownParser {
    static func parse(_ src: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = src.components(separatedBy: "\n")
        var i = 0

        func flushParagraph(_ buf: inout [String]) {
            let text = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            buf.removeAll()
        }

        var para: [String] = []

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 代码围栏
            if line.hasPrefix("```") {
                flushParagraph(&para)
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(l)
                    i += 1
                }
                blocks.append(.code(lang: lang, code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            // 数学块 $$
            if line.hasPrefix("$$") {
                flushParagraph(&para)
                let body = String(line.dropFirst(2))
                if body.hasSuffix("$$"), body.count >= 2 {
                    let tex = String(body.dropLast(2))
                    if looksLikeMath(tex) {
                        blocks.append(.math(tex))
                    } else {
                        blocks.append(.paragraph(tex))
                    }
                    i += 1
                    continue
                }
                var acc: [String] = body.isEmpty ? [] : [body]
                i += 1
                var closed = false
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasSuffix("$$") {
                        let t = String(l.dropLast(2))
                        if !t.isEmpty { acc.append(t) }
                        closed = true
                        i += 1
                        break
                    }
                    acc.append(lines[i])
                    i += 1
                }
                if closed {
                    let tex = acc.joined(separator: "\n")
                    if looksLikeMath(tex) {
                        blocks.append(.math(tex))
                    } else {
                        blocks.append(.paragraph(tex))
                    }
                }
                continue
            }

            // 标题
            if line.hasPrefix("#") {
                var level = 0
                for ch in line { if ch == "#" { level += 1 } else { break } }
                if level >= 1 && level <= 4 && line.count > level {
                    flushParagraph(&para)
                    let t = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, text: t))
                    i += 1
                    continue
                }
            }

            // 分隔线
            if line == "---" || line == "***" {
                flushParagraph(&para)
                blocks.append(.rule)
                i += 1
                continue
            }

            // 引用
            if line.hasPrefix("> ") || line == ">" {
                flushParagraph(&para)
                var acc: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    acc.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(acc.joined(separator: "\n")))
                continue
            }

            // 无序列表
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph(&para)
                var acc: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") {
                        acc.append(String(l.dropFirst(2)))
                        i += 1
                    } else if l.isEmpty {
                        break
                    } else if !acc.isEmpty
                                && !l.hasPrefix("- ") && !l.hasPrefix("* ")
                                && !l.hasPrefix("+ ") && !l.hasPrefix(">")
                                && !l.hasPrefix("#") && !l.hasPrefix("```")
                                && l.range(of: #"^\d+\.\s"#, options: .regularExpression) == nil {
                        acc[acc.count - 1] += "\n" + l
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.bullets(acc))
                continue
            }

            // 有序列表
            if let _ = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                flushParagraph(&para)
                var acc: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let r = l.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                        acc.append(String(l[r.upperBound...]))
                        i += 1
                    } else if l.isEmpty {
                        break
                    } else if !acc.isEmpty
                                && !l.hasPrefix("- ") && !l.hasPrefix("* ")
                                && !l.hasPrefix("+ ") && !l.hasPrefix(">")
                                && !l.hasPrefix("#") && !l.hasPrefix("```") {
                        acc[acc.count - 1] += "\n" + l
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.numbered(acc))
                continue
            }

            if line.isEmpty {
                flushParagraph(&para)
                i += 1
                continue
            }

            para.append(raw)
            i += 1
        }

        flushParagraph(&para)
        return blocks
    }
}

// MARK: - 行内解析

enum InlineSeg: Identifiable {
    case text(String, bold: Bool, code: Bool)
    case math(String)
    case image(String)

    var id: String {
        switch self {
        case .text(let t, let b, let c): return "t\(t.hashValue)\(b)\(c)"
        case .math(let m): return "m\(m.hashValue)"
        case .image(let p): return "i\(p.hashValue)"
        }
    }
}

enum InlineParser {
    static func parse(_ s: String) -> [InlineSeg] {
        var segs: [InlineSeg] = []
        var buf = ""
        let chars = Array(s)
        var i = 0

        func flush() {
            if !buf.isEmpty { segs.append(.text(buf, bold: false, code: false)); buf = "" }
        }

        while i < chars.count {
            let c = chars[i]

            // 图片 ![alt](path)
            if c == "!" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let close = indexOf("]", in: chars, from: i + 2),
                   close + 1 < chars.count, chars[close + 1] == "(",
                   let end = indexOf(")", in: chars, from: close + 2) {
                    flush()
                    let path = String(chars[(close + 2)..<end])
                    segs.append(.image(path))
                    i = end + 1
                    continue
                }
            }

            // 块公式 $$...$$ 出现在行内时，作为整段公式
            if c == "$" && i + 1 < chars.count && chars[i + 1] == "$" {
                if let end = indexOfSeq("$$", in: chars, from: i + 2), end > i + 2 {
                    let tex = String(chars[(i + 2)..<end])
                    flush()
                    segs.append(.math(tex))
                    i = end + 2
                    continue
                }
            }

            // 数学 $...$
            if c == "$" {
                if let end = indexOf("$", in: chars, from: i + 1), end > i + 1 {
                    let tex = String(chars[(i + 1)..<end])
                    if !tex.contains("\n") {
                        flush()
                        if looksLikeMath(tex) {
                            segs.append(.math(tex))
                        } else {
                            segs.append(.text("$" + tex + "$", bold: false, code: false))
                        }
                        i = end + 1
                        continue
                    }
                }
            }

            // 行内代码 `...`
            if c == "`" {
                if let end = indexOf("`", in: chars, from: i + 1) {
                    flush()
                    segs.append(.text(String(chars[(i + 1)..<end]), bold: false, code: true))
                    i = end + 1
                    continue
                }
            }

            // 粗体 **...**
            if c == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                if let end = indexOfSeq("**", in: chars, from: i + 2) {
                    flush()
                    segs.append(.text(String(chars[(i + 2)..<end]), bold: true, code: false))
                    i = end + 2
                    continue
                }
            }

            // 链接 [text](url) → 只保留文字
            if c == "[" {
                if let close = indexOf("]", in: chars, from: i + 1),
                   close + 1 < chars.count, chars[close + 1] == "(",
                   let end = indexOf(")", in: chars, from: close + 2) {
                    flush()
                    let label = String(chars[(i + 1)..<close])
                    segs.append(.text(label, bold: false, code: false))
                    i = end + 1
                    continue
                }
            }

            buf.append(c)
            i += 1
        }

        flush()
        return segs
    }

    private static func indexOf(_ target: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func indexOfSeq(_ target: String, in chars: [Character], from: Int) -> Int? {
        let t = Array(target)
        guard !t.isEmpty else { return nil }
        var i = from
        while i + t.count <= chars.count {
            if Array(chars[i..<(i + t.count)]) == t { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - 自动换行布局（用于行内公式混排）

struct FlowLayout: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 {
                x = 0
                y += lineH + lineSpacing
                lineH = 0
            }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineH + lineSpacing
                lineH = 0
            }
            sv.place(at: CGPoint(x: x, y: y),
                     anchor: .topLeading,
                     proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
