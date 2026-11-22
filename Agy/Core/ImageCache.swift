import UIKit

/// 统一有界图片缓存：80MB 内存 + 40MB 附件解码缓存 + 60MB LRU 磁盘缓存 + 内存告警自动清理
final class ImageCache {
    static let shared = ImageCache()

    private let memCache = NSCache<NSString, UIImage>()
    private let blobCache = NSCache<NSString, UIImage>()
    private let diskQueue = DispatchQueue(label: "agy.imagecache.disk", qos: .utility)
    private let maxDiskBytes: Int = 60 * 1024 * 1024
    private var writesSincePrune = 0

    private lazy var diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agy-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        memCache.countLimit = 160
        memCache.totalCostLimit = 80 * 1024 * 1024

        blobCache.countLimit = 80
        blobCache.totalCostLimit = 40 * 1024 * 1024

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.memCache.removeAllObjects()
            self?.blobCache.removeAllObjects()
        }
    }

    // MARK: - 内存缓存（支持旧签名与新统一键）

    func get(key: String) -> UIImage? {
        memCache.object(forKey: key as NSString)
    }

    func set(_ img: UIImage, forKey key: String) {
        memCache.setObject(img, forKey: key as NSString, cost: imageCost(img))
    }

    private func legacyKey(_ path: String, _ taskId: String?, _ base: String) -> String {
        "\(base)|\(taskId ?? "")|\(path)"
    }

    func get(_ path: String, taskId: String?, base: String = APIClient.shared.baseURLString) -> UIImage? {
        get(key: legacyKey(path, taskId, base))
    }

    func set(_ img: UIImage, for path: String, taskId: String?, base: String = APIClient.shared.baseURLString) {
        set(img, forKey: legacyKey(path, taskId, base))
    }

    private func imageCost(_ img: UIImage) -> Int {
        guard let cg = img.cgImage else { return 512 * 1024 }
        return cg.bytesPerRow * cg.height
    }

    // MARK: - LRU 磁盘缓存

    private func diskURL(for key: String) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return diskDir.appendingPathComponent(String(h, radix: 16) + ".img")
    }

    func loadFromDisk(key: String) -> UIImage? {
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        // 更新修改时间用于 LRU
        diskQueue.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return img
    }

    func saveToDisk(_ data: Data, forKey key: String) {
        let url = diskURL(for: key)
        diskQueue.async { [weak self] in
            guard let self else { return }
            try? data.write(to: url, options: .atomic)
            self.writesSincePrune += 1
            if self.writesSincePrune >= 20 {
                self.writesSincePrune = 0
                self.pruneDiskIfNeeded()
            }
        }
    }

    private func pruneDiskIfNeeded() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: diskDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for u in urls {
            let rv = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sz = rv?.fileSize ?? 0
            let dt = rv?.contentModificationDate ?? .distantPast
            entries.append((u, sz, dt))
            total += sz
        }
        guard total > maxDiskBytes else { return }
        let target = Int(Double(maxDiskBytes) * 0.75)
        for item in entries.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: item.url)
            total -= item.size
            if total <= target { break }
        }
    }

    // MARK: - 本地附件解码缓存

    private func blobKey(_ data: Data) -> NSString {
        var h: UInt64 = 1469598103934665603
        for b in data.prefix(256) { h = (h ^ UInt64(b)) &* 1099511628211 }
        for b in data.suffix(256) { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(data.count)-\(String(h, radix: 16))" as NSString
    }

    func decoded(_ data: Data) -> UIImage? {
        let k = blobKey(data)
        if let hit = blobCache.object(forKey: k) { return hit }
        guard let img = UIImage(data: data) else { return nil }
        blobCache.setObject(img, forKey: k, cost: imageCost(img))
        return img
    }
}
