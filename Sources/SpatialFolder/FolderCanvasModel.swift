import AppKit
import Darwin
import Foundation
import SwiftUI

struct FolderItem: Identifiable, Hashable {
    let url: URL
    let icon: NSImage
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
    private let defaults: UserDefaults
    private let monitorFolders: Bool

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
    private var iconCache: [String: NSImage] = [:]
    private var savedCanvas = SavedCanvas()
    private var needsInitialArrangement = false
    private var needsGridMigration = false
    private var selectionStart: CGPoint?
    private var cutURLs: [URL] = []
    private var canvasKey: String?
    private var rootResourceID: String?
    private var lastFolderBookmark: Data?
    private var undoStack: [SavedCanvas] = []
    private var redoStack: [SavedCanvas] = []

    init(
        layoutStore: CanvasLayoutStore = CanvasLayoutStore(),
        userDefaults: UserDefaults = .standard,
        autoOpenLastFolder: Bool = true,
        initialCanvasSize: CGSize? = nil,
        monitorFolders: Bool = true
    ) {
        self.layoutStore = layoutStore
        defaults = userDefaults
        self.monitorFolders = monitorFolders
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
        let standardized = folder.standardizedFileURL
        guard Self.directoryExists(at: standardized) else {
            errorMessage = "无法打开文件夹：文件夹不存在或暂时不可用。"
            return
        }
        folderMonitor?.cancel()
        refreshWorkItem?.cancel()
        folderURL = standardized
        rootResourceID = persistentResourceIdentifier(for: standardized) ?? "path:\(standardized.path)"
        canvasKey = rootResourceID.map(layoutStore.canvasKey(for:))
        lastFolderBookmark = makeBookmark(for: standardized)
        saveLastOpenedFolder(standardized)
        remember(folder: standardized)
        selectedIDs = []
        undoStack = []
        redoStack = []
        updateUndoAvailability()
        folderUnavailable = false
        loadSavedCanvas()
        refreshItems()
        if monitorFolders { watchFolder() }
    }

