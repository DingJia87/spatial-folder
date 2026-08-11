import Foundation

enum FileTransferSourceScope: Equatable, Sendable {
    case externalAllowed
    case currentFolderOnly
}

/// 真实文件操作的最后一道边界检查。不解析符号链接，因为画布允许操作作为
/// 当前文件夹直接子项存在的符号链接本身，而不是它指向的外部目标。
extension FileOperationPathValidator {
    static func validatedItemName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw FileOperationSafetyError.invalidItemName
        }
        return name
    }

    static func renameDestination(
        for itemURL: URL,
        name rawName: String,
        in authorizedFolder: URL
    ) throws -> (name: String, destination: URL) {
        let requestedFolder = authorizedFolder.standardizedFileURL
        let folder = requestedFolder.resolvingSymlinksInPath()
        let source = itemURL.standardizedFileURL
        guard source.deletingLastPathComponent().resolvingSymlinksInPath() == folder else {
            throw FileOperationSafetyError.sourceOutsideAuthorizedFolder
        }

        let name = try validatedItemName(rawName)
        let destination = requestedFolder.appendingPathComponent(name).standardizedFileURL
        guard destination.deletingLastPathComponent().resolvingSymlinksInPath() == folder
        else {
            throw FileOperationSafetyError.destinationOutsideAuthorizedFolder
        }
        return (name, destination)
    }

    static func validateTransferPlans(
        _ plans: [FileTransferPlan],
        authorization: FileOperationAuthorizationContext,
        sourceScope: FileTransferSourceScope = .externalAllowed
    ) throws {
        let destinationFolder = authorization.folder
        for plan in plans {
            guard isDirectChild(plan.destination, of: destinationFolder) else {
                throw FileOperationSafetyError.destinationOutsideAuthorizedFolder
            }
            if sourceScope == .currentFolderOnly {
                guard isDirectChild(plan.source, of: destinationFolder) else {
                    throw FileOperationSafetyError.sourceOutsideAuthorizedFolder
                }
            }
        }
    }

    static func validateCompressionPlans(
        _ plans: [FileCompressionPlan],
        authorization: FileOperationAuthorizationContext
    ) throws {
        try validateSources(plans.map(\.source), authorization: authorization)
        try validateDestinations(plans.map(\.destination), authorization: authorization)
    }

}

struct FileInfoSnapshot: Equatable, Sendable {
    var size: Int64
    var modificationDate: Date?
}

/// 短时文件系统读取与目标规划仓库。它与主模型隔离，避免 `fileExists`、属性读取和批量
/// 目标命名随着目录规模或网络磁盘延迟而卡住 UI。
actor FolderAccessRepository {
    private static let incompleteDownloadExtensions: Set<String> = [
        "crdownload", "download", "icloud", "part"
    ]

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

    /// 返回桌面第一级可安全收纳的可见项目。文件夹作为整体返回，不递归拆分其内容。
    ///
    /// 如果目标空间位于桌面某个项目内部，该祖先项目必须排除，否则会尝试把目标移入自身。
    func desktopCollectionSources(
        in desktopDirectory: URL,
        destinationFolder: URL
    ) throws -> [URL] {
        let desktop = desktopDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationFolder.standardizedFileURL.resolvingSymlinksInPath()
        guard desktop != destination else { return [] }

        let candidates = try fileManager.contentsOfDirectory(
            at: desktop,
            includingPropertiesForKeys: [.isHiddenKey],
            options: [.skipsHiddenFiles]
        )
        return candidates.filter { candidate in
            let source = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let values = try? source.resourceValues(forKeys: [.isHiddenKey])
            guard values?.isHidden != true, !source.lastPathComponent.hasPrefix(".") else {
                return false
            }
            guard !Self.incompleteDownloadExtensions.contains(source.pathExtension.lowercased()) else {
                return false
            }
            guard source != destination else { return false }
            let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
            return !destination.path.hasPrefix(sourcePrefix)
        }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
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
