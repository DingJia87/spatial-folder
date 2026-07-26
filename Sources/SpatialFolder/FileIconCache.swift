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

    func icon(for url: URL, folderTagColor: FinderTagColor? = nil) -> NSImage {
        let variant = folderTagColor.map { "tag-\($0.rawValue)" } ?? "base"
        let key = "\(url.path)|\(variant)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let baseIcon = NSWorkspace.shared.icon(forFile: url.path)
        let icon = folderTagColor.map {
            tintedFolderIcon(baseIcon, color: nsColor(for: $0))
        } ?? baseIcon
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// 同一路径的文件被外部替换后，主动丢弃旧图标以免显示过期类型。
    func invalidate(_ url: URL) {
        // 变体键包含标签颜色，无法只移除一个固定键；替换文件是低频操作，整体清理更可靠。
        cache.removeAllObjects()
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private func tintedFolderIcon(_ baseIcon: NSImage, color: NSColor) -> NSImage {
        let image = NSImage(size: baseIcon.size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: baseIcon.size)
        baseIcon.draw(in: bounds)
        color.withAlphaComponent(0.72).setFill()
        bounds.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func nsColor(for color: FinderTagColor) -> NSColor {
        switch color {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
}
