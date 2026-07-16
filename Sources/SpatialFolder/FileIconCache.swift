import AppKit
import Foundation

/// 主线程图标缓存。只有真正出现在画布或信息面板中的项目才会请求图标，
/// 因而包含数千个文件的目录不会在首次扫描时一次性加载全部图标。
@MainActor
final class FileIconCache {
    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int = 256) {
        cache.countLimit = max(64, countLimit)
    }

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// 同一路径的文件被外部替换后，主动丢弃旧图标以免显示过期类型。
    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url.path as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
