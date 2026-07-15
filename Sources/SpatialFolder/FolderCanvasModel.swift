import AppKit
import Darwin
import Foundation
import SwiftUI

struct FolderItem: Identifiable, Hashable {
    let url: URL
    let tags: [String]
    let resourceID: String?

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func == (lhs: FolderItem, rhs: FolderItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

private struct RecentFolderBookmark: Codable {
    var bookmarkData: Data
    var fallbackPath: String
}

private struct LayoutHistoryEntry {
    var canvas: SavedCanvas
    var operationID: UUID
    var transitionDate: Date
}

struct PendingFileConflict: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// 画布的主线程编排模型。
///
/// 它保存界面需要观察的状态，并把布局仓库、后台扫描、文件操作协调器和会话锁连接起来。
/// 耗时 I/O 必须交给独立 service/actor，不能直接塞回这个类型的主线程方法。
@MainActor
final class FolderCanvasModel: ObservableObject {
    let mainCanvasCapacity = 64

    private let defaultIconScale: CGFloat = 1.25
    private let initialColumns = 8
    private let recentFoldersKey = "recentFolderPaths"
    private let recentFolderBookmarksKey = "recentFolderBookmarksV2"
    private let lastFolderBookmarkKey = "lastOpenedFolderBookmarkV2"
    private let maximumRecentFolders = 8
    private let maximumUndoDepth = 50
    private let grid: CGFloat = 24
    private let layoutStore: CanvasLayoutStore
    private let operationStore: OperationHistoryStore
    private let fileOperationEngine: FileOperationEngine
    private let defaults: UserDefaults
    private let monitorFolders: Bool
    private let sessionLockDirectory: URL
    private let sessionLockingEnabled: Bool
    private let directoryScanner: FolderDirectoryScanner
    private let scanService: FolderScanService
    private let scansAsynchronously: Bool
    private let fileOperationCoordinator: FileOperationCoordinator
    private let fileOperationsAsynchronously: Bool
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
    @Published private(set) var canvasSize: CGSize
    @Published private(set) var currentDisplaySize: CGSize
    @Published var errorMessage: String?
    @Published private(set) var appearanceMode: String
    @Published private(set) var recentFolders: [URL] = []
    @Published var searchText = ""
    @Published var infoItem: FolderItem?

    private var folderMonitor: DispatchSourceFileSystemObject?
    private var refreshWorkItem: DispatchWorkItem?
    private var scanTask: Task<Void, Never>?
    private var fileOperationTask: Task<Void, Never>?
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
        fileOperationsAsynchronously: Bool = true
    ) {
        self.layoutStore = layoutStore
        self.operationStore = operationStore
        self.fileOperationEngine = fileOperationEngine
        defaults = userDefaults
        self.monitorFolders = monitorFolders
        self.sessionLockDirectory = sessionLockDirectory
        self.sessionLockingEnabled = sessionLockingEnabled
        self.directoryScanner = directoryScanner
        scanService = FolderScanService(scanner: directoryScanner)
        self.scansAsynchronously = scansAsynchronously
        fileOperationCoordinator = FileOperationCoordinator(fileOperationEngine: fileOperationEngine)
        self.fileOperationsAsynchronously = fileOperationsAsynchronously
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

    var selectedItems: [FolderItem] { items.filter { selectedIDs.contains($0.id) } }

    var displayedItems: [FolderItem] {
        matchingItems.filter { !inboxIDs.contains($0.id) }
    }

    var inboxItems: [FolderItem] {
        matchingItems.filter { inboxIDs.contains($0.id) }
    }

    var desktopCanvasSize: CGSize { canvasSize }

    /// 统一供界面和命令判断，避免只在按钮层禁用而底层仍然修改布局。
    var canEditLayout: Bool {
        folderURL != nil && !layoutIsBlocked && !folderUnavailable && !sessionIsReadOnly && !isLocked
    }

    var isFileOperationInProgress: Bool { fileOperationProgress != nil }

    func icon(for item: FolderItem) -> NSImage {
        iconCache.icon(for: item.url)
    }

    var defaultDesktopWallpaperURL: URL? {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    private var matchingItems: [FolderItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.tags.contains { normalizedTagName($0).localizedCaseInsensitiveContains(query) }
        }
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

    func open(folder: URL) {
        guard !isFileOperationInProgress else {
            errorMessage = "请等待当前文件操作完成，或先取消操作，再切换空间。"
            return
        }
        let standardized = folder.standardizedFileURL
        guard Self.directoryExists(at: standardized) else {
            errorMessage = "无法打开文件夹：文件夹不存在或暂时不可用。"
            return
        }
        folderMonitor?.cancel()
        refreshWorkItem?.cancel()
        scanTask?.cancel()
        scanGeneration = UUID()
        iconCache.removeAll()
        sessionLock?.release()
        sessionLock = nil
        sessionIsReadOnly = false
        sessionLockOwner = nil
        folderURL = standardized
        rootResourceID = persistentResourceIdentifier(for: standardized) ?? "path:\(standardized.path)"
        canvasKey = rootResourceID.map(layoutStore.canvasKey(for:))
        acquireSessionLock()
        lastFolderBookmark = makeBookmark(for: standardized)
        saveLastOpenedFolder(standardized)
        remember(folder: standardized)
        selectedIDs = []
        undoStack = []
        redoStack = []
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
            FolderItem(url: $0.url, tags: $0.tags, resourceID: $0.resourceID)
        }
        items = freshItems
        let currentPaths = Set(freshItems.map(\.id))
        selectedIDs.formIntersection(currentPaths)

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
        if changed { persistOperationHistory() }
    }

    func position(for item: FolderItem) -> CanvasPoint {
        positions[item.id] ?? CanvasPoint(x: 72, y: 72)
    }

    func move(_ item: FolderItem, to point: CGPoint) {
        guard canEditLayout, !inboxIDs.contains(item.id) else { return }
        captureUndoSnapshot(summary: "移动图标")
        positions[item.id] = snapped(point, scale: scale(for: item))
        persist(makeBackup: true)
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
        persist(makeBackup: true)
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
        if moved { persist(makeBackup: true) }
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
        guard !sessionIsReadOnly, !layoutIsBlocked, folderURL != nil else { return }
        guard isLocked != locked else { return }
        captureUndoSnapshot(summary: locked ? "锁定画布" : "解锁画布")
        isLocked = locked
        persist(makeBackup: true)
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
        persist(makeBackup: true)
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
        persist(makeBackup: true)
        if placements.count < targets.count {
            errorMessage = "主画布空间不足，已放入 \(placements.count) 个项目，其余仍保留在待放置区。"
        }
    }

    var availableCanvasSlots: Int {
        max(0, mainCanvasCapacity - items.filter { !inboxIDs.contains($0.id) && positions[$0.id] != nil }.count)
    }

    /// 右键点在已选项目上时，菜单作用于整个选择集合；点在未选项目上时只作用于该项目。
    func contextItems(for item: FolderItem) -> [FolderItem] {
        selectedIDs.contains(item.id) ? selectedItems : [item]
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
            operationRecords.removeAll { $0.id == operationID }
            persistOperationHistory()
            updateUndoAvailability()
            errorMessage = "当前没有越界项目。"
        } else {
            persist(makeBackup: true)
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
        persist(makeBackup: true)
    }

    func undoLayoutChange() {
        guard !sessionIsReadOnly, let previous = undoStack.popLast() else { return }
        syncSavedCanvas()
        let now = Date()
        redoStack.append(LayoutHistoryEntry(
            canvas: savedCanvas,
            operationID: previous.operationID,
            transitionDate: now
        ))
        applySavedCanvas(previous.canvas)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true)
        setOperationState(id: previous.operationID, state: .undone, transitionDate: now)
        updateUndoAvailability()
    }

    func redoLayoutChange() {
        guard !sessionIsReadOnly, let next = redoStack.popLast() else { return }
        syncSavedCanvas()
        let now = Date()
        undoStack.append(LayoutHistoryEntry(
            canvas: savedCanvas,
            operationID: next.operationID,
            transitionDate: now
        ))
        applySavedCanvas(next.canvas)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true)
        setOperationState(id: next.operationID, state: .applied, transitionDate: now)
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
        guard !sessionIsReadOnly else { return }
        if !layoutIsBlocked { captureUndoSnapshot(summary: "重置当前布局") }
        layoutIsBlocked = false
        positions = [:]
        scales = [:]
        inboxIDs = []
        arrangeInitialItems(items)
        persist(makeBackup: true)
    }

