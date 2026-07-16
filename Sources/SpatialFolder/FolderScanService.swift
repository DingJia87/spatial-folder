import Foundation

/// 后台扫描得到的轻量文件信息。这里故意不包含 `NSImage`，避免把 AppKit 图像跨线程传递。
struct ScannedFolderEntry: Equatable, Sendable {
    let url: URL
    let tags: [String]
    let resourceID: String?
}

/// 只负责读取所选文件夹的第一级内容，不接触布局和界面状态。
struct FolderDirectoryScanner: Sendable {
    func scan(folder: URL) throws -> [ScannedFolderEntry] {
        let keys: Set<URLResourceKey> = [
            .isHiddenKey,
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
                tags: values?.tagNames ?? [],
                resourceID: persistentResourceIdentifier(values)
            ))
        }
        return entries.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    /// 文件系统资源标识用于在 Finder 外部改名后找回原来的画布位置。
    private func persistentResourceIdentifier(_ values: URLResourceValues?) -> String? {
        guard let fileID = values?.fileResourceIdentifier else { return nil }
        let volumeID = values?.volumeIdentifier.map { String(describing: $0) } ?? "unknown-volume"
        return "\(volumeID)|\(String(describing: fileID))"
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
}