    func refreshItems() {
        guard let folderURL else { return }
        guard Self.directoryExists(at: folderURL) else {
            attemptFolderRecovery()
            return
        }
        folderUnavailable = false
        do {
            let keys: Set<URLResourceKey> = [
                .isHiddenKey, .tagNamesKey, .fileResourceIdentifierKey, .volumeIdentifierKey
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let freshItems = urls.compactMap { url -> FolderItem? in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isHidden != true else { return nil }
                return FolderItem(
                    url: url,
                    icon: cachedIcon(for: url),
                    tags: values?.tagNames ?? [],
                    resourceID: persistentResourceIdentifier(values: values)
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let currentPaths = Set(freshItems.map(\.id))
            iconCache = iconCache.filter { currentPaths.contains($0.key) }
            items = freshItems
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
        } catch {
            errorMessage = "无法读取文件夹：\(error.localizedDescription)"
        }
    }

    func position(for item: FolderItem) -> CanvasPoint {
        positions[item.id] ?? CanvasPoint(x: 72, y: 72)
    }

    func move(_ item: FolderItem, to point: CGPoint) {
        guard !isLocked, !inboxIDs.contains(item.id) else { return }
        captureUndoSnapshot()
        positions[item.id] = snapped(point, scale: scale(for: item))
        persist(makeBackup: true)
    }

    func scale(for item: FolderItem) -> CGFloat {
        scales[item.id] ?? defaultIconScale
    }

    func setScale(_ scale: CGFloat, for item: FolderItem) {
        guard !isLocked else { return }
        captureUndoSnapshot()
        let adjustedScale = min(max(scale, 0.7), 1.8)
        scales[item.id] = adjustedScale
        if let position = positions[item.id] {
            positions[item.id] = snapped(CGPoint(x: position.x, y: position.y), scale: adjustedScale)
        }
        persist(makeBackup: true)
    }

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
        guard !isLocked, !inboxIDs.contains(item.id) else { return }
        if !selectedIDs.contains(item.id) { selectedIDs = [item.id] }
        draggingIDs = selectedIDs
    }

    func updateDrag(translation: CGSize) {
        guard !draggingIDs.isEmpty else { return }
        dragTranslation = translation
    }

    func finishDrag() {
        guard !isLocked, !draggingIDs.isEmpty else {
            dragTranslation = .zero
            draggingIDs = []
            return
        }
        let moved = abs(dragTranslation.width) > 0.5 || abs(dragTranslation.height) > 0.5
        if moved { captureUndoSnapshot() }
        for id in draggingIDs {
            guard let position = positions[id] else { continue }
            let itemScale = scales[id] ?? defaultIconScale
            positions[id] = snapped(
                CGPoint(x: position.x + dragTranslation.width, y: position.y + dragTranslation.height),
                scale: itemScale
            )
        }
        dragTranslation = .zero
        draggingIDs = []
        if moved { persist(makeBackup: true) }
    }

    func setLocked(_ locked: Bool) {
        guard isLocked != locked else { return }
        captureUndoSnapshot()
        isLocked = locked
        persist(makeBackup: true)
    }

    func toggleLocked() { setLocked(!isLocked) }

    func moveToInbox(_ item: FolderItem) {
        guard !isLocked, !inboxIDs.contains(item.id) else { return }
        captureUndoSnapshot()
        inboxIDs.insert(item.id)
        positions.removeValue(forKey: item.id)
        selectedIDs.remove(item.id)
        persist(makeBackup: true)
    }

    func placeFromInbox(_ item: FolderItem) {
        guard !isLocked, inboxIDs.contains(item.id) else { return }
        let activeItems = items.filter { !inboxIDs.contains($0.id) && positions[$0.id] != nil }
        guard activeItems.count < mainCanvasCapacity,
              let point = nextAvailableGridPoint(for: item, among: activeItems) else {
            errorMessage = "主画布已经放满。请先把一个项目移到待放置区。"
            return
        }
        captureUndoSnapshot()
        inboxIDs.remove(item.id)
        positions[item.id] = point
        persist(makeBackup: true)
    }

    func recoverOutOfBoundsItems() {
        guard !isLocked else { return }
        let before = positions
        captureUndoSnapshot()
        for item in items where !inboxIDs.contains(item.id) {
            guard let point = positions[item.id] else { continue }
            positions[item.id] = snapped(CGPoint(x: point.x, y: point.y), scale: scale(for: item))
        }
        if before == positions {
            undoStack.removeLast()
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
        guard folderURL != nil, !layoutIsBlocked, !isLocked else { return }
        guard abs(canvasSize.width - currentDisplaySize.width) > 1 ||
                abs(canvasSize.height - currentDisplaySize.height) > 1 else {
            errorMessage = "当前显示器已经是基准画布。"
            return
        }
        captureUndoSnapshot()
        resizeLogicalCanvas(to: currentDisplaySize)
        _ = enforceCapacityAndBounds(items)
        persist(makeBackup: true)
    }

    func undoLayoutChange() {
        guard let previous = undoStack.popLast() else { return }
        syncSavedCanvas()
        redoStack.append(savedCanvas)
        applySavedCanvas(previous)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true)
        updateUndoAvailability()
    }

    func redoLayoutChange() {
        guard let next = redoStack.popLast() else { return }
        syncSavedCanvas()
        undoStack.append(savedCanvas)
        applySavedCanvas(next)
        reconcileAfterLayoutRestore()
        persist(makeBackup: true)
        updateUndoAvailability()
    }

    func resetLayout() {
        if !layoutIsBlocked { captureUndoSnapshot() }
        layoutIsBlocked = false
        positions = [:]
        scales = [:]
        inboxIDs = []
        arrangeInitialItems(items)
        persist(makeBackup: true)
    }

    func restoreLatestBackup() {
        guard let canvasKey else { return }
        do {
            if !layoutIsBlocked { captureUndoSnapshot() }
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
        let imported = try layoutStore.importedCanvas(from: url, expectedRootResourceID: rootResourceID)
        if !layoutIsBlocked { captureUndoSnapshot() }
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
        guard preservingCurrentLayout else { return }
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

    func open(_ item: FolderItem) { NSWorkspace.shared.open(item.url) }

    func reveal(_ item: FolderItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func showInfo(_ item: FolderItem) { infoItem = item }

    func share(_ item: FolderItem) {
        guard let view = NSApp.keyWindow?.contentView else {
            errorMessage = "当前没有可用于分享的窗口。"
            return
        }
        let picker = NSSharingServicePicker(items: [item.url])
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func toggleTag(_ tag: String, for item: FolderItem) {
        var tags = item.tags
        let normalized = normalizedTagName(tag)
        if let index = tags.firstIndex(where: { normalizedTagName($0) == normalized }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        do {
            try (item.url as NSURL).setResourceValue(tags, forKey: URLResourceKey.tagNamesKey)
            refreshItems()
        } catch {
            errorMessage = "无法更新标签：\(error.localizedDescription)"
        }
    }

    func clearTags(for item: FolderItem) {
        do {
            try (item.url as NSURL).setResourceValue([], forKey: URLResourceKey.tagNamesKey)
            refreshItems()
        } catch {
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
        do {
            try FileManager.default.copyItem(
                at: item.url,
                to: uniqueDestination(for: item.url, in: item.url.deletingLastPathComponent())
            )
            refreshItems()
        } catch {
            errorMessage = "无法复制文件：\(error.localizedDescription)"
        }
    }

    func compress(_ item: FolderItem) {
        guard let folderURL else { return }
        let archiveSource = folderURL
            .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("zip")
        let archiveURL = uniqueDestination(for: archiveSource, in: folderURL)
        let sourcePath = item.url.path
        let archivePath = archiveURL.path
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-c", "-k", "--keepParent", sourcePath, archivePath]
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0 ? nil : "系统压缩命令未能完成。"
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                self?.errorMessage = "无法压缩项目：\(failure)"
            } else {
                self?.refreshItems()
            }
        }
    }

    func importFiles(_ urls: [URL], move: Bool = false) {
        guard let folderURL else { return }
        do {
            for source in urls where source.deletingLastPathComponent() != folderURL {
                let target = uniqueDestination(for: source, in: folderURL)
                if move { try FileManager.default.moveItem(at: source, to: target) }
                else { try FileManager.default.copyItem(at: source, to: target) }
            }
            refreshItems()
        } catch {
            errorMessage = "无法导入文件：\(error.localizedDescription)"
        }
    }

    func trash(_ item: FolderItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            positions.removeValue(forKey: item.id)
            scales.removeValue(forKey: item.id)
            inboxIDs.remove(item.id)
            selectedIDs.remove(item.id)
            persist(makeBackup: true)
            refreshItems()
        } catch {
            errorMessage = "无法移至废纸篓：\(error.localizedDescription)"
        }
    }

    func createFolder() {
        guard let folderURL else { return }
        var name = "新建文件夹"
        var suffix = 2
        while FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(name).path) {
            name = "新建文件夹 \(suffix)"
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(
                at: folderURL.appendingPathComponent(name),
                withIntermediateDirectories: false
            )
            refreshItems()
        } catch {
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

    func rename(_ item: FolderItem, to name: String) {
        guard !name.isEmpty else { return }
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard newURL != item.url else { return }
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            transferLayout(from: item.id, to: newURL.path)
            if let resourceID = item.resourceID { savedCanvas.resourcePaths[resourceID] = newURL.path }
            persist(makeBackup: true)
            refreshItems()
        } catch {
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
        captureUndoSnapshot()
        wallpaperURL = url
        persist(makeBackup: true)
    }

    func hasTag(_ tag: String, in item: FolderItem) -> Bool {
        item.tags.contains { normalizedTagName($0) == normalizedTagName(tag) }
    }

    func normalizedTagName(_ tag: String) -> String {
        tag.components(separatedBy: "\n").first ?? tag
    }

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
        guard !layoutIsBlocked, let canvasKey else { return }
        syncSavedCanvas()
        do {
            try layoutStore.save(savedCanvas, canvasKey: canvasKey, makeBackup: makeBackup)
            updateBackupCount()
        } catch {
            errorMessage = "无法保存画布布局：\(error.localizedDescription)"
        }
    }

    private func captureUndoSnapshot() {
        syncSavedCanvas()
        undoStack.append(savedCanvas)
        if undoStack.count > maximumUndoDepth { undoStack.removeFirst() }
        redoStack = []
        updateUndoAvailability()
    }

    private func updateUndoAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
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

    private func cachedIcon(for url: URL) -> NSImage {
        if let icon = iconCache[url.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url.path] = icon
        return icon
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

    private func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let extensionName = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        var index = 1
        var target = folder.appendingPathComponent(source.lastPathComponent)
        while FileManager.default.fileExists(atPath: target.path) {
            index += 1
            target = folder.appendingPathComponent("\(baseName) \(index)").appendingPathExtension(extensionName)
        }
        return target
    }

    private func createFromTemplate(resource: String, baseName: String, extension fileExtension: String) {
        guard let folderURL else { return }
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
        do {
            try FileManager.default.copyItem(at: templateURL, to: targetURL)
            refreshItems()
        } catch {
            errorMessage = "无法新建文件：\(error.localizedDescription)"
        }
    }
}
