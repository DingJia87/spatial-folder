import AppKit
import Darwin
import Foundation

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
    let isDirectory: Bool
    let icon: NSImage

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func == (lhs: FolderItem, rhs: FolderItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

@MainActor
final class FolderCanvasModel: ObservableObject {
    private let defaultIconScale: CGFloat = 1.25
    private let initialColumns = 8
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

    private var folderMonitor: DispatchSourceFileSystemObject?
    private var savedCanvas = SavedCanvas()
    private var needsGridMigration = false
    private var selectionStart: CGPoint?
    private let grid: CGFloat = 24

    private var layoutsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SpatialFolder/Layouts", isDirectory: true)
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
        folderURL = folder.standardizedFileURL
        selectedIDs = []
        loadSavedCanvas()
        refreshItems()
        watchFolder()
    }

    func refreshItems() {
        guard let folderURL else { return }
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let freshItems = urls.compactMap { url -> FolderItem? in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isHidden != true else { return nil }
                return FolderItem(url: url, isDirectory: values?.isDirectory == true,
                                  icon: NSWorkspace.shared.icon(forFile: url.path))
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        if item.isDirectory {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.url.path)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func reveal(_ item: FolderItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
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
        let existingCount = positions.count
        var newItemIndex = 0
        for item in freshItems where positions[item.id] == nil {
            let index = existingCount + newItemIndex
            positions[item.id] = gridPoint(for: index)
            newItemIndex += 1
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
        source.setEventHandler { [weak self] in self?.refreshItems() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderMonitor = source
    }
}
