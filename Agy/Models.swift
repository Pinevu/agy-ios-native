import Foundation

// MARK: - 会话

struct Session: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let prompt: String?
    let model: String?
    let done: Bool
    let started: Double
    let updated: Double?
    let turnCount: Int?
    let conversationId: String?
    let latestTaskId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, model, done, started, updated
        case turnCount = "turn_count"
        case conversationId = "conversation_id"
        case latestTaskId = "latest_task_id"
    }

    var displayTitle: String {
        var raw = title ?? prompt ?? "（无标题会话）"
        // 首轮注入的行为约定不进标题
        if let r = raw.range(of: "【行为约定】"), raw.distance(from: raw.startIndex, to: r.lowerBound) < 5 {
            let after = raw[r.lowerBound...]
            if let end = after.range(of: "\n\n") {
                raw = String(after[end.upperBound...])
            } else if let nl = after.range(of: "\n") {
                raw = String(after[nl.upperBound...])
            }
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = "（无标题会话）" }
        return raw
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? raw
    }

    var displayDate: String {
        let ts = updated ?? started
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: d)
    }
}

// MARK: - 事件

struct Usage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }

    var summary: String {
        "↑\(inputTokens ?? 0) ↓\(outputTokens ?? 0) · \(totalTokens ?? 0) tok"
    }
}

struct ChatEvent: Decodable {
    let type: String
    let text: String?
    let name: String?
    let prompt: String?
    let secs: Double?
    let output: String?
    let params: String?
    let conversationId: String?
    let taskId: String?
    let usage: Usage?
    let images: [String]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, text, name, prompt, secs, output, params, usage, images, error
        case conversationId = "conversation_id"
        case taskId = "task_id"
    }
}

// MARK: - 服务端运行态快照

struct RunningSnapshot: Decodable {
    let running: [ServerRunning]
    let recent: [ServerRecent]
}

struct ServerRecent: Decodable {
    let taskId: String
    let sessionId: String?
    let endedAgo: Double?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case sessionId = "session_id"
        case endedAgo = "ended_ago"
    }
}

// MARK: - 服务端运行中任务

struct ServerRunning: Decodable {
    let taskId: String
    let sessionId: String?
    let conversationId: String?
    let title: String?
    let elapsed: Int?

    enum CodingKeys: String, CodingKey {
        case title, elapsed
        case taskId = "task_id"
        case sessionId = "session_id"
        case conversationId = "conversation_id"
    }
}

// MARK: - 配额

struct QuotaResponse: Decodable {
    let ok: Bool?
    let plan: String?
    let groups: [QuotaGroup]?
    let week: WeekStat?
}

struct QuotaGroup: Decodable, Identifiable {
    let name: String
    let count: Int?
    let windows: [QuotaWindow]

    var id: String { name }
}

struct QuotaWindow: Decodable, Identifiable {
    let label: String
    let remaining: Double?
    let resetAt: String?
    let desc: String?

    var id: String { label + (resetAt ?? "") }

    enum CodingKeys: String, CodingKey {
        case label, remaining, desc
        case resetAt = "reset_at"
    }
}

struct WeekStat: Decodable {
    let calls: Int?
    let tokens: Int?
}

// MARK: - 技能

struct Skill: Decodable, Identifiable {
    let name: String
    let desc: String?
    let mtime: Double?

    var id: String { name }
}

// MARK: - 上传

struct UploadResponse: Decodable {
    let path: String?
    let name: String?
    let error: String?
}

struct RunResponse: Decodable {
    let id: String?
    let conversationId: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, error
        case conversationId = "conversation_id"
    }
}

// MARK: - 聊天气泡模型

enum ChatItemKind {
    case user(text: String, attachments: [Data], remotePaths: [String] = [])
    case assistant(text: String)
    /// 模型在调用工具前写的一句说明，和正文分开渲染
    case note(text: String)
    case thought(text: String)
    case tool(name: String, input: String, output: String?, seconds: Double?, running: Bool)
    case usage(text: String)
    case error(text: String)
    case images([String])
}

struct ChatItem: Identifiable {
    var id = UUID()
    var kind: ChatItemKind
    /// 产生这条消息的任务 id（用户气泡才有，用于「编辑后重发」时截断服务端上下文）
    var taskId: String? = nil
    /// 原文（不含附件路径），编辑时回填
    var rawText: String? = nil
}
