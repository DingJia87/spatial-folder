import AppKit
import Darwin
import Foundation
import SwiftUI

struct FolderItem: Identifiable, Hashable {
    let url: URL
    let tags: [String]
    let resourceID: String?
    let isDirectory: Bool

    init(
        url: URL,
        tags: [String],
        resourceID: String?,
        isDirectory: Bool = false
    ) {
        self.url = url
        self.tags = tags
        self.resourceID = resourceID
        self.isDirectory = isDirectory
    }

    var id: String { url.path }
    var renderID: String { "\(id)|\(tags.joined(separator: "\u{1F}"))|\(isDirectory)" }
    var name: String { url.lastPathComponent }

    static func == (lhs: FolderItem, rhs: FolderItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

private struct RecentFolderBookmark: Codable {
    var bookmarkData: Data
    var fallbackPath: String
}

struct PendingFileConflict: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

private struct PreparedImport: Sendable {
    var hasConflict: Bool
    var plans: [FileTransferPlan]
}

private struct PreparedDesktopCollection: Sendable {
    var sources: [URL]
    var plans: [FileTransferPlan]
    var destinationFolder: URL
    var fileCount: Int
    var folderCount: Int
}

struct DesktopCollectionConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let destinationName: String
    let fileCount: Int
    let folderCount: Int

    var totalCount: Int { fileCount + folderCount }

    var countDescription: String {
        var parts: [String] = []
        if fileCount > 0 { parts.append("\(fileCount) 个文件") }
        if folderCount > 0 { parts.append("\(folderCount) 个文件夹") }
        return parts.joined(separator: "、")
    }
}

struct LayoutBackupDifference: Equatable, Sendable {
    var unchangedCount: Int
    var changedCount: Int
    var newItemCount: Int
    var missingItemCount: Int
}

private struct PreparedRename: Sendable {
    var destination: URL
    var replacesExisting: Bool
    var hasConflict: Bool
}

/// 画布的主线程编排模型。
///
/// 它保存界面需要观察的状态，并把布局仓库、后台扫描、文件操作协调器和会话锁连接起来。
/// 耗时 I/O 必须交给独立 service/actor，不能直接塞回这个类型的主线程方法。
@MainActor
final class FolderCanvasModel: ObservableObject {
    let mainCanvasCapacity = 64

    private let defaultIconScale: CGFloat = 1.25
    private let recentFoldersKey = "recentFolderPaths"
    private let recentFolderBookmarksKey = "recentFolderBookmarksV2"
    private let pinnedFolderBookmarksKey = "pinnedFolderBookmarksV1"
    private let lastFolderBookmarkKey = "lastOpenedFolderBookmarkV2"
    private let maximumRecentFolders = 8
    let maximumPinnedFolders = 5
    private let maximumUndoDepth = 3
    private let grid: CGFloat = 24
    private let layoutStore: CanvasLayoutStore
    private let operationStore: OperationHistoryStore
    private let operationJournal: OperationJournalStore
    private let operationJournalDiskStore: OperationJournalDiskStore
    private let fileOperationEngine: FileOperationEngine
    private let defaults: UserDefaults
    private let monitorFolders: Bool
    private let sessionLockDirectory: URL
    private let sessionLockingEnabled: Bool
    private let directoryScanner: FolderDirectoryScanner
    private let scanService: FolderScanService
    private let scansAsynchronously: Bool
    private let fileOperationCoordinator: FileOperationCoordinator
    private let folderAccessRepository: FolderAccessRepository
    private let recoveryAnalyzer: RecoveryAnalyzer
    private let fileOperationsAsynchronously: Bool
    private let desktopDirectoryURL: URL
    private let layoutEngine = CanvasLayoutEngine()
    private let iconCache = FileIconCache()

    @Published private(set) var folderURL: URL?
    @Published private(set) var items: [FolderItem] = []
    @Published private(set) var positions: [String: CanvasPoint] = [:]
    @Published private(set) var scales: [String: CGFloat] = [:]
    @Published private(set) var wallpaperURL: URL?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var selectionRect: CGRect?
    @Published private(set) var dragTranslation: CGSize = .zero
    @Published private(set) var draggingIDs: Set<String> = []
    @Published private(set) var inboxIDs: Set<String> = []
    @Published private(set) var isLocked = false
    @Published private(set) var layoutIsBlocked = false
    @Published private(set) var folderUnavailable = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var operationRecords: [OperationRecord] = []
    @Published private(set) var operationHistoryIsBlocked = false
    @Published private(set) var sessionIsReadOnly = false
    @Published private(set) var sessionLockOwner: CanvasSessionOwner?
    @Published private(set) var isRefreshing = false
    @Published private(set) var fileOperationProgress: FileOperationProgressState?
    @Published var pendingConflict: PendingFileConflict?
    @Published private(set) var backupCount = 0
    @Published private(set) var layoutBackups: [LayoutBackupSnapshot] = []
    @Published private(set) var canvasSize: CGSize
    @Published private(set) var currentDisplaySize: CGSize
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var appearanceMode: String
    @Published private(set) var recentFolders: [URL] = []
    @Published private(set) var pinnedFolders: [URL] = []
    @Published private(set) var pendingSpaceReplacementURL: URL?
    @Published var searchText = "" {
        didSet {
            if searchText != oldValue { removeHiddenItemsFromSelection() }
        }
    }
    @Published private(set) var selectedTagColors: Set<FinderTagColor> = []
    @Published private(set) var includesUntaggedInFilter = false
    @Published var infoItem: FolderItem?
    @Published private(set) var infoSnapshot: FileInfoSnapshot?
    @Published private(set) var recoveryCases: [RecoveryCase] = []
    @Published private(set) var isLoadingOperationHistory = false
    @Published var isRecoveryWizardPresented = false
    @Published private(set) var desktopCollectionConfirmation: DesktopCollectionConfirmation?

    private var folderMonitor: FolderChangeMonitor?
    private var legacyFolderMonitor: DispatchSourceFileSystemObject?
    private var tagPollingTimer: DispatchSourceTimer?
    private var tagPollingTask: Task<Void, Never>?
    private(set) var tagReconciliationIsActive = true
    var tagReconciliationIsScheduled: Bool { tagPollingTimer != nil }
    private var tagReconciliationTick = 0
    private var refreshWorkItem: DispatchWorkItem?
    private var scanTask: Task<Void, Never>?
    private var fileOperationTask: Task<Void, Never>?
    private var journalWriteTask: Task<Void, Never>?
    private var operationHistoryLoadTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var savedCanvas = SavedCanvas()
    private var needsInitialArrangement = false
    private var needsGridMigration = false
    private var selectionStart: CGPoint?
    private var cutURLs: [URL] = []
    private var canvasKey: String?
    private var rootResourceID: String?
    private var lastFolderBookmark: Data?
    private var undoStack: [LayoutHistoryEntry] = []
    private var redoStack: [LayoutHistoryEntry] = []
    private var conflictResolution: ((ConflictChoice) -> Void)?
    private var pendingDropPoints: [UUID: CGPoint] = [:]
    private var pendingDesktopCollectionIDs: Set<UUID> = []
    private var preparedDesktopCollection: PreparedDesktopCollection?
    private var statusDismissTask: Task<Void, Never>?
    /// 持有对象即代表当前进程拥有这张画布的唯一写入权。
    private var sessionLock: CanvasSessionLock?

