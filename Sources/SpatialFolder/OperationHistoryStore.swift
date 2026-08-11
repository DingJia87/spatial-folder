import Darwin
import Foundation

func writeFinderTags(_ tags: [String], to url: URL) throws {
    if tags.isEmpty {
        try removeExtendedAttributeIfPresent("com.apple.metadata:_kMDItemUserTags", at: url)
        try clearFinderInfoLabel(at: url)
    } else {
        try (url as NSURL).setResourceValue(tags, forKey: URLResourceKey.tagNamesKey)
    }
}

private func removeExtendedAttributeIfPresent(_ name: String, at url: URL) throws {
    let result = removexattr(url.path, name, 0)
    if result != 0, errno != ENOATTR {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func clearFinderInfoLabel(at url: URL) throws {
    let name = "com.apple.FinderInfo"
    let size = getxattr(url.path, name, nil, 0, 0, 0)
    if size < 0 {
        if errno == ENOATTR { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    guard size >= 10 else { return }
    var bytes = [UInt8](repeating: 0, count: size)
    let readCount = bytes.withUnsafeMutableBytes { buffer in
        getxattr(url.path, name, buffer.baseAddress, size, 0, 0)
    }
    guard readCount == size else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let flags = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
    let clearedFlags = flags & ~UInt16(0x000E)
    bytes[8] = UInt8((clearedFlags >> 8) & 0x00FF)
    bytes[9] = UInt8(clearedFlags & 0x00FF)

    if bytes.allSatisfy({ $0 == 0 }) {
        try removeExtendedAttributeIfPresent(name, at: url)
    } else {
        let written = bytes.withUnsafeBytes { buffer in
            setxattr(url.path, name, buffer.baseAddress, size, 0, 0)
        }
        if written != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

enum OperationCategory: String, Codable, Sendable {
    case file
    case layout
}

enum OperationKind: String, Codable, CaseIterable, Sendable {
    case layout
    case rename
    case trash
    case createFolder
    case createDocument
    case duplicate
    case copyItems
    case moveItems
    case compress
    case tags

    var title: String {
        switch self {
        case .layout: "画布布局"
        case .rename: "重命名"
        case .trash: "移至废纸篓"
        case .createFolder: "新建文件夹"
        case .createDocument: "新建文档"
        case .duplicate: "制作副本"
        case .copyItems: "复制到空间"
        case .moveItems: "移动到空间"
        case .compress: "压缩"
        case .tags: "修改标签"
        }
    }
}

enum OperationState: String, Codable, Sendable {
    case pending
    case undoing
    case redoing
    case applied
    case undone
    case superseded
    case failed
    case unavailable
    case archived
    case viewOnly

    var title: String {
        switch self {
        case .pending: "进行中"
        case .undoing: "正在撤销"
        case .redoing: "正在重做"
        case .applied: "已完成"
        case .undone: "已撤销"
        case .superseded: "已失效"
        case .failed: "失败"
        case .unavailable: "需核对"
        case .archived: "已存档"
        case .viewOnly: "仅可查看"
        }
    }
}

enum ConflictChoice: Equatable, Sendable {
    case keepBoth
    case replace
    case cancel
}

struct DiagnosticOperation: Codable, Equatable, Sendable {
    var category: OperationCategory
    var kind: OperationKind
    var state: OperationState
    var occurredAt: Date
    var actionCount: Int
    var errorType: String?
}

struct PrivacySafeDiagnostics: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var generatedAt: Date
    var appVersion: String
    var macOSVersion: String
    var logicalCanvasSize: CanvasDimensions
    var currentDisplaySize: CanvasDimensions
    var visibleItemCount: Int
    var inboxItemCount: Int
    var operationCount: Int
    var recentOperations: [DiagnosticOperation]
}

struct RelocateAction: Codable, Equatable, Sendable {
    var originalPath: String
    var destinationPath: String
}

struct MaterializeAction: Codable, Equatable, Sendable {
    var destinationPath: String
    var undoTrashPath: String?
}

struct DiscardAction: Codable, Equatable, Sendable {
    var originalPath: String
    var trashPath: String?
}

struct TagAction: Codable, Equatable, Sendable {
    var path: String
    var before: [String]
    var after: [String]
}

enum ReversibleFileAction: Codable, Equatable, Sendable {
    case relocate(RelocateAction)
    case materialize(MaterializeAction)
    case discard(DiscardAction)
    case tags(TagAction)
}

struct ConflictDisplacement: Codable, Equatable, Sendable {
    var originalPath: String
    var trashPath: String
    var createdInState: OperationState
}

struct OperationCanvasItem: Codable, Equatable, Sendable {
    var actionIndex: Int
    var position: CanvasPoint?
    var scale: CGFloat?
    var wasInInbox: Bool
}

struct OperationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var category: OperationCategory
    var kind: OperationKind
    var summary: String
    var itemNames: [String]
    var performedAt: Date
    var transitionDate: Date
    var state: OperationState
    var actions: [ReversibleFileAction]
    var displacements: [ConflictDisplacement]
    var canvasItems: [OperationCanvasItem]
    var detail: String?

    init(
        id: UUID = UUID(),
        category: OperationCategory,
        kind: OperationKind,
        summary: String,
        itemNames: [String] = [],
        performedAt: Date = Date(),
        transitionDate: Date? = nil,
        state: OperationState = .pending,
        actions: [ReversibleFileAction] = [],
        displacements: [ConflictDisplacement] = [],
        canvasItems: [OperationCanvasItem] = [],
        detail: String? = nil
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.summary = summary
        self.itemNames = itemNames
        self.performedAt = performedAt
        self.transitionDate = transitionDate ?? performedAt
        self.state = state
        self.actions = actions
        self.displacements = displacements
        self.canvasItems = canvasItems
        self.detail = detail
    }

    var isFileReversible: Bool {
        category == .file && !actions.isEmpty && (state == .applied || state == .undone)
    }
}

extension FileOperationPathValidator {
    /// 撤销/重做允许“外部来源 ↔ 当前空间”的搬移记录，但每个动作必须至少有一端属于
    /// 当前空间；新建、删除和标签动作则只能指向当前空间的第一层项目。
    static func validateTransitionRecord(
        _ record: OperationRecord,
        authorization: FileOperationAuthorizationContext
    ) throws -> [URL] {
        let folder = authorization.folder
        var authorizedEndpoints = Set<String>()
        var trashURLs: [URL] = []

        for action in record.actions {
            switch action {
            case let .relocate(value):
                let original = URL(fileURLWithPath: value.originalPath).standardizedFileURL
                let destination = URL(fileURLWithPath: value.destinationPath).standardizedFileURL
                guard isDirectChild(original, of: folder) || isDirectChild(destination, of: folder) else {
                    throw FileOperationSafetyError.sourceOutsideAuthorizedFolder
                }
                authorizedEndpoints.insert(original.path)
                authorizedEndpoints.insert(destination.path)

            case let .materialize(value):
                let destination = URL(fileURLWithPath: value.destinationPath).standardizedFileURL
                guard isDirectChild(destination, of: folder) else {
                    throw FileOperationSafetyError.destinationOutsideAuthorizedFolder
                }
                authorizedEndpoints.insert(destination.path)
                if let path = value.undoTrashPath {
                    trashURLs.append(URL(fileURLWithPath: path))
                }

            case let .discard(value):
                let original = URL(fileURLWithPath: value.originalPath).standardizedFileURL
                guard isDirectChild(original, of: folder) else {
                    throw FileOperationSafetyError.sourceOutsideAuthorizedFolder
                }
                authorizedEndpoints.insert(original.path)
                if let path = value.trashPath {
                    trashURLs.append(URL(fileURLWithPath: path))
                }

            case let .tags(value):
                let url = URL(fileURLWithPath: value.path).standardizedFileURL
                guard isDirectChild(url, of: folder) else {
                    throw FileOperationSafetyError.sourceOutsideAuthorizedFolder
                }
                authorizedEndpoints.insert(url.path)
            }
        }

        for displacement in record.displacements {
            let original = URL(fileURLWithPath: displacement.originalPath).standardizedFileURL
            guard authorizedEndpoints.contains(original.path) else {
                throw FileOperationSafetyError.destinationOutsideAuthorizedFolder
            }
            trashURLs.append(URL(fileURLWithPath: displacement.trashPath))
        }
        return trashURLs
    }
}

struct OperationHistoryDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var records: [OperationRecord] = []
}

enum OperationHistoryStoreError: LocalizedError {
    case corruptHistory

    var errorDescription: String? {
        switch self {
        case .corruptHistory:
            "操作记录无法读取。原记录已保留；在修复前，真实文件修改已被阻止。"
        }
    }
}

struct OperationHistoryStore {
    let directory: URL
    let maximumRecords: Int

    init(directory: URL? = nil, maximumRecords: Int = 200) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("SpatialFolder/Operations", isDirectory: true)
        }
        self.maximumRecords = max(20, maximumRecords)
    }

    func historyURL(canvasKey: String) -> URL {
        directory.appendingPathComponent(canvasKey).appendingPathExtension("json")
    }

    func load(canvasKey: String) throws -> OperationHistoryDocument {
        let url = historyURL(canvasKey: canvasKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 测试工具和 2.4 兼容调用仍可读取已经迁移到 2.5 的快照与日志。
            return try OperationJournalDiskStore(legacyStore: self)
                .load(canvasKey: canvasKey, migrateLegacy: false)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(OperationHistoryDocument.self, from: Data(contentsOf: url)) else {
            throw OperationHistoryStoreError.corruptHistory
        }
        return document
    }

    func save(_ document: OperationHistoryDocument, canvasKey: String) throws {
        var trimmed = document
        if trimmed.records.count > maximumRecords {
            trimmed.records = Array(trimmed.records.suffix(maximumRecords))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoderCompatibleData = try encoder.encode(trimmed)
        try decoderCompatibleData.write(to: historyURL(canvasKey: canvasKey), options: .atomic)
    }

    func archiveCorruptHistoryAndReset(canvasKey: String) throws -> URL {
        let source = historyURL(canvasKey: canvasKey)
        let corruptDirectory = directory.appendingPathComponent("Corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let stamp = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds)
        let archive = corruptDirectory.appendingPathComponent("\(canvasKey)-\(stamp).json")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: archive)
        } else {
            try Data().write(to: archive)
        }
        try save(OperationHistoryDocument(), canvasKey: canvasKey)
        return archive
    }
}

struct FileOperationConflict: LocalizedError, Equatable, Sendable {
    let targetPath: String
    let operationSummary: String

    var errorDescription: String? {
        "“\(URL(fileURLWithPath: targetPath).lastPathComponent)”已经存在。"
    }
}

enum FileOperationTransitionError: LocalizedError {
    case invalidState
    case missingSource(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidState:
            "这个操作当前不能撤销或重做。"
        case let .missingSource(path):
            "找不到“\(URL(fileURLWithPath: path).lastPathComponent)”，它可能已在其他应用中移动或删除。"
        case .cancelled:
            "操作已取消。"
        }
    }
}

/// `FileManager` 的公开文件操作可跨线程调用；本类型的配置在初始化后不再修改，
/// 并且 2.4 的协调器保证同一画布只有一个真实文件事务执行，因此可安全传入后台 Actor。
struct FileOperationEngine: @unchecked Sendable {
    var fileManager: FileManager = .default
    var trashDirectoryForTesting: URL?

    func moveToTrash(
        _ url: URL,
        authorization: FileOperationAuthorizationContext
    ) throws -> URL {
        try FileOperationPathValidator.validateSources([url], authorization: authorization)
        return try trashItem(at: url)
    }

    func transition(
        _ record: OperationRecord,
        to targetState: OperationState,
        conflictChoice: ConflictChoice,
        authorization: FileOperationAuthorizationContext
    ) throws -> OperationRecord {
        guard record.category == .file,
              (record.state == .applied && targetState == .undone) ||
                (record.state == .undone && targetState == .applied) else {
            throw FileOperationTransitionError.invalidState
        }
        let trashURLs = try FileOperationPathValidator.validateTransitionRecord(
            record,
            authorization: authorization
        )
        try validateTrustedTrashLocations(trashURLs)
        try preflight(record, to: targetState, conflictChoice: conflictChoice)
        var updated = record
        let previousState = record.state
        let indexes = targetState == .undone
            ? Array(updated.actions.indices.reversed())
            : Array(updated.actions.indices)

        for index in indexes {
            updated.actions[index] = try transitionAction(
                updated.actions[index],
                to: targetState,
                conflictChoice: conflictChoice,
                summary: updated.summary,
                displacements: &updated.displacements
            )
        }

        var retainedDisplacements: [ConflictDisplacement] = []
        for displacement in updated.displacements {
            guard displacement.createdInState == previousState else {
                retainedDisplacements.append(displacement)
                continue
            }
            var destination = URL(fileURLWithPath: displacement.originalPath)
            destination = try resolvedDestination(
                destination,
                choice: conflictChoice,
                summary: updated.summary,
                state: targetState,
                displacements: &retainedDisplacements
            )
            let source = URL(fileURLWithPath: displacement.trashPath)
            guard fileManager.fileExists(atPath: source.path) else {
                throw FileOperationTransitionError.missingSource(source.path)
            }
            try fileManager.moveItem(at: source, to: destination)
        }

        updated.displacements = retainedDisplacements
        updated.state = targetState
        updated.transitionDate = Date()
        updated.detail = nil
        return updated
    }

    private func validateTrustedTrashLocations(_ urls: [URL]) throws {
        let testingDirectory = trashDirectoryForTesting?
            .standardizedFileURL
            .resolvingSymlinksInPath()
        for url in urls where fileManager.fileExists(atPath: url.path) {
            let parent = url.standardizedFileURL
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
            if let testingDirectory,
               parent == testingDirectory {
                continue
            }

            let homeTrash = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if parent == homeTrash { continue }

            let userTrash = try? fileManager.url(
                for: .trashDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).standardizedFileURL
                .resolvingSymlinksInPath()
            if let userTrash, parent == userTrash { continue }

            if let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
               parent == volume
                    .appendingPathComponent(".Trashes", isDirectory: true)
                    .appendingPathComponent(String(getuid()), isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath() {
                continue
            }
            throw FileOperationSafetyError.untrustedTrashLocation
        }
    }

    private func preflight(
        _ record: OperationRecord,
        to targetState: OperationState,
        conflictChoice: ConflictChoice
    ) throws {
        let indexes = targetState == .undone
            ? Array(record.actions.indices.reversed())
            : Array(record.actions.indices)
        let paths = record.actions.flatMap(actionPaths) + record.displacements.flatMap {
            [$0.originalPath, $0.trashPath]
        }
        let trackedPaths = Set(paths)
        var exists = Set(paths.filter { fileManager.fileExists(atPath: $0) })

        func virtuallyExists(_ path: String) -> Bool {
            trackedPaths.contains(path) ? exists.contains(path) : fileManager.fileExists(atPath: path)
        }

        func requireSource(_ path: String) throws {
            guard virtuallyExists(path) else {
                throw FileOperationTransitionError.missingSource(path)
            }
        }

        func requireDestination(_ path: String) throws {
            guard conflictChoice == .cancel,
                  virtuallyExists(path) else { return }
            throw FileOperationConflict(targetPath: path, operationSummary: record.summary)
        }

        for index in indexes {
            switch record.actions[index] {
            case let .relocate(value):
                let source = targetState == .undone ? value.destinationPath : value.originalPath
                let destination = targetState == .undone ? value.originalPath : value.destinationPath
                try requireSource(source)
                try requireDestination(destination)
                exists.remove(source)
                exists.insert(destination)
            case let .materialize(value):
                if targetState == .undone {
                    try requireSource(value.destinationPath)
                    exists.remove(value.destinationPath)
                } else {
                    guard let source = value.undoTrashPath else {
                        throw FileOperationTransitionError.missingSource(value.destinationPath)
                    }
                    try requireSource(source)
                    try requireDestination(value.destinationPath)
                    exists.remove(source)
                    exists.insert(value.destinationPath)
                }
            case let .discard(value):
                if targetState == .undone {
                    guard let source = value.trashPath else {
                        throw FileOperationTransitionError.missingSource(value.originalPath)
                    }
                    try requireSource(source)
                    try requireDestination(value.originalPath)
                    exists.remove(source)
                    exists.insert(value.originalPath)
                } else {
                    try requireSource(value.originalPath)
                    exists.remove(value.originalPath)
                }
            case let .tags(value):
                try requireSource(value.path)
            }
        }

        for displacement in record.displacements where displacement.createdInState == record.state {
            try requireSource(displacement.trashPath)
            try requireDestination(displacement.originalPath)
            exists.remove(displacement.trashPath)
            exists.insert(displacement.originalPath)
        }
    }

    private func actionPaths(_ action: ReversibleFileAction) -> [String] {
        switch action {
        case let .relocate(value): [value.originalPath, value.destinationPath]
        case let .materialize(value): [value.destinationPath] + (value.undoTrashPath.map { [$0] } ?? [])
        case let .discard(value): [value.originalPath] + (value.trashPath.map { [$0] } ?? [])
        case let .tags(value): [value.path]
        }
    }

    private func transitionAction(
        _ action: ReversibleFileAction,
        to targetState: OperationState,
        conflictChoice: ConflictChoice,
        summary: String,
        displacements: inout [ConflictDisplacement]
    ) throws -> ReversibleFileAction {
        switch action {
        case var .relocate(value):
            let sourcePath = targetState == .undone ? value.destinationPath : value.originalPath
            var destination = URL(fileURLWithPath: targetState == .undone ? value.originalPath : value.destinationPath)
            let source = URL(fileURLWithPath: sourcePath)
            guard fileManager.fileExists(atPath: source.path) else {
                throw FileOperationTransitionError.missingSource(source.path)
            }
            destination = try resolvedDestination(
                destination,
                choice: conflictChoice,
                summary: summary,
                state: targetState,
                displacements: &displacements
            )
            try fileManager.moveItem(at: source, to: destination)
            if targetState == .undone { value.originalPath = destination.path }
            else { value.destinationPath = destination.path }
            return .relocate(value)

        case var .materialize(value):
            let destination = URL(fileURLWithPath: value.destinationPath)
            if targetState == .undone {
                guard fileManager.fileExists(atPath: destination.path) else {
                    throw FileOperationTransitionError.missingSource(destination.path)
                }
                value.undoTrashPath = try trashItem(at: destination).path
            } else {
                guard let trashPath = value.undoTrashPath else {
                    throw FileOperationTransitionError.missingSource(value.destinationPath)
                }
                let source = URL(fileURLWithPath: trashPath)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw FileOperationTransitionError.missingSource(source.path)
                }
                let resolved = try resolvedDestination(
                    destination,
                    choice: conflictChoice,
                    summary: summary,
                    state: targetState,
                    displacements: &displacements
                )
                try fileManager.moveItem(at: source, to: resolved)
                value.destinationPath = resolved.path
                value.undoTrashPath = nil
            }
            return .materialize(value)

        case var .discard(value):
            let original = URL(fileURLWithPath: value.originalPath)
            if targetState == .undone {
                guard let trashPath = value.trashPath else {
                    throw FileOperationTransitionError.missingSource(value.originalPath)
                }
                let source = URL(fileURLWithPath: trashPath)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw FileOperationTransitionError.missingSource(source.path)
                }
                let destination = try resolvedDestination(
                    original,
                    choice: conflictChoice,
                    summary: summary,
                    state: targetState,
                    displacements: &displacements
                )
                try fileManager.moveItem(at: source, to: destination)
                value.originalPath = destination.path
            } else {
                guard fileManager.fileExists(atPath: original.path) else {
                    throw FileOperationTransitionError.missingSource(original.path)
                }
                value.trashPath = try trashItem(at: original).path
            }
            return .discard(value)

        case let .tags(value):
            let url = URL(fileURLWithPath: value.path)
            guard fileManager.fileExists(atPath: url.path) else {
                throw FileOperationTransitionError.missingSource(url.path)
            }
            let tags = targetState == .undone ? value.before : value.after
            try writeFinderTags(tags, to: url)
            return action
        }
    }

    private func resolvedDestination(
        _ requested: URL,
        choice: ConflictChoice,
        summary: String,
        state: OperationState,
        displacements: inout [ConflictDisplacement]
    ) throws -> URL {
        guard fileManager.fileExists(atPath: requested.path) else { return requested }
        switch choice {
        case .cancel:
            throw FileOperationConflict(targetPath: requested.path, operationSummary: summary)
        case .keepBoth:
            return uniqueDestination(for: requested)
        case .replace:
            let trashPath = try trashItem(at: requested).path
            displacements.append(ConflictDisplacement(
                originalPath: requested.path,
                trashPath: trashPath,
                createdInState: state
            ))
            return requested
        }
    }

    func uniqueDestination(for requested: URL) -> URL {
        let folder = requested.deletingLastPathComponent()
        let extensionName = requested.pathExtension
        let baseName = requested.deletingPathExtension().lastPathComponent
        var index = 2
        var target = requested
        while fileManager.fileExists(atPath: target.path) {
            let name = extensionName.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(extensionName)"
            target = folder.appendingPathComponent(name)
            index += 1
        }
        return target
    }

    private func trashItem(at url: URL) throws -> URL {
        if let trashDirectoryForTesting {
            try fileManager.createDirectory(at: trashDirectoryForTesting, withIntermediateDirectories: true)
            let destination = uniqueDestination(
                for: trashDirectoryForTesting.appendingPathComponent(url.lastPathComponent)
            )
            try fileManager.moveItem(at: url, to: destination)
            return destination
        }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let result = resultingURL as URL? else {
            throw FileOperationTransitionError.missingSource(url.path)
        }
        return result
    }
}
