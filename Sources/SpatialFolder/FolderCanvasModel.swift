import AppKit
import Darwin
import Foundation
import SwiftUI

struct CanvasPoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
}

struct SavedCanvas: Codable {
    var layoutVersion: Int = 3
    var positions: [String: CanvasPoint] = [:]
    var scales: [String: CGFloat] = [:]
    var wallpaperPath: String?

    enum CodingKeys: String, CodingKey { case layoutVersion, positions, scales, wallpaperPath }

    init(layoutVersion: Int = 3, positions: [String: CanvasPoint] = [:], scales: [String: CGFloat] = [:], wallpaperPath: String? = nil) {
        self.layoutVersion = layoutVersion
        self.positions = positions
        self.scales = scales
        self.wallpaperPath = wallpaperPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layoutVersion = try container.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 1
        positions = try container.decodeIfPresent([String: CanvasPoint].self, forKey: .positions) ?? [:]
        scales = try container.decodeIfPresent([String: CGFloat].self, forKey: .scales) ?? [:]
        wallpaperPath = try container.decodeIfPresent(String.self, forKey: .wallpaperPath)
    }
}

struct FolderItem: Identifiable, Hashable {
    let url: URL
    let icon: NSImage
    let tags: [String]

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func == (lhs: FolderItem, rhs: FolderItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

@MainActor
final class FolderCanvasModel: ObservableObject {
    private let defaultIconScale: CGFloat = 1.25
    private let initialColumns = 8
    private let recentFoldersKey = "recentFolderPaths"
    private let maximumRecentFolders = 8
    @Published private(set) var folderURL: URL?
    @Published private(set) var items: [FolderItem] = []
    @Published private(set) var positions: [String: CanvasPoint] = [:]
    @Published private(set) var scales: [String: CGFloat] = [:]
    @Published private(set) var wallpaperURL: URL?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var selectionRect: CGRect?
    @Published private(set) var dragTranslation: CGSize = .zero
    @Published private(set) var draggingIDs: Set<String> = []
    @Published var errorMessage: String?
    @Published private(set) var appearanceMode: String
    @Published private(set) var recentFolders: [URL] = []
    @Published var searchText = ""
    @Published var infoItem: FolderItem?

    private var folderMonitor: DispatchSourceFileSystemObject?
    private var refreshWorkItem: DispatchWorkItem?
    private var iconCache: [String: NSImage] = [:]
    private var savedCanvas = SavedCanvas()
    private var needsGridMigration = false
    private var selectionStart: CGPoint?
    private var cutURLs: [URL] = []
    private let grid: CGFloat = 24

    private var layoutsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SpatialFolder/Layouts", isDirectory: true)
    }

    init() {
        appearanceMode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        recentFolders = (UserDefaults.standard.stringArray(forKey: recentFoldersKey) ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.path) }
        if let path = UserDefaults.standard.string(forKey: "lastOpenedFolderPath") {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                open(folder: url)
            }
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.tags.contains { normalizedTagName($0).localizedCaseInsensitiveContains(query) }
        }
    }

    func setAppearanceMode(_ mode: String) {
        appearanceMode = mode
        UserDefaults.standard.set(mode, forKey: "appearanceMode")
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
        folderMonitor?.cancel()
        refreshWorkItem?.cancel()
        folderURL = folder.standardizedFileURL
        UserDefaults.standard.set(folderURL?.path, forKey: "lastOpenedFolderPath")
        remember(folder: folder.standardizedFileURL)
        selectedIDs = []
        loadSavedCanvas()
        refreshItems()
        watchFolder()
    }

    func refreshItems() {
        guard let folderURL else { return }
        do {
            let keys: Set<URLResourceKey> = [.isHiddenKey, .tagNamesKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let freshItems = urls.compactMap { url -> FolderItem? in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isHidden != true else { return nil }
                return FolderItem(url: url,
                                  icon: cachedIcon(for: url),
                                  tags: values?.tagNames ?? [])
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let currentPaths = Set(freshItems.map(\.id))
            iconCache = iconCache.filter { currentPaths.contains($0.key) }
            items = freshItems
            if needsGridMigration {
                arrangeAllItemsInGrid(freshItems)
                needsGridMigration = false
            } else {
                assignPositionsToNewItems(freshItems)
            }
        } catch {
            errorMessage = "无法读取文件夹：\(error.localizedDescription)"
        }
    }

    func position(for item: FolderItem) -> CanvasPoint {
        positions[item.id] ?? CanvasPoint(x: 72, y: 72)
    }

    func move(_ item: FolderItem, to point: CGPoint) {
        positions[item.id] = snapped(point)
        persist()
    }

    func scale(for item: FolderItem) -> CGFloat {
        scales[item.id] ?? defaultIconScale
    }

    func setScale(_ scale: CGFloat, for item: FolderItem) {
        scales[item.id] = min(max(scale, 0.7), 1.8)
        persist()
    }

    var defaultDesktopWallpaperURL: URL? {
        guard let screen = NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    var desktopCanvasSize: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    func select(_ item: FolderItem, extendingSelection: Bool) {
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
        selectionRect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(point.x - start.x), height: abs(point.y - start.y))
    }

    func finishSelection(addingToSelection: Bool) {
        guard let selectionRect else { return }
        let selected = Set(items.compactMap { item -> String? in
            let point = position(for: item)
            return selectionRect.insetBy(dx: -52, dy: -48).contains(CGPoint(x: point.x, y: point.y)) ? item.id : nil
        })
        selectedIDs = addingToSelection ? selectedIDs.union(selected) : selected
        self.selectionRect = nil
        selectionStart = nil
    }

    func beginDragging(_ item: FolderItem) {
        if !selectedIDs.contains(item.id) { selectedIDs = [item.id] }
        draggingIDs = selectedIDs
    }

    func updateDrag(translation: CGSize) { dragTranslation = translation }

    func finishDrag() {
        for id in draggingIDs {
            guard let position = positions[id] else { continue }
            positions[id] = snapped(CGPoint(x: position.x + dragTranslation.width, y: position.y + dragTranslation.height))
        }
        dragTranslation = .zero
        draggingIDs = []
        persist()
    }

    func open(_ item: FolderItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: FolderItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func showInfo(_ item: FolderItem) {
        infoItem = item
    }

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
        if let index = tags.firstIndex(where: { normalizedTagName($0) == normalized }) { tags.remove(at: index) }
        else { tags.append(tag) }
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutURLs = []
    }

    func cut(_ items: [FolderItem]) {
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
            try FileManager.default.copyItem(at: item.url, to: uniqueDestination(for: item.url, in: item.url.deletingLastPathComponent()))
            refreshItems()
        } catch { errorMessage = "无法复制文件：\(error.localizedDescription)" }
    }

    func compress(_ item: FolderItem) {
        guard let folderURL else { return }
        let archiveSource = folderURL
            .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("zip")
        let archiveURL = uniqueDestination(for: archiveSource, in: folderURL)
        Task.detached { [weak self] in
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", item.url.path, archiveURL.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "SpatialFolder", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "系统压缩命令未能完成。"])
                }
                await MainActor.run { self?.refreshItems() }
            } catch {
                await MainActor.run { self?.errorMessage = "无法压缩项目：\(error.localizedDescription)" }
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
        } catch { errorMessage = "无法导入文件：\(error.localizedDescription)" }
    }

    func trash(_ item: FolderItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            positions.removeValue(forKey: item.id)
            scales.removeValue(forKey: item.id)
            selectedIDs.remove(item.id)
            persist()
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
            try FileManager.default.createDirectory(at: folderURL.appendingPathComponent(name), withIntermediateDirectories: false)
            refreshItems()
        } catch { errorMessage = "无法新建文件夹：\(error.localizedDescription)" }
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
            if let position = positions.removeValue(forKey: item.id) { positions[newURL.path] = position }
            if let scale = scales.removeValue(forKey: item.id) { scales[newURL.path] = scale }
            persist()
            refreshItems()
        } catch { errorMessage = "无法重命名：\(error.localizedDescription)" }
    }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "选择画布壁纸"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            wallpaperURL = url
            savedCanvas.wallpaperPath = url.path
            persist()
        }
    }

    private func snapped(_ point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: max(grid, (point.x / grid).rounded() * grid),
                    y: max(grid, (point.y / grid).rounded() * grid))
    }

    private func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let extensionName = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        var index = 1
        var target = folder.appendingPathComponent(source.lastPathComponent)
        while FileManager.default.fileExists(atPath: target.path) {
            index += 1
            let name = "\(baseName) \(index)"
            target = folder.appendingPathComponent(name).appendingPathExtension(extensionName)
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

    private func assignPositionsToNewItems(_ freshItems: [FolderItem]) {
        for item in freshItems where positions[item.id] == nil {
            positions[item.id] = nextInboxPoint()
        }
        persist()
    }

    private func arrangeAllItemsInGrid(_ freshItems: [FolderItem]) {
        positions = [:]
        for (index, item) in freshItems.enumerated() {
            positions[item.id] = gridPoint(for: index)
        }
        persist()
    }

    private func gridPoint(for index: Int) -> CanvasPoint {
        let canvas = desktopCanvasSize
        let column = index % initialColumns
        let row = index / initialColumns
        let cellWidth = canvas.width / CGFloat(initialColumns)
        let cellHeight = canvas.height / CGFloat(initialColumns)
        return CanvasPoint(x: cellWidth * (CGFloat(column) + 0.5),
                           y: cellHeight * (CGFloat(row) + 0.5))
    }

    private func nextInboxPoint() -> CanvasPoint {
        let occupied = Set(items.compactMap { positions[$0.id] }.map { "\(Int($0.x)):\(Int($0.y))" })
        let canvas = desktopCanvasSize
        let horizontalInset = max(grid * 3, canvas.width - grid * 12)
        let verticalInset = grid * 3
        for row in 0..<100 {
            for column in 0..<3 {
                let point = CanvasPoint(x: horizontalInset + CGFloat(column) * grid * 4,
                                        y: verticalInset + CGFloat(row) * grid * 5)
                let key = "\(Int(point.x)):\(Int(point.y))"
                if point.x < canvas.width - grid * 2, point.y < canvas.height - grid * 2, !occupied.contains(key) {
                    return point
                }
            }
        }
        return gridPoint(for: items.count)
    }

    private func layoutURL() -> URL? {
        guard let folderURL else { return nil }
        let digest = folderURL.path.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return layoutsDirectory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private func loadSavedCanvas() {
        savedCanvas = SavedCanvas()
        guard let layoutURL = layoutURL(), let data = try? Data(contentsOf: layoutURL),
              let loaded = try? JSONDecoder().decode(SavedCanvas.self, from: data) else {
            positions = [:]; scales = [:]; wallpaperURL = nil; return
        }
        savedCanvas = loaded
        positions = loaded.positions
        scales = loaded.scales
        needsGridMigration = loaded.layoutVersion < 3
        wallpaperURL = loaded.wallpaperPath.map(URL.init(fileURLWithPath:))
    }

    private func persist() {
        guard let layoutURL = layoutURL() else { return }
        savedCanvas.positions = positions
        savedCanvas.scales = scales
        savedCanvas.layoutVersion = 3
        do {
            try FileManager.default.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(savedCanvas)
            try data.write(to: layoutURL, options: .atomic)
        } catch { errorMessage = "无法保存画布布局：\(error.localizedDescription)" }
    }

    private func watchFolder() {
        guard let folderURL else { return }
        let descriptor = Darwin.open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
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
        recentFolders.removeAll { $0.standardizedFileURL == folder }
        recentFolders.insert(folder, at: 0)
        recentFolders = Array(recentFolders.prefix(maximumRecentFolders))
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: recentFoldersKey)
    }

    func hasTag(_ tag: String, in item: FolderItem) -> Bool {
        item.tags.contains { normalizedTagName($0) == normalizedTagName(tag) }
    }

    func normalizedTagName(_ tag: String) -> String {
        tag.components(separatedBy: "\n").first ?? tag
    }
}