    init(
        layoutStore: CanvasLayoutStore = CanvasLayoutStore(),
        operationStore: OperationHistoryStore = OperationHistoryStore(),
        fileOperationEngine: FileOperationEngine = FileOperationEngine(),
        userDefaults: UserDefaults = .standard,
        autoOpenLastFolder: Bool = true,
        initialCanvasSize: CGSize? = nil,
        monitorFolders: Bool = true,
        sessionLockDirectory: URL = CanvasSessionLock.defaultLockDirectory(),
        sessionLockingEnabled: Bool = true,
        directoryScanner: FolderDirectoryScanner = FolderDirectoryScanner(),
        scansAsynchronously: Bool = true,
        fileOperationsAsynchronously: Bool = true,
        desktopDirectoryURL: URL? = nil
    ) {
        self.layoutStore = layoutStore
        self.operationStore = operationStore
        operationJournal = OperationJournalStore(legacyStore: operationStore)
        operationJournalDiskStore = OperationJournalDiskStore(legacyStore: operationStore)
        self.fileOperationEngine = fileOperationEngine
        defaults = userDefaults
        self.monitorFolders = monitorFolders
        self.sessionLockDirectory = sessionLockDirectory
        self.sessionLockingEnabled = sessionLockingEnabled
        self.directoryScanner = directoryScanner
        scanService = FolderScanService(scanner: directoryScanner)
        self.scansAsynchronously = scansAsynchronously
        fileOperationCoordinator = FileOperationCoordinator(fileOperationEngine: fileOperationEngine)
        folderAccessRepository = FolderAccessRepository(fileManager: fileOperationEngine.fileManager)
        recoveryAnalyzer = RecoveryAnalyzer(fileManager: fileOperationEngine.fileManager)
        self.fileOperationsAsynchronously = fileOperationsAsynchronously
        self.desktopDirectoryURL = (
            desktopDirectoryURL
                ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        ).standardizedFileURL
        let startingSize = initialCanvasSize ?? NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        canvasSize = startingSize
        currentDisplaySize = startingSize
        appearanceMode = userDefaults.string(forKey: "appearanceMode") ?? "system"
        recentFolders = Self.loadRecentFolders(from: userDefaults, key: recentFolderBookmarksKey)
        if recentFolders.isEmpty {
            recentFolders = (userDefaults.stringArray(forKey: recentFoldersKey) ?? [])
                .map(URL.init(fileURLWithPath:))
                .filter { Self.directoryExists(at: $0) }
        }
        pinnedFolders = Self.loadRecentFolders(from: userDefaults, key: pinnedFolderBookmarksKey)
        if userDefaults.object(forKey: pinnedFolderBookmarksKey) == nil {
            pinnedFolders = Array(recentFolders.prefix(maximumPinnedFolders).reversed())
            persistPinnedFolders()
        }
        if autoOpenLastFolder, let folder = resolveLastOpenedFolder() {
            open(folder: folder)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// 批量命令只能作用于用户当前看得见的选择，避免筛选后误操作隐藏文件。
    var selectedItems: [FolderItem] { displayedItems.filter { selectedIDs.contains($0.id) } }

    var displayedItems: [FolderItem] {
        matchingItems.filter { !inboxIDs.contains($0.id) }
    }

    var inboxItems: [FolderItem] {
        items.filter { inboxIDs.contains($0.id) }
    }

    var desktopCanvasSize: CGSize { canvasSize }

    var toolbarSpaceFolders: [URL] {
        Array(pinnedFolders.prefix(maximumPinnedFolders))
    }

    var overflowSpaceFolders: [URL] {
        overflowSpaceFolders(excluding: toolbarSpaceFolders)
    }

    func overflowSpaceFolders(excluding visibleFolders: [URL]) -> [URL] {
        let visiblePaths = Set(visibleFolders.map { $0.standardizedFileURL.path })
        var seen = visiblePaths
        return (pinnedFolders + recentFolders).compactMap { folder in
            let standardized = folder.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    var hasActiveFilters: Bool { itemFilter.isActive }

    var activeTagFilterCount: Int {
        selectedTagColors.count + (includesUntaggedInFilter ? 1 : 0)
    }

    /// 统一供界面和命令判断，避免只在按钮层禁用而底层仍然修改布局。
    var canEditLayout: Bool {
        folderURL != nil && !layoutIsBlocked && !folderUnavailable && !sessionIsReadOnly &&
            !isLoadingOperationHistory && !isLocked
    }

    var undoHelpText: String {
        nextUndoSummary.map { "撤销：\($0)" } ?? "没有可撤销的操作"
    }

    var redoHelpText: String {
        nextRedoSummary.map { "重做：\($0)" } ?? "没有可重做的操作"
    }

    private var nextUndoSummary: String? {
        let layout = undoStack.last
        let file = operationRecords
            .filter { $0.isFileReversible && $0.state == .applied }
            .max { $0.transitionDate < $1.transitionDate }
        if let layout, file == nil || layout.transitionDate >= file!.transitionDate {
            return operationRecords.first(where: { $0.id == layout.operationID })?.summary
                ?? "上一步布局调整"
        }
        return file?.summary
    }

    private var nextRedoSummary: String? {
        let layout = redoStack.last
        let file = operationRecords
            .filter { $0.isFileReversible && $0.state == .undone }
            .max { $0.transitionDate < $1.transitionDate }
        if let layout, file == nil || layout.transitionDate >= file!.transitionDate {
            return operationRecords.first(where: { $0.id == layout.operationID })?.summary
                ?? "上一步布局调整"
        }
        return file?.summary
    }

    /// 锁定只保护图标布局；壁纸属于显示偏好，锁定时仍应允许调整。
    var canChangeWallpaper: Bool {
        folderURL != nil && !layoutIsBlocked && !folderUnavailable && !sessionIsReadOnly &&
            !isLoadingOperationHistory
    }

    var isFileOperationInProgress: Bool { fileOperationProgress != nil }

    var canCollectDesktopItems: Bool {
        guard let folderURL else { return false }
        return folderURL.standardizedFileURL != desktopDirectoryURL &&
            !layoutIsBlocked && !folderUnavailable && !sessionIsReadOnly &&
            !isLoadingOperationHistory && !operationHistoryIsBlocked &&
            !isFileOperationInProgress && desktopCollectionConfirmation == nil
    }

    func pileCount(for item: FolderItem) -> Int {
        guard let point = positions[item.id] else { return 0 }
        return displayedItems.reduce(into: 0) { count, candidate in
            if positions[candidate.id] == point { count += 1 }
        }
    }

    func isTopOfPile(_ item: FolderItem) -> Bool {
        guard let point = positions[item.id] else { return false }
        return displayedItems.last { positions[$0.id] == point }?.id == item.id
    }

    func icon(for item: FolderItem) -> NSImage {
        iconCache.icon(for: item.url, folderTagColor: folderTagColor(for: item))
    }

    func currentItem(for item: FolderItem) -> FolderItem {
        items.first(where: { $0.id == item.id }) ?? item
    }

    private func currentItems(for candidates: [FolderItem]) -> [FolderItem] {
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.id).inserted else { return nil }
            return items.first(where: { $0.id == candidate.id })
        }
    }

    func folderTagColor(for item: FolderItem) -> FinderTagColor? {
        guard let color = item.tags.lazy.compactMap(FinderTagColor.init(finderTag:)).first else {
            return nil
        }
        if item.isDirectory { return color }
        let isDirectory = (try? item.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory ? color : nil
    }

    var defaultDesktopWallpaperURL: URL? {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    private var itemFilter: CanvasItemFilter {
        CanvasItemFilter(
            query: searchText,
            tagColors: selectedTagColors,
            includesUntagged: includesUntaggedInFilter
        )
    }

    private var matchingItems: [FolderItem] {
        let filter = itemFilter
        guard filter.isActive else { return items }
        return items.filter(filter.matches)
    }

    func toggleTagFilter(_ color: FinderTagColor) {
        if !selectedTagColors.insert(color).inserted {
            selectedTagColors.remove(color)
        }
        removeHiddenItemsFromSelection()
    }

    func toggleUntaggedFilter() {
        includesUntaggedInFilter.toggle()
        removeHiddenItemsFromSelection()
    }

    func clearFilters() {
        searchText = ""
        selectedTagColors = []
        includesUntaggedInFilter = false
        removeHiddenItemsFromSelection()
    }

    private func removeHiddenItemsFromSelection() {
        let visibleIDs = Set(displayedItems.map(\.id))
        selectedIDs.formIntersection(visibleIDs)
    }

    // MARK: - 外观、空间打开与目录扫描

    func setAppearanceMode(_ mode: String) {
        appearanceMode = mode
        defaults.set(mode, forKey: "appearanceMode")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择一个要空间化展示的文件夹"
        panel.prompt = "打开画布"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(folder: url) }
    }

    func isPinnedFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return pinnedFolders.contains { $0.standardizedFileURL.path == path }
    }

    func pinFolder(_ folder: URL) {
        let standardized = folder.standardizedFileURL
        guard Self.directoryExists(at: standardized) else { return }
        guard !isPinnedFolder(standardized) else { return }
        guard pinnedFolders.count < maximumPinnedFolders else {
            errorMessage = "顶部最多固定 \(maximumPinnedFolders) 个空间。可以先取消固定一个空间。"
            return
        }
        pinnedFolders.append(standardized)
        persistPinnedFolders()
    }

    func unpinFolder(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard folderURL?.standardizedFileURL.path != path else {
            errorMessage = "当前空间需要保留在顶部。请先切换到其他空间再移除。"
            return
        }
        pinnedFolders.removeAll { $0.standardizedFileURL.path == path }
        persistPinnedFolders()
    }

    func movePinnedFolder(_ source: URL, to target: URL) {
        let sourcePath = source.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard sourcePath != targetPath,
              let sourceIndex = pinnedFolders.firstIndex(where: { $0.standardizedFileURL.path == sourcePath }),
              let targetIndex = pinnedFolders.firstIndex(where: { $0.standardizedFileURL.path == targetPath }) else { return }
        let folder = pinnedFolders.remove(at: sourceIndex)
        let insertionIndex = min(targetIndex, pinnedFolders.count)
        pinnedFolders.insert(folder, at: insertionIndex)
        persistPinnedFolders()
    }

    func movePinnedFolder(_ source: URL, byHorizontalDistance distance: CGFloat) {
        guard abs(distance) >= 24 else { return }
        let sourcePath = source.standardizedFileURL.path
        guard let sourceIndex = pinnedFolders.firstIndex(where: {
            $0.standardizedFileURL.path == sourcePath
        }) else { return }
        let direction = distance > 0 ? 1 : -1
        let steps = max(1, Int((abs(distance) / 90).rounded()))
        let targetIndex = min(max(0, sourceIndex + direction * steps), pinnedFolders.count - 1)
        guard targetIndex != sourceIndex else { return }
        let folder = pinnedFolders.remove(at: sourceIndex)
        pinnedFolders.insert(folder, at: targetIndex)
        persistPinnedFolders()
    }

    func open(folder: URL) {
        guard !isFileOperationInProgress else {
            errorMessage = "请等待当前文件操作完成，或先取消操作，再切换空间。"
            return
        }
        cancelDesktopCollection()
        let standardized = folder.standardizedFileURL
        guard Self.directoryExists(at: standardized) else {
            errorMessage = "无法打开文件夹：文件夹不存在或暂时不可用。"
            return
        }
        if standardized == folderURL?.standardizedFileURL { return }
        if !isPinnedFolder(standardized) {
            guard pinnedFolders.count < maximumPinnedFolders else {
                pendingSpaceReplacementURL = standardized
                return
            }
            pinnedFolders.append(standardized)
            persistPinnedFolders()
        }
        performOpen(folder: standardized)
    }

    func replaceSpaceAndOpen(with replacement: URL, replacing existingFolder: URL) {
        guard !isFileOperationInProgress else {
            errorMessage = "请等待当前文件操作完成，或先取消操作，再切换空间。"
            return
        }
        guard Self.directoryExists(at: replacement) else {
            pendingSpaceReplacementURL = nil
            errorMessage = "无法打开文件夹：文件夹不存在或暂时不可用。"
            return
        }
        let existingPath = existingFolder.standardizedFileURL.path
        guard let index = pinnedFolders.firstIndex(where: { $0.standardizedFileURL.path == existingPath }) else {
            pendingSpaceReplacementURL = nil
            return
        }
        let standardized = replacement.standardizedFileURL
        pinnedFolders[index] = standardized
        persistPinnedFolders()
        pendingSpaceReplacementURL = nil
        performOpen(folder: standardized)
    }

    func cancelSpaceReplacement() {
        pendingSpaceReplacementURL = nil
    }

    private func performOpen(folder standardized: URL) {
        persistLayoutUndoHistory()
        folderMonitor?.cancel()
        folderMonitor = nil
        legacyFolderMonitor?.cancel()
        legacyFolderMonitor = nil
        tagPollingTimer?.cancel()
        tagPollingTimer = nil
        tagPollingTask?.cancel()
        tagPollingTask = nil
        refreshWorkItem?.cancel()
        scanTask?.cancel()
        operationHistoryLoadTask?.cancel()
        scanGeneration = UUID()
        iconCache.removeAll()
        sessionLock?.release()
        sessionLock = nil
        sessionIsReadOnly = false
        sessionLockOwner = nil
        clearFilters()
        folderURL = standardized
        rootResourceID = persistentResourceIdentifier(for: standardized) ?? "path:\(standardized.path)"
        canvasKey = rootResourceID.map(layoutStore.canvasKey(for:))
        acquireSessionLock()
        lastFolderBookmark = makeBookmark(for: standardized)
        saveLastOpenedFolder(standardized)
        remember(folder: standardized)
        selectedIDs = []
        loadLayoutUndoHistory()
        pendingConflict = nil
        conflictResolution = nil
        folderUnavailable = false
        loadSavedCanvas()
        loadOperationHistory()
        refreshItems()
        updateUndoAvailability()
        if monitorFolders { watchFolder() }
    }

    func refreshItems() {
        guard let folderURL else { return }
        guard Self.directoryExists(at: folderURL) else {
            attemptFolderRecovery()
            return
        }
        folderUnavailable = false
        if scansAsynchronously {
            refreshItemsInBackground(folder: folderURL)
        } else {
            do {
                applyScan(try directoryScanner.scan(folder: folderURL), for: folderURL)
            } catch {
                errorMessage = "无法读取文件夹：\(error.localizedDescription)"
            }
        }
    }

    /// 生产环境使用后台扫描；generation 防止切换空间后旧结果覆盖新画布。
    private func refreshItemsInBackground(folder: URL) {
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        isRefreshing = true
        scanTask = Task { [weak self, scanService] in
            do {
                let entries = try await scanService.scan(folder: folder)
                guard !Task.isCancelled,
                      let self,
                      self.scanGeneration == generation,
                      self.folderURL?.standardizedFileURL == folder.standardizedFileURL else { return }
                self.applyScan(entries, for: folder)
                self.isRefreshing = false
            } catch is CancellationError {
                if self?.scanGeneration == generation { self?.isRefreshing = false }
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.isRefreshing = false
                self.errorMessage = "无法读取文件夹：\(error.localizedDescription)"
            }
        }
    }

    /// 把扫描快照一次性应用到主线程状态，避免边扫描边发布造成界面反复重排。
    private func applyScan(_ entries: [ScannedFolderEntry], for folder: URL) {
        guard folderURL?.standardizedFileURL == folder.standardizedFileURL else { return }
        let freshItems = entries.map {
            FolderItem(
                url: $0.url,
                tags: $0.tags,
                resourceID: $0.resourceID,
                isDirectory: $0.isDirectory
            )
        }
        items = freshItems
        let currentPaths = Set(freshItems.map(\.id))
        selectedIDs.formIntersection(currentPaths)
        removeHiddenItemsFromSelection()

        var changed = reconcileResourcePaths(freshItems)
        guard !layoutIsBlocked else { return }
        if needsInitialArrangement {
            arrangeInitialItems(freshItems)
            needsInitialArrangement = false
            changed = true
        } else if needsGridMigration {
            arrangeInitialItems(freshItems)
            needsGridMigration = false
            changed = true
        } else {
            changed = assignPositionsToNewItems(freshItems) || changed
        }
        changed = enforceCapacityAndBounds(freshItems) || changed
        if changed { persist(makeBackup: false) }
        capturePendingCanvasMetadataAfterRefresh()
    }

    /// 文件操作先落盘、扫描稍后完成时，在这里补记新项目的画布位置。
    private func capturePendingCanvasMetadataAfterRefresh() {
        let kinds: Set<OperationKind> = [.createFolder, .createDocument, .duplicate, .copyItems, .moveItems, .compress]
        var changed = false
        for index in operationRecords.indices where
            operationRecords[index].state == .applied &&
            operationRecords[index].canvasItems.isEmpty &&
            kinds.contains(operationRecords[index].kind) {
            var record = operationRecords[index]
            captureCanvasMetadata(in: &record)
            if !record.canvasItems.isEmpty {
                operationRecords[index] = record
                changed = true
            }
        }
        if changed {
            let changedRecords = operationRecords.filter { record in
                kinds.contains(record.kind) && !record.canvasItems.isEmpty
            }
            enqueueOperationJournalUpsert(changedRecords)
        }
    }

    func position(for item: FolderItem) -> CanvasPoint {
        positions[item.id] ?? CanvasPoint(x: 72, y: 72)
    }

    func move(_ item: FolderItem, to point: CGPoint) {
        guard canEditLayout, !inboxIDs.contains(item.id) else { return }
        captureUndoSnapshot(summary: "移动图标")
        positions[item.id] = snapped(point, scale: scale(for: item))
        persist(makeBackup: true, backupReason: "移动图标前")
    }

    func scale(for item: FolderItem) -> CGFloat {
        scales[item.id] ?? defaultIconScale
    }

    func setScale(_ scale: CGFloat, for item: FolderItem) {
        setScale(scale, for: [item])
    }

    func setScale(_ scale: CGFloat, for targetItems: [FolderItem]) {
        guard canEditLayout else { return }
        let targets = targetItems.filter { !inboxIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        captureUndoSnapshot(summary: "调整图标和字体大小")
        let adjustedScale = min(max(scale, 0.7), 1.8)
        for item in targets {
            scales[item.id] = adjustedScale
            if let position = positions[item.id] {
                positions[item.id] = snapped(CGPoint(x: position.x, y: position.y), scale: adjustedScale)
            }
        }
        persist(makeBackup: true, backupReason: "调整图标大小前")
    }

    // MARK: - 选择、框选和整体拖动

    func select(_ item: FolderItem, extendingSelection: Bool) {
        guard !inboxIDs.contains(item.id) else { return }
        if extendingSelection {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        } else {
            selectedIDs = [item.id]
        }
    }

    func clearSelection() { selectedIDs = [] }

    func beginSelection(at point: CGPoint) {
        selectionStart = point
        selectionRect = CGRect(origin: point, size: .zero)
    }

    func updateSelection(to point: CGPoint) {
        guard let start = selectionStart else { return }
        selectionRect = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
    }

    func finishSelection(addingToSelection: Bool) {
        guard let selectionRect else { return }
        let selected = Set(displayedItems.compactMap { item -> String? in
            let point = position(for: item)
            let halfWidth = 52 * scale(for: item)
            let halfHeight = 48 * scale(for: item)
            let iconFrame = CGRect(
                x: point.x - halfWidth,
                y: point.y - halfHeight,
                width: halfWidth * 2,
                height: halfHeight * 2
            )
            return selectionRect.intersects(iconFrame) ? item.id : nil
        })
        selectedIDs = addingToSelection ? selectedIDs.union(selected) : selected
        self.selectionRect = nil
        selectionStart = nil
    }

    func beginDragging(_ item: FolderItem) {
        guard canEditLayout, !inboxIDs.contains(item.id) else { return }
        if !selectedIDs.contains(item.id) { selectedIDs = [item.id] }
        draggingIDs = selectedIDs
    }

    func updateDrag(translation: CGSize) {
        guard !draggingIDs.isEmpty else { return }
        dragTranslation = constrainedGroupTranslation(translation)
    }

    func finishDrag() {
        guard canEditLayout, !draggingIDs.isEmpty else {
            dragTranslation = .zero
            draggingIDs = []
            return
        }
        let moved = abs(dragTranslation.width) > 0.5 || abs(dragTranslation.height) > 0.5
        if moved { captureUndoSnapshot(summary: "移动所选图标") }
        for id in draggingIDs {
            guard let position = positions[id] else { continue }
            positions[id] = CanvasPoint(
                x: position.x + dragTranslation.width,
                y: position.y + dragTranslation.height
            )
        }
        dragTranslation = .zero
        draggingIDs = []
        if moved { persist(makeBackup: true, backupReason: "移动所选图标前") }
    }

    /// 先把位移吸附到网格，再按整个选择集合的外接边界统一限位。
    /// 这样任意一个图标碰到边缘时，整组一起停止，不会破坏组内相对位置。
    private func constrainedGroupTranslation(_ proposed: CGSize) -> CGSize {
        let activeItems = items.filter { draggingIDs.contains($0.id) && positions[$0.id] != nil }
        guard !activeItems.isEmpty else { return .zero }
        var minimumDX = -CGFloat.greatestFiniteMagnitude
        var maximumDX = CGFloat.greatestFiniteMagnitude
        var minimumDY = -CGFloat.greatestFiniteMagnitude
        var maximumDY = CGFloat.greatestFiniteMagnitude
        for item in activeItems {
            guard let position = positions[item.id] else { continue }
            let rect = iconRect(at: position, scale: scale(for: item))
            minimumDX = max(minimumDX, -rect.minX)
            maximumDX = min(maximumDX, canvasSize.width - rect.maxX)
            minimumDY = max(minimumDY, -rect.minY)
            maximumDY = min(maximumDY, canvasSize.height - rect.maxY)
        }
        guard minimumDX <= maximumDX, minimumDY <= maximumDY else { return .zero }
        let snappedDX = (proposed.width / grid).rounded() * grid
        let snappedDY = (proposed.height / grid).rounded() * grid
        return CGSize(
            width: min(maximumDX, max(minimumDX, snappedDX)),
            height: min(maximumDY, max(minimumDY, snappedDY))
        )
    }

    // MARK: - 画布布局命令

    func setLocked(_ locked: Bool) {
        guard !sessionIsReadOnly, !isLoadingOperationHistory, !layoutIsBlocked, folderURL != nil else { return }
        guard isLocked != locked else { return }
        captureUndoSnapshot(summary: locked ? "锁定画布" : "解锁画布")
        isLocked = locked
        persist(makeBackup: true, backupReason: locked ? "锁定画布前" : "解锁画布前")
    }

    func toggleLocked() { setLocked(!isLocked) }

    func moveToInbox(_ item: FolderItem) {
        moveToInbox([item])
    }

    func moveToInbox(_ targetItems: [FolderItem]) {
        guard canEditLayout else { return }
        let targets = targetItems.filter { !inboxIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        captureUndoSnapshot(summary: "将 \(targets.count) 个项目移到待放置区")
        for item in targets {
            inboxIDs.insert(item.id)
            positions.removeValue(forKey: item.id)
            selectedIDs.remove(item.id)
        }
        persist(makeBackup: true, backupReason: "移入待放置区前")
    }

    func placeFromInbox(_ item: FolderItem) {
        placeFromInbox([item])
    }

    func placeFromInbox(_ targetItems: [FolderItem]) {
        guard canEditLayout else { return }
        let targets = targetItems.filter { inboxIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        var activeItems = items.filter { !inboxIDs.contains($0.id) && positions[$0.id] != nil }
        var occupiedRects = activeItems.compactMap { active -> CGRect? in
            guard let position = positions[active.id] else { return nil }
            return iconRect(at: position, scale: scale(for: active))
        }
        var placements: [(FolderItem, CanvasPoint)] = []
        for item in targets where activeItems.count < mainCanvasCapacity {
            let point = (0..<mainCanvasCapacity).lazy
                .map { self.gridPoint(for: $0, scale: self.scale(for: item)) }
                .first { candidatePoint in
                    let candidate = self.iconRect(at: candidatePoint, scale: self.scale(for: item))
                        .insetBy(dx: -4, dy: -4)
                    return !occupiedRects.contains(where: { $0.intersects(candidate) })
                }
            guard let point else { break }
            placements.append((item, point))
            activeItems.append(item)
            occupiedRects.append(iconRect(at: point, scale: scale(for: item)))
        }
        guard !placements.isEmpty else {
            errorMessage = "主画布已经放满。请先把一个项目移到待放置区。"
            return
        }
        captureUndoSnapshot(summary: "从待放置区放入 \(placements.count) 个项目")
        for (item, point) in placements {
            inboxIDs.remove(item.id)
            positions[item.id] = point
        }
        persist(makeBackup: true, backupReason: "从待放置区取出前")
        if placements.count < targets.count {
            errorMessage = "主画布空间不足，已放入 \(placements.count) 个项目，其余仍保留在待放置区。"
        }
    }

    var availableCanvasSlots: Int {
        max(0, mainCanvasCapacity - items.filter { !inboxIDs.contains($0.id) && positions[$0.id] != nil }.count)
    }

    /// 右键点在已选项目上时，菜单作用于整个选择集合；点在未选项目上时只作用于该项目。
    func contextItems(for item: FolderItem) -> [FolderItem] {
        selectedIDs.contains(item.id) ? selectedItems : [currentItem(for: item)]
    }

    func recoverOutOfBoundsItems() {
        guard canEditLayout else { return }
        let before = positions
        let operationID = captureUndoSnapshot(summary: "找回越界项目")
        for item in items where !inboxIDs.contains(item.id) {
            guard let point = positions[item.id] else { continue }
            positions[item.id] = snapped(CGPoint(x: point.x, y: point.y), scale: scale(for: item))
        }
        if before == positions {
            undoStack.removeLast()
            persistLayoutUndoHistory()
            operationRecords.removeAll { $0.id == operationID }
            persistOperationHistory()
            updateUndoAvailability()
            errorMessage = "当前没有越界项目。"
        } else {
            persist(makeBackup: true, backupReason: "找回越界项目前")
        }
    }

    func updateCanvasSize(_ newSize: CGSize) {
        guard newSize.width >= 640, newSize.height >= 480 else { return }
        currentDisplaySize = newSize
        if folderURL == nil { canvasSize = newSize }
    }

    func setCurrentDisplayAsReferenceCanvas() {
        guard canEditLayout else { return }
        guard abs(canvasSize.width - currentDisplaySize.width) > 1 ||
                abs(canvasSize.height - currentDisplaySize.height) > 1 else {
            errorMessage = "当前显示器已经是基准画布。"
            return
        }
        captureUndoSnapshot(summary: "重设基准画布")
        resizeLogicalCanvas(to: currentDisplaySize)
        _ = enforceCapacityAndBounds(items)
        persist(makeBackup: true, backupReason: "重设基准画布前")
    }

    func undoLayoutChange() {
        guard !sessionIsReadOnly, !isLoadingOperationHistory, let previous = undoStack.popLast() else { return }
        syncSavedCanvas()
        let now = Date()
        redoStack.append(LayoutHistoryEntry(
            canvas: savedCanvas,
            operationID: previous.operationID,
            transitionDate: now
        ))
        applySavedCanvas(previous.canvas)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true, backupReason: "撤销布局前")
        setOperationState(id: previous.operationID, state: .undone, transitionDate: now)
        persistLayoutUndoHistory()
        updateUndoAvailability()
    }

    func redoLayoutChange() {
        guard !sessionIsReadOnly, !isLoadingOperationHistory, let next = redoStack.popLast() else { return }
        syncSavedCanvas()
        let now = Date()
        undoStack.append(LayoutHistoryEntry(
            canvas: savedCanvas,
            operationID: next.operationID,
            transitionDate: now
        ))
        applySavedCanvas(next.canvas)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true, backupReason: "重做布局前")
        setOperationState(id: next.operationID, state: .applied, transitionDate: now)
        persistLayoutUndoHistory()
        updateUndoAvailability()
    }

    // MARK: - 统一撤销、重做和布局交换

    func undoLastAction() {
        let layout = undoStack.last
        let file = operationRecords
            .filter { $0.isFileReversible && $0.state == .applied }
            .max { $0.transitionDate < $1.transitionDate }
        if let layout, file == nil || layout.transitionDate >= file!.transitionDate {
            undoLayoutChange()
        } else if let file {
            transitionFileOperation(id: file.id, to: .undone, conflictChoice: .cancel)
        }
    }

    func redoLastAction() {
        let layout = redoStack.last
        let file = operationRecords
            .filter { $0.isFileReversible && $0.state == .undone }
            .max { $0.transitionDate < $1.transitionDate }
        if let layout, file == nil || layout.transitionDate >= file!.transitionDate {
            redoLayoutChange()
        } else if let file {
            transitionFileOperation(id: file.id, to: .applied, conflictChoice: .cancel)
        }
    }

    func resolvePendingConflict(_ choice: ConflictChoice) {
        let resolution = conflictResolution
        conflictResolution = nil
        pendingConflict = nil
        resolution?(choice)
    }

    func resetLayout() {
        guard !sessionIsReadOnly, !isLoadingOperationHistory else { return }
        if !layoutIsBlocked { captureUndoSnapshot(summary: "重置当前布局") }
        layoutIsBlocked = false
        positions = [:]
        scales = [:]
        inboxIDs = []
        arrangeInitialItems(items)
        persist(makeBackup: true, backupReason: "重置布局前")
    }

    func restoreLatestBackup() {
        guard !sessionIsReadOnly, !isLoadingOperationHistory, let canvasKey else { return }
        do {
            if !layoutIsBlocked { captureUndoSnapshot(summary: "恢复布局备份") }
            let restored = try layoutStore.restoreLatestBackup(canvasKey: canvasKey)
            layoutIsBlocked = false
            applySavedCanvas(restored)
            reconcileAfterLayoutRestore()
            persist(makeBackup: false)
            errorMessage = "已经恢复最近一次布局备份。"
        } catch {
            errorMessage = "无法恢复布局：\(error.localizedDescription)"
        }
    }

    func loadLayoutBackups() {
        guard let canvasKey else {
            layoutBackups = []
            return
        }
        layoutBackups = layoutStore.backupSnapshots(canvasKey: canvasKey)
        backupCount = layoutBackups.count
    }

    func saveLayoutSnapshot(note: String?) {
        guard !sessionIsReadOnly, !layoutIsBlocked, let canvasKey else { return }
        syncSavedCanvas()
        let snapshotCanvas = canvasLimitedToCurrentItems(savedCanvas)
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = trimmed.isEmpty ? "手动保存的布局" : trimmed
        do {
            try layoutStore.createBackup(
                snapshotCanvas,
                canvasKey: canvasKey,
                reason: reason,
                appVersion: currentAppVersion
            )
            loadLayoutBackups()
            errorMessage = "已经保存当前布局快照。"
        } catch {
            errorMessage = "无法保存布局快照：\(error.localizedDescription)"
        }
    }

    func restoreLayoutBackup(_ snapshot: LayoutBackupSnapshot, restoreAppearance: Bool) {
        guard !sessionIsReadOnly, !isLoadingOperationHistory, let canvasKey else { return }
        do {
            syncSavedCanvas()
            if !layoutIsBlocked { captureUndoSnapshot(summary: "恢复布局备份") }
            var restored = try layoutStore.restoreBackup(
                snapshot,
                canvasKey: canvasKey,
                preservingAppearanceFrom: savedCanvas,
                restoreAppearance: restoreAppearance,
                appVersion: currentAppVersion
            )
            restored = preservingCurrentOnlyItems(in: restored, current: savedCanvas)
            layoutIsBlocked = false
            applySavedCanvas(restored)
            reconcileAfterLayoutRestore()
            persist(makeBackup: false)
            loadLayoutBackups()
            errorMessage = "已经恢复所选布局备份。真实文件没有改变。"
        } catch {
            errorMessage = "无法恢复布局：\(error.localizedDescription)"
        }
    }

    func deleteLayoutBackup(_ snapshot: LayoutBackupSnapshot) {
        guard !sessionIsReadOnly, let canvasKey else { return }
        do {
            try layoutStore.deleteBackup(snapshot, canvasKey: canvasKey)
            loadLayoutBackups()
            errorMessage = "已经删除所选布局备份。当前布局和真实文件没有改变。"
        } catch {
            errorMessage = "无法删除布局备份：\(error.localizedDescription)"
        }
    }

    func canvasForBackupPreview(_ snapshot: LayoutBackupSnapshot) -> SavedCanvas {
        remappingBackupCanvasToCurrentItems(snapshot.canvas)
    }

    var currentCanvasForPreview: SavedCanvas {
        let currentIDs = Set(items.map(\.id))
        return SavedCanvas(
            positions: positions.filter { currentIDs.contains($0.key) },
            scales: scales.filter { currentIDs.contains($0.key) },
            wallpaperPath: wallpaperURL?.path,
            isLocked: isLocked,
            inboxIDs: inboxIDs.intersection(currentIDs),
            resourcePaths: savedCanvas.resourcePaths,
            canvasSize: CanvasDimensions(canvasSize),
            rootResourceID: rootResourceID
        )
    }

    func layoutDifference(for snapshot: LayoutBackupSnapshot) -> LayoutBackupDifference {
        let backup = canvasForBackupPreview(snapshot)
        let currentIDs = Set(items.map(\.id))
        let backupIDs = Set(backup.positions.keys).union(backup.inboxIDs)
        let shared = currentIDs.intersection(backupIDs)
        var changed = 0
        for id in shared {
            let currentScale = scales[id] ?? defaultIconScale
            let backupScale = backup.scales[id] ?? defaultIconScale
            if positions[id] != backup.positions[id]
                || inboxIDs.contains(id) != backup.inboxIDs.contains(id)
                || abs(currentScale - backupScale) > 0.001 {
                changed += 1
            }
        }
        return LayoutBackupDifference(
            unchangedCount: shared.count - changed,
            changedCount: changed,
            newItemCount: currentIDs.subtracting(backupIDs).count,
            missingItemCount: backupIDs.subtracting(currentIDs).count
        )
    }

    func missingItemNames(for snapshot: LayoutBackupSnapshot) -> [String] {
        let backup = canvasForBackupPreview(snapshot)
        let currentIDs = Set(items.map(\.id))
        return Set(backup.positions.keys)
            .union(backup.inboxIDs)
            .subtracting(currentIDs)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func revealBackups() {
        guard let canvasKey else { return }
        let directory = layoutStore.backupDirectory(canvasKey: canvasKey)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            errorMessage = "无法打开备份位置：\(error.localizedDescription)"
        }
    }

    func exportLayout() {
        guard folderURL != nil else { return }
        let panel = NSSavePanel()
        panel.title = "导出当前空间布局"
        panel.nameFieldStringValue = "\(folderURL?.lastPathComponent ?? "空间")-布局.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try exportLayout(to: url)
            } catch {
                errorMessage = "无法导出布局：\(error.localizedDescription)"
            }
        }
    }

    func exportLayout(to url: URL) throws {
        syncSavedCanvas()
        try layoutStore.export(savedCanvas, to: url)
    }

    func diagnosticsData() throws -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let report = PrivacySafeDiagnostics(
            generatedAt: Date(),
            appVersion: version,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            logicalCanvasSize: CanvasDimensions(canvasSize),
            currentDisplaySize: CanvasDimensions(currentDisplaySize),
            visibleItemCount: displayedItems.count,
            inboxItemCount: inboxItems.count,
            operationCount: operationRecords.count,
            recentOperations: operationRecords.suffix(100).map { record in
                DiagnosticOperation(
                    category: record.category,
                    kind: record.kind,
                    state: record.state,
                    occurredAt: record.transitionDate,
                    actionCount: record.actions.count,
                    errorType: record.detail == nil ? nil : "operation_error"
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "导出隐私安全的诊断信息"
        panel.nameFieldStringValue = "指针空间-诊断.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnosticsData().write(to: url, options: .atomic)
            errorMessage = "诊断信息已导出。内容不包含文件名或完整路径。"
        } catch {
            errorMessage = "无法导出诊断信息：\(error.localizedDescription)"
        }
    }

    func revealOperationHistory() {
        do {
            try FileManager.default.createDirectory(at: operationStore.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(operationStore.directory)
        } catch {
            errorMessage = "无法打开操作记录位置：\(error.localizedDescription)"
        }
    }

    func archiveDamagedOperationHistoryAndContinue() {
        guard operationHistoryIsBlocked, let canvasKey else { return }
        let alert = NSAlert()
        alert.messageText = "存档损坏记录并重新开始？"
        alert.informativeText = "原操作记录会移入 Corrupt 存档目录，不会删除。重新开始后，旧操作不能在 App 内撤销，但真实文件不会被改动。"
        alert.addButton(withTitle: "存档并继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let journal = operationJournal
        journalWriteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await journal.archiveCorruptHistoryAndReset(canvasKey: canvasKey)
                guard self.canvasKey == canvasKey else { return }
                self.operationRecords = []
                self.operationHistoryIsBlocked = false
                self.updateUndoAvailability()
                self.errorMessage = "损坏记录已存档为“\(archive.lastPathComponent)”，可以继续使用。"
            } catch {
                guard self.canvasKey == canvasKey else { return }
                self.errorMessage = "无法存档损坏操作记录：\(error.localizedDescription)"
            }
        }
    }

    func importLayout() {
        let panel = NSOpenPanel()
        panel.title = "导入空间布局"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try importLayout(from: url)
                errorMessage = "布局导入完成。"
            } catch {
                errorMessage = "无法导入布局：\(error.localizedDescription)"
            }
        }
    }

