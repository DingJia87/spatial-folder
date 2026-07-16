import Foundation

struct FileInfoSnapshot: Equatable, Sendable {
    var size: Int64
    var modificationDate: Date?
}

/// 短时文件系统读取与目标规划仓库。它与主模型隔离，避免 `fileExists`、属性读取和批量
/// 目标命名随着目录规模或网络磁盘延迟而卡住 UI。
actor FolderAccessRepository {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func containsNameConflict(sources: [URL], destinationFolder: URL) -> Bool {
        sources.contains {
            fileManager.fileExists(atPath: destinationFolder.appendingPathComponent($0.lastPathComponent).path)
        }
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func uniqueDestination(
        for source: URL,
        in folder: URL,
        excluding reservedPaths: Set<String> = []
    ) -> URL {
        let extensionName = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        var index = 1
        var target = folder.appendingPathComponent(source.lastPathComponent)
        while fileManager.fileExists(atPath: target.path) || reservedPaths.contains(target.path) {
            index += 1
            target = folder.appendingPathComponent("\(baseName) \(index)").appendingPathExtension(extensionName)
        }
        return target
    }

    func uniqueNamedItem(in folder: URL, baseName: String, fileExtension: String? = nil) -> URL {
        var index = 1
        func candidate(_ index: Int) -> URL {
            let suffix = index == 1 ? "" : " \(index)"
            let base = folder.appendingPathComponent("\(baseName)\(suffix)")
            guard let fileExtension else { return base }
            return base.appendingPathExtension(fileExtension)
        }
        var result = candidate(index)
        while fileManager.fileExists(atPath: result.path) {
            index += 1
            result = candidate(index)
        }
        return result
    }

    func transferPlans(
        sources: [URL],
        destinationFolder: URL,
        move: Bool,
        policy: ConflictChoice
    ) -> [FileTransferPlan] {
        var reservedPaths = Set<String>()
        return sources.map { source in
            var destination = destinationFolder.appendingPathComponent(source.lastPathComponent)
            let collidesWithBatch = reservedPaths.contains(destination.path)
            let existsBeforeBatch = fileManager.fileExists(atPath: destination.path)
            var replacesExisting = false
            if collidesWithBatch || (existsBeforeBatch && policy == .keepBoth) {
                destination = uniqueDestination(for: source, in: destinationFolder, excluding: reservedPaths)
            } else if existsBeforeBatch && policy == .replace {
                replacesExisting = true
            }
            reservedPaths.insert(destination.path)
            return FileTransferPlan(
                source: source,
                destination: destination,
                move: move,
                replacesExistingDestination: replacesExisting
            )
        }
    }

    func duplicatePlans(for sources: [URL]) -> [FileTransferPlan] {
        var reservedPaths = Set<String>()
        return sources.map { source in
            let destination = uniqueDestination(
                for: source,
                in: source.deletingLastPathComponent(),
                excluding: reservedPaths
            )
            reservedPaths.insert(destination.path)
            return FileTransferPlan(
                source: source,
                destination: destination,
                move: false,
                replacesExistingDestination: false
            )
        }
    }

    func compressionPlans(for sources: [URL], destinationFolder: URL) -> [FileCompressionPlan] {
        var reservedPaths = Set<String>()
        return sources.map { source in
            let requested = destinationFolder
                .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("zip")
            let destination = uniqueDestination(
                for: requested,
                in: destinationFolder,
                excluding: reservedPaths
            )
            reservedPaths.insert(destination.path)
            return FileCompressionPlan(source: source, destination: destination)
        }
    }

    func attributes(of url: URL) throws -> FileInfoSnapshot {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return FileInfoSnapshot(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}
