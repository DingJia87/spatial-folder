import Darwin
import Foundation

/// 后台扫描得到的轻量文件信息。这里故意不包含 `NSImage`，避免把 AppKit 图像跨线程传递。
struct ScannedFolderEntry: Equatable, Sendable {
    let url: URL
    let tags: [String]
    let resourceID: String?
    let isDirectory: Bool
}

/// 只负责读取所选文件夹的第一级内容，不接触布局和界面状态。
struct FolderDirectoryScanner: Sendable {
    func scan(folder: URL) throws -> [ScannedFolderEntry] {
        let keys: Set<URLResourceKey> = [
            .isHiddenKey,
            .isDirectoryKey,
            .tagNamesKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var entries: [ScannedFolderEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isHidden != true else { continue }
            entries.append(ScannedFolderEntry(
                url: url,
                tags: finderTags(at: url, fallback: values?.tagNames ?? []),
                resourceID: persistentResourceIdentifier(values),
                isDirectory: values?.isDirectory == true
            ))
        }
        return entries.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    /// 监听能力不可用时只复核标签，不重复读取图标、布局或资源标识。
    func scanTags(for urls: [URL]) -> [String: [String]] {
        urls.reduce(into: [:]) { result, url in
            let fallback = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            result[url.path] = finderTags(at: url, fallback: fallback)
        }
    }

    /// 文件系统资源标识用于在 Finder 外部改名后找回原来的画布位置。
    private func persistentResourceIdentifier(_ values: URLResourceValues?) -> String? {
        guard let fileID = values?.fileResourceIdentifier else { return nil }
        let volumeID = values?.volumeIdentifier.map { String(describing: $0) } ?? "unknown-volume"
        return "\(volumeID)|\(String(describing: fileID))"
    }

    /// `URLResourceValues.tagNames` 只返回标签名称，会丢失 Finder 的颜色编号。
    /// 原生扩展属性是二进制 plist；读取失败时回退到系统 API 的名称结果。
    private func finderTags(at url: URL, fallback: [String]) -> [String] {
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return fallback }

        var bytes = [UInt8](repeating: 0, count: size)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            getxattr(url.path, attribute, buffer.baseAddress, size, 0, 0)
        }
        guard readCount == size,
              let tags = try? PropertyListSerialization.propertyList(
                from: Data(bytes),
                options: [],
                format: nil
              ) as? [String] else { return fallback }
        return tags
    }
}

/// Actor 保证多次刷新按顺序执行，并让目录 I/O 离开主线程。
actor FolderScanService {
    private let scanner: FolderDirectoryScanner

    init(scanner: FolderDirectoryScanner = FolderDirectoryScanner()) {
        self.scanner = scanner
    }

    func scan(folder: URL) throws -> [ScannedFolderEntry] {
        try scanner.scan(folder: folder)
    }

    func scanTags(for urls: [URL]) -> [String: [String]] {
        scanner.scanTags(for: urls)
    }
}
