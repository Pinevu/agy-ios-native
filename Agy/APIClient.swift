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

class APIClient {
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
        token = UserDefaults.standard.string(forKey: Self.tokenKey(for: baseURLString))
    }

    static func tokenKey(for base: String) -> String { "agy_token::" + base }

    var isLoggedIn: Bool { (token?.isEmpty == false) }

    /// 切到另一个实例：换地址 + 换该实例自己的令牌
    func setBase(_ urlString: String) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !clean.isEmpty else { return }
        baseURLString = clean
        UserDefaults.standard.set(clean, forKey: "agy_base_url")
        token = UserDefaults.standard.string(forKey: Self.tokenKey(for: clean))
    }

    func setToken(_ t: String?) {
        token = t
        let k = Self.tokenKey(for: baseURLString)
        if let t, !t.isEmpty {
            UserDefaults.standard.set(t, forKey: k)
        } else {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    // MARK: - 基础请求

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    private func send<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, as type: T.Type) async throws -> T {
        let req = makeRequest(path, method: method, body: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.server("无响应") }
        if http.statusCode == 401 {
            // 登录接口的 401 是密码错，其它接口的 401 才是令牌过期
            if path == "api/login" { throw APIError.badPassword }
            throw APIError.unauthorized
        }
        if http.statusCode >= 400 {
            // 服务端错误体是 {"error": "..."}，取出可读文案，不要把 JSON 原样抛给界面
            let friendly = (try? decoder.decode(ErrorBody.self, from: data))?.error
            let msg = friendly ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(msg.isEmpty ? "HTTP \(http.statusCode)" : msg)
        }
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

    // MARK: - 会话

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

    func truncateFrom(_ taskId: String) async -> Bool {
        struct Resp: Decodable { let ok: Bool?; let dropped_conversation: Bool? }
        guard let r = try? await send("api/tasks/\(taskId)/from", method: "DELETE", as: Resp.self) else { return false }
        return r.dropped_conversation == true
    }

    // MARK: - 配额 / 技能

    /// 服务端运行态：running = 正在跑，recent = 最近 8 秒刚结束（供补拉）
    func runningTasks() async throws -> RunningSnapshot {
        try await send("api/running", as: RunningSnapshot.self)
    }

    func quota() async throws -> QuotaResponse {
        try await send("api/quota", as: QuotaResponse.self)
    }

    func skills() async throws -> [Skill] {
        try await send("api/skills", as: [Skill].self)
    }

    /// 服务端当前账号真实可用的模型
    func models() async throws -> [ModelInfo] {
        struct Resp: Decodable { let models: [ModelInfo] }
        let r = try await send("api/models", as: Resp.self)
        return r.models
    }

    func deleteSkill(_ name: String) async {
        _ = try? await send("api/skills/\(name)", method: "DELETE", as: EmptyResponse.self)
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

    // MARK: - 图片

    private var imageCache = NSCache<NSString, UIImage>()

    func imageURL(path: String, width: Int = 0) -> URL? {
        var comp = URLComponents(url: baseURL.appendingPathComponent("api/file"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "path", value: path)]
        if width > 0 { items.append(URLQueryItem(name: "w", value: "\(width)")) }
        comp?.queryItems = items
        return comp?.url
    }

    /// 任务产物文件：/api/files?id=<taskId>&name=<filename>
    func taskFileURL(taskId: String, name: String, width: Int = 0) -> URL? {
        var comp = URLComponents(url: baseURL.appendingPathComponent("api/file"),
                                 resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "id", value: taskId),
                     URLQueryItem(name: "name", value: name)]
        if width > 0 { items.append(URLQueryItem(name: "w", value: "\(width)")) }
        comp?.queryItems = items
        return comp?.url
    }

    func loadTaskImage(taskId: String, name: String, width: Int = 0) async -> UIImage? {
        let key = "\(taskId)/\(name)/\(width)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        // 磁盘缓存：再次进入同一会话时直接读本地，不再重新下载
        let file = imageDiskURL(key as String)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            imageCache.setObject(img, forKey: key)
            return img
        }
        guard let url = taskFileURL(taskId: taskId, name: name, width: width) else { return nil }
        var req = URLRequest(url: url)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        try? data.write(to: file, options: .atomic)
        return img
    }

    /// 图片磁盘缓存目录，文件名用 key 的稳定哈希
    private func imageDiskURL(_ key: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agy-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var h = UInt64(1469598103934665603)
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return dir.appendingPathComponent(String(h, radix: 16) + ".img")
    }

    func loadImage(path: String) async -> UIImage? {
        let key = path as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let url = imageURL(path: path) else { return nil }
        var req = URLRequest(url: url)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    // MARK: - SSE

    /// 订阅任务事件流，逐条回调。自动处理 meta/init/text/tool/usage/end。
    func stream(taskId: String,
                from: Int = 0,
                onEvent: @escaping (ChatEvent) -> Void,
                onClose: @escaping () -> Void) -> Task<Void, Never>? {
        guard var comp = URLComponents(url: baseURL.appendingPathComponent("api/stream/\(taskId)"), resolvingAgainstBaseURL: false) else { return nil }
        var items: [URLQueryItem] = []
        if let t = token { items.append(URLQueryItem(name: "token", value: t)) }
        // 从上次收到的位置续上，重连不重放已有内容
        if from > 0 { items.append(URLQueryItem(name: "from", value: "\(from)")) }
        if !items.isEmpty { comp.queryItems = items }
        guard let url = comp.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        return Task { [weak self] in
            guard let self else { return }
            do {
                // 流专用会话：25 秒无数据就断开，交给重连。普通请求不受影响
                let (bytes, resp) = try await self.streamSession.bytes(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    onClose(); return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = json.data(using: .utf8) else { continue }
                    if let ev = try? JSONDecoder().decode(ChatEvent.self, from: data) {
                        onEvent(ev)
                        if ev.type == "end" { break }
                    }
                }
            } catch {
                // 网络中断 / 取消
            }
            onClose()
        }
    }
}

struct EmptyResponse: Decodable {}
