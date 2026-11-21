import Foundation
import UIKit

enum APIError: LocalizedError {
    case unauthorized
    case badPassword
    case server(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "登录已过期，请重新登录"
        case .badPassword: return "密码错误"
        case .server(let m): return m
        case .decoding(let m): return "数据解析失败：\(m)"
        }
    }
}

struct ErrorBody: Decodable { let error: String? }
struct EmptyResponse: Decodable {}

final class APIClient {
    static let shared = APIClient()

    /// 当前实例地址，可切换
    private(set) var baseURLString: String
    var baseURL: URL { URL(string: baseURLString) ?? URL(string: "https://agy.nooh.cc")! }
    private(set) var token: String?

    private let session: URLSession
    /// 事件流专用：空闲 25 秒即超时，避免代理冻住连接导致界面卡死
    private let streamSession: URLSession
    private let decoder: JSONDecoder

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: cfg)

        let scfg = URLSessionConfiguration.default
        scfg.timeoutIntervalForRequest = 25
        scfg.timeoutIntervalForResource = 7200
        streamSession = URLSession(configuration: scfg)

        decoder = JSONDecoder()
        baseURLString = UserDefaults.standard.string(forKey: "agy_base_url") ?? "https://agy.nooh.cc"
        token = KeychainStore.loadOrMigrateToken(for: Self.tokenKey(for: baseURLString))
    }

    static func tokenKey(for base: String) -> String { "agy_token::" + base }

    static func hasStoredToken(for base: String) -> Bool {
        KeychainStore.loadOrMigrateToken(for: tokenKey(for: base))?.isEmpty == false
    }

    var isLoggedIn: Bool { (token?.isEmpty == false) }

    /// 切到另一个实例：换地址 + 换该实例自己的令牌（Keychain 存储）
    func setBase(_ urlString: String) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !clean.isEmpty else { return }
        baseURLString = clean
        UserDefaults.standard.set(clean, forKey: "agy_base_url")
        token = KeychainStore.loadOrMigrateToken(for: Self.tokenKey(for: clean))
    }

    func setToken(_ t: String?) {
        token = t
        let k = Self.tokenKey(for: baseURLString)
        UserDefaults.standard.removeObject(forKey: k)
        if let t, !t.isEmpty {
            KeychainStore.save(t, account: k)
        } else {
            KeychainStore.delete(account: k)
        }
    }

    // MARK: - 基础请求

    private func makeRequest(
        _ path: String,
        queryItems: [URLQueryItem]? = nil,
        method: String = "GET",
        body: Data? = nil
    ) -> URLRequest {
        let url: URL
        if let queryItems, !queryItems.isEmpty,
           var comp = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) {
            comp.queryItems = queryItems
            url = comp.url ?? baseURL.appendingPathComponent(path)
        } else {
            url = baseURL.appendingPathComponent(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    private func sendRaw(
        _ path: String,
        queryItems: [URLQueryItem]? = nil,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let req = makeRequest(path, queryItems: queryItems, method: method, body: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.server("无响应") }
        if http.statusCode == 401 {
            if path == "api/login" { throw APIError.badPassword }
            throw APIError.unauthorized
        }
        if http.statusCode >= 400 {
            let friendly = (try? decoder.decode(ErrorBody.self, from: data))?.error
            let msg = friendly ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(msg.isEmpty ? "HTTP \(http.statusCode)" : msg)
        }
        return (data, http)
    }

    private func send<T: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem]? = nil,
        method: String = "GET",
        body: Data? = nil,
        as type: T.Type
    ) async throws -> T {
        let (data, _) = try await sendRaw(path, queryItems: queryItems, method: method, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // MARK: - 登录

    func login(password: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["password": password])
        struct Resp: Decodable { let token: String?; let error: String? }
        let r = try await send("api/login", method: "POST", body: body, as: Resp.self)
        guard let t = r.token else { throw APIError.server(r.error ?? "密码错误") }
        setToken(t)
        return t
    }

    func checkSession() async -> Bool {
        struct Resp: Decodable { let ok: Bool? }
        guard isLoggedIn else { return false }
        do {
            let r = try await send("api/session", as: Resp.self)
            return r.ok == true
        } catch {
            return false
        }
    }

    // MARK: - 会话 & 元数据 & 全文搜索 & 导出

    func tasks() async throws -> [Session] {
        try await send("api/tasks", as: [Session].self)
    }

    func replay(_ id: String) async throws -> [ChatEvent] {
        try await send("api/replay/\(id)", as: [ChatEvent].self)
    }

    func run(prompt: String, model: String?, conversationId: String?, sessionId: String?) async throws -> (id: String, conversationId: String?) {
        var payload: [String: Any] = ["prompt": prompt]
        if let m = model { payload["model"] = m }
        if let c = conversationId { payload["conversation_id"] = c }
        if let s = sessionId { payload["session_id"] = s }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let r = try await send("api/run", method: "POST", body: body, as: RunResponse.self)
        guard let id = r.id else { throw APIError.server(r.error ?? "任务创建失败") }
        return (id, r.conversationId)
    }

    func stop(_ taskId: String) async {
        _ = try? await send("api/tasks/\(taskId)/stop", method: "POST", body: Data("{}".utf8), as: EmptyResponse.self)
    }

    func deleteSession(_ id: String) async {
        _ = try? await send("api/tasks/\(id)", method: "DELETE", as: EmptyResponse.self)
    }

    func batchDeleteSessions(ids: [String]) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["ids": ids])
        let r = try await send("api/tasks/batch-delete", method: "POST", body: body, as: BatchDeleteResponse.self)
        return r.deleted ?? ids.count
    }

    func truncateFrom(_ taskId: String) async -> Bool {
        struct Resp: Decodable { let ok: Bool?; let dropped_conversation: Bool? }
        guard let r = try? await send("api/tasks/\(taskId)/from", method: "DELETE", as: Resp.self) else { return false }
        return r.dropped_conversation == true
    }

    func getSessionsMeta() async throws -> SessionMeta {
        try await send("api/sessions/meta", as: SessionMeta.self)
    }

    @discardableResult
    func updateSessionMeta(_ payload: [String: Any]) async throws -> SessionMeta {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let r = try await send("api/sessions/meta", method: "POST", body: body, as: SessionMetaMutationResponse.self)
        return r.meta ?? .empty
    }

    func searchSessions(query: String, limit: Int = 30) async throws -> [SearchResultItem] {
        let q = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        let r = try await send("api/search", queryItems: q, as: SearchResponse.self)
        return r.results
    }

    /// 导出会话为 Markdown 或 JSON 文件并写入临时目录供系统分享
    func exportSessionToTempFile(sessionId: String, format: String = "md", suggestedTitle: String) async throws -> URL {
        let q = [URLQueryItem(name: "format", value: format)]
        let (data, _) = try await sendRaw("api/export/\(sessionId)", queryItems: q)
        let ext = format == "json" ? "json" : "md"
        let cleanTitle = suggestedTitle
            .replacingOccurrences(of: #"[^\w\u4e00-\u9fff.-]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = cleanTitle.isEmpty ? sessionId : String(cleanTitle.prefix(40))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 运行态 / 配额 / 模型

    func runningTasks() async throws -> RunningSnapshot {
        try await send("api/running", as: RunningSnapshot.self)
    }

    func quota() async throws -> QuotaResponse {
        try await send("api/quota", as: QuotaResponse.self)
    }

    func models() async throws -> [ModelInfo] {
        struct Resp: Decodable { let models: [ModelInfo] }
        let r = try await send("api/models", as: Resp.self)
        return r.models
    }

    // MARK: - 技能与社区市场

    func skills() async throws -> [Skill] {
        try await send("api/skills", as: [Skill].self)
    }

    func skillDetail(_ name: String) async throws -> SkillDetail {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try await send("api/skills/\(safe)", as: SkillDetail.self)
    }

    func installSkill(name: String? = nil, url: String? = nil, content: String? = nil) async throws -> SkillInstallResponse {
        var payload: [String: Any] = [:]
        if let name, !name.isEmpty { payload["name"] = name }
        if let url, !url.isEmpty { payload["url"] = url }
        if let content, !content.isEmpty { payload["content"] = content }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await send("api/skills/install", method: "POST", body: body, as: SkillInstallResponse.self)
    }

    func skillsCatalog(force: Bool = false) async throws -> SkillCatalogResponse {
        let q = force ? [URLQueryItem(name: "force", value: "1")] : nil
        return try await send("api/skills/catalog", queryItems: q, as: SkillCatalogResponse.self)
    }

    func deleteSkill(_ name: String) async {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try? await send("api/skills/\(safe)", method: "DELETE", as: EmptyResponse.self)
    }

    // MARK: - 定时任务（Scheduled Cron Jobs）

    func jobs() async throws -> [ScheduledJob] {
        let r = try await send("api/jobs", as: JobsListResponse.self)
        return r.jobs
    }

    func upsertJob(
        id: String? = nil,
        name: String,
        cron: String,
        prompt: String,
        model: String?,
        enabled: Bool = true
    ) async throws -> ScheduledJob {
        var payload: [String: Any] = [
            "name": name,
            "cron": cron,
            "prompt": prompt,
            "enabled": enabled,
            "notify": true
        ]
        if let id, !id.isEmpty { payload["id"] = id }
        if let model, !model.isEmpty { payload["model"] = model }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let r = try await send("api/jobs", method: "POST", body: body, as: JobMutationResponse.self)
        guard let job = r.job else { throw APIError.server(r.error ?? "保存定时任务失败") }
        return job
    }

    func runJob(_ id: String) async throws -> String {
        let r = try await send("api/jobs/\(id)/run", method: "POST", body: Data("{}".utf8), as: JobRunResponse.self)
        guard let tid = r.taskId else { throw APIError.server(r.error ?? "触发失败") }
        return tid
    }

    func toggleJob(_ id: String) async throws -> ScheduledJob {
        let r = try await send("api/jobs/\(id)/toggle", method: "POST", body: Data("{}".utf8), as: JobMutationResponse.self)
        guard let job = r.job else { throw APIError.server(r.error ?? "切换状态失败") }
        return job
    }

    func deleteJob(_ id: String) async throws {
        _ = try await send("api/jobs/\(id)", method: "DELETE", as: EmptyResponse.self)
    }

    // MARK: - 上传

    func upload(name: String, data: Data) async throws -> String {
        let b64 = data.base64EncodedString()
        let payload: [String: Any] = ["name": name, "data": "data:application/octet-stream;base64,\(b64)"]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let r = try await send("api/upload", method: "POST", body: body, as: UploadResponse.self)
        guard let p = r.path else { throw APIError.server(r.error ?? "上传失败") }
        return p
    }

    // MARK: - 图片（统一走有界 ImageCache）

    func imageURL(path: String, width: Int = 0) -> URL? {
        var comp = URLComponents(url: baseURL.appendingPathComponent("api/file"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "path", value: path)]
        if width > 0 { items.append(URLQueryItem(name: "w", value: "\(width)")) }
        comp?.queryItems = items
        return comp?.url
    }

    func taskFileURL(taskId: String, name: String, width: Int = 0) -> URL? {
        var comp = URLComponents(url: baseURL.appendingPathComponent("api/file"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "id", value: taskId),
            URLQueryItem(name: "name", value: name)
        ]
        if width > 0 { items.append(URLQueryItem(name: "w", value: "\(width)")) }
        comp?.queryItems = items
        return comp?.url
    }

    func loadTaskImage(taskId: String, name: String, width: Int = 0) async -> UIImage? {
        let cacheKey = "\(baseURLString)|\(taskId)/\(name)/\(width)"
        if let hit = ImageCache.shared.get(key: cacheKey) { return hit }
        if let disk = ImageCache.shared.loadFromDisk(key: cacheKey) {
            ImageCache.shared.set(disk, forKey: cacheKey)
            return disk
        }
        guard let url = taskFileURL(taskId: taskId, name: name, width: width) else { return nil }
        var req = URLRequest(url: url)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        ImageCache.shared.set(img, forKey: cacheKey)
        ImageCache.shared.saveToDisk(data, forKey: cacheKey)
        return img
    }

    func loadImage(path: String, width: Int = 0) async -> UIImage? {
        let cacheKey = "\(baseURLString)|\(path)|\(width)"
        if let hit = ImageCache.shared.get(key: cacheKey) { return hit }
        if let disk = ImageCache.shared.loadFromDisk(key: cacheKey) {
            ImageCache.shared.set(disk, forKey: cacheKey)
            return disk
        }
        guard let url = imageURL(path: path, width: width) else { return nil }
        var req = URLRequest(url: url)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        ImageCache.shared.set(img, forKey: cacheKey)
        ImageCache.shared.saveToDisk(data, forKey: cacheKey)
        return img
    }

    // MARK: - SSE

    func stream(
        taskId: String,
        from: Int = 0,
        onActivity: @escaping () -> Void = {},
        onEvent: @escaping (ChatEvent) -> Void,
        onClose: @escaping () -> Void
    ) -> Task<Void, Never>? {
        guard var comp = URLComponents(url: baseURL.appendingPathComponent("api/stream/\(taskId)"), resolvingAgainstBaseURL: false) else { return nil }
        var items: [URLQueryItem] = []
        if let t = token { items.append(URLQueryItem(name: "token", value: t)) }
        if from > 0 { items.append(URLQueryItem(name: "from", value: "\(from)")) }
        if !items.isEmpty { comp.queryItems = items }
        guard let url = comp.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        return Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, resp) = try await self.streamSession.bytes(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    onClose(); return
                }
                let lineDecoder = JSONDecoder()
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    onActivity()
                    guard line.hasPrefix("data:") else { continue }
                    let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = json.data(using: .utf8) else { continue }
                    if let ev = try? lineDecoder.decode(ChatEvent.self, from: data) {
                        onEvent(ev)
                        if ev.type == "end" { break }
                    }
                }
            } catch {
                // 网络中断或取消，由上层退避重连
            }
            onClose()
        }
    }
}