    func importLayout(from url: URL) throws {
        guard !sessionIsReadOnly, !isLoadingOperationHistory else { return }
        let imported = try layoutStore.importedCanvas(from: url, expectedRootResourceID: rootResourceID)
        if !layoutIsBlocked { captureUndoSnapshot(summary: "导入空间布局") }
        layoutIsBlocked = false
        applySavedCanvas(imported)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true, backupReason: "导入布局前")
    }

    func chooseReplacementFolder() {
        let panel = NSOpenPanel()
        panel.title = "重新关联原来的空间"
        panel.prompt = "重新关联"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() != .OK || panel.url == nil { return }
        guard let replacement = panel.url else { return }
        let replacementID = persistentResourceIdentifier(for: replacement) ?? "path:\(replacement.standardizedFileURL.path)"
        let preservingCurrentLayout = replacementID == rootResourceID || confirmLayoutTransfer(to: replacement)
        if preservingCurrentLayout {
            relink(to: replacement, preservingCurrentLayout: true)
        }
    }

    func relink(to replacement: URL, preservingCurrentLayout: Bool) {
        guard Self.directoryExists(at: replacement) else { return }
        let previous = savedCanvas
        replaceCurrentSpaceReference(with: replacement)
        performOpen(folder: replacement.standardizedFileURL)
        guard preservingCurrentLayout, !sessionIsReadOnly else { return }
        var transferred = remappedCanvas(previous, to: replacement.standardizedFileURL, matching: items)
        transferred.rootResourceID = rootResourceID
        transferred.resourcePaths = [:]
        layoutIsBlocked = false
        applySavedCanvas(transferred)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true, backupReason: "重新关联空间前")
    }

    private func remappedCanvas(
        _ canvas: SavedCanvas,
        to replacement: URL,
        matching replacementItems: [FolderItem]
    ) -> SavedCanvas {
        var remapped = canvas
        let replacementPaths = Dictionary(uniqueKeysWithValues: replacementItems.map { ($0.name, $0.id) })
        func replacementPath(for oldPath: String) -> String {
            let name = URL(fileURLWithPath: oldPath).lastPathComponent
            return replacementPaths[name] ?? replacement.appendingPathComponent(name).path
        }
        remapped.positions = Dictionary(uniqueKeysWithValues: canvas.positions.map { oldPath, point in
            (replacementPath(for: oldPath), point)
        })
        remapped.scales = Dictionary(uniqueKeysWithValues: canvas.scales.map { oldPath, scale in
            (replacementPath(for: oldPath), scale)
        })
        remapped.inboxIDs = Set(canvas.inboxIDs.map { oldPath in
            replacementPath(for: oldPath)
        })
        return remapped
    }

    // MARK: - Finder 风格命令与真实文件事务

    func open(_ item: FolderItem) { open([item]) }

    func open(_ targetItems: [FolderItem]) {
        for item in targetItems { NSWorkspace.shared.open(item.url) }
    }

    func reveal(_ item: FolderItem) {
        reveal([item])
    }

    func reveal(_ targetItems: [FolderItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(targetItems.map(\.url))
    }

    func showInfo(_ item: FolderItem) {
        infoItem = item
        infoSnapshot = nil
        let repository = folderAccessRepository
        Task { [weak self] in
            do {
                let snapshot = try await repository.attributes(of: item.url)
                guard self?.infoItem?.id == item.id else { return }
                self?.infoSnapshot = snapshot
            } catch {
                guard self?.infoItem?.id == item.id else { return }
                self?.errorMessage = "无法读取文件信息：\(error.localizedDescription)"
            }
        }
    }

    func share(_ item: FolderItem) { share([item]) }

    func share(_ targetItems: [FolderItem]) {
        guard !targetItems.isEmpty else { return }
        guard let view = NSApp.keyWindow?.contentView else {
            errorMessage = "当前没有可用于分享的窗口。"
            return
        }
        let picker = NSSharingServicePicker(items: targetItems.map(\.url))
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func toggleTag(_ tag: String, for item: FolderItem) {
        toggleTag(tag, for: [item])
    }

    func toggleTag(_ tag: String, for targetItems: [FolderItem]) {
        let targets = currentItems(for: targetItems)
        guard realFileMutationsAllowed(), !targets.isEmpty else { return }
        let normalized = normalizedTagName(tag)
        let targetColor = FinderTagColor(finderTag: tag)
        let tagActions = targets.map { item -> TagAction in
            var tags = item.tags
            if let targetColor,
               tags.contains(where: { FinderTagColor(finderTag: $0) == targetColor }) {
                tags.removeAll { FinderTagColor(finderTag: $0) == targetColor }
            } else if let index = tags.firstIndex(where: { normalizedTagName($0) == normalized }) {
                tags.remove(at: index)
            } else {
                tags.append(tag)
            }
            return TagAction(path: item.url.path, before: item.tags, after: tags)
        }
        if fileOperationsAsynchronously {
            guard let record = beginFileOperation(
                kind: .tags,
                summary: "修改 \(targets.count) 个项目的标签",
                itemNames: targets.map(\.name)
            ) else { return }
            startCoordinatedTags(recordID: record.id, title: "修改标签", actions: tagActions)
            return
        }
        guard var record = beginFileOperation(
            kind: .tags,
            summary: "修改 \(targets.count) 个项目的标签",
            itemNames: targets.map(\.name)
        ) else { return }
        do {
            for value in tagActions {
                try writeFinderTags(value.after, to: URL(fileURLWithPath: value.path))
                record.actions.append(.tags(value))
                replaceOperationRecord(record)
            }
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            refreshItems()
        } catch {
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法更新标签：\(error.localizedDescription)"
        }
    }

    func clearTags(for item: FolderItem) {
        clearTags(for: [item])
    }

    func clearTags(for targetItems: [FolderItem]) {
        let targets = currentItems(for: targetItems).filter { !$0.tags.isEmpty }
        guard realFileMutationsAllowed(), !targets.isEmpty else { return }
        let tagActions = targets.map { TagAction(path: $0.url.path, before: $0.tags, after: []) }
        if fileOperationsAsynchronously {
            guard let record = beginFileOperation(
                kind: .tags,
                summary: "清除 \(targets.count) 个项目的标签",
                itemNames: targets.map(\.name)
            ) else { return }
            startCoordinatedTags(recordID: record.id, title: "清除标签", actions: tagActions)
            return
        }
        guard var record = beginFileOperation(
            kind: .tags,
            summary: "清除 \(targets.count) 个项目的标签",
            itemNames: targets.map(\.name)
        ) else { return }
        do {
            for item in targets {
                try writeFinderTags([], to: item.url)
                record.actions.append(.tags(TagAction(path: item.url.path, before: item.tags, after: [])))
                replaceOperationRecord(record)
            }
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            refreshItems()
        } catch {
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法清除标签：\(error.localizedDescription)"
        }
    }

    func copy(_ items: [FolderItem]) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutURLs = []
    }

    func cut(_ items: [FolderItem]) {
        guard !items.isEmpty else { return }
        copy(items)
        cutURLs = items.map(\.url)
    }

    func paste() {
        let urls = ((NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [NSURL]) ?? [])
            .map { $0 as URL }
        guard !urls.isEmpty else {
            errorMessage = "剪贴板中没有可粘贴的文件或文件夹。"
            return
        }
        importFiles(urls, move: urls.allSatisfy { source in cutURLs.contains(source) })
        cutURLs = []
    }

    func duplicate(_ item: FolderItem) {
        duplicate([item])
    }

    func duplicate(_ targetItems: [FolderItem]) {
        guard realFileMutationsAllowed(), !targetItems.isEmpty else { return }
        if fileOperationsAsynchronously {
            let sources = targetItems.map(\.url)
            let names = targetItems.map(\.name)
            let repository = folderAccessRepository
            startFilePreparation(title: "准备制作副本") {
                await repository.duplicatePlans(for: sources)
            } completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(plans):
                    guard let record = self.beginFileOperation(
                        kind: .duplicate,
                        summary: "制作 \(names.count) 个项目的副本",
                        itemNames: names
                    ) else { return }
                    self.startCoordinatedTransfers(recordID: record.id, title: "制作副本", plans: plans)
                case let .failure(error):
                    self.errorMessage = "无法准备副本目标：\(error.localizedDescription)"
                }
            }
            return
        }
        var reserved: Set<String> = []
        let plans = targetItems.map { item -> FileTransferPlan in
            let destination = uniqueDestination(
                for: item.url,
                in: item.url.deletingLastPathComponent(),
                excluding: reserved
            )
            reserved.insert(destination.path)
            return FileTransferPlan(
                source: item.url,
                destination: destination,
                move: false,
                replacesExistingDestination: false
            )
        }
        guard var record = beginFileOperation(
            kind: .duplicate,
            summary: "制作 \(targetItems.count) 个项目的副本",
            itemNames: targetItems.map(\.name)
        ) else { return }
        do {
            for plan in plans {
                try FileManager.default.copyItem(at: plan.source, to: plan.destination)
                record.actions.append(.materialize(MaterializeAction(destinationPath: plan.destination.path)))
                replaceOperationRecord(record)
            }
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            refreshItems()
            captureCanvasMetadata(in: &record)
            replaceOperationRecord(record)
        } catch {
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法复制文件：\(error.localizedDescription)"
        }
    }

    func compress(_ item: FolderItem) {
        compress([item])
    }

    func compress(_ targetItems: [FolderItem]) {
        guard let folderURL, realFileMutationsAllowed(), !targetItems.isEmpty else { return }
        if fileOperationsAsynchronously {
            let sources = targetItems.map(\.url)
            let names = targetItems.map(\.name)
            let repository = folderAccessRepository
            startFilePreparation(title: "准备压缩") {
                await repository.compressionPlans(for: sources, destinationFolder: folderURL)
            } completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(plans):
                    guard let record = self.beginFileOperation(
                        kind: .compress,
                        summary: "压缩 \(names.count) 个项目",
                        itemNames: names
                    ) else { return }
                    self.startCoordinatedCompressions(recordID: record.id, title: "压缩文件", plans: plans)
                case let .failure(error):
                    self.errorMessage = "无法准备压缩目标：\(error.localizedDescription)"
                }
            }
            return
        }
        var reserved: Set<String> = []
        let plans = targetItems.map { item -> FileCompressionPlan in
            let requested = folderURL
                .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("zip")
            let destination = uniqueDestination(for: requested, in: folderURL, excluding: reserved)
            reserved.insert(destination.path)
            return FileCompressionPlan(source: item.url, destination: destination)
        }
        guard let record = beginFileOperation(
            kind: .compress,
            summary: "压缩 \(targetItems.count) 个项目",
            itemNames: targetItems.map(\.name)
        ) else { return }
        startCoordinatedCompressions(
            recordID: record.id,
            title: "压缩文件",
            plans: plans
        )
    }

    func importFiles(
        _ urls: [URL],
        move: Bool = false,
        conflictChoice: ConflictChoice? = nil,
        dropPoint: CGPoint? = nil
    ) {
        guard let folderURL, realFileMutationsAllowed() else { return }
        let sources = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != folderURL.standardizedFileURL }
        guard !sources.isEmpty else { return }
        if fileOperationsAsynchronously {
            let repository = folderAccessRepository
            let policy = conflictChoice ?? .cancel
            startFilePreparation(title: move ? "准备移动到空间" : "准备复制到空间") {
                let hasConflict = await repository.containsNameConflict(
                    sources: sources,
                    destinationFolder: folderURL
                )
                let plans = await repository.transferPlans(
                    sources: sources,
                    destinationFolder: folderURL,
                    move: move,
                    policy: policy
                )
                return PreparedImport(hasConflict: hasConflict, plans: plans)
            } completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(prepared):
                    if prepared.hasConflict, conflictChoice == nil {
                        self.presentConflict(
                            title: "目标中已有同名项目",
                            message: sources.count == 1
                                ? "“\(sources[0].lastPathComponent)”已经存在。请选择保留两者、替换现有项目或取消。"
                                : "要导入的项目中存在同名文件。本次选择将应用到所有冲突项目。"
                        ) { [weak self] choice in
                            guard choice != .cancel else { return }
                            self?.importFiles(sources, move: move, conflictChoice: choice, dropPoint: dropPoint)
                        }
                        return
                    }
                    guard let record = self.beginFileOperation(
                        kind: move ? .moveItems : .copyItems,
                        summary: move ? "移动 \(sources.count) 个项目到空间" : "复制 \(sources.count) 个项目到空间",
                        itemNames: sources.map(\.lastPathComponent)
                    ) else { return }
                    if let dropPoint { self.pendingDropPoints[record.id] = dropPoint }
                    self.startCoordinatedTransfers(
                        recordID: record.id,
                        title: move ? "移动到空间" : "复制到空间",
                        plans: prepared.plans
                    )
                case let .failure(error):
                    self.errorMessage = "无法准备导入：\(error.localizedDescription)"
                }
            }
            return
        }
        let hasConflict = sources.contains {
            FileManager.default.fileExists(atPath: folderURL.appendingPathComponent($0.lastPathComponent).path)
        }
        if hasConflict, conflictChoice == nil {
            presentConflict(
                title: "目标中已有同名项目",
                message: sources.count == 1
                    ? "“\(sources[0].lastPathComponent)”已经存在。请选择保留两者、替换现有项目或取消。"
                    : "要导入的项目中存在同名文件。本次选择将应用到所有冲突项目。"
            ) { [weak self] choice in
                guard choice != .cancel else { return }
                self?.importFiles(sources, move: move, conflictChoice: choice, dropPoint: dropPoint)
            }
            return
        }
        let policy = conflictChoice ?? .cancel
        guard var record = beginFileOperation(
            kind: move ? .moveItems : .copyItems,
            summary: move ? "移动 \(sources.count) 个项目到空间" : "复制 \(sources.count) 个项目到空间",
            itemNames: sources.map(\.lastPathComponent)
        ) else { return }
        do {
            for source in sources {
                var target = folderURL.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    if policy == .keepBoth {
                        target = uniqueDestination(for: source, in: folderURL)
                    } else if policy == .replace {
                        let trashURL = try trashItemRecordingResult(at: target)
                        record.actions.append(.discard(DiscardAction(originalPath: target.path, trashPath: trashURL.path)))
                        replaceOperationRecord(record)
                    } else {
                        throw FileOperationTransitionError.cancelled
                    }
                }
                if move {
                    try FileManager.default.moveItem(at: source, to: target)
                    record.actions.append(.relocate(RelocateAction(originalPath: source.path, destinationPath: target.path)))
                } else {
                    try FileManager.default.copyItem(at: source, to: target)
                    record.actions.append(.materialize(MaterializeAction(destinationPath: target.path)))
                }
                replaceOperationRecord(record)
            }
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            if let dropPoint { applyImportedPlacement(from: record.actions, near: dropPoint) }
            refreshItems()
            captureCanvasMetadata(in: &record)
            replaceOperationRecord(record)
        } catch {
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法导入文件：\(error.localizedDescription)"
        }
    }

    /// 只读扫描桌面并生成确认信息；用户确认前不修改任何真实文件。
    ///
    /// 所有入口都必须先经过这里，确认后的批量移动继续沿用原有事务和回滚机制。
    func collectDesktopItems() {
        guard let folderURL, !layoutIsBlocked, !folderUnavailable else { return }
        guard realFileMutationsAllowed() else { return }
        let destinationFolder = folderURL.standardizedFileURL
        let desktopDirectory = desktopDirectoryURL
        guard destinationFolder != desktopDirectory else {
            presentStatusMessage("当前空间就是桌面，无需收纳。")
            return
        }

        let repository = folderAccessRepository
        startFilePreparation(title: "准备收纳桌面") {
            let sources = try await repository.desktopCollectionSources(
                in: desktopDirectory,
                destinationFolder: destinationFolder
            )
            let plans = await repository.transferPlans(
                sources: sources,
                destinationFolder: destinationFolder,
                move: true,
                policy: .keepBoth
            )
            var fileCount = 0
            var folderCount = 0
            for source in sources {
                if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    folderCount += 1
                } else {
                    fileCount += 1
                }
            }
            return PreparedDesktopCollection(
                sources: sources,
                plans: plans,
                destinationFolder: destinationFolder,
                fileCount: fileCount,
                folderCount: folderCount
            )
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(prepared):
                guard !prepared.sources.isEmpty else {
                    self.presentStatusMessage("桌面已经很干净。")
                    return
                }
                self.preparedDesktopCollection = prepared
                self.desktopCollectionConfirmation = DesktopCollectionConfirmation(
                    id: UUID(),
                    destinationName: prepared.destinationFolder.lastPathComponent,
                    fileCount: prepared.fileCount,
                    folderCount: prepared.folderCount
                )
            case let .failure(error):
                self.errorMessage = "无法读取桌面项目：\(error.localizedDescription)"
            }
        }
    }

    func confirmDesktopCollection() {
        guard let prepared = preparedDesktopCollection,
              let folderURL,
              folderURL.standardizedFileURL == prepared.destinationFolder.standardizedFileURL
        else {
            cancelDesktopCollection()
            presentStatusMessage("当前空间已经变化，请重新检查桌面项目。")
            return
        }
        desktopCollectionConfirmation = nil
        preparedDesktopCollection = nil
        guard realFileMutationsAllowed(),
              let record = beginFileOperation(
                  kind: .moveItems,
                  summary: "收纳桌面 \(prepared.sources.count) 个项目",
                  itemNames: prepared.sources.map(\.lastPathComponent)
              )
        else { return }
        pendingDropPoints[record.id] = CGPoint(
            x: max(0, canvasSize.width - 132),
            y: max(0, canvasSize.height - 180)
        )
        pendingDesktopCollectionIDs.insert(record.id)
        startCoordinatedTransfers(
            recordID: record.id,
            title: "收纳桌面",
            plans: prepared.plans
        )
    }

    func cancelDesktopCollection() {
        desktopCollectionConfirmation = nil
        preparedDesktopCollection = nil
    }

    /// 用户点击进度条取消按钮后只设置取消标记；协调器会在当前文件系统调用结束后安全回滚。
    func cancelCurrentFileOperation() {
        guard var progress = fileOperationProgress, progress.allowsCancellation else { return }
        progress.isCancelling = true
        progress.detail = "正在完成当前步骤并准备回滚…"
        fileOperationProgress = progress
        fileOperationTask?.cancel()
    }

    // MARK: - 后台文件操作协调

    /// 目标命名和冲突探测也可能访问网络磁盘。统一显示短暂准备状态，并在结果回到主线程后
    /// 再创建 pending 事务；准备阶段只读，不会修改真实文件。
    private func startFilePreparation<Value: Sendable>(
        title: String,
        work: @escaping @Sendable () async throws -> Value,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        let preparationID = UUID()
        fileOperationProgress = FileOperationProgressState(
            id: preparationID,
            title: title,
            detail: "正在检查目标名称和磁盘状态…",
            completedUnitCount: 0,
            totalUnitCount: 0,
            isCancelling: false,
            allowsCancellation: false
        )
        fileOperationTask = Task { [weak self] in
            let result: Result<Value, Error>
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            guard let self, self.fileOperationProgress?.id == preparationID else { return }
            self.fileOperationProgress = nil
            self.fileOperationTask = nil
            completion(result)
        }
    }

    private func startCoordinatedTransfers(
        recordID: UUID,
        title: String,
        plans: [FileTransferPlan]
    ) {
        let total = plans.reduce(0) { $0 + ($1.replacesExistingDestination ? 2 : 1) }
        fileOperationProgress = FileOperationProgressState(
            id: recordID,
            title: title,
            detail: "正在准备…",
            completedUnitCount: 0,
            totalUnitCount: total,
            isCancelling: false,
            allowsCancellation: true
        )
        let coordinator = fileOperationCoordinator
        fileOperationTask = Task { [weak self] in
            do {
                guard let self else { throw CancellationError() }
                try await self.waitForOperationJournal()
                let actions = try await coordinator.performTransfers(plans) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self.finishCoordinatedOperation(recordID: recordID, actions: actions)
            } catch let failure as CoordinatedFileOperationFailure {
                self?.finishCoordinatedOperation(recordID: recordID, failure: failure)
            } catch {
                self?.finishCoordinatedOperation(recordID: recordID, unexpectedError: error)
            }
        }
    }

    private func startCoordinatedCompressions(
        recordID: UUID,
        title: String,
        plans: [FileCompressionPlan]
    ) {
        fileOperationProgress = FileOperationProgressState(
            id: recordID,
            title: title,
            detail: "正在准备…",
            completedUnitCount: 0,
            totalUnitCount: plans.count,
            isCancelling: false,
            allowsCancellation: true
        )
        let coordinator = fileOperationCoordinator
        fileOperationTask = Task { [weak self] in
            do {
                guard let self else { throw CancellationError() }
                try await self.waitForOperationJournal()
                let actions = try await coordinator.performCompressions(plans) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self.finishCoordinatedOperation(recordID: recordID, actions: actions)
            } catch let failure as CoordinatedFileOperationFailure {
                self?.finishCoordinatedOperation(recordID: recordID, failure: failure)
            } catch {
                self?.finishCoordinatedOperation(recordID: recordID, unexpectedError: error)
            }
        }
    }

    private func startCoordinatedTrash(
        recordID: UUID,
        title: String,
        urls: [URL]
    ) {
        fileOperationProgress = FileOperationProgressState(
            id: recordID,
            title: title,
            detail: "正在准备…",
            completedUnitCount: 0,
            totalUnitCount: urls.count,
            isCancelling: false,
            allowsCancellation: true
        )
        let coordinator = fileOperationCoordinator
        fileOperationTask = Task { [weak self] in
            do {
                guard let self else { throw CancellationError() }
                try await self.waitForOperationJournal()
                let actions = try await coordinator.performTrash(urls) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self.finishCoordinatedOperation(recordID: recordID, actions: actions)
            } catch let failure as CoordinatedFileOperationFailure {
                self?.finishCoordinatedOperation(recordID: recordID, failure: failure)
            } catch {
                self?.finishCoordinatedOperation(recordID: recordID, unexpectedError: error)
            }
        }
    }

    private func startCoordinatedCreate(recordID: UUID, title: String, destination: URL) {
        fileOperationProgress = FileOperationProgressState(
            id: recordID,
            title: title,
            detail: "正在准备…",
            completedUnitCount: 0,
            totalUnitCount: 1,
            isCancelling: false,
            allowsCancellation: false
        )
        let coordinator = fileOperationCoordinator
        fileOperationTask = Task { [weak self] in
            do {
                guard let self else { throw CancellationError() }
                try await self.waitForOperationJournal()
                let actions = try await coordinator.createDirectory(at: destination) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self.finishCoordinatedOperation(recordID: recordID, actions: actions)
            } catch let failure as CoordinatedFileOperationFailure {
                self?.finishCoordinatedOperation(recordID: recordID, failure: failure)
            } catch {
                self?.finishCoordinatedOperation(recordID: recordID, unexpectedError: error)
            }
        }
    }

    private func startCoordinatedTags(recordID: UUID, title: String, actions: [TagAction]) {
        fileOperationProgress = FileOperationProgressState(
            id: recordID,
            title: title,
            detail: "正在准备…",
            completedUnitCount: 0,
            totalUnitCount: actions.count,
            isCancelling: false,
            allowsCancellation: actions.count > 1
        )
        let coordinator = fileOperationCoordinator
        fileOperationTask = Task { [weak self] in
            do {
                guard let self else { throw CancellationError() }
                try await self.waitForOperationJournal()
                let completed = try await coordinator.applyTags(actions) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self.finishCoordinatedOperation(recordID: recordID, actions: completed)
            } catch let failure as CoordinatedFileOperationFailure {
                self?.finishCoordinatedOperation(recordID: recordID, failure: failure)
            } catch {
                self?.finishCoordinatedOperation(recordID: recordID, unexpectedError: error)
            }
        }
    }

    /// 每个真实文件步骤完成后立即更新并原子写入操作记录。
    private func applyCoordinatorEvent(
        _ event: CoordinatedFileOperationEvent,
        recordID: UUID
    ) async throws {
        guard let index = operationRecords.firstIndex(where: { $0.id == recordID }) else {
            throw CancellationError()
        }
        var record = operationRecords[index]
        switch event {
        case let .willBegin(_, total, detail):
            record.detail = detail
            record.transitionDate = Date()
            if var progress = fileOperationProgress, progress.id == recordID {
                progress.detail = detail
                progress.totalUnitCount = total
                fileOperationProgress = progress
            }
        case let .didApply(action, completed, total):
            record.actions.append(action)
            record.detail = "已完成 \(completed)/\(total) 个文件步骤"
            record.transitionDate = Date()
            if var progress = fileOperationProgress, progress.id == recordID {
                progress.completedUnitCount = completed
                progress.totalUnitCount = total
                progress.detail = record.detail ?? progress.detail
                fileOperationProgress = progress
            }
        case let .rollingBack(detail):
            record.detail = detail
            record.transitionDate = Date()
            if var progress = fileOperationProgress, progress.id == recordID {
                progress.detail = detail
                progress.isCancelling = true
                fileOperationProgress = progress
            }
        }
        operationRecords[index] = record
        do {
            try await persistOperationRecordNow(record)
        } catch {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func finishCoordinatedOperation(
        recordID: UUID,
        actions: [ReversibleFileAction]
    ) {
        guard var record = operationRecords.first(where: { $0.id == recordID }) else { return }
        let completedDesktopCollection = pendingDesktopCollectionIDs.remove(recordID) != nil
        record.actions = actions
        record.state = .applied
        record.transitionDate = Date()
        record.detail = nil
        if let dropPoint = pendingDropPoints.removeValue(forKey: recordID) {
            applyImportedPlacement(
                from: actions,
                near: dropPoint,
                stacksAtSinglePoint: completedDesktopCollection
            )
        }
        if completedDesktopCollection {
            captureCanvasMetadata(in: &record)
        }
        // 删除/替换动作完成后立即清除画布上的旧路径；真实文件刷新随后再确认最终状态。
        if record.kind == .trash {
            for action in actions {
                guard case let .discard(value) = action else { continue }
                positions.removeValue(forKey: value.originalPath)
                scales.removeValue(forKey: value.originalPath)
                inboxIDs.remove(value.originalPath)
                selectedIDs.remove(value.originalPath)
            }
        }
        replaceOperationRecord(record)
        fileOperationProgress = nil
        fileOperationTask = nil
        persist(makeBackup: true)
        refreshItems()
        if completedDesktopCollection {
            let movedCount = actions.reduce(into: 0) { count, action in
                if case .relocate = action { count += 1 }
            }
            presentStatusMessage("已收纳 \(movedCount) 个桌面项目。")
        }
    }

    private func finishCoordinatedOperation(
        recordID: UUID,
        failure: CoordinatedFileOperationFailure
    ) {
        guard var record = operationRecords.first(where: { $0.id == recordID }) else { return }
        record.actions = failure.actions
        record.displacements = failure.displacements
        record.state = failure.rollbackSucceeded ? .failed : .unavailable
        record.transitionDate = Date()
        record.detail = failure.rollbackSucceeded
            ? "\(failure.message) 已恢复本批次完成的内容。"
            : "\(failure.message) 无法完整恢复，请在访达中核对。"
        pendingDropPoints.removeValue(forKey: recordID)
        pendingDesktopCollectionIDs.remove(recordID)
        replaceOperationRecord(record)
        fileOperationProgress = nil
        fileOperationTask = nil
        refreshItems()
        errorMessage = record.detail
        refreshRecoveryCases(presentWhenNeeded: true)
    }

    private func finishCoordinatedOperation(recordID: UUID, unexpectedError: Error) {
        guard var record = operationRecords.first(where: { $0.id == recordID }) else { return }
        record.state = .unavailable
        record.transitionDate = Date()
        record.detail = "操作异常中断：\(unexpectedError.localizedDescription)。请在访达中核对。"
        pendingDropPoints.removeValue(forKey: recordID)
        pendingDesktopCollectionIDs.remove(recordID)
        replaceOperationRecord(record)
        fileOperationProgress = nil
        fileOperationTask = nil
        refreshItems()
        errorMessage = record.detail
        refreshRecoveryCases(presentWhenNeeded: true)
    }

    func trash(_ item: FolderItem) {
        trash([item])
    }

    func trash(_ targetItems: [FolderItem]) {
        guard realFileMutationsAllowed(), !targetItems.isEmpty else { return }
        let canvasItems = targetItems.enumerated().map { index, item in
            canvasMetadata(for: item.id, actionIndex: index)
        }
        if fileOperationsAsynchronously {
            guard let record = beginFileOperation(
                kind: .trash,
                summary: "将 \(targetItems.count) 个项目移至废纸篓",
                itemNames: targetItems.map(\.name),
                canvasItems: canvasItems
            ) else { return }
            startCoordinatedTrash(
                recordID: record.id,
                title: "移至废纸篓",
                urls: targetItems.map(\.url)
            )
            return
        }
        guard var record = beginFileOperation(
            kind: .trash,
            summary: "将 \(targetItems.count) 个项目移至废纸篓",
            itemNames: targetItems.map(\.name),
            canvasItems: canvasItems
        ) else { return }
        do {
            for item in targetItems {
                let trashURL = try trashItemRecordingResult(at: item.url)
                record.actions.append(.discard(DiscardAction(
                    originalPath: item.url.path,
                    trashPath: trashURL.path
                )))
                replaceOperationRecord(record)
            }
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            for item in targetItems {
                positions.removeValue(forKey: item.id)
                scales.removeValue(forKey: item.id)
                inboxIDs.remove(item.id)
                selectedIDs.remove(item.id)
            }
            persist(makeBackup: true, backupReason: "移至废纸篓前")
            refreshItems()
        } catch {
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法移至废纸篓：\(error.localizedDescription)"
        }
    }

    func createFolder() {
        guard let folderURL, realFileMutationsAllowed() else { return }
        if fileOperationsAsynchronously {
            let repository = folderAccessRepository
            startFilePreparation(title: "准备新建文件夹") {
                await repository.uniqueNamedItem(in: folderURL, baseName: "新建文件夹")
            } completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(destination):
                    let name = destination.lastPathComponent
                    guard let record = self.beginFileOperation(
                        kind: .createFolder,
                        summary: "新建“\(name)”",
                        itemNames: [name]
                    ) else { return }
                    self.startCoordinatedCreate(recordID: record.id, title: "新建文件夹", destination: destination)
                case let .failure(error):
                    self.errorMessage = "无法准备新文件夹：\(error.localizedDescription)"
                }
            }
            return
        }
        var name = "新建文件夹"
        var suffix = 2
        while FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(name).path) {
            name = "新建文件夹 \(suffix)"
            suffix += 1
        }
        let destination = folderURL.appendingPathComponent(name)
        guard var record = beginFileOperation(
            kind: .createFolder,
            summary: "新建“\(name)”",
            itemNames: [name],
            actions: [.materialize(MaterializeAction(destinationPath: destination.path))]
        ) else { return }
        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            refreshItems()
            captureCanvasMetadata(in: &record)
            replaceOperationRecord(record)
        } catch {
            markOperationFailed(&record, error: error)
            errorMessage = "无法新建文件夹：\(error.localizedDescription)"
        }
    }

    func createExcelWorkbook() {
        createFromTemplate(resource: "BlankWorkbook", baseName: "新建 Excel 工作簿", extension: "xlsx")
    }

    func createWordDocument() {
        createFromTemplate(resource: "BlankDocument", baseName: "新建 Word 文档", extension: "docx")
    }

    func createPowerPointPresentation() {
        createFromTemplate(resource: "BlankPresentation", baseName: "新建 PowerPoint 演示文稿", extension: "pptx")
    }

    func rename(_ item: FolderItem, to name: String, conflictChoice: ConflictChoice? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, realFileMutationsAllowed() else { return }
        var newURL = item.url.deletingLastPathComponent().appendingPathComponent(cleanName)
        guard newURL != item.url else { return }
        if fileOperationsAsynchronously {
            let repository = folderAccessRepository
            let requestedURL = newURL
            startFilePreparation(title: "准备重命名") {
                let exists = await repository.itemExists(at: requestedURL)
                if exists, conflictChoice == .keepBoth {
                    let unique = await repository.uniqueDestination(
                        for: requestedURL,
                        in: requestedURL.deletingLastPathComponent()
                    )
                    return PreparedRename(destination: unique, replacesExisting: false, hasConflict: true)
                }
                return PreparedRename(
                    destination: requestedURL,
                    replacesExisting: exists && conflictChoice == .replace,
                    hasConflict: exists
                )
            } completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(prepared):
                    if prepared.hasConflict, conflictChoice == nil {
                        self.presentConflict(
                            title: "名称已存在",
                            message: "“\(cleanName)”已经存在。请选择保留两者、替换现有项目或取消。"
                        ) { [weak self] choice in
                            guard choice != .cancel else { return }
                            self?.rename(item, to: cleanName, conflictChoice: choice)
                        }
                        return
                    }
                    let actionIndex = prepared.replacesExisting ? 1 : 0
                    guard let record = self.beginFileOperation(
                        kind: .rename,
                        summary: "将“\(item.name)”重命名为“\(prepared.destination.lastPathComponent)”",
                        itemNames: [item.name, prepared.destination.lastPathComponent],
                        canvasItems: [self.canvasMetadata(for: item.id, actionIndex: actionIndex)]
                    ) else { return }
                    self.startCoordinatedTransfers(
                        recordID: record.id,
                        title: "重命名",
                        plans: [FileTransferPlan(
                            source: item.url,
                            destination: prepared.destination,
                            move: true,
                            replacesExistingDestination: prepared.replacesExisting
                        )]
                    )
                case let .failure(error):
                    self.errorMessage = "无法准备重命名：\(error.localizedDescription)"
                }
            }
            return
        }
        if FileManager.default.fileExists(atPath: newURL.path), conflictChoice == nil {
            presentConflict(
                title: "名称已存在",
                message: "“\(cleanName)”已经存在。请选择保留两者、替换现有项目或取消。"
            ) { [weak self] choice in
                guard choice != .cancel else { return }
                self?.rename(item, to: cleanName, conflictChoice: choice)
            }
            return
        }
        var actions: [ReversibleFileAction] = []
        if FileManager.default.fileExists(atPath: newURL.path), conflictChoice == .keepBoth {
            newURL = uniqueDestination(for: newURL, in: newURL.deletingLastPathComponent())
        }
        guard var record = beginFileOperation(
            kind: .rename,
            summary: "将“\(item.name)”重命名为“\(newURL.lastPathComponent)”",
            itemNames: [item.name, newURL.lastPathComponent]
        ) else { return }
        do {
            if FileManager.default.fileExists(atPath: newURL.path) {
                guard conflictChoice == .replace else { throw FileOperationTransitionError.cancelled }
                let trashURL = try trashItemRecordingResult(at: newURL)
                actions.append(.discard(DiscardAction(originalPath: newURL.path, trashPath: trashURL.path)))
            }
            try FileManager.default.moveItem(at: item.url, to: newURL)
            actions.append(.relocate(RelocateAction(originalPath: item.url.path, destinationPath: newURL.path)))
            record.actions = actions
            record.canvasItems = [canvasMetadata(for: item.id, actionIndex: actions.count - 1)]
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            transferLayout(from: item.id, to: newURL.path)
            if let resourceID = item.resourceID { savedCanvas.resourcePaths[resourceID] = newURL.path }
            persist(makeBackup: true)
            refreshItems()
        } catch {
            record.actions = actions
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法重命名：\(error.localizedDescription)"
        }
    }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "选择画布壁纸"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { setWallpaper(url) }
    }

    func setWallpaper(_ url: URL?) {
        guard canChangeWallpaper else { return }
        let standardizedURL = url?.standardizedFileURL
        guard wallpaperURL?.standardizedFileURL != standardizedURL else { return }
        captureUndoSnapshot(summary: url == nil ? "使用系统桌面壁纸" : "更换画布壁纸")
        wallpaperURL = standardizedURL
        persist(makeBackup: true)
    }

    func hasTag(_ tag: String, in item: FolderItem) -> Bool {
        if let color = FinderTagColor(finderTag: tag) {
            return item.tags.contains { FinderTagColor(finderTag: $0) == color }
        }
        return item.tags.contains { normalizedTagName($0) == normalizedTagName(tag) }
    }

    func normalizedTagName(_ tag: String) -> String {
        tag.components(separatedBy: "\n").first ?? tag
    }

    private func beginFileOperation(
        kind: OperationKind,
        summary: String,
        itemNames: [String],
        actions: [ReversibleFileAction] = [],
        canvasItems: [OperationCanvasItem] = []
    ) -> OperationRecord? {
        guard realFileMutationsAllowed() else { return nil }
        let record = OperationRecord(
            category: .file,
            kind: kind,
            summary: summary,
            itemNames: itemNames,
            state: .pending,
            actions: actions,
            canvasItems: canvasItems
        )
        appendOperationRecord(record)
        return operationHistoryIsBlocked ? nil : record
    }

    private func markOperationFailed(_ record: inout OperationRecord, error: Error) {
        record.state = .failed
        record.transitionDate = Date()
        record.detail = error.localizedDescription
        replaceOperationRecord(record)
    }

    private func rollbackPendingOperation(_ record: inout OperationRecord) {
        let originalDetail = record.detail
        guard !record.actions.isEmpty else {
            record.state = .failed
            record.transitionDate = Date()
            record.detail = originalDetail ?? "操作未完成。"
            replaceOperationRecord(record)
            return
        }
        do {
            record.state = .applied
            record = try fileOperationEngine.transition(record, to: .undone, conflictChoice: .replace)
            record.state = .failed
            record.detail = originalDetail ?? "操作失败，已回滚完成的文件变更。"
        } catch {
            record.state = .unavailable
            record.detail = "操作失败且无法完整回滚：\(error.localizedDescription)。请在访达中核对。"
        }
        record.transitionDate = Date()
        replaceOperationRecord(record)
        refreshItems()
    }

    private func presentConflict(
        title: String,
        message: String,
        resolution: @escaping (ConflictChoice) -> Void
    ) {
        pendingConflict = PendingFileConflict(title: title, message: message)
        conflictResolution = resolution
    }

    private func transitionFileOperation(
        id: UUID,
        to targetState: OperationState,
        conflictChoice: ConflictChoice
    ) {
        guard realFileMutationsAllowed(),
              let record = operationRecords.first(where: { $0.id == id }) else { return }
        if fileOperationsAsynchronously {
            startCoordinatedTransition(
                record: record,
                targetState: targetState,
                conflictChoice: conflictChoice
            )
            return
        }
        do {
            let updated = try fileOperationEngine.transition(
                record,
                to: targetState,
                conflictChoice: conflictChoice
            )
            applyCanvasMetadata(from: record, updated: updated, targetState: targetState)
            replaceOperationRecord(updated)
            refreshItems()
            persist(makeBackup: true)
        } catch let conflict as FileOperationConflict {
            presentConflict(
                title: targetState == .undone ? "撤销时发现同名项目" : "重做时发现同名项目",
                message: "\(conflict.localizedDescription)请选择保留两者、替换现有项目或取消。"
            ) { [weak self] choice in
                guard choice != .cancel else { return }
                self?.transitionFileOperation(id: id, to: targetState, conflictChoice: choice)
            }
        } catch {
            errorMessage = "无法\(targetState == .undone ? "撤销" : "重做")操作：\(error.localizedDescription)"
        }
    }

    /// 撤销/重做也可能涉及很多真实文件，生产模式下同样离开主线程执行。
    private func startCoordinatedTransition(
        record: OperationRecord,
        targetState: OperationState,
        conflictChoice: ConflictChoice
    ) {
        var transitioning = record
        transitioning.state = targetState == .undone ? .undoing : .redoing
        transitioning.transitionDate = Date()
        transitioning.detail = targetState == .undone ? "正在撤销文件操作" : "正在重做文件操作"
        replaceOperationRecord(transitioning)

        fileOperationProgress = FileOperationProgressState(
            id: record.id,
            title: targetState == .undone ? "撤销文件操作" : "重做文件操作",
            detail: transitioning.detail ?? "正在准备…",
            completedUnitCount: 0,
            totalUnitCount: 1,
            isCancelling: false,
            allowsCancellation: false
        )
        let coordinator = fileOperationCoordinator
        fileOperationTask = Task { [weak self] in
            do {
                guard let self else { throw CancellationError() }
                try await self.waitForOperationJournal()
                let updated = try await coordinator.transition(
                    record: record,
                    to: targetState,
                    conflictChoice: conflictChoice
                ) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: record.id)
                }
                self.applyCanvasMetadata(from: record, updated: updated, targetState: targetState)
                self.replaceOperationRecord(updated)
                self.fileOperationProgress = nil
                self.fileOperationTask = nil
                self.refreshItems()
                self.persist(makeBackup: true)
            } catch let conflict as FileOperationConflict {
                guard let self else { return }
                self.replaceOperationRecord(record)
                self.fileOperationProgress = nil
                self.fileOperationTask = nil
                self.presentConflict(
                    title: targetState == .undone ? "撤销时发现同名项目" : "重做时发现同名项目",
                    message: "\(conflict.localizedDescription)请选择保留两者、替换现有项目或取消。"
                ) { [weak self] choice in
                    guard choice != .cancel else { return }
                    self?.transitionFileOperation(id: record.id, to: targetState, conflictChoice: choice)
                }
            } catch {
                guard let self else { return }
                var unavailable = record
                unavailable.state = .unavailable
                unavailable.transitionDate = Date()
                unavailable.detail = "文件操作未能确认完成：\(error.localizedDescription)。请在访达中核对。"
                self.replaceOperationRecord(unavailable)
                self.fileOperationProgress = nil
                self.fileOperationTask = nil
                self.refreshItems()
                self.errorMessage = unavailable.detail
            }
        }
    }

    private func canvasMetadata(for path: String, actionIndex: Int) -> OperationCanvasItem {
        OperationCanvasItem(
            actionIndex: actionIndex,
            position: positions[path],
            scale: scales[path],
            wasInInbox: inboxIDs.contains(path)
        )
    }

    /// 文件已经成功进入目标目录后，再把最终目标路径放到鼠标落点附近。
    /// 失败批次不会污染画布布局；已有图标由纯布局引擎作为占用区，只读不重排。
    private func applyImportedPlacement(
        from actions: [ReversibleFileAction],
        near point: CGPoint,
        stacksAtSinglePoint: Bool = false
    ) {
        let importedPaths = actions.compactMap { action -> String? in
            switch action {
            case let .relocate(value): value.destinationPath
            case let .materialize(value): value.destinationPath
            case .discard, .tags: nil
            }
        }
        guard !importedPaths.isEmpty else { return }
        let importedItems = importedPaths.map {
            CanvasLayoutItem(id: $0, scale: scales[$0] ?? defaultIconScale)
        }
        let existingItems = layoutItems(items)
        let result = if stacksAtSinglePoint {
            layoutEngine.stackImportedItems(
                importedItems,
                near: point,
                existingItems: existingItems,
                positions: positions,
                inboxIDs: inboxIDs,
                canvasSize: canvasSize
            )
        } else {
            layoutEngine.placeImportedItems(
                importedItems,
                near: point,
                existingItems: existingItems,
                positions: positions,
                inboxIDs: inboxIDs,
                canvasSize: canvasSize
            )
        }
        positions = result.positions
        inboxIDs = result.inboxIDs
        persist(makeBackup: true)
    }

    private func captureCanvasMetadata(in record: inout OperationRecord) {
        var captured: [OperationCanvasItem] = []
        for index in record.actions.indices {
            guard let path = activePath(for: record.actions[index], state: .applied),
                  positions[path] != nil || inboxIDs.contains(path) else { continue }
            captured.append(canvasMetadata(for: path, actionIndex: index))
        }
        record.canvasItems = captured
    }

    private func presentStatusMessage(_ message: String) {
        statusDismissTask?.cancel()
        statusMessage = message
        statusDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    private func activePath(for action: ReversibleFileAction, state: OperationState) -> String? {
        switch action {
        case let .relocate(value):
            return state == .undone ? value.originalPath : value.destinationPath
        case let .materialize(value):
            return state == .applied ? value.destinationPath : nil
        case let .discard(value):
            return state == .undone ? value.originalPath : nil
        case let .tags(value):
            return value.path
        }
    }

    private func applyCanvasMetadata(
        from previous: OperationRecord,
        updated: OperationRecord,
        targetState: OperationState
    ) {
        for index in previous.actions.indices {
            if let oldPath = activePath(for: previous.actions[index], state: previous.state) {
                positions.removeValue(forKey: oldPath)
                scales.removeValue(forKey: oldPath)
                inboxIDs.remove(oldPath)
                selectedIDs.remove(oldPath)
            }
        }
        for metadata in updated.canvasItems {
            guard updated.actions.indices.contains(metadata.actionIndex),
                  let path = activePath(for: updated.actions[metadata.actionIndex], state: targetState) else { continue }
            if let position = metadata.position { positions[path] = position }
            if let scale = metadata.scale { scales[path] = scale }
            if metadata.wasInInbox { inboxIDs.insert(path) }
        }
    }

    private func trashItemRecordingResult(at url: URL) throws -> URL {
        try fileOperationEngine.moveToTrash(url)
    }

    // MARK: - 布局与操作历史持久化

    private func loadSavedCanvas() {
        savedCanvas = SavedCanvas(rootResourceID: rootResourceID)
        positions = [:]
        scales = [:]
        inboxIDs = []
        wallpaperURL = nil
        isLocked = false
        layoutIsBlocked = false
        needsInitialArrangement = false
        needsGridMigration = false
        guard let canvasKey, let folderURL else { return }
        do {
            switch try layoutStore.load(canvasKey: canvasKey, legacyFolderPath: folderURL.path) {
            case .missing:
                canvasSize = currentDisplaySize
                needsInitialArrangement = true
                savedCanvas = SavedCanvas(
                    canvasSize: CanvasDimensions(canvasSize),
                    rootResourceID: rootResourceID
                )
            case let .loaded(canvas, migratedLegacyLayout):
                let previousLayoutVersion = canvas.layoutVersion
                needsGridMigration = canvas.layoutVersion < 3
                applySavedCanvas(canvas)
                if previousLayoutVersion < 5 {
                    migrateLegacyReferenceCanvasIfUseful()
                }
                if migratedLegacyLayout || previousLayoutVersion < SavedCanvas.currentLayoutVersion {
                    persist(makeBackup: true)
                }
            case let .recovered(canvas, corruptCopyURL):
                applySavedCanvas(canvas)
                errorMessage = "布局文件损坏，已经从最近备份恢复。损坏文件已保存在：\(corruptCopyURL.lastPathComponent)"
            case .blocked:
                layoutIsBlocked = true
                errorMessage = "布局文件损坏且没有可用备份。原文件已保留，请导入布局备份或选择“重置布局”。"
            }
            updateBackupCount()
        } catch {
            layoutIsBlocked = true
            errorMessage = "无法读取布局：\(error.localizedDescription)"
        }
    }

    private func applySavedCanvas(_ canvas: SavedCanvas) {
        savedCanvas = canvas
        savedCanvas.backupMetadata = nil
        positions = canvas.positions
        scales = canvas.scales
        wallpaperURL = canvas.wallpaperPath.map(URL.init(fileURLWithPath:))
        isLocked = canvas.isLocked
        inboxIDs = canvas.inboxIDs
        canvasSize = canvas.canvasSize?.size ?? currentDisplaySize
        savedCanvas.rootResourceID = rootResourceID
        savedCanvas.layoutVersion = SavedCanvas.currentLayoutVersion
        savedCanvas.canvasSize = CanvasDimensions(canvasSize)
    }

    private func syncSavedCanvas() {
        savedCanvas.layoutVersion = SavedCanvas.currentLayoutVersion
        savedCanvas.positions = positions
        savedCanvas.scales = scales
        savedCanvas.wallpaperPath = wallpaperURL?.path
        savedCanvas.isLocked = isLocked
        savedCanvas.inboxIDs = inboxIDs
        savedCanvas.canvasSize = CanvasDimensions(canvasSize)
        savedCanvas.rootResourceID = rootResourceID
    }

    private func persist(makeBackup: Bool, backupReason: String = "布局调整前") {
        guard !layoutIsBlocked, !sessionIsReadOnly, let canvasKey else { return }
        syncSavedCanvas()
        do {
            try layoutStore.save(
                savedCanvas,
                canvasKey: canvasKey,
                makeBackup: makeBackup,
                backupReason: backupReason,
                appVersion: currentAppVersion
            )
            updateBackupCount()
        } catch {
            errorMessage = "无法保存画布布局：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func captureUndoSnapshot(summary: String = "调整画布布局") -> UUID {
        syncSavedCanvas()
        invalidateRedoHistory(persistLayoutHistory: false)
        let record = OperationRecord(
            category: .layout,
            kind: .layout,
            summary: summary,
            state: .applied
        )
        appendOperationRecord(record, invalidatingRedo: false)
        undoStack.append(LayoutHistoryEntry(
            canvas: savedCanvas,
            operationID: record.id,
            transitionDate: record.transitionDate
        ))
        if undoStack.count > maximumUndoDepth {
            let dropped = undoStack.removeFirst()
            setOperationState(
                id: dropped.operationID,
                state: .viewOnly,
                detail: "布局撤销深度已达上限；操作记录仍可查看。"
            )
        }
        persistLayoutUndoHistory()
        updateUndoAvailability()
        return record.id
    }

    private func loadLayoutUndoHistory() {
        undoStack = []
        redoStack = []
        guard let canvasKey else { return }
        do {
            let document = try layoutStore.loadLayoutUndoHistory(canvasKey: canvasKey)
            guard document.version == LayoutUndoHistoryDocument.currentVersion else { return }
            undoStack = Array(document.undoEntries.suffix(maximumUndoDepth))
            redoStack = Array(document.redoEntries.suffix(maximumUndoDepth))
        } catch {
            errorMessage = "当前空间的布局撤销记录无法读取，已从空记录继续；布局和真实文件不受影响。"
        }
    }

    private func persistLayoutUndoHistory() {
        guard let canvasKey else { return }
        let document = LayoutUndoHistoryDocument(
            undoEntries: Array(undoStack.suffix(maximumUndoDepth)),
            redoEntries: Array(redoStack.suffix(maximumUndoDepth))
        )
        do {
            try layoutStore.saveLayoutUndoHistory(document, canvasKey: canvasKey)
        } catch {
            errorMessage = "无法保存当前空间的布局撤销记录：\(error.localizedDescription)"
        }
    }

    private func updateUndoAvailability() {
        canUndo = !undoStack.isEmpty || operationRecords.contains { $0.isFileReversible && $0.state == .applied }
        canRedo = !redoStack.isEmpty || operationRecords.contains { $0.isFileReversible && $0.state == .undone }
    }

    private func loadOperationHistory() {
        operationRecords = []
        recoveryCases = []
        isRecoveryWizardPresented = false
        operationHistoryIsBlocked = false
        isLoadingOperationHistory = false
        guard let canvasKey else { return }
        if fileOperationsAsynchronously {
            isLoadingOperationHistory = true
            let journal = operationJournal
            operationHistoryLoadTask = Task { [weak self] in
                do {
                    let document = try await journal.load(canvasKey: canvasKey)
                    guard let self, self.canvasKey == canvasKey, !Task.isCancelled else { return }
                    self.isLoadingOperationHistory = false
                    self.applyLoadedOperationHistory(document)
                } catch {
                    guard let self, self.canvasKey == canvasKey, !Task.isCancelled else { return }
                    self.isLoadingOperationHistory = false
                    self.operationHistoryIsBlocked = true
                    self.errorMessage = error.localizedDescription
                }
            }
            return
        }
        do {
            // 首次读取会把 2.4 的单文件 JSON 原样迁移为 2.5 快照 + 空增量日志。
            let document = try OperationJournalDiskStore(legacyStore: operationStore)
                .load(canvasKey: canvasKey)
            applyLoadedOperationHistory(document)
        } catch {
            operationHistoryIsBlocked = true
            errorMessage = error.localizedDescription
        }
    }

    private func applyLoadedOperationHistory(_ loadedDocument: OperationHistoryDocument) {
        var document = loadedDocument
        var changed = remapOperationPathsToCurrentFolder(in: &document)
        for index in document.records.indices {
            if [.pending, .undoing, .redoing].contains(document.records[index].state) {
                document.records[index].state = .unavailable
                document.records[index].transitionDate = Date()
                document.records[index].detail = "上次操作未能确认完成，请在访达中核对文件。"
                changed = true
            } else if document.records[index].category == .layout,
                      document.records[index].state == .applied || document.records[index].state == .undone {
                document.records[index].state = .viewOnly
                document.records[index].detail = "布局快照未跨重启保留；操作记录仍可查看。"
                changed = true
            }
        }
        operationRecords = document.records
        if changed, !sessionIsReadOnly { enqueueOperationJournalUpsert(document.records) }
        updateUndoAvailability()
        refreshRecoveryCases(presentWhenNeeded: changed)
    }

    private func remapOperationPathsToCurrentFolder(in document: inout OperationHistoryDocument) -> Bool {
        guard let folderURL else { return false }
        let currentFolder = folderURL.standardizedFileURL
        var changed = false

        func pathInCurrentFolder(_ path: String) -> String {
            currentFolder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        }

        for recordIndex in document.records.indices {
            for actionIndex in document.records[recordIndex].actions.indices {
                switch document.records[recordIndex].actions[actionIndex] {
                case var .relocate(value):
                    let oldCanvasParent = URL(fileURLWithPath: value.destinationPath).deletingLastPathComponent().standardizedFileURL
                    if oldCanvasParent != currentFolder {
                        value.destinationPath = pathInCurrentFolder(value.destinationPath)
                        if URL(fileURLWithPath: value.originalPath).deletingLastPathComponent().standardizedFileURL == oldCanvasParent {
                            value.originalPath = pathInCurrentFolder(value.originalPath)
                        }
                        document.records[recordIndex].actions[actionIndex] = .relocate(value)
                        changed = true
                    }
                case var .materialize(value):
                    if URL(fileURLWithPath: value.destinationPath).deletingLastPathComponent().standardizedFileURL != currentFolder {
                        value.destinationPath = pathInCurrentFolder(value.destinationPath)
                        document.records[recordIndex].actions[actionIndex] = .materialize(value)
                        changed = true
                    }
                case var .discard(value):
                    if URL(fileURLWithPath: value.originalPath).deletingLastPathComponent().standardizedFileURL != currentFolder {
                        value.originalPath = pathInCurrentFolder(value.originalPath)
                        document.records[recordIndex].actions[actionIndex] = .discard(value)
                        changed = true
                    }
                case var .tags(value):
                    if URL(fileURLWithPath: value.path).deletingLastPathComponent().standardizedFileURL != currentFolder {
                        value.path = pathInCurrentFolder(value.path)
                        document.records[recordIndex].actions[actionIndex] = .tags(value)
                        changed = true
                    }
                }
            }
            for displacementIndex in document.records[recordIndex].displacements.indices {
                let old = document.records[recordIndex].displacements[displacementIndex].originalPath
                if URL(fileURLWithPath: old).deletingLastPathComponent().standardizedFileURL != currentFolder {
                    document.records[recordIndex].displacements[displacementIndex].originalPath = pathInCurrentFolder(old)
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: - 异常恢复向导

    func refreshRecoveryCases(presentWhenNeeded: Bool = false) {
        let candidates = operationRecords.filter {
            [.pending, .undoing, .redoing, .unavailable].contains($0.state)
        }
        guard !candidates.isEmpty else {
            recoveryCases = []
            isRecoveryWizardPresented = false
            return
        }
        let analyzer = recoveryAnalyzer
        let analyzedCanvasKey = canvasKey
        Task { [weak self] in
            let cases = await analyzer.analyze(records: candidates)
            guard let self, self.canvasKey == analyzedCanvasKey else { return }
            self.recoveryCases = cases
            if presentWhenNeeded, !cases.isEmpty { self.isRecoveryWizardPresented = true }
        }
    }

    /// 用户确认的是“日志解释”，不是让 App 再次移动真实文件。只有证据明确支持的完成/回滚
    /// 结果可以直接确认；证据混合时仍允许仅存档，避免永久阻塞后续操作。
    func resolveRecovery(_ recoveryCase: RecoveryCase, as outcome: RecoveryOutcome) {
        guard let index = operationRecords.firstIndex(where: { $0.id == recoveryCase.recordID }) else { return }
        if outcome == .applied, recoveryCase.suggestedOutcome != .applied {
            errorMessage = "当前证据不足以确认操作已完成，请先在访达核对或仅存档记录。"
            return
        }
        if outcome == .undone, recoveryCase.suggestedOutcome != .undone {
            errorMessage = "当前证据不足以确认操作已回滚，请先在访达核对或仅存档记录。"
            return
        }
        switch outcome {
        case .applied:
            operationRecords[index].state = .applied
            operationRecords[index].detail = "已通过 2.5 异常恢复向导核对为完成。"
        case .undone:
            operationRecords[index].state = .undone
            operationRecords[index].detail = "已通过 2.5 异常恢复向导核对为回滚。"
        case .archived, .manualReview:
            operationRecords[index].state = .archived
            operationRecords[index].detail = "用户已核对并存档异常记录；App 未修改任何真实文件。"
        }
        operationRecords[index].transitionDate = Date()
        enqueueOperationJournalUpsert([operationRecords[index]])
        updateUndoAvailability()
        refreshRecoveryCases()
    }

    func revealRecoveryFolder() {
        guard let folderURL else { return }
        NSWorkspace.shared.open(folderURL)
    }

    private func persistOperationHistory() {
        enqueueOperationJournalReplaceAll(operationRecords)
    }

    private func enqueueOperationJournalUpsert(_ records: [OperationRecord]) {
        guard !records.isEmpty,
              !operationHistoryIsBlocked,
              !sessionIsReadOnly,
              let canvasKey else { return }
        if operationRecords.count > 200 {
            operationRecords = Array(operationRecords.suffix(200))
        }
        if !fileOperationsAsynchronously {
            do {
                _ = try operationJournalDiskStore.append(.upsert(records), canvasKey: canvasKey)
            } catch {
                blockOperationHistory(after: error)
            }
            return
        }
        let journal = operationJournal
        let previous = journalWriteTask
        journalWriteTask = Task { [weak self] in
            _ = await previous?.value
            guard let self, !self.operationHistoryIsBlocked else { return }
            do {
                _ = try await journal.upsert(records, canvasKey: canvasKey)
            } catch {
                if self.canvasKey == canvasKey { self.blockOperationHistory(after: error) }
            }
        }
    }

    private func enqueueOperationJournalReplaceAll(_ records: [OperationRecord]) {
        guard !operationHistoryIsBlocked,
              !sessionIsReadOnly,
              let canvasKey else { return }
        if !fileOperationsAsynchronously {
            do {
                _ = try operationJournalDiskStore.append(.replaceAll(records), canvasKey: canvasKey)
            } catch {
                blockOperationHistory(after: error)
            }
            return
        }
        let journal = operationJournal
        let previous = journalWriteTask
        journalWriteTask = Task { [weak self] in
            _ = await previous?.value
            guard let self, !self.operationHistoryIsBlocked else { return }
            do {
                _ = try await journal.replaceAll(records, canvasKey: canvasKey)
            } catch {
                if self.canvasKey == canvasKey { self.blockOperationHistory(after: error) }
            }
        }
    }

    /// 文件系统动作调用此方法作为写前屏障：pending 事件真正落盘之后，才能修改真实文件。
    private func persistOperationRecordNow(_ record: OperationRecord) async throws {
        guard !operationHistoryIsBlocked, !sessionIsReadOnly, let canvasKey else {
            throw CocoaError(.fileWriteNoPermission)
        }
        _ = await journalWriteTask?.value
        do {
            _ = try await operationJournal.upsert(record, canvasKey: canvasKey)
        } catch {
            blockOperationHistory(after: error)
            throw error
        }
    }

    private func waitForOperationJournal() async throws {
        _ = await journalWriteTask?.value
        if operationHistoryIsBlocked { throw CocoaError(.fileWriteUnknown) }
    }

    private func blockOperationHistory(after error: Error) {
        operationHistoryIsBlocked = true
        errorMessage = "无法保存操作记录：\(error.localizedDescription)。真实文件修改已被阻止。"
    }

    private func appendOperationRecord(_ record: OperationRecord, invalidatingRedo: Bool = true) {
        if invalidatingRedo { invalidateRedoHistory() }
        operationRecords.append(record)
        enqueueOperationJournalUpsert([record])
        updateUndoAvailability()
    }

    private func replaceOperationRecord(_ record: OperationRecord) {
        guard let index = operationRecords.firstIndex(where: { $0.id == record.id }) else { return }
        operationRecords[index] = record
        enqueueOperationJournalUpsert([record])
        updateUndoAvailability()
    }

    private func setOperationState(id: UUID, state: OperationState, transitionDate: Date = Date(), detail: String? = nil) {
        guard let index = operationRecords.firstIndex(where: { $0.id == id }) else { return }
        operationRecords[index].state = state
        operationRecords[index].transitionDate = transitionDate
        operationRecords[index].detail = detail
        enqueueOperationJournalUpsert([operationRecords[index]])
    }

    private func invalidateRedoHistory(persistLayoutHistory shouldPersistLayoutHistory: Bool = true) {
        let invalidatedIDs = Set(redoStack.map(\.operationID))
        redoStack = []
        for index in operationRecords.indices where
            operationRecords[index].state == .undone || invalidatedIDs.contains(operationRecords[index].id) {
            operationRecords[index].state = .superseded
            operationRecords[index].transitionDate = Date()
        }
        let changedRecords = operationRecords.filter { $0.state == .superseded }
        if !invalidatedIDs.isEmpty || !changedRecords.isEmpty {
            enqueueOperationJournalUpsert(changedRecords)
        }
        if shouldPersistLayoutHistory { persistLayoutUndoHistory() }
    }

    private func realFileMutationsAllowed() -> Bool {
        guard !isFileOperationInProgress else {
            errorMessage = "已有文件操作正在进行，请等待完成或先取消。"
            return false
        }
        guard !sessionIsReadOnly else {
            errorMessage = "这个空间正在被另一个指针空间进程使用。当前窗口为只读模式，请先退出占用它的旧版本。"
            return false
        }
        guard !isLoadingOperationHistory else {
            errorMessage = "正在后台读取当前空间的操作记录，请稍后再修改文件。"
            return false
        }
        guard !operationHistoryIsBlocked else {
            errorMessage = "操作记录需要修复。为了避免真实文件不可恢复，当前暂停新建、改名、覆盖和删除。"
            return false
        }
        return true
    }

    // MARK: - 会话写入权和布局修复

    /// 尝试取得画布独占写入权。失败时仍允许浏览和打开文件，但所有写操作都被模型层阻止。
    private func acquireSessionLock() {
        guard sessionLockingEnabled, let canvasKey else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        do {
            switch try CanvasSessionLock.acquire(
                canvasKey: canvasKey,
                directory: sessionLockDirectory,
                appVersion: version
            ) {
            case let .acquired(lock):
                sessionLock = lock
            case let .occupied(owner):
                sessionIsReadOnly = true
                sessionLockOwner = owner
                let ownerText = owner.map { "（进程 \($0.processID)，版本 \($0.appVersion)）" } ?? ""
                errorMessage = "这个空间已被另一个指针空间占用\(ownerText)。当前以只读方式打开。"
            }
        } catch {
            sessionIsReadOnly = true
            errorMessage = "无法取得空间写入锁，已切换为只读模式：\(error.localizedDescription)"
        }
    }

    private func updateBackupCount() {
        guard let canvasKey else { backupCount = 0; return }
        backupCount = layoutStore.backupURLs(canvasKey: canvasKey).count
    }

    private var currentAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private func remappingBackupCanvasToCurrentItems(_ original: SavedCanvas) -> SavedCanvas {
        var canvas = original
        for item in items {
            guard let resourceID = item.resourceID,
                  let oldID = original.resourcePaths[resourceID],
                  oldID != item.id else { continue }
            if let point = canvas.positions.removeValue(forKey: oldID) {
                canvas.positions[item.id] = point
            }
            if let scale = canvas.scales.removeValue(forKey: oldID) {
                canvas.scales[item.id] = scale
            }
            if canvas.inboxIDs.remove(oldID) != nil {
                canvas.inboxIDs.insert(item.id)
            }
        }
        return canvas
    }

    private func preservingCurrentOnlyItems(in backup: SavedCanvas, current: SavedCanvas) -> SavedCanvas {
        var merged = backup
        let currentIDs = Set(items.map(\.id))
        let backupIDs = Set(backup.positions.keys).union(backup.inboxIDs)
        for id in currentIDs.subtracting(backupIDs) {
            if let point = current.positions[id] { merged.positions[id] = point }
            if let scale = current.scales[id] { merged.scales[id] = scale }
            if current.inboxIDs.contains(id) { merged.inboxIDs.insert(id) }
        }
        for (resourceID, path) in current.resourcePaths where merged.resourcePaths[resourceID] == nil {
            merged.resourcePaths[resourceID] = path
        }
        return merged
    }

    private func reconcileAfterLayoutRestore() {
        _ = reconcileResourcePaths(items)
        _ = assignPositionsToNewItems(items)
        _ = enforceCapacityAndBounds(items)
    }

    private func reconcileResourcePaths(_ freshItems: [FolderItem]) -> Bool {
        var changed = false
        for item in freshItems {
            guard let resourceID = item.resourceID else { continue }
            if let previousPath = savedCanvas.resourcePaths[resourceID], previousPath != item.id {
                transferLayout(from: previousPath, to: item.id)
                changed = true
            }
            if savedCanvas.resourcePaths[resourceID] != item.id {
                savedCanvas.resourcePaths[resourceID] = item.id
                changed = true
            }
        }
        return changed
    }

    private func canvasLimitedToCurrentItems(_ original: SavedCanvas) -> SavedCanvas {
        let currentPaths = Set(items.map(\.id))
        var canvas = original
        canvas.positions = original.positions.filter { currentPaths.contains($0.key) }
        canvas.scales = original.scales.filter { currentPaths.contains($0.key) }
        canvas.inboxIDs.formIntersection(currentPaths)
        canvas.resourcePaths = original.resourcePaths.filter { currentPaths.contains($0.value) }
        return canvas
    }

    private func transferLayout(from oldID: String, to newID: String) {
        if let position = positions.removeValue(forKey: oldID) { positions[newID] = position }
        if let scale = scales.removeValue(forKey: oldID) { scales[newID] = scale }
        if inboxIDs.remove(oldID) != nil { inboxIDs.insert(newID) }
        if selectedIDs.remove(oldID) != nil { selectedIDs.insert(newID) }
    }

    // MARK: - 自动放置、容量与坐标算法

    private func arrangeInitialItems(_ freshItems: [FolderItem]) {
        let result = layoutEngine.initialLayout(
            for: layoutItems(freshItems),
            canvasSize: canvasSize
        )
        positions = result.positions
        inboxIDs = result.inboxIDs
    }

    private func assignPositionsToNewItems(_ freshItems: [FolderItem]) -> Bool {
        let previousPositions = positions
        let previousInbox = inboxIDs
        let result = layoutEngine.assignNewItems(
            layoutItems(freshItems),
            positions: positions,
            inboxIDs: inboxIDs,
            canvasSize: canvasSize
        )
        positions = result.positions
        inboxIDs = result.inboxIDs
        let changed = previousPositions != positions || previousInbox != inboxIDs
        return changed
    }

    private func enforceCapacityAndBounds(_ freshItems: [FolderItem]) -> Bool {
        var changed = false
        var active = freshItems.filter { !inboxIDs.contains($0.id) && positions[$0.id] != nil }
        if active.count > mainCanvasCapacity {
            active.sort { lhs, rhs in
                let left = positions[lhs.id] ?? CanvasPoint(x: 0, y: 0)
                let right = positions[rhs.id] ?? CanvasPoint(x: 0, y: 0)
                let leftInside = isInsideBounds(left, scale: scale(for: lhs))
                let rightInside = isInsideBounds(right, scale: scale(for: rhs))
                if leftInside != rightInside { return leftInside }
                if left.y != right.y { return left.y < right.y }
                return left.x < right.x
            }
            for item in active.dropFirst(mainCanvasCapacity) {
                inboxIDs.insert(item.id)
                positions.removeValue(forKey: item.id)
                selectedIDs.remove(item.id)
                changed = true
            }
            active = Array(active.prefix(mainCanvasCapacity))
        }
        for item in active {
            guard let old = positions[item.id] else { continue }
            let corrected = snapped(CGPoint(x: old.x, y: old.y), scale: scale(for: item))
            if old != corrected {
                positions[item.id] = corrected
                changed = true
            }
        }
        return changed
    }

    private func gridPoint(for index: Int, scale: CGFloat) -> CanvasPoint {
        layoutEngine.gridPoint(for: index, scale: scale, canvasSize: canvasSize)
    }

    private func snapped(_ point: CGPoint, scale: CGFloat) -> CanvasPoint {
        layoutEngine.snapped(point, scale: scale, canvasSize: canvasSize)
    }

    private func iconRect(at point: CanvasPoint, scale: CGFloat) -> CGRect {
        layoutEngine.iconRect(at: point, scale: scale)
    }

    private func isInsideBounds(_ point: CanvasPoint, scale: CGFloat) -> Bool {
        layoutEngine.isInsideBounds(point, scale: scale, canvasSize: canvasSize)
    }

    private func layoutItems(_ sourceItems: [FolderItem]) -> [CanvasLayoutItem] {
        sourceItems.map { CanvasLayoutItem(id: $0.id, scale: scale(for: $0)) }
    }

    private func resizeLogicalCanvas(to newSize: CGSize) {
        let oldSize = canvasSize
        guard oldSize.width > 0, oldSize.height > 0 else { return }
        let scale = min(newSize.width / oldSize.width, newSize.height / oldSize.height)
        let offsetX = (newSize.width - oldSize.width * scale) / 2
        let offsetY = (newSize.height - oldSize.height * scale) / 2
        canvasSize = newSize
        for (id, point) in positions {
            let itemScale = scales[id] ?? defaultIconScale
            positions[id] = snapped(
                CGPoint(x: point.x * scale + offsetX, y: point.y * scale + offsetY),
                scale: itemScale
            )
        }
    }

    private func migrateLegacyReferenceCanvasIfUseful() {
        let widthGrowth = currentDisplaySize.width / max(1, canvasSize.width)
        let heightGrowth = currentDisplaySize.height / max(1, canvasSize.height)
        guard widthGrowth >= 1.05, heightGrowth >= 1.05 else { return }
        resizeLogicalCanvas(to: currentDisplaySize)
    }

    private func persistentResourceIdentifier(for url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        return persistentResourceIdentifier(values: try? url.resourceValues(forKeys: keys))
    }

    private func persistentResourceIdentifier(values: URLResourceValues?) -> String? {
        guard let fileID = values?.fileResourceIdentifier else { return nil }
        let volumeID = values?.volumeIdentifier.map { String(describing: $0) } ?? "unknown-volume"
        return "\(volumeID)|\(String(describing: fileID))"
    }

    // MARK: - 书签恢复、最近空间与文件夹监听

    private func makeBookmark(for folder: URL) -> Data? {
        try? folder.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey],
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale, let refreshed = makeBookmark(for: url) { lastFolderBookmark = refreshed }
        return url.standardizedFileURL
    }

    private func resolveLastOpenedFolder() -> URL? {
        if let bookmark = defaults.data(forKey: lastFolderBookmarkKey),
           let resolved = resolveBookmark(bookmark), Self.directoryExists(at: resolved) {
            lastFolderBookmark = bookmark
            return resolved
        }
        if let path = defaults.string(forKey: "lastOpenedFolderPath") {
            let url = URL(fileURLWithPath: path)
            if Self.directoryExists(at: url) { return url }
        }
        return nil
    }

    private func saveLastOpenedFolder(_ folder: URL) {
        defaults.set(folder.path, forKey: "lastOpenedFolderPath")
        if let bookmark = lastFolderBookmark {
            defaults.set(bookmark, forKey: lastFolderBookmarkKey)
        }
    }

    private func attemptFolderRecovery() {
        if let lastFolderBookmark,
           let resolved = resolveBookmark(lastFolderBookmark),
           Self.directoryExists(at: resolved), resolved != folderURL {
            replaceCurrentSpaceReference(with: resolved)
            performOpen(folder: resolved.standardizedFileURL)
            errorMessage = "检测到文件夹已移动，原空间布局已经自动重新关联。"
            return
        }
        folderUnavailable = true
        folderMonitor?.cancel()
        folderMonitor = nil
        legacyFolderMonitor?.cancel()
        legacyFolderMonitor = nil
        tagPollingTimer?.cancel()
        tagPollingTimer = nil
        tagPollingTask?.cancel()
        tagPollingTask = nil
        errorMessage = "原文件夹已移动、删除或所在磁盘暂不可用。请使用“重新关联”选择它的新位置。"
    }

    private func confirmLayoutTransfer(to replacement: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "关联到新的文件夹？"
        alert.informativeText = "无法确认“\(replacement.lastPathComponent)”就是原文件夹。继续会把当前空间布局应用到它，但不会移动或修改里面的文件。"
        alert.addButton(withTitle: "关联")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func watchFolder() {
        guard let folderURL else { return }
        if let monitor = FolderChangeMonitor(folderURL: folderURL, onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }) {
            folderMonitor = monitor
        } else {
            startLegacyFolderMonitoringFallback(folderURL: folderURL)
        }
        if tagReconciliationIsActive {
            startTagReconciliation()
        }
    }

    /// 窗口隐藏或最小化时停止标签轮询；再次可见时立即补查，避免无意义的后台唤醒。
    func setTagReconciliationActive(_ isActive: Bool) {
        guard tagReconciliationIsActive != isActive else { return }
        tagReconciliationIsActive = isActive
        if isActive {
            guard folderURL != nil, !folderUnavailable else { return }
            pollTagChanges()
            startTagReconciliation()
        } else {
            tagPollingTimer?.cancel()
            tagPollingTimer = nil
            tagPollingTask?.cancel()
            tagPollingTask = nil
        }
    }

    /// 保留原 vnode 监听以处理新增、删除和重命名；它本身看不到子文件标签变化。
    private func startLegacyFolderMonitoringFallback(folderURL: URL) {
        let descriptor = Darwin.open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        legacyFolderMonitor = source
        source.resume()
    }

    /// 每秒核对当前可见项目的标签快照，补足 FSEvents 对扩展属性变化的事件缺口。
    private func startTagReconciliation() {
        guard tagReconciliationIsActive, tagPollingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(500),
            repeating: .seconds(1),
            leeway: .milliseconds(150)
        )
        timer.setEventHandler { [weak self] in
            self?.pollTagChanges()
        }
        tagPollingTimer = timer
        timer.resume()
    }

    private func pollTagChanges() {
        guard tagPollingTask == nil, !items.isEmpty else { return }
        tagReconciliationTick = (tagReconciliationTick + 1) % 5
        let needsFilteredFullSweep = hasActiveFilters && tagReconciliationTick == 0
        var observedItems = needsFilteredFullSweep ? items : displayedItems
        if let infoItem,
           !observedItems.contains(where: { $0.id == infoItem.id }) {
            observedItems.append(infoItem)
        }
        let urls = observedItems.map(\.url)
        let scanService = scanService
        tagPollingTask = Task { [weak self] in
            let snapshot = await scanService.scanTags(for: urls)
            guard !Task.isCancelled, let self else { return }
            self.applyTagSnapshot(snapshot)
            self.tagPollingTask = nil
        }
    }

    private func applyTagSnapshot(_ snapshot: [String: [String]]) {
        var changed = false
        let refreshed = items.map { item in
            guard let tags = snapshot[item.id], tags != item.tags else { return item }
            changed = true
            return FolderItem(
                url: item.url,
                tags: tags,
                resourceID: item.resourceID,
                isDirectory: item.isDirectory
            )
        }
        guard changed else { return }
        items = refreshed
        if let infoItem,
           let updated = refreshed.first(where: { $0.id == infoItem.id }) {
            self.infoItem = updated
        }
        removeHiddenItemsFromSelection()
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.refreshItems() }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
    }

    private func remember(folder: URL) {
        recentFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
        recentFolders.insert(folder.standardizedFileURL, at: 0)
        recentFolders = Array(recentFolders.prefix(maximumRecentFolders))
        defaults.set(recentFolders.map(\.path), forKey: recentFoldersKey)
        let records = recentFolders.compactMap { recent -> RecentFolderBookmark? in
            guard let bookmark = makeBookmark(for: recent) else { return nil }
            return RecentFolderBookmark(bookmarkData: bookmark, fallbackPath: recent.path)
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: recentFolderBookmarksKey)
        }
    }

    private func persistPinnedFolders() {
        pinnedFolders = Array(pinnedFolders.prefix(maximumPinnedFolders))
        let records = pinnedFolders.compactMap { folder -> RecentFolderBookmark? in
            guard let bookmark = makeBookmark(for: folder) else { return nil }
            return RecentFolderBookmark(bookmarkData: bookmark, fallbackPath: folder.path)
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: pinnedFolderBookmarksKey)
        }
    }

    private func replaceCurrentSpaceReference(with replacement: URL) {
        guard let currentPath = folderURL?.standardizedFileURL.path,
              let index = pinnedFolders.firstIndex(where: { $0.standardizedFileURL.path == currentPath }) else {
            return
        }
        pinnedFolders[index] = replacement.standardizedFileURL
        persistPinnedFolders()
    }

    private static func loadRecentFolders(from defaults: UserDefaults, key: String) -> [URL] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([RecentFolderBookmark].self, from: data) else {
            return []
        }
        return records.compactMap { record in
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: record.bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), directoryExists(at: url) {
                return url.standardizedFileURL
            }
            let fallback = URL(fileURLWithPath: record.fallbackPath)
            return directoryExists(at: fallback) ? fallback : nil
        }
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - 文件名冲突和 Office 模板

    private func uniqueDestination(for source: URL, in folder: URL) -> URL {
        uniqueDestination(for: source, in: folder, excluding: [])
    }

    /// 除了磁盘已有项目，还排除同一批次已经预订的目标路径。
    private func uniqueDestination(
        for source: URL,
        in folder: URL,
        excluding reservedPaths: Set<String>
    ) -> URL {
        let extensionName = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        var index = 1
        var target = folder.appendingPathComponent(source.lastPathComponent)
        while FileManager.default.fileExists(atPath: target.path) || reservedPaths.contains(target.path) {
            index += 1
            target = folder.appendingPathComponent("\(baseName) \(index)").appendingPathExtension(extensionName)
        }
        return target
    }

    private func createFromTemplate(resource: String, baseName: String, extension fileExtension: String) {
        guard let folderURL, realFileMutationsAllowed() else { return }
        guard let templateURL = Bundle.module.url(forResource: resource, withExtension: fileExtension) else {
            errorMessage = "找不到内置 \(fileExtension.uppercased()) 模板。"
            return
        }
        if fileOperationsAsynchronously {
            let repository = folderAccessRepository
            startFilePreparation(title: "准备新建文档") {
                await repository.uniqueNamedItem(
                    in: folderURL,
                    baseName: baseName,
                    fileExtension: fileExtension
                )
            } completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(targetURL):
                    guard let record = self.beginFileOperation(
                        kind: .createDocument,
                        summary: "新建“\(targetURL.lastPathComponent)”",
                        itemNames: [targetURL.lastPathComponent]
                    ) else { return }
                    self.startCoordinatedTransfers(
                        recordID: record.id,
                        title: "新建文档",
                        plans: [FileTransferPlan(
                            source: templateURL,
                            destination: targetURL,
                            move: false,
                            replacesExistingDestination: false
                        )]
                    )
                case let .failure(error):
                    self.errorMessage = "无法准备新文档：\(error.localizedDescription)"
                }
            }
            return
        }
        var index = 1
        var targetURL = folderURL.appendingPathComponent("\(baseName).\(fileExtension)")
        while FileManager.default.fileExists(atPath: targetURL.path) {
            index += 1
            targetURL = folderURL.appendingPathComponent("\(baseName) \(index).\(fileExtension)")
        }
        guard var record = beginFileOperation(
            kind: .createDocument,
            summary: "新建“\(targetURL.lastPathComponent)”",
            itemNames: [targetURL.lastPathComponent],
            actions: [.materialize(MaterializeAction(destinationPath: targetURL.path))]
        ) else { return }
        do {
            try FileManager.default.copyItem(at: templateURL, to: targetURL)
            record.state = .applied
            record.transitionDate = Date()
            replaceOperationRecord(record)
            refreshItems()
            captureCanvasMetadata(in: &record)
            replaceOperationRecord(record)
        } catch {
            markOperationFailed(&record, error: error)
            errorMessage = "无法新建文件：\(error.localizedDescription)"
        }
    }
}
