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
    // v2 元数据字段（向下兼容旧服务端，全部可选）
    let pinned: Bool?
    let groupId: String?
    let customTitle: String?
    let lastRead: Double?
    let unread: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, model, done, started, updated, pinned, unread
        case turnCount = "turn_count"
        case conversationId = "conversation_id"
        case latestTaskId = "latest_task_id"
        case groupId = "group_id"
        case customTitle = "custom_title"
        case lastRead = "last_read"
    }

    var displayTitle: String {
        if let ct = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !ct.isEmpty {
            return ct
        }
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    var displayDate: String {
        let d = Date(timeIntervalSince1970: updated ?? started)
        let f = Calendar.current.isDateInToday(d) ? Self.timeFormatter : Self.dayTimeFormatter
        return f.string(from: d)
    }
}

// MARK: - 会话元数据（置顶 / 分组 / 自定义标题 / 已读）

struct SessionGroup: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var color: String
}

struct SessionMeta: Codable {
    var pinned: [String]
    var groups: [SessionGroup]
    var sessionGroups: [String: String]
    var customTitles: [String: String]
    var lastRead: [String: Double]
    var collapsedPinned: Bool

    enum CodingKeys: String, CodingKey {
        case pinned, groups
        case sessionGroups = "session_groups"
        case customTitles = "custom_titles"
        case lastRead = "last_read"
        case collapsedPinned = "collapsed_pinned"
    }

    static let empty = SessionMeta(
        pinned: [],
        groups: [],
        sessionGroups: [:],
        customTitles: [:],
        lastRead: [:],
        collapsedPinned: false
    )

    init(
        pinned: [String] = [],
        groups: [SessionGroup] = [],
        sessionGroups: [String: String] = [:],
        customTitles: [String: String] = [:],
        lastRead: [String: Double] = [:],
        collapsedPinned: Bool = false
    ) {
        self.pinned = pinned
        self.groups = groups
        self.sessionGroups = sessionGroups
        self.customTitles = customTitles
        self.lastRead = lastRead
        self.collapsedPinned = collapsedPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = (try? c.decode([String].self, forKey: .pinned)) ?? []
        groups = (try? c.decode([SessionGroup].self, forKey: .groups)) ?? []
        sessionGroups = (try? c.decode([String: String].self, forKey: .sessionGroups)) ?? [:]
        customTitles = (try? c.decode([String: String].self, forKey: .customTitles)) ?? [:]
        lastRead = (try? c.decode([String: Double].self, forKey: .lastRead)) ?? [:]
        collapsedPinned = (try? c.decode(Bool.self, forKey: .collapsedPinned)) ?? false
    }
}

struct SessionMetaMutationResponse: Decodable {
    let ok: Bool?
    let meta: SessionMeta?
}

// MARK: - 全文搜索

struct SearchResultItem: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let updated: Double?
    let turnCount: Int?
    let done: Bool?
    let pinned: Bool?
    let groupId: String?
    let titleHit: Bool?
    let matchCount: Int?
    let snippet: String?

    enum CodingKeys: String, CodingKey {
        case id, title, updated, done, pinned, snippet
        case turnCount = "turn_count"
        case groupId = "group_id"
        case titleHit = "title_hit"
        case matchCount = "match_count"
    }
}

struct SearchResponse: Decodable {
    let query: String?
    let results: [SearchResultItem]
}

struct BatchDeleteResponse: Decodable {
    let ok: Bool?
    let deleted: Int?
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

/// 兼容后端 latest_tool 既可能是对象 {"name","text","state"} 也可能是纯字符串的场景
struct RunningToolInfo: Decodable, Hashable {
    let name: String
    let text: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case name, text, state
    }

    init(name: String, text: String? = nil, state: String? = nil) {
        self.name = name
        self.text = text
        self.state = state
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let str = try? single.decode(String.self) {
            self.name = str
            self.text = nil
            self.state = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.text = try? c.decode(String.self, forKey: .text)
        self.state = try? c.decode(String.self, forKey: .state)
    }
}

struct ServerRunning: Decodable {
    let taskId: String
    let sessionId: String?
    let conversationId: String?
    let title: String?
    let started: Double?
    let elapsed: Int?
    let latestTool: RunningToolInfo?
    let subagentCount: Int?

    var latestToolName: String? {
        guard let n = latestTool?.name, !n.isEmpty else { return nil }
        return n
    }

    enum CodingKeys: String, CodingKey {
        case title, started, elapsed
        case taskId = "task_id"
        case sessionId = "session_id"
        case conversationId = "conversation_id"
        case latestTool = "latest_tool"
        case subagentCount = "subagent_count"
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
    let desc: String?
    let count: Int?
    let windows: [QuotaWindow]

    var id: String { name }
}

struct QuotaWindow: Decodable, Identifiable {
    let window: String?
    let label: String
    let remaining: Double?
    let resetAt: String?
    let desc: String?

    var id: String { (window ?? "") + "|" + label + "|" + (resetAt ?? "") }

    enum CodingKeys: String, CodingKey {
        case window, label, remaining, desc
        case resetAt = "reset_at"
    }
}

struct WeekStat: Decodable {
    let calls: Int?
    let tokens: Int?
}

// MARK: - 技能与技能商店

struct Skill: Decodable, Identifiable, Hashable {
    let name: String
    let desc: String?
    let mtime: Double?
    let hasScripts: Bool?
    let sizeKb: Double?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, desc, mtime
        case hasScripts = "has_scripts"
        case sizeKb = "size_kb"
    }
}

struct SkillFileEntry: Decodable, Identifiable, Hashable {
    let path: String
    let size: Int?
    var id: String { path }
}

struct SkillDetail: Decodable {
    let name: String
    let desc: String?
    let content: String
    let files: [SkillFileEntry]?
    let mtime: Double?
}

struct SkillInstallResponse: Decodable {
    let ok: Bool?
    let name: String?
    let files: Int?
    let bytes: Int?
    let error: String?
}

struct SkillCatalogItem: Decodable, Identifiable, Hashable {
    let name: String
    let desc: String?
    let url: String
    var installed: Bool

    var id: String { name }
}

struct SkillCatalogResponse: Decodable {
    let ok: Bool?
    let source: String?
    let skills: [SkillCatalogItem]?
    let error: String?
}

// MARK: - 定时任务（Scheduled Cron Jobs）

struct ScheduledJob: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let cron: String
    let prompt: String
    let model: String?
    let enabled: Bool
    let notify: Bool?
    let created: Double?
    let lastRun: Double?
    let lastTaskId: String?
    let nextRun: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, cron, prompt, model, enabled, notify, created
        case lastRun = "last_run"
        case lastTaskId = "last_task_id"
        case nextRun = "next_run"
    }
}

struct JobsListResponse: Decodable {
    let jobs: [ScheduledJob]
}

struct JobMutationResponse: Decodable {
    let ok: Bool?
    let job: ScheduledJob?
    let error: String?
}

struct JobRunResponse: Decodable {
    let ok: Bool?
    let taskId: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case taskId = "task_id"
    }
}

// MARK: - 上传 / 执行 / 模型

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

struct ModelInfo: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
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