    func restoreLatestBackup() {
        guard !sessionIsReadOnly, let canvasKey else { return }
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
        panel.nameFieldStringValue = "空间文件夹-诊断.json"
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
        do {
            let archive = try operationStore.archiveCorruptHistoryAndReset(canvasKey: canvasKey)
            operationRecords = []
            operationHistoryIsBlocked = false
            updateUndoAvailability()
            errorMessage = "损坏记录已存档为“\(archive.lastPathComponent)”，可以继续使用。"
        } catch {
            errorMessage = "无法存档损坏操作记录：\(error.localizedDescription)"
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
        guard !sessionIsReadOnly else { return }
        let imported = try layoutStore.importedCanvas(from: url, expectedRootResourceID: rootResourceID)
        if !layoutIsBlocked { captureUndoSnapshot(summary: "导入空间布局") }
        layoutIsBlocked = false
        applySavedCanvas(imported)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true)
    }

    func chooseReplacementFolder() {
        let panel = NSOpenPanel()
        panel.title = "重新关联原来的空间文件夹"
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
        open(folder: replacement)
        guard preservingCurrentLayout, !sessionIsReadOnly else { return }
        var transferred = remappedCanvas(previous, to: replacement.standardizedFileURL, matching: items)
        transferred.rootResourceID = rootResourceID
        transferred.resourcePaths = [:]
        layoutIsBlocked = false
        applySavedCanvas(transferred)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true)
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

