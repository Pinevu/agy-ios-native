import Foundation

/// 统一 DeepLink 路由器：处理小组件、灵动岛、Siri 快捷指令与外部 URL Scheme（antigravity:// / agy://）
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    enum Route: Equatable {
        case open
        case newChat(prompt: String?, autoSend: Bool)
        case session(id: String)
        case voice
        case jobs
        case skills
        case quota
    }

    @Published var pending: Route?

    private init() {}

    func enqueue(_ route: Route) {
        pending = route
    }

    func consume() -> Route? {
        defer { pending = nil }
        return pending
    }

    /// 解析如下链接格式：
    /// - antigravity://session/<id>
    /// - antigravity://new?prompt=xxx&autosend=1
    /// - antigravity://voice
    /// - antigravity://jobs
    /// - antigravity://skills
    /// - antigravity://quota
    func handle(url: URL) {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let host = (comp.host ?? "").lowercased()
        let parts = comp.path.split(separator: "/").map(String.init)
        let query = Dictionary(uniqueKeysWithValues: (comp.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") })

        if let sid = query["session"], !sid.isEmpty {
            enqueue(.session(id: sid))
            return
        }

        switch host {
        case "session":
            if let sid = parts.first, !sid.isEmpty {
                enqueue(.session(id: sid))
            } else {
                enqueue(.open)
            }
        case "new", "ask":
            let prompt = query["prompt"]
            let auto = query["autosend"] == "1" || query["autosend"] == "true"
            enqueue(.newChat(prompt: prompt?.isEmpty == true ? nil : prompt, autoSend: auto))
        case "voice":
            enqueue(.voice)
        case "jobs":
            enqueue(.jobs)
        case "skills":
            enqueue(.skills)
        case "quota":
            enqueue(.quota)
        default:
            if let prompt = query["prompt"], !prompt.isEmpty {
                let auto = query["autosend"] == "1" || query["autosend"] == "true"
                enqueue(.newChat(prompt: prompt, autoSend: auto))
            } else {
                enqueue(.open)
            }
        }
    }
}
