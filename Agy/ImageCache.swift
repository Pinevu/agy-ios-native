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
}
