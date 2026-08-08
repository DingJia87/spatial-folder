import CryptoKit
import Foundation

struct CanvasPoint: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
}

struct CanvasDimensions: Codable, Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    var size: CGSize { CGSize(width: width, height: height) }
}

struct LayoutBackupMetadata: Codable, Equatable, Sendable {
    var createdAt: Date
    var reason: String
    var appVersion: String?
}

struct SavedCanvas: Codable, Equatable, Sendable {
    static let currentLayoutVersion = 5

    var layoutVersion: Int = currentLayoutVersion
    var positions: [String: CanvasPoint] = [:]
    var scales: [String: CGFloat] = [:]
    var wallpaperPath: String?
    var isLocked = false
    var inboxIDs: Set<String> = []
    var resourcePaths: [String: String] = [:]
    var canvasSize: CanvasDimensions?
    var rootResourceID: String?
    var backupMetadata: LayoutBackupMetadata?

    enum CodingKeys: String, CodingKey {
        case layoutVersion
        case positions
        case scales
        case wallpaperPath
        case isLocked
        case inboxIDs
        case resourcePaths
        case canvasSize
        case rootResourceID
        case backupMetadata
    }

    init(
        layoutVersion: Int = currentLayoutVersion,
        positions: [String: CanvasPoint] = [:],
        scales: [String: CGFloat] = [:],
        wallpaperPath: String? = nil,
        isLocked: Bool = false,
        inboxIDs: Set<String> = [],
        resourcePaths: [String: String] = [:],
        canvasSize: CanvasDimensions? = nil,
        rootResourceID: String? = nil,
        backupMetadata: LayoutBackupMetadata? = nil
    ) {
        self.layoutVersion = layoutVersion
        self.positions = positions
        self.scales = scales
        self.wallpaperPath = wallpaperPath
        self.isLocked = isLocked
        self.inboxIDs = inboxIDs
        self.resourcePaths = resourcePaths
        self.canvasSize = canvasSize
        self.rootResourceID = rootResourceID
        self.backupMetadata = backupMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layoutVersion = try container.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 1
        positions = try container.decodeIfPresent([String: CanvasPoint].self, forKey: .positions) ?? [:]
        scales = try container.decodeIfPresent([String: CGFloat].self, forKey: .scales) ?? [:]
        wallpaperPath = try container.decodeIfPresent(String.self, forKey: .wallpaperPath)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        inboxIDs = try container.decodeIfPresent(Set<String>.self, forKey: .inboxIDs) ?? []
        resourcePaths = try container.decodeIfPresent([String: String].self, forKey: .resourcePaths) ?? [:]
        canvasSize = try container.decodeIfPresent(CanvasDimensions.self, forKey: .canvasSize)
        rootResourceID = try container.decodeIfPresent(String.self, forKey: .rootResourceID)
        backupMetadata = try container.decodeIfPresent(LayoutBackupMetadata.self, forKey: .backupMetadata)
    }
}

struct LayoutBackupSnapshot: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    var url: URL
    var createdAt: Date
    var reason: String
    var appVersion: String?
    var canvas: SavedCanvas

    var itemCount: Int {
        Set(canvas.positions.keys).union(canvas.inboxIDs).count
    }
}

struct LayoutHistoryEntry: Codable, Equatable, Sendable {
    var canvas: SavedCanvas
    var operationID: UUID
    var transitionDate: Date
}

struct LayoutUndoHistoryDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var undoEntries: [LayoutHistoryEntry] = []
    var redoEntries: [LayoutHistoryEntry] = []
}

enum CanvasLayoutLoadResult: Equatable {
    case missing
    case loaded(SavedCanvas, migratedLegacyLayout: Bool)
    case recovered(SavedCanvas, corruptCopyURL: URL)
    case blocked(corruptLayoutURL: URL)
}

enum CanvasLayoutStoreError: LocalizedError, Equatable {
    case noBackup
    case invalidImport
    case invalidBackup
    case wrongFolder

    var errorDescription: String? {
        switch self {
        case .noBackup:
            "当前空间还没有可恢复的布局备份。"
        case .invalidImport:
            "选择的文件不是有效的指针空间布局。"
        case .invalidBackup:
            "选择的布局备份无效或已经不存在。"
        case .wrongFolder:
            "这个布局属于另一个文件夹，不能导入当前空间。"
        }
    }
}

