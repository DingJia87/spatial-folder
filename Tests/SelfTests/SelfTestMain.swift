import AppKit
import Darwin
import Foundation

extension Bundle {
    static var module: Bundle { .main }
}

private struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct SpatialFolderSelfTests {
    private static var passed = 0
    private static var failed = 0

    static func main() {
        run("备份数量限制与恢复") { try testBackupRetentionAndRestore() }
        run("损坏布局自动恢复") { try testCorruptRecovery() }
        run("无备份损坏布局阻断") { try testCorruptWithoutBackupBlocks() }
        run("旧版路径布局迁移") { try testLegacyMigration() }
        run("跨文件夹布局导入拒绝") { try testWrongFolderImport() }
        run("70 项目进入 64+6 布局") { try testSeventyItemOverflow() }
        run("待放置区与主画布交换") { try testInboxSwap() }
        run("外部重命名保持位置") { try testExternalRenameKeepsPosition() }
        run("撤销、重做和锁定") { try testUndoRedoAndLock() }
        run("锁定状态按文件夹持久保存") { try testLockPersistsPerFolder() }
        run("跨屏往返不改写布局") { try testScreenSwitchDoesNotMutateLayout() }
        run("小屏视口统一缩放") { try testViewportScaleIsUniform() }
        run("基准画布重设与撤销") { try testReferenceCanvasResetAndUndo() }
        run("小屏重启保持原基准画布") { try testRestartOnSmallerDisplayKeepsReferenceCanvas() }
        run("v4 压缩布局迁移到大屏基准") { try testVersionFourReferenceMigration() }
        run("布局导出和导入") { try testExportImport() }
        run("根文件夹移动后恢复") { try testRootFolderMoveRecovery() }
        run("手动重新关联按文件名保留布局") { try testManualRelinkKeepsLayoutByName() }

        print("\n自测结果：\(passed) 通过，\(failed) 失败")
        if failed > 0 { exit(1) }
    }

    private static func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("✓ \(name)")
        } catch {
            failed += 1
            print("✗ \(name)：\(error)")
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SelfTestFailure(description: message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SelfTestFailure(description: message) }
        return value
    }

    private static func testBackupRetentionAndRestore() throws {
        let directory = temporaryDirectory(prefix: "Store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CanvasLayoutStore(layoutsDirectory: directory, maximumBackups: 3)
        let key = store.canvasKey(for: "root-one")
        for value in 0...4 {
            try store.save(
                SavedCanvas(positions: ["file": CanvasPoint(x: CGFloat(value), y: 20)]),
                canvasKey: key,
                makeBackup: true
            )
        }
        try check(store.backupURLs(canvasKey: key).count == 3, "备份数量不是 3")
        let restored = try store.restoreLatestBackup(canvasKey: key)
        try check(restored.positions["file"]?.x == 3, "没有恢复最新备份")
    }

    private static func testCorruptRecovery() throws {
        let directory = temporaryDirectory(prefix: "Store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CanvasLayoutStore(layoutsDirectory: directory)
        let key = store.canvasKey(for: "root-two")
        let original = SavedCanvas(positions: ["file": CanvasPoint(x: 120, y: 240)])
        try store.save(original, canvasKey: key, makeBackup: true)
        try store.save(SavedCanvas(positions: ["file": CanvasPoint(x: 300, y: 400)]), canvasKey: key, makeBackup: true)
        try Data("not-json".utf8).write(to: store.layoutURL(canvasKey: key), options: .atomic)
        let result = try store.load(canvasKey: key, legacyFolderPath: nil)
        guard case let .recovered(canvas, corruptCopyURL) = result else {
            throw SelfTestFailure(description: "未进入恢复状态")
        }
        try check(canvas == original, "恢复的数据不正确")
        try check(FileManager.default.fileExists(atPath: corruptCopyURL.path), "未保留损坏副本")
    }

    private static func testCorruptWithoutBackupBlocks() throws {
        let directory = temporaryDirectory(prefix: "Store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CanvasLayoutStore(layoutsDirectory: directory)
        let key = store.canvasKey(for: "root-three")
        let url = store.layoutURL(canvasKey: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: url)
        let result = try store.load(canvasKey: key, legacyFolderPath: nil)
        guard case .blocked = result else {
            throw SelfTestFailure(description: "损坏布局被静默重置")
        }
        let preserved = try Data(contentsOf: url)
        try check(preserved == Data("broken".utf8), "损坏原文件被覆盖")
    }

    private static func testLegacyMigration() throws {
        let directory = temporaryDirectory(prefix: "Store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CanvasLayoutStore(layoutsDirectory: directory)
        let path = "/tmp/old/spatial/folder"
        let key = store.canvasKey(for: "stable-resource-id")
        let legacy = SavedCanvas(layoutVersion: 3, positions: ["old": CanvasPoint(x: 72, y: 96)])
        try store.export(legacy, to: store.legacyLayoutURL(folderPath: path))
        let result = try store.load(canvasKey: key, legacyFolderPath: path)
        guard case let .loaded(canvas, migrated) = result else {
            throw SelfTestFailure(description: "旧布局未读取")
        }
        try check(migrated && canvas.positions == legacy.positions, "旧布局迁移内容不正确")
    }

    private static func testWrongFolderImport() throws {
        let directory = temporaryDirectory(prefix: "Store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CanvasLayoutStore(layoutsDirectory: directory)
        let exportURL = directory.appendingPathComponent("export.json")
        try store.export(SavedCanvas(rootResourceID: "other-root"), to: exportURL)
        do {
            _ = try store.importedCanvas(from: exportURL, expectedRootResourceID: "current-root")
            throw SelfTestFailure(description: "错误接受了其他文件夹布局")
        } catch CanvasLayoutStoreError.wrongFolder {
            return
        }
    }

    private static func testSeventyItemOverflow() throws {
        let fixture = try makeFixture(itemCount: 70, canvasSize: CGSize(width: 1728, height: 1117))
        defer { fixture.cleanup() }
        try check(fixture.model.displayedItems.count == 64, "主画布数量不是 64")
        try check(fixture.model.inboxItems.count == 6, "待放置区数量不是 6")
        try assertItemsInsideBounds(fixture.model)
    }

    private static func testInboxSwap() throws {
        let fixture = try makeFixture(itemCount: 70, canvasSize: CGSize(width: 1728, height: 1117))
        defer { fixture.cleanup() }
        let canvasItem = try require(fixture.model.displayedItems.first, "主画布没有项目")
        let waitingItem = try require(fixture.model.inboxItems.first, "待放置区没有项目")

        fixture.model.moveToInbox(canvasItem)
        try check(fixture.model.displayedItems.count == 63, "移出后主画布数量不正确")
        try check(fixture.model.inboxItems.count == 7, "移出后待放置区数量不正确")
        fixture.model.placeFromInbox(waitingItem)
        try check(fixture.model.displayedItems.count == 64, "放入后主画布数量不正确")
        try check(fixture.model.inboxItems.count == 6, "放入后待放置区数量不正确")
        try check(fixture.model.positions[waitingItem.id] != nil, "待放置项目没有获得位置")
        try assertItemsInsideBounds(fixture.model)
    }

    private static func testExternalRenameKeepsPosition() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(item, to: CGPoint(x: 600, y: 420))
        let expected = try require(fixture.model.positions[item.id], "没有保存移动位置")
        let renamedURL = fixture.folder.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: item.url, to: renamedURL)
        fixture.model.refreshItems()
        let renamed = try require(
            fixture.model.items.first { $0.name == "renamed.txt" },
            "重命名文件未刷新，当前项目：\(fixture.model.items.map(\.name))"
        )
        try check(fixture.model.positions[renamed.id] == expected, "外部重命名后位置变化")
        try check(fixture.model.positions[item.id] == nil, "旧路径布局未迁移")
    }

    private static func testUndoRedoAndLock() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        let original = try require(fixture.model.positions[item.id], "没有初始位置")
        fixture.model.move(item, to: CGPoint(x: 700, y: 500))
        let moved = try require(fixture.model.positions[item.id], "没有移动位置")
        try check(moved != original, "移动没有生效")
        fixture.model.undoLayoutChange()
        try check(fixture.model.positions[item.id] == original, "撤销失败")
        fixture.model.redoLayoutChange()
        try check(fixture.model.positions[item.id] == moved, "重做失败")
        fixture.model.setLocked(true)
        fixture.model.move(item, to: CGPoint(x: 100, y: 100))
        try check(fixture.model.positions[item.id] == moved, "锁定后仍能移动")
    }

    private static func testLockPersistsPerFolder() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        fixture.model.setLocked(true)
        let reopened = FolderCanvasModel(
            layoutStore: fixture.store,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: false,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false
        )
        reopened.open(folder: fixture.folder)
        try check(reopened.isLocked, "重新打开文件夹后锁定状态丢失")
    }

    private static func testScreenSwitchDoesNotMutateLayout() throws {
        let external = CGSize(width: 2560, height: 1440)
        let internalDisplay = CGSize(width: 1512, height: 982)
        let fixture = try makeFixture(itemCount: 12, canvasSize: external)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(item, to: CGPoint(x: 1900, y: 1080))
        let before = fixture.base.appendingPathComponent("before.json")
        let after = fixture.base.appendingPathComponent("after.json")
        try fixture.model.exportLayout(to: before)

        for _ in 0..<10 {
            fixture.model.updateCanvasSize(internalDisplay)
            fixture.model.updateCanvasSize(external)
        }
        try fixture.model.exportLayout(to: after)

        try check(fixture.model.desktopCanvasSize == external, "跨屏后逻辑画布尺寸变化")
        let beforeData = try Data(contentsOf: before)
        let afterData = try Data(contentsOf: after)
        try check(beforeData == afterData, "跨屏后布局文件发生变化")
    }

    private static func testViewportScaleIsUniform() throws {
        let logical = CGSize(width: 2560, height: 1440)
        let internalDisplay = CGSize(width: 1512, height: 982)
        let scale = CanvasViewport.displayScale(
            logicalSize: logical,
            viewportWidth: 1512,
            displaySize: internalDisplay
        )
        let expected = min(1512.0 / 2560.0, 982.0 / 1440.0)
        try check(abs(scale - expected) < 0.000_001, "视口没有使用单一比例缩放")
        try check(scale < 1, "小屏视口没有缩小")
        let iconWidth = 104.0 * scale
        let spacing = 320.0 * scale
        try check(abs(iconWidth / spacing - 104.0 / 320.0) < 0.000_001, "图标和间距比例不一致")
    }

    private static func testReferenceCanvasResetAndUndo() throws {
        let internalDisplay = CGSize(width: 1512, height: 982)
        let external = CGSize(width: 2560, height: 1440)
        let fixture = try makeFixture(itemCount: 1, canvasSize: internalDisplay)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(item, to: CGPoint(x: 1100, y: 700))
        let original = try require(fixture.model.positions[item.id], "没有原始位置")

        fixture.model.updateCanvasSize(external)
        fixture.model.setCurrentDisplayAsReferenceCanvas()
        let expanded = try require(fixture.model.positions[item.id], "重设后没有位置")
        try check(fixture.model.desktopCanvasSize == external, "没有采用当前显示器作为基准")
        try check(expanded != original, "重设基准没有映射坐标")
        try check(fixture.model.canUndo, "重设基准不能撤销")

        fixture.model.undoLayoutChange()
        try check(fixture.model.desktopCanvasSize == internalDisplay, "撤销没有恢复旧基准尺寸")
        try check(fixture.model.positions[item.id] == original, "撤销没有恢复旧坐标")
    }

    private static func testRestartOnSmallerDisplayKeepsReferenceCanvas() throws {
        let external = CGSize(width: 2560, height: 1440)
        let internalDisplay = CGSize(width: 1512, height: 982)
        let fixture = try makeFixture(itemCount: 1, canvasSize: external)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(item, to: CGPoint(x: 1900, y: 1080))
        let expected = try require(fixture.model.positions[item.id], "没有保存外接屏位置")
        fixture.model.updateCanvasSize(internalDisplay)

        let reopened = FolderCanvasModel(
            layoutStore: fixture.store,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: false,
            initialCanvasSize: internalDisplay,
            monitorFolders: false
        )
        reopened.open(folder: fixture.folder)
        let reopenedItem = try require(reopened.items.first, "重启后项目缺失")
        try check(reopened.desktopCanvasSize == external, "小屏重启改写了基准画布")
        try check(reopened.positions[reopenedItem.id] == expected, "小屏重启改变了坐标")
    }

    private static func testVersionFourReferenceMigration() throws {
        let internalDisplay = CGSize(width: 1512, height: 982)
        let external = CGSize(width: 2560, height: 1440)
        let fixture = try makeFixture(itemCount: 1, canvasSize: internalDisplay)
        defer { fixture.cleanup() }
        let exportURL = fixture.base.appendingPathComponent("v5.json")
        try fixture.model.exportLayout(to: exportURL)
        var legacy = try JSONDecoder().decode(SavedCanvas.self, from: Data(contentsOf: exportURL))
        legacy.layoutVersion = 4
        legacy.canvasSize = CanvasDimensions(internalDisplay)
        let item = try require(fixture.model.items.first, "没有测试文件")
        legacy.positions[item.id] = CanvasPoint(x: 1100, y: 700)
        let rootID = try require(legacy.rootResourceID, "布局缺少根标识")
        let key = fixture.store.canvasKey(for: rootID)
        try fixture.store.save(legacy, canvasKey: key, makeBackup: false)

        let migrated = FolderCanvasModel(
            layoutStore: fixture.store,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: false,
            initialCanvasSize: external,
            monitorFolders: false
        )
        migrated.open(folder: fixture.folder)
        let migratedItem = try require(migrated.items.first, "迁移后项目缺失")
        let migratedPoint = try require(migrated.positions[migratedItem.id], "迁移后位置缺失")
        try check(migrated.desktopCanvasSize == external, "v4 小画布没有迁移到当前大屏")
        try check(migratedPoint != legacy.positions[item.id], "v4 坐标没有迁移")
        let migratedExport = fixture.base.appendingPathComponent("migrated.json")
        try migrated.exportLayout(to: migratedExport)
        let saved = try JSONDecoder().decode(SavedCanvas.self, from: Data(contentsOf: migratedExport))
        try check(saved.layoutVersion == SavedCanvas.currentLayoutVersion, "迁移后版本号不正确")
        try check(fixture.store.backupURLs(canvasKey: key).contains { url in
            (try? JSONDecoder().decode(SavedCanvas.self, from: Data(contentsOf: url)).layoutVersion) == 4
        }, "迁移前的 v4 布局没有备份")
    }

    private static func testExportImport() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(item, to: CGPoint(x: 650, y: 450))
        let exported = try require(fixture.model.positions[item.id], "没有导出位置")
        let exportURL = fixture.base.appendingPathComponent("layout-export.json")
        try fixture.model.exportLayout(to: exportURL)
        fixture.model.move(item, to: CGPoint(x: 200, y: 200))
        try fixture.model.importLayout(from: exportURL)
        try check(fixture.model.positions[item.id] == exported, "导入没有恢复导出位置")
    }

    private static func testRootFolderMoveRecovery() throws {
        let fixture = try makeFixture(itemCount: 1)
        let originalItem = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(originalItem, to: CGPoint(x: 600, y: 420))
        let expected = try require(fixture.model.positions[originalItem.id], "没有保存原位置")
        let movedFolder = fixture.base.appendingPathComponent("Moved Root", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.folder, to: movedFolder)
        let reopened = FolderCanvasModel(
            layoutStore: fixture.store,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: true,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false
        )
        defer { fixture.cleanup() }
        try check(reopened.folderURL?.standardizedFileURL == movedFolder.standardizedFileURL, "移动后没有恢复新路径")
        try check(reopened.items.count == 1, "移动后没有读取原文件")
        let reopenedItem = try require(reopened.items.first, "移动后项目缺失")
        try check(reopened.positions[reopenedItem.id] == expected, "根文件夹移动后布局位置丢失")
    }

    private static func testManualRelinkKeepsLayoutByName() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let originalItem = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(originalItem, to: CGPoint(x: 600, y: 420))
        let expected = try require(fixture.model.positions[originalItem.id], "没有保存原位置")
        let replacement = fixture.base.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.folder, to: replacement)

        fixture.model.relink(to: replacement, preservingCurrentLayout: true)

        let replacementItem = try require(fixture.model.items.first, "重新关联后项目缺失")
        try check(fixture.model.folderURL == replacement.standardizedFileURL, "没有切换到重新关联文件夹")
        try check(
            fixture.model.positions[replacementItem.id] == expected,
            "重新关联后没有按文件名保留位置；期望 \(expected)，实际 \(String(describing: fixture.model.positions[replacementItem.id]))"
        )
    }

    private static func assertItemsInsideBounds(_ model: FolderCanvasModel) throws {
        for item in model.displayedItems {
            let point = try require(model.positions[item.id], "\(item.name) 缺少位置")
            let scale = model.scale(for: item)
            try check(point.x - 52 * scale >= 0, "\(item.name) 超出左边界")
            try check(point.y - 48 * scale >= 0, "\(item.name) 超出上边界")
            try check(point.x + 52 * scale <= model.desktopCanvasSize.width, "\(item.name) 超出右边界")
            try check(point.y + 48 * scale <= model.desktopCanvasSize.height, "\(item.name) 超出下边界")
        }
    }

    private static func makeFixture(
        itemCount: Int,
        canvasSize: CGSize = CGSize(width: 1024, height: 768)
    ) throws -> ModelFixture {
        let base = temporaryDirectory(prefix: "Model")
        let folder = base.appendingPathComponent("Root", isDirectory: true)
        let layouts = base.appendingPathComponent("Layouts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<itemCount {
            let name = String(format: "item-%03d.txt", index)
            try Data("test-\(index)".utf8).write(to: folder.appendingPathComponent(name))
        }
        let suite = "SpatialFolderSelfTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "无法创建测试偏好设置")
        defaults.removePersistentDomain(forName: suite)
        let store = CanvasLayoutStore(layoutsDirectory: layouts, maximumBackups: 12)
        let model = FolderCanvasModel(
            layoutStore: store,
            userDefaults: defaults,
            autoOpenLastFolder: false,
            initialCanvasSize: canvasSize,
            monitorFolders: false
        )
        model.open(folder: folder)
        return ModelFixture(
            base: base,
            folder: folder,
            store: store,
            defaults: defaults,
            defaultsSuite: suite,
            model: model
        )
    }

    private static func temporaryDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpatialFolder\(prefix)Tests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private struct ModelFixture {
    let base: URL
    let folder: URL
    let store: CanvasLayoutStore
    let defaults: UserDefaults
    let defaultsSuite: String
    let model: FolderCanvasModel

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
}