    func showInfo(_ item: FolderItem) { infoItem = item }

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
        guard realFileMutationsAllowed(), !targetItems.isEmpty else { return }
        let normalized = normalizedTagName(tag)
        let actions = targetItems.map { item -> ReversibleFileAction in
            var tags = item.tags
            if let index = tags.firstIndex(where: { normalizedTagName($0) == normalized }) {
                tags.remove(at: index)
            } else {
                tags.append(tag)
            }
            return .tags(TagAction(path: item.url.path, before: item.tags, after: tags))
        }
        guard var record = beginFileOperation(
            kind: .tags,
            summary: "修改 \(targetItems.count) 个项目的标签",
            itemNames: targetItems.map(\.name)
        ) else { return }
        do {
            for action in actions {
                guard case let .tags(value) = action else { continue }
                try writeFinderTags(value.after, to: URL(fileURLWithPath: value.path))
                record.actions.append(action)
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
        let targets = targetItems.filter { !$0.tags.isEmpty }
        guard realFileMutationsAllowed(), !targets.isEmpty else { return }
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
        if fileOperationsAsynchronously {
            guard let record = beginFileOperation(
                kind: .duplicate,
                summary: "制作 \(targetItems.count) 个项目的副本",
                itemNames: targetItems.map(\.name)
            ) else { return }
            startCoordinatedTransfers(
                recordID: record.id,
                title: "制作副本",
                plans: plans
            )
            return
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

    func importFiles(_ urls: [URL], move: Bool = false, conflictChoice: ConflictChoice? = nil) {
        guard let folderURL, realFileMutationsAllowed() else { return }
        let sources = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != folderURL.standardizedFileURL }
        guard !sources.isEmpty else { return }
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
                self?.importFiles(sources, move: move, conflictChoice: choice)
            }
            return
        }
        let policy = conflictChoice ?? .cancel
        if fileOperationsAsynchronously {
            let plans = makeTransferPlans(
                sources: sources,
                destinationFolder: folderURL,
                move: move,
                policy: policy
            )
            guard let record = beginFileOperation(
                kind: move ? .moveItems : .copyItems,
                summary: move ? "移动 \(sources.count) 个项目到空间" : "复制 \(sources.count) 个项目到空间",
                itemNames: sources.map(\.lastPathComponent)
            ) else { return }
            startCoordinatedTransfers(
                recordID: record.id,
                title: move ? "移动到空间" : "复制到空间",
                plans: plans
            )
            return
        }
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
            refreshItems()
            captureCanvasMetadata(in: &record)
            replaceOperationRecord(record)
        } catch {
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法导入文件：\(error.localizedDescription)"
        }
    }

    /// 用户点击进度条取消按钮后只设置取消标记；协调器会在当前文件系统调用结束后安全回滚。
    func cancelCurrentFileOperation() {
        guard var progress = fileOperationProgress, progress.allowsCancellation else { return }
        progress.isCancelling = true
        progress.detail = "正在完成当前步骤并准备回滚…"
        fileOperationProgress = progress
        fileOperationTask?.cancel()
    }

    /// 把来源列表预先变成确定的目标计划，避免异步执行期间重复询问或目标名互相覆盖。
    private func makeTransferPlans(
        sources: [URL],
        destinationFolder: URL,
        move: Bool,
        policy: ConflictChoice
    ) -> [FileTransferPlan] {
        var reservedPaths: Set<String> = []
        return sources.map { source in
            var destination = destinationFolder.appendingPathComponent(source.lastPathComponent)
            let collidesWithBatch = reservedPaths.contains(destination.path)
            let existsBeforeBatch = FileManager.default.fileExists(atPath: destination.path)
            var replacesExisting = false

            if collidesWithBatch || (existsBeforeBatch && policy == .keepBoth) {
                destination = uniqueDestination(
                    for: source,
                    in: destinationFolder,
                    excluding: reservedPaths
                )
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

    // MARK: - 后台文件操作协调

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
                let actions = try await coordinator.performTransfers(plans) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self?.finishCoordinatedOperation(recordID: recordID, actions: actions)
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
                let actions = try await coordinator.performCompressions(plans) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self?.finishCoordinatedOperation(recordID: recordID, actions: actions)
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
                let actions = try await coordinator.performTrash(urls) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: recordID)
                }
                self?.finishCoordinatedOperation(recordID: recordID, actions: actions)
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
    ) throws {
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
        persistOperationHistory()
        if operationHistoryIsBlocked { throw CocoaError(.fileWriteUnknown) }
    }

    private func finishCoordinatedOperation(
        recordID: UUID,
        actions: [ReversibleFileAction]
    ) {
        guard var record = operationRecords.first(where: { $0.id == recordID }) else { return }
        record.actions = actions
        record.state = .applied
        record.transitionDate = Date()
        record.detail = nil
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
        replaceOperationRecord(record)
        fileOperationProgress = nil
        fileOperationTask = nil
        refreshItems()
        errorMessage = record.detail
    }

    private func finishCoordinatedOperation(recordID: UUID, unexpectedError: Error) {
        guard var record = operationRecords.first(where: { $0.id == recordID }) else { return }
        record.state = .unavailable
        record.transitionDate = Date()
        record.detail = "操作异常中断：\(unexpectedError.localizedDescription)。请在访达中核对。"
        replaceOperationRecord(record)
        fileOperationProgress = nil
        fileOperationTask = nil
        refreshItems()
        errorMessage = record.detail
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
            persist(makeBackup: true)
            refreshItems()
        } catch {
            record.detail = error.localizedDescription
            rollbackPendingOperation(&record)
            errorMessage = "无法移至废纸篓：\(error.localizedDescription)"
        }
    }

    func createFolder() {
        guard let folderURL, realFileMutationsAllowed() else { return }
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
        guard canEditLayout else { return }
        captureUndoSnapshot(summary: url == nil ? "使用系统桌面壁纸" : "更换画布壁纸")
        wallpaperURL = url
        persist(makeBackup: true)
    }

    func hasTag(_ tag: String, in item: FolderItem) -> Bool {
        item.tags.contains { normalizedTagName($0) == normalizedTagName(tag) }
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
                let updated = try await coordinator.transition(
                    record: record,
                    to: targetState,
                    conflictChoice: conflictChoice
                ) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.applyCoordinatorEvent(event, recordID: record.id)
                }
                guard let self else { return }
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

    private func captureCanvasMetadata(in record: inout OperationRecord) {
        var captured: [OperationCanvasItem] = []
        for index in record.actions.indices {
            guard let path = activePath(for: record.actions[index], state: .applied),
                  items.contains(where: { $0.id == path }) else { continue }
            captured.append(canvasMetadata(for: path, actionIndex: index))
        }
        record.canvasItems = captured
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

    private func persist(makeBackup: Bool) {
        guard !layoutIsBlocked, !sessionIsReadOnly, let canvasKey else { return }
        syncSavedCanvas()
        do {
            try layoutStore.save(savedCanvas, canvasKey: canvasKey, makeBackup: makeBackup)
            updateBackupCount()
        } catch {
            errorMessage = "无法保存画布布局：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func captureUndoSnapshot(summary: String = "调整画布布局") -> UUID {
        syncSavedCanvas()
        invalidateRedoHistory()
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
        updateUndoAvailability()
        return record.id
    }

    private func updateUndoAvailability() {
        canUndo = !undoStack.isEmpty || operationRecords.contains { $0.isFileReversible && $0.state == .applied }
        canRedo = !redoStack.isEmpty || operationRecords.contains { $0.isFileReversible && $0.state == .undone }
    }

    private func loadOperationHistory() {
        operationRecords = []
        operationHistoryIsBlocked = false
        guard let canvasKey else { return }
        do {
            var document = try operationStore.load(canvasKey: canvasKey)
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
            if changed, !sessionIsReadOnly { try operationStore.save(document, canvasKey: canvasKey) }
        } catch {
            operationHistoryIsBlocked = true
            errorMessage = error.localizedDescription
        }
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

    private func persistOperationHistory() {
        guard !operationHistoryIsBlocked, !sessionIsReadOnly, let canvasKey else { return }
        if operationRecords.count > 200 {
            operationRecords = Array(operationRecords.suffix(200))
        }
        do {
            try operationStore.save(
                OperationHistoryDocument(records: operationRecords),
                canvasKey: canvasKey
            )
        } catch {
            operationHistoryIsBlocked = true
            errorMessage = "无法保存操作记录：\(error.localizedDescription)。真实文件修改已被阻止。"
        }
    }

    private func appendOperationRecord(_ record: OperationRecord, invalidatingRedo: Bool = true) {
        if invalidatingRedo { invalidateRedoHistory() }
        operationRecords.append(record)
        persistOperationHistory()
        updateUndoAvailability()
    }

    private func replaceOperationRecord(_ record: OperationRecord) {
        guard let index = operationRecords.firstIndex(where: { $0.id == record.id }) else { return }
        operationRecords[index] = record
        persistOperationHistory()
        updateUndoAvailability()
    }

    private func setOperationState(id: UUID, state: OperationState, transitionDate: Date = Date(), detail: String? = nil) {
        guard let index = operationRecords.firstIndex(where: { $0.id == id }) else { return }
        operationRecords[index].state = state
        operationRecords[index].transitionDate = transitionDate
        operationRecords[index].detail = detail
        persistOperationHistory()
    }

    private func invalidateRedoHistory() {
        let invalidatedIDs = Set(redoStack.map(\.operationID))
        redoStack = []
        for index in operationRecords.indices where
            operationRecords[index].state == .undone || invalidatedIDs.contains(operationRecords[index].id) {
            operationRecords[index].state = .superseded
            operationRecords[index].transitionDate = Date()
        }
        if !invalidatedIDs.isEmpty || operationRecords.contains(where: { $0.state == .superseded }) {
            persistOperationHistory()
        }
    }

    private func realFileMutationsAllowed() -> Bool {
        guard !isFileOperationInProgress else {
            errorMessage = "已有文件操作正在进行，请等待完成或先取消。"
            return false
        }
        guard !sessionIsReadOnly else {
            errorMessage = "这个空间正在被另一个空间文件夹进程使用。当前窗口为只读模式，请先退出占用它的旧版本。"
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
                errorMessage = "这个空间已被另一个空间文件夹占用\(ownerText)。当前以只读方式打开。"
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

    private func transferLayout(from oldID: String, to newID: String) {
        if let position = positions.removeValue(forKey: oldID) { positions[newID] = position }
        if let scale = scales.removeValue(forKey: oldID) { scales[newID] = scale }
        if inboxIDs.remove(oldID) != nil { inboxIDs.insert(newID) }
        if selectedIDs.remove(oldID) != nil { selectedIDs.insert(newID) }
    }

    // MARK: - 自动放置、容量与坐标算法

    private func arrangeInitialItems(_ freshItems: [FolderItem]) {
        positions = [:]
        inboxIDs = []
        for (index, item) in freshItems.enumerated() {
            if index < mainCanvasCapacity {
                positions[item.id] = gridPoint(for: index, scale: scale(for: item))
            } else {
                inboxIDs.insert(item.id)
            }
        }
    }

    private func assignPositionsToNewItems(_ freshItems: [FolderItem]) -> Bool {
        var changed = false
        var activeItems = freshItems.filter { !inboxIDs.contains($0.id) && positions[$0.id] != nil }
        for item in freshItems where positions[item.id] == nil && !inboxIDs.contains(item.id) {
            if activeItems.count < mainCanvasCapacity,
               let point = nextAvailableGridPoint(for: item, among: activeItems) {
                positions[item.id] = point
                activeItems.append(item)
            } else {
                inboxIDs.insert(item.id)
            }
            changed = true
        }
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

    private func nextAvailableGridPoint(for item: FolderItem, among activeItems: [FolderItem]) -> CanvasPoint? {
        let occupiedRects = activeItems.compactMap { active -> CGRect? in
            guard let position = positions[active.id] else { return nil }
            return iconRect(at: position, scale: scale(for: active))
        }
        for index in 0..<mainCanvasCapacity {
            let point = gridPoint(for: index, scale: scale(for: item))
            let candidate = iconRect(at: point, scale: scale(for: item)).insetBy(dx: -4, dy: -4)
            if !occupiedRects.contains(where: { $0.intersects(candidate) }) { return point }
        }
        return nil
    }

    private func gridPoint(for index: Int, scale: CGFloat) -> CanvasPoint {
        let column = index % initialColumns
        let row = index / initialColumns
        let cellWidth = canvasSize.width / CGFloat(initialColumns)
        let cellHeight = canvasSize.height / CGFloat(initialColumns)
        let point = CGPoint(
            x: cellWidth * (CGFloat(column) + 0.5),
            y: cellHeight * (CGFloat(row) + 0.5)
        )
        return snapped(point, scale: scale)
    }

    private func snapped(_ point: CGPoint, scale: CGFloat) -> CanvasPoint {
        let halfWidth = max(grid, 52 * scale)
        let halfHeight = max(grid, 48 * scale)
        let maximumX = max(halfWidth, canvasSize.width - halfWidth)
        let maximumY = max(halfHeight, canvasSize.height - halfHeight)
        let snappedX = (point.x / grid).rounded() * grid
        let snappedY = (point.y / grid).rounded() * grid
        return CanvasPoint(
            x: min(maximumX, max(halfWidth, snappedX)),
            y: min(maximumY, max(halfHeight, snappedY))
        )
    }

    private func iconRect(at point: CanvasPoint, scale: CGFloat) -> CGRect {
        let halfWidth = 52 * scale
        let halfHeight = 48 * scale
        return CGRect(
            x: point.x - halfWidth,
            y: point.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    private func isInsideBounds(_ point: CanvasPoint, scale: CGFloat) -> Bool {
        let rect = iconRect(at: point, scale: scale)
        return rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= canvasSize.width && rect.maxY <= canvasSize.height
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
            open(folder: resolved)
            errorMessage = "检测到文件夹已移动，原空间布局已经自动重新关联。"
            return
        }
        folderUnavailable = true
        folderMonitor?.cancel()
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
        let descriptor = Darwin.open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderMonitor = source
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