struct CanvasLayoutStore {
    let layoutsDirectory: URL
    let maximumBackups: Int

    init(layoutsDirectory: URL? = nil, maximumBackups: Int = 12) {
        if let layoutsDirectory {
            self.layoutsDirectory = layoutsDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.layoutsDirectory = base.appendingPathComponent("SpatialFolder/Layouts", isDirectory: true)
        }
        self.maximumBackups = max(1, maximumBackups)
    }

    func canvasKey(for rootResourceID: String) -> String {
        let digest = SHA256.hash(data: Data(rootResourceID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func layoutURL(canvasKey: String) -> URL {
        layoutsDirectory.appendingPathComponent(canvasKey).appendingPathExtension("json")
    }

    func backupDirectory(canvasKey: String) -> URL {
        layoutsDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(canvasKey, isDirectory: true)
    }

    func layoutUndoHistoryURL(canvasKey: String) -> URL {
        layoutsDirectory
            .appendingPathComponent("UndoHistory", isDirectory: true)
            .appendingPathComponent(canvasKey)
            .appendingPathExtension("json")
    }

    func loadLayoutUndoHistory(canvasKey: String) throws -> LayoutUndoHistoryDocument {
        let url = layoutUndoHistoryURL(canvasKey: canvasKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LayoutUndoHistoryDocument()
        }
        return try JSONDecoder().decode(LayoutUndoHistoryDocument.self, from: Data(contentsOf: url))
    }

    func saveLayoutUndoHistory(_ document: LayoutUndoHistoryDocument, canvasKey: String) throws {
        let url = layoutUndoHistoryURL(canvasKey: canvasKey)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
    }

    func corruptDirectory() -> URL {
        layoutsDirectory.appendingPathComponent("Corrupt", isDirectory: true)
    }

    func legacyLayoutURL(folderPath: String) -> URL {
        let digest = Data(folderPath.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return layoutsDirectory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    func load(canvasKey: String, legacyFolderPath: String?) throws -> CanvasLayoutLoadResult {
        let currentURL = layoutURL(canvasKey: canvasKey)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            do {
                return .loaded(try decode(at: currentURL), migratedLegacyLayout: false)
            } catch {
                if var recovered = try newestValidBackup(canvasKey: canvasKey) {
                    recovered.backupMetadata = nil
                    let corruptCopy = try preserveCorruptLayout(at: currentURL, canvasKey: canvasKey)
                    try write(recovered, to: currentURL)
                    return .recovered(recovered, corruptCopyURL: corruptCopy)
                }
                return .blocked(corruptLayoutURL: currentURL)
            }
        }

        if let legacyFolderPath {
            let legacyURL = legacyLayoutURL(folderPath: legacyFolderPath)
            if FileManager.default.fileExists(atPath: legacyURL.path), let legacy = try? decode(at: legacyURL) {
                try write(legacy, to: currentURL)
                return .loaded(legacy, migratedLegacyLayout: true)
            }
        }
        return .missing
    }

    func save(
        _ canvas: SavedCanvas,
        canvasKey: String,
        makeBackup: Bool,
        backupReason: String = "布局调整前",
        appVersion: String? = nil
    ) throws {
        let currentURL = layoutURL(canvasKey: canvasKey)
        try FileManager.default.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
        if makeBackup, FileManager.default.fileExists(atPath: currentURL.path) {
            try createBackup(
                try decode(at: currentURL),
                canvasKey: canvasKey,
                reason: backupReason,
                appVersion: appVersion
            )
        }
        var current = canvas
        current.backupMetadata = nil
        try write(current, to: currentURL)
    }

    func createBackup(
        _ canvas: SavedCanvas,
        canvasKey: String,
        reason: String,
        appVersion: String? = nil
    ) throws {
        let directory = backupDirectory(canvasKey: canvasKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var backup = canvas
        backup.backupMetadata = LayoutBackupMetadata(
            createdAt: now,
            reason: reason,
            appVersion: appVersion
        )
        let stamp = String(Int(now.timeIntervalSince1970 * 1_000))
        let name = "\(stamp)-\(UUID().uuidString).json"
        try write(backup, to: directory.appendingPathComponent(name))
        try trimBackups(canvasKey: canvasKey)
    }

    func backupURLs(canvasKey: String) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: backupDirectory(canvasKey: canvasKey),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                if left == right { return lhs.lastPathComponent > rhs.lastPathComponent }
                return left > right
            }
    }

    func restoreLatestBackup(canvasKey: String) throws -> SavedCanvas {
        guard let latestURL = backupURLs(canvasKey: canvasKey).first,
              let latest = try? decode(at: latestURL) else {
            throw CanvasLayoutStoreError.noBackup
        }
        try save(latest, canvasKey: canvasKey, makeBackup: true, backupReason: "恢复布局前")
        var restored = latest
        restored.backupMetadata = nil
        return restored
    }

    func backupSnapshots(canvasKey: String) -> [LayoutBackupSnapshot] {
        backupURLs(canvasKey: canvasKey).compactMap { url in
            guard let canvas = try? decode(at: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let createdAt = canvas.backupMetadata?.createdAt
                ?? values?.creationDate
                ?? values?.contentModificationDate
                ?? .distantPast
            return LayoutBackupSnapshot(
                url: url,
                createdAt: createdAt,
                reason: canvas.backupMetadata?.reason ?? "历史备份",
                appVersion: canvas.backupMetadata?.appVersion,
                canvas: canvas
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func restoreBackup(
        _ snapshot: LayoutBackupSnapshot,
        canvasKey: String,
        preservingAppearanceFrom current: SavedCanvas,
        restoreAppearance: Bool,
        appVersion: String? = nil
    ) throws -> SavedCanvas {
        guard snapshot.url.deletingLastPathComponent().standardizedFileURL.path
                == backupDirectory(canvasKey: canvasKey).standardizedFileURL.path,
              var restored = try? decode(at: snapshot.url) else {
            throw CanvasLayoutStoreError.invalidImport
        }
        try save(
            current,
            canvasKey: canvasKey,
            makeBackup: true,
            backupReason: "恢复布局前",
            appVersion: appVersion
        )
        restored.backupMetadata = nil
        if !restoreAppearance {
            restored.wallpaperPath = current.wallpaperPath
            restored.isLocked = current.isLocked
        }
        return restored
    }

    func deleteBackup(_ snapshot: LayoutBackupSnapshot, canvasKey: String) throws {
        guard snapshot.url.deletingLastPathComponent().standardizedFileURL.path
                == backupDirectory(canvasKey: canvasKey).standardizedFileURL.path,
              FileManager.default.fileExists(atPath: snapshot.url.path) else {
            throw CanvasLayoutStoreError.invalidBackup
        }
        try FileManager.default.removeItem(at: snapshot.url)
    }

    func export(_ canvas: SavedCanvas, to destination: URL) throws {
        try write(canvas, to: destination)
    }

    func importedCanvas(from source: URL, expectedRootResourceID: String?) throws -> SavedCanvas {
        guard let canvas = try? decode(at: source) else {
            throw CanvasLayoutStoreError.invalidImport
        }
        if let expectedRootResourceID,
           let importedRoot = canvas.rootResourceID,
           importedRoot != expectedRootResourceID {
            throw CanvasLayoutStoreError.wrongFolder
        }
        return canvas
    }

    func deleteCurrentLayout(canvasKey: String) throws {
        let url = layoutURL(canvasKey: canvasKey)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func decode(at url: URL) throws -> SavedCanvas {
        try JSONDecoder().decode(SavedCanvas.self, from: Data(contentsOf: url))
    }

    private func write(_ canvas: SavedCanvas, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(canvas).write(to: url, options: .atomic)
    }

    private func newestValidBackup(canvasKey: String) throws -> SavedCanvas? {
        for url in backupURLs(canvasKey: canvasKey) {
            if let canvas = try? decode(at: url) { return canvas }
        }
        return nil
    }

    private func preserveCorruptLayout(at url: URL, canvasKey: String) throws -> URL {
        let directory = corruptDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            "\(canvasKey)-\(Int(Date().timeIntervalSince1970 * 1_000))-corrupt.json"
        )
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func trimBackups(canvasKey: String) throws {
        let backups = backupURLs(canvasKey: canvasKey)
        guard backups.count > maximumBackups else { return }
        for url in backups.dropFirst(maximumBackups) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
