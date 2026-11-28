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
    let errorKind: String?
    let rawError: String?

    enum CodingKeys: String, CodingKey {
        case type, text, name, prompt, secs, output, params, usage, images, error
        case conversationId = "conversation_id"
        case taskId = "task_id"
        case errorKind = "error_kind"
        case rawError = "raw_error"
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
    let conversationId: String?
    let endedAgo: Double?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case sessionId = "session_id"
        case conversationId = "conversation_id"
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
    let accountId: String?
    let accountEmail: String?

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
        case accountId = "account_id"
        case accountEmail = "account_email"
    }
}

// MARK: - 配额

struct QuotaResponse: Decodable {
    let ok: Bool?
    let error: String?
    let plan: String?
    let accountId: String?
    let accountEmail: String?
    let accountLabel: String?
    let groups: [QuotaGroup]?
    let buckets: [QuotaBucket]?
    let week: WeekStat?

    enum CodingKeys: String, CodingKey {
        case ok, error, plan, groups, buckets, week
        case accountId = "account_id"
        case accountEmail = "account_email"
        case accountLabel = "account_label"
    }
}

struct QuotaBucket: Decodable, Identifiable, Equatable {
    let model: String?
    let label: String
    let remaining: Double?
    let resetAt: String?

    var id: String { (model ?? label) + "|" + (resetAt ?? "") }

    enum CodingKeys: String, CodingKey {
        case model, label, remaining
        case resetAt = "reset_at"
    }
}

struct QuotaGroup: Decodable, Identifiable, Equatable {
    let name: String
    let desc: String?
    let count: Int?
    let windows: [QuotaWindow]

    var id: String { name }
}

struct QuotaWindow: Decodable, Identifiable, Equatable {
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

// MARK: - Antigravity 多账号池

struct AgyAccountItem: Decodable, Identifiable, Equatable {
    let id: String
    let email: String
    var label: String
    let authMethod: String?
    var active: Bool
    let isPrimary: Bool?
    let addedAt: Double?
    let lastUsedAt: Double?
    let runningTasks: Int?
    let plan: String?
    let tier: String?
    let quotaOk: Bool?
    let quotaGroups: [QuotaGroup]?
    let quotaError: String?

    enum CodingKeys: String, CodingKey {
        case id, email, label, active, plan, tier
        case authMethod = "auth_method"
        case isPrimary = "is_primary"
        case addedAt = "added_at"
        case lastUsedAt = "last_used_at"
        case runningTasks = "running_tasks"
        case quotaOk = "quota_ok"
        case quotaGroups = "quota_groups"
        case quotaError = "quota_error"
    }

    var displayLabel: String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return email.components(separatedBy: "@").first ?? email
    }

    /// 评估某池（Gemini 或 Claude/GPT）当前是否还有有效余量（要求 5h 与 weekly 均 > 0，若仅一项存在则取该项）
    func effectiveRemaining(thirdParty: Bool) -> Double? {
        guard let groups = quotaGroups, !groups.isEmpty else { return nil }
        let matched = groups.first { g in
            let n = g.name.lowercased()
            if thirdParty {
                return n.contains("claude") || n.contains("gpt") || n.contains("third")
            } else {
                return n.contains("gemini") && !n.contains("argon")
            }
        }
        guard let group = matched else { return nil }
        let vals = group.windows.compactMap(\.remaining)
        guard !vals.isEmpty else { return nil }
        return vals.min()
    }
}

struct AccountsListResponse: Decodable {
    let ok: Bool?
    let activeId: String?
    let accounts: [AgyAccountItem]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, accounts, error
        case activeId = "active_id"
    }
}

struct AccountMutationResponse: Decodable {
    let ok: Bool?
    let activeId: String?
    let account: AgyAccountItem?
    let updatedExisting: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, account, error
        case activeId = "active_id"
        case updatedExisting = "updated_existing"
    }
}

struct OAuthStartResponse: Decodable {
    let ok: Bool?
    let sessionId: String?
    let authUrl: String?
    let expiresIn: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case sessionId = "session_id"
        case authUrl = "auth_url"
        case expiresIn = "expires_in"
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

// MARK: - 环境变量（对齐 OpenMinis EnvironmentVariables）

struct EnvVarItem: Codable, Identifiable, Hashable {
    let id: String
    var key: String
    var value: String
    var note: String?
    var enabled: Bool
    var updated: Double?
}

struct EnvVarsResponse: Decodable {
    let ok: Bool?
    let privacyMode: Bool?
    let vars: [EnvVarItem]?
    let item: EnvVarItem?
    let imported: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, vars, item, imported, error
        case privacyMode = "privacy_mode"
    }
}

// MARK: - MCP 服务器（对齐 OpenMinis MCPIntegrations + JSON-RPC 工具探测）

struct MCPServerItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var transport: String
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var url: String?
    var headers: [String: String]?
    var note: String?
    var enabled: Bool
    var toolsCount: Int?
    var lastOk: Bool?
    var updated: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, transport, command, args, env, url, headers, note, enabled, updated
        case toolsCount = "tools_count"
        case lastOk = "last_ok"
    }

    var isHTTP: Bool {
        transport.lowercased() == "http"
    }

    var displayTitle: String {
        if let n = name, !n.isEmpty { return n }
        return id
    }

    var summaryLine: String {
        if isHTTP {
            return url ?? ""
        }
        let cmd = command ?? ""
        let joined = (args ?? []).joined(separator: " ")
        return joined.isEmpty ? cmd : "\(cmd) \(joined)"
    }
}

struct MCPToolInfo: Decodable, Identifiable, Hashable {
    let name: String
    let description: String?
    var id: String { name }
}

struct MCPListResponse: Decodable {
    let ok: Bool?
    let servers: [MCPServerItem]?
    let presets: [MCPServerItem]?
    let server: MCPServerItem?
    let imported: [String]?
    let error: String?
}

struct MCPProbeResponse: Decodable {
    let ok: Bool?
    let id: String?
    let latencyMs: Int?
    let toolsCount: Int?
    let tools: [MCPToolInfo]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, id, tools, error
        case latencyMs = "latency_ms"
        case toolsCount = "tools_count"
    }
}

// MARK: - Agent 人格规则（Soul）与持久记忆（GEMINI.md）

struct AgentSoulConfig: Codable, Equatable {
    var name: String
    var role: String
    var style: String
    var language: String
    var rules: String

    static let empty = AgentSoulConfig(name: "", role: "", style: "", language: "简体中文", rules: "")

    init(name: String = "", role: String = "", style: String = "", language: String = "简体中文", rules: String = "") {
        self.name = name
        self.role = role
        self.style = style
        self.language = language
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
        style = (try? c.decode(String.self, forKey: .style)) ?? ""
        language = (try? c.decode(String.self, forKey: .language)) ?? "简体中文"
        rules = (try? c.decode(String.self, forKey: .rules)) ?? ""
    }
}

struct MemoryNoteFile: Decodable, Identifiable, Hashable {
    let name: String
    let size: Int?
    let mtime: Double?
    let content: String?
    var id: String { name }
}

struct AgentMemoryResponse: Decodable {
    let ok: Bool?
    let enabled: Bool?
    let injectNotes: Bool?
    let soul: AgentSoulConfig?
    let globalMemory: String?
    let files: [MemoryNoteFile]?
    let charCount: Int?
    let charLimit: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, enabled, soul, files, error
        case injectNotes = "inject_notes"
        case globalMemory = "global_memory"
        case charCount = "char_count"
        case charLimit = "char_limit"
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
