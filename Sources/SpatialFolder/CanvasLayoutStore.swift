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
        rootResourceID: String? = nil
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
    }
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
    case wrongFolder

    var errorDescription: String? {
        switch self {
        case .noBackup:
            "当前空间还没有可恢复的布局备份。"
        case .invalidImport:
            "选择的文件不是有效的指针空间布局。"
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
                if let recovered = try newestValidBackup(canvasKey: canvasKey) {
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

    func save(_ canvas: SavedCanvas, canvasKey: String, makeBackup: Bool) throws {
        let currentURL = layoutURL(canvasKey: canvasKey)
        try FileManager.default.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
        if makeBackup, FileManager.default.fileExists(atPath: currentURL.path) {
            let directory = backupDirectory(canvasKey: canvasKey)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds)
            let name = "\(stamp)-\(UUID().uuidString).json"
            try FileManager.default.copyItem(at: currentURL, to: directory.appendingPathComponent(name))
            try trimBackups(canvasKey: canvasKey)
        }
        try write(canvas, to: currentURL)
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
        guard let latest = try newestValidBackup(canvasKey: canvasKey) else {
            throw CanvasLayoutStoreError.noBackup
        }
        try save(latest, canvasKey: canvasKey, makeBackup: true)
        return latest
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
