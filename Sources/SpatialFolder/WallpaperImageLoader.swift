import AppKit
import Foundation
import ImageIO

/// 壁纸加载请求。像素尺寸按档位取整，避免窗口每变化 1 像素就产生一份新缓存。
struct WallpaperImageRequest: Hashable, Sendable {
    let url: URL
    let maximumPixelSize: Int

    init(url: URL, requestedPixelSize: CGFloat) {
        self.url = url.standardizedFileURL
        let clamped = min(max(512, Int(requestedPixelSize.rounded(.up))), 8_192)
        maximumPixelSize = ((clamped + 255) / 256) * 256
    }

    var cacheKey: String { "\(url.path)|\(maximumPixelSize)" }
}

/// 在后台解码并缩小壁纸，避免 SwiftUI 每次刷新都在主线程读取完整原图。
actor WallpaperImageLoader {
    static let shared = WallpaperImageLoader()

    private var cache: [String: CGImage] = [:]
    private var insertionOrder: [String] = []
    private let maximumCacheCount = 8

    func image(for request: WallpaperImageRequest) -> CGImage? {
        if let cached = cache[request.cacheKey] { return cached }
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: request.maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        cache[request.cacheKey] = image
        insertionOrder.append(request.cacheKey)
        while insertionOrder.count > maximumCacheCount {
            let removed = insertionOrder.removeFirst()
            cache.removeValue(forKey: removed)
        }
        return image
    }

    func removeAll() {
        cache.removeAll()
        insertionOrder.removeAll()
    }
}
