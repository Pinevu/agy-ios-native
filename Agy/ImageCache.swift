import UIKit

/// 跨视图共享的图片缓存。APIClient 里那份是 NSCache（异步取用），
/// 这里再包一层同步查询，用于「命中就立刻显示，不闪 loading」。
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 240
        cache.totalCostLimit = 220 * 1024 * 1024   // 220 MB
    }

    private func key(_ path: String, _ taskId: String?) -> NSString {
        "\(taskId ?? "")|\(path)" as NSString
    }

    func get(_ path: String, taskId: String?) -> UIImage? {
        cache.object(forKey: key(path, taskId))
    }

    func set(_ img: UIImage, for path: String, taskId: String?) {
        cache.setObject(img, forKey: key(path, taskId))
    }

    // MARK: - 本地附件解码缓存

    /// 用户发的图片存在 Data 里。每帧 body 都 `UIImage(data:)` 会反复解码几 MB 的 JPEG，
    /// 长会话里就是肉眼可见的卡顿。用「长度 + 首尾字节指纹」做键，避免整段哈希。
    private let blobCache = NSCache<NSString, UIImage>()

    private func blobKey(_ data: Data) -> NSString {
        var h: UInt64 = 1469598103934665603
        let head = data.prefix(256)
        let tail = data.suffix(256)
        for b in head { h = (h ^ UInt64(b)) &* 1099511628211 }
        for b in tail { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(data.count)-\(String(h, radix: 16))" as NSString
    }

    /// 同步解码本地附件；命中缓存直接返回，不再重新解码
    func decoded(_ data: Data) -> UIImage? {
        let k = blobKey(data)
        if let hit = blobCache.object(forKey: k) { return hit }
        guard let img = UIImage(data: data) else { return nil }
        blobCache.setObject(img, forKey: k, cost: data.count)
        return img
    }
}
