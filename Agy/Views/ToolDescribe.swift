import Foundation

/// 把工具调用翻成人话：名字 + 一句话说明它在做什么
enum ToolDescribe {
    static func title(_ name: String) -> String {
        switch name {
        case "run_command": return "执行命令"
        case "read_file": return "读取文件"
        case "write_file": return "写入文件"
        case "edit_file", "search_replace", "str_replace": return "编辑文件"
        case "list_dir", "list_directory": return "列出目录"
        case "grep", "search", "codebase_search": return "搜索"
        case "web_search": return "网上搜索"
        case "browse", "web_fetch", "fetch": return "打开网页"
        case "delete_file": return "删除文件"
        default:
            return name.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// 一句话说明。input 可能是纯命令文本，也可能是 JSON
    static func detail(name: String, input: String) -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let fields = jsonFields(raw)
        let text = fields["CommandLine"] ?? fields["command"] ?? fields["cmd"] ?? raw
        let path = fields["Path"] ?? fields["path"] ?? fields["file_path"] ?? fields["target_file"]

        switch name {
        case "run_command":
            return commandDetail(text)
        case "read_file":
            return path.map { "读取 " + shortPath($0) } ?? "读取 " + shortPath(text)
        case "write_file":
            return path.map { "写入 " + shortPath($0) } ?? "写入 " + shortPath(text)
        case "edit_file", "search_replace", "str_replace":
            return path.map { "修改 " + shortPath($0) } ?? "修改 " + shortPath(text)
        case "list_dir", "list_directory":
            return "列出 " + shortPath(path ?? text)
        case "grep", "search", "codebase_search":
            let q = fields["pattern"] ?? fields["query"] ?? text
            return "搜索「" + clip(q, 40) + "」"
        case "web_search":
            return "搜索「" + clip(fields["query"] ?? text, 40) + "」"
        case "browse", "web_fetch", "fetch":
            return clip(fields["url"] ?? text, 48)
        default:
            return clip(text, 60)
        }
    }

    // MARK: - 命令文本 → 一句话

    private static func commandDetail(_ cmd: String) -> String {
        let line = cmd.components(separatedBy: .newlines).first ?? cmd
        let parts = line.split(separator: " ").map(String.init)
        guard let bin = parts.first else { return clip(cmd, 60) }
        let args = Array(parts.dropFirst())

        switch bin {
        case "ls":
            return "列出 " + shortPath(args.last(where: { !$0.hasPrefix("-") }) ?? ".")
        case "cd":
            return "进入 " + shortPath(args.first ?? "")
        case "pwd":
            return "查看当前目录"
        case "cat", "head", "tail", "less", "more":
            return "查看 " + shortPath(args.last(where: { !$0.hasPrefix("-") }) ?? "")
        case "mkdir":
            return "新建目录 " + shortPath(args.last(where: { !$0.hasPrefix("-") }) ?? "")
        case "rm":
            return "删除 " + shortPath(args.last(where: { !$0.hasPrefix("-") }) ?? "")
        case "cp":
            return "复制 " + shortPath(args.last(where: { !$0.hasPrefix("-") }) ?? "")
        case "mv":
            return "移动 " + shortPath(args.last(where: { !$0.hasPrefix("-") }) ?? "")
        case "grep", "rg":
            let q = args.first(where: { !$0.hasPrefix("-") }) ?? ""
            return "搜索「" + clip(q, 30) + "」"
        case "find":
            return "查找 " + shortPath(args.first(where: { !$0.hasPrefix("-") }) ?? "")
        case "python3", "python", "pip", "pip3":
            return clip(line, 60)
        case "git":
            return "git " + clip(args.joined(separator: " "), 50)
        case "curl", "wget":
            return "下载 " + clip(args.last(where: { $0.hasPrefix("http") }) ?? "", 40)
        default:
            return clip(line, 60)
        }
    }

    private static func shortPath(_ p: String) -> String {
        let s = p.trimmingCharacters(in: .whitespaces)
        guard s.count > 28 else { return s }
        let parts = s.split(separator: "/").map(String.init)
        if parts.count >= 2 { return "…/" + parts.suffix(2).joined(separator: "/") }
        return "…" + String(s.suffix(24))
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    /// 尝试把 JSON 拆成字段；不是 JSON 就返回空
    private static func jsonFields(_ s: String) -> [String: String] {
        guard s.hasPrefix("{"), let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let str = v as? String { out[k] = str }
        }
        return out
    }
}
