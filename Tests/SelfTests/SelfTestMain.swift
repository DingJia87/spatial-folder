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
        run("操作记录持久化与数量限制") { try testOperationHistoryPersistence() }
        run("重命名事务撤销与重做") { try testRelocateUndoRedo() }
        run("新建事务撤销后保留内容") { try testMaterializeUndoRedo() }
        run("废纸篓事务撤销与重做") { try testDiscardUndoRedo() }
        run("Finder 标签事务撤销与重做") { try testTagUndoRedo() }
        run("恢复冲突保留两者") { try testConflictKeepBoth() }
        run("恢复冲突替换后可逆") { try testConflictReplaceRoundTrip() }
        run("多项撤销预检防止部分执行") { try testMultiActionPreflightPreventsPartialUndo() }
        run("损坏操作记录阻止静默覆盖") { try testCorruptOperationHistoryBlocks() }
        run("App 新建文件夹统一撤销重做") { try testModelCreateFolderUndoRedo() }
        run("App 重命名恢复路径与画布位置") { try testModelRenameUndoRedo() }
        run("App 制作副本统一撤销重做") { try testModelDuplicateUndoRedo() }
        run("App 移至废纸篓恢复真实文件与位置") { try testModelTrashUndoRestoresLayout() }
        run("导入替换操作可完整撤销重做") { try testImportReplaceUndoRedo() }
        run("文件撤销跨重启保留") { try testFileUndoSurvivesRestart() }
        run("根文件夹移动后文件撤销路径自动迁移") { try testFileUndoAfterRootFolderMove() }
        run("布局与文件按时序统一撤销") { try testUnifiedUndoOrdering() }
        run("超出布局撤销深度后历史状态如实标记") { try testLayoutUndoDepthMarksViewOnly() }
        run("重命名冲突必须明确选择") { try testRenameConflictRequiresChoice() }
        run("诊断导出不含文件名和路径") { try testDiagnosticsPrivacy() }
        run("未完成操作在重启后标记核对") { try testPendingOperationMarkedUnavailableOnRestart() }
        run("损坏操作记录阻止 App 真实文件修改") { try testCorruptHistoryBlocksModelMutations() }
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

    private static func testOperationHistoryPersistence() throws {
        let directory = temporaryDirectory(prefix: "Operations")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationHistoryStore(directory: directory, maximumRecords: 20)
        let key = "canvas"
        var document = OperationHistoryDocument()
        for index in 0..<24 {
            document.records.append(OperationRecord(
                category: .file,
                kind: .createDocument,
                summary: "记录 \(index)",
                state: .applied,
                actions: [.materialize(MaterializeAction(destinationPath: "/tmp/\(index)"))]
            ))
        }
        try store.save(document, canvasKey: key)
        let loaded = try store.load(canvasKey: key)
        try check(loaded.records.count == 20, "操作记录没有限制为 20 条")
        try check(loaded.records.first?.summary == "记录 4", "操作记录没有保留最新项目")
        try check(loaded.records.last?.state == .applied, "操作状态没有持久化")
    }

    private static func testRelocateUndoRedo() throws {
        let base = temporaryDirectory(prefix: "Relocate")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let original = base.appendingPathComponent("original.txt")
        let destination = base.appendingPathComponent("renamed.txt")
        try Data("rename".utf8).write(to: original)
        try FileManager.default.moveItem(at: original, to: destination)
        let engine = FileOperationEngine(trashDirectoryForTesting: base.appendingPathComponent("Trash"))
        let record = OperationRecord(
            category: .file,
            kind: .rename,
            summary: "重命名",
            state: .applied,
            actions: [.relocate(RelocateAction(originalPath: original.path, destinationPath: destination.path))]
        )
        let undone = try engine.transition(record, to: .undone, conflictChoice: .cancel)
        try check(FileManager.default.fileExists(atPath: original.path), "撤销重命名没有恢复原路径")
        let redone = try engine.transition(undone, to: .applied, conflictChoice: .cancel)
        try check(FileManager.default.fileExists(atPath: destination.path), "重做重命名没有恢复目标路径")
        try check(redone.state == .applied, "重做后的状态不正确")
    }

    private static func testMaterializeUndoRedo() throws {
        let base = temporaryDirectory(prefix: "Materialize")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent("created.txt")
        try Data("edited-after-create".utf8).write(to: destination)
        let engine = FileOperationEngine(trashDirectoryForTesting: base.appendingPathComponent("Trash"))
        let record = OperationRecord(
            category: .file,
            kind: .createDocument,
            summary: "新建文档",
            state: .applied,
            actions: [.materialize(MaterializeAction(destinationPath: destination.path))]
        )
        let undone = try engine.transition(record, to: .undone, conflictChoice: .cancel)
        try check(!FileManager.default.fileExists(atPath: destination.path), "撤销新建后文件仍存在")
        _ = try engine.transition(undone, to: .applied, conflictChoice: .cancel)
        let restored = try String(contentsOf: destination, encoding: .utf8)
        try check(restored == "edited-after-create", "重做没有保留撤销前的文件内容")
    }

    private static func testDiscardUndoRedo() throws {
        let base = temporaryDirectory(prefix: "Discard")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let original = base.appendingPathComponent("deleted.txt")
        let trashURL = trash.appendingPathComponent("deleted.txt")
        try Data("deleted".utf8).write(to: original)
        try FileManager.default.moveItem(at: original, to: trashURL)
        let engine = FileOperationEngine(trashDirectoryForTesting: trash)
        let record = OperationRecord(
            category: .file,
            kind: .trash,
            summary: "移至废纸篓",
            state: .applied,
            actions: [.discard(DiscardAction(originalPath: original.path, trashPath: trashURL.path))]
        )
        let undone = try engine.transition(record, to: .undone, conflictChoice: .cancel)
        try check(FileManager.default.fileExists(atPath: original.path), "撤销删除没有恢复文件")
        let redone = try engine.transition(undone, to: .applied, conflictChoice: .cancel)
        guard case let .discard(action) = redone.actions.first else {
            throw SelfTestFailure(description: "删除操作类型被改变")
        }
        try check(!FileManager.default.fileExists(atPath: original.path), "重做删除后原文件仍存在")
        try check(action.trashPath.map { FileManager.default.fileExists(atPath: $0) } == true, "重做删除没有记录新废纸篓位置")
    }

    private static func testTagUndoRedo() throws {
        let base = temporaryDirectory(prefix: "Tags")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("tagged.txt")
        try Data("tag".utf8).write(to: file)
        let after = ["红色\n6"]
        try (file as NSURL).setResourceValue(after, forKey: URLResourceKey.tagNamesKey)
        let initiallySetTags = try file.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        try check(initiallySetTags == ["红色"], "测试文件系统无法设置 Finder 标签：\(initiallySetTags)")
        let record = OperationRecord(
            category: .file,
            kind: .tags,
            summary: "修改标签",
            state: .applied,
            actions: [.tags(TagAction(path: file.path, before: [], after: after))]
        )
        let engine = FileOperationEngine(trashDirectoryForTesting: base.appendingPathComponent("Trash"))
        let undone = try engine.transition(record, to: .undone, conflictChoice: .cancel)
        let undoneTags = try URL(fileURLWithPath: file.path)
            .resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        try check(undoneTags.isEmpty, "撤销没有清除 Finder 标签：\(undoneTags)")
        _ = try engine.transition(undone, to: .applied, conflictChoice: .cancel)
        let redoneTags = try URL(fileURLWithPath: file.path)
            .resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        try check(redoneTags == ["红色"], "重做没有恢复 Finder 标签：\(redoneTags)")
    }

    private static func testConflictKeepBoth() throws {
        let base = temporaryDirectory(prefix: "KeepBoth")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let original = base.appendingPathComponent("report.txt")
        let trashURL = trash.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: trashURL)
        try Data("current".utf8).write(to: original)
        let engine = FileOperationEngine(trashDirectoryForTesting: trash)
        let record = OperationRecord(
            category: .file,
            kind: .trash,
            summary: "恢复报告",
            state: .applied,
            actions: [.discard(DiscardAction(originalPath: original.path, trashPath: trashURL.path))]
        )
        let undone = try engine.transition(record, to: .undone, conflictChoice: .keepBoth)
        guard case let .discard(action) = undone.actions.first else {
            throw SelfTestFailure(description: "恢复操作类型错误")
        }
        try check(action.originalPath != original.path, "保留两者没有生成新路径")
        try check(FileManager.default.fileExists(atPath: action.originalPath), "旧文件没有恢复到新路径")
        try check(FileManager.default.fileExists(atPath: original.path), "现有文件被覆盖")
    }

    private static func testConflictReplaceRoundTrip() throws {
        let base = temporaryDirectory(prefix: "Replace")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let original = base.appendingPathComponent("report.txt")
        let oldTrash = trash.appendingPathComponent("old-report.txt")
        try Data("old".utf8).write(to: oldTrash)
        try Data("current".utf8).write(to: original)
        let engine = FileOperationEngine(trashDirectoryForTesting: trash)
        let record = OperationRecord(
            category: .file,
            kind: .trash,
            summary: "恢复并替换",
            state: .applied,
            actions: [.discard(DiscardAction(originalPath: original.path, trashPath: oldTrash.path))]
        )
        let undone = try engine.transition(record, to: .undone, conflictChoice: .replace)
        let restoredOldContent = try String(contentsOf: original, encoding: .utf8)
        try check(restoredOldContent == "old", "替换后没有恢复旧文件")
        try check(undone.displacements.count == 1, "被替换文件没有登记可恢复位置")
        let redone = try engine.transition(undone, to: .applied, conflictChoice: .replace)
        let restoredCurrentContent = try String(contentsOf: original, encoding: .utf8)
        try check(restoredCurrentContent == "current", "重做后没有恢复被替换文件")
        try check(redone.displacements.isEmpty, "重做后冲突位移记录没有清理")
    }

    private static func testMultiActionPreflightPreventsPartialUndo() throws {
        let base = temporaryDirectory(prefix: "Preflight")
        defer { try? FileManager.default.removeItem(at: base) }
        let existing = base.appendingPathComponent("existing.txt")
        let missing = base.appendingPathComponent("missing.txt")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing)
        let record = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "多项复制",
            state: .applied,
            actions: [
                .materialize(MaterializeAction(destinationPath: missing.path)),
                .materialize(MaterializeAction(destinationPath: existing.path))
            ]
        )
        let engine = FileOperationEngine(trashDirectoryForTesting: base.appendingPathComponent("Trash"))
        do {
            _ = try engine.transition(record, to: .undone, conflictChoice: .cancel)
            throw SelfTestFailure(description: "错误接受了缺少源文件的多项撤销")
        } catch FileOperationTransitionError.missingSource {
            try check(FileManager.default.fileExists(atPath: existing.path), "预检前就移走了其他文件")
        }
    }

    private static func testCorruptOperationHistoryBlocks() throws {
        let directory = temporaryDirectory(prefix: "Operations")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationHistoryStore(directory: directory)
        let url = store.historyURL(canvasKey: "broken")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: url)
        do {
            _ = try store.load(canvasKey: "broken")
            throw SelfTestFailure(description: "损坏操作记录被静默接受")
        } catch OperationHistoryStoreError.corruptHistory {
            let preserved = try Data(contentsOf: url)
            try check(preserved == Data("broken".utf8), "损坏操作记录被覆盖")
            let archive = try store.archiveCorruptHistoryAndReset(canvasKey: "broken")
            let archivedData = try Data(contentsOf: archive)
            try check(archivedData == Data("broken".utf8), "存档没有保留损坏原文件")
            let reset = try store.load(canvasKey: "broken")
            try check(reset.records.isEmpty, "存档后没有创建新操作记录")
        }
    }

    private static func testModelCreateFolderUndoRedo() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        let created = fixture.folder.appendingPathComponent("新建文件夹")
        fixture.model.createFolder()
        try check(FileManager.default.fileExists(atPath: created.path), "App 没有创建真实文件夹")
        try check(fixture.model.operationRecords.last?.kind == .createFolder, "新建文件夹没有记录")
        fixture.model.undoLastAction()
        try check(!FileManager.default.fileExists(atPath: created.path), "Command+Z 没有撤销新建文件夹")
        fixture.model.redoLastAction()
        try check(FileManager.default.fileExists(atPath: created.path), "Shift+Command+Z 没有重做新建文件夹")
    }

    private static func testModelRenameUndoRedo() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        let expectedPosition = try require(fixture.model.positions[item.id], "没有原始位置")
        let renamed = item.url.deletingLastPathComponent().appendingPathComponent("renamed.txt")
        fixture.model.rename(item, to: renamed.lastPathComponent)
        try check(FileManager.default.fileExists(atPath: renamed.path), "App 重命名没有生效")
        try check(
            fixture.model.positions[renamed.path] == expectedPosition,
            "重命名后画布位置丢失：期望 \(expectedPosition)，实际 \(fixture.model.positions)"
        )
        fixture.model.undoLastAction()
        try check(FileManager.default.fileExists(atPath: item.url.path), "撤销重命名没有恢复原路径")
        try check(fixture.model.positions[item.id] == expectedPosition, "撤销重命名没有恢复位置")
        fixture.model.redoLastAction()
        try check(FileManager.default.fileExists(atPath: renamed.path), "重做重命名没有恢复新路径")
    }

    private static func testModelDuplicateUndoRedo() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        let duplicate = fixture.folder.appendingPathComponent("item-000 2.txt")
        fixture.model.duplicate(item)
        try check(FileManager.default.fileExists(atPath: duplicate.path), "制作副本没有创建真实文件")
        fixture.model.undoLastAction()
        try check(!FileManager.default.fileExists(atPath: duplicate.path), "撤销制作副本没有移除副本")
        fixture.model.redoLastAction()
        try check(FileManager.default.fileExists(atPath: duplicate.path), "重做制作副本没有恢复副本")
    }

    private static func testModelTrashUndoRestoresLayout() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        fixture.model.move(item, to: CGPoint(x: 650, y: 430))
        let expected = try require(fixture.model.positions[item.id], "没有移动后位置")
        fixture.model.trash(item)
        try check(!FileManager.default.fileExists(atPath: item.url.path), "真实文件没有移至废纸篓")
        fixture.model.undoLastAction()
        try check(FileManager.default.fileExists(atPath: item.url.path), "撤销没有恢复真实文件")
        try check(fixture.model.positions[item.id] == expected, "撤销删除没有恢复图标位置")
        fixture.model.redoLastAction()
        try check(!FileManager.default.fileExists(atPath: item.url.path), "重做没有再次移至废纸篓")
    }

    private static func testImportReplaceUndoRedo() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        let target = fixture.folder.appendingPathComponent("report.txt")
        let incomingFolder = fixture.base.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incomingFolder, withIntermediateDirectories: true)
        let source = incomingFolder.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: source)
        fixture.model.refreshItems()
        fixture.model.importFiles([source])
        try check(fixture.model.pendingConflict != nil, "导入冲突没有请求选择")
        fixture.model.resolvePendingConflict(.replace)
        let replaced = try String(contentsOf: target, encoding: .utf8)
        try check(replaced == "new", "替换没有写入新文件")
        fixture.model.undoLastAction()
        let restored = try String(contentsOf: target, encoding: .utf8)
        try check(restored == "old", "撤销替换没有恢复原文件")
        fixture.model.redoLastAction()
        let redone = try String(contentsOf: target, encoding: .utf8)
        try check(redone == "new", "重做替换没有恢复新文件")
    }

    private static func testFileUndoSurvivesRestart() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        let created = fixture.folder.appendingPathComponent("新建文件夹")
        fixture.model.createFolder()
        let reopened = FolderCanvasModel(
            layoutStore: fixture.store,
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: false,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false
        )
        reopened.open(folder: fixture.folder)
        try check(reopened.canUndo, "重启后文件操作不能撤销")
        reopened.undoLastAction()
        try check(!FileManager.default.fileExists(atPath: created.path), "重启后没有撤销新建操作")
    }

    private static func testFileUndoAfterRootFolderMove() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        fixture.model.createFolder()
        let movedFolder = fixture.base.appendingPathComponent("Moved Root", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.folder, to: movedFolder)
        let movedCreated = movedFolder.appendingPathComponent("新建文件夹")
        let reopened = FolderCanvasModel(
            layoutStore: fixture.store,
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: true,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false
        )
        try check(reopened.folderURL == movedFolder.standardizedFileURL, "根文件夹移动后没有自动恢复")
        reopened.undoLastAction()
        try check(!FileManager.default.fileExists(atPath: movedCreated.path), "根文件夹移动后文件撤销仍使用旧路径")
    }

    private static func testUnifiedUndoOrdering() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        let original = try require(fixture.model.positions[item.id], "没有初始位置")
        fixture.model.move(item, to: CGPoint(x: 700, y: 500))
        let moved = try require(fixture.model.positions[item.id], "没有移动位置")
        let created = fixture.folder.appendingPathComponent("新建文件夹")
        fixture.model.createFolder()

        fixture.model.undoLastAction()
        try check(!FileManager.default.fileExists(atPath: created.path), "统一撤销没有先撤销最新文件操作")
        try check(fixture.model.positions[item.id] == moved, "撤销文件操作时误改了布局")
        fixture.model.undoLastAction()
        try check(fixture.model.positions[item.id] == original, "第二次撤销没有回退布局")

        fixture.model.redoLastAction()
        try check(fixture.model.positions[item.id] == moved, "统一重做没有先恢复布局")
        fixture.model.redoLastAction()
        try check(FileManager.default.fileExists(atPath: created.path), "统一重做没有再恢复文件操作")
    }

    private static func testLayoutUndoDepthMarksViewOnly() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        let item = try require(fixture.model.items.first, "没有测试文件")
        for index in 0..<51 {
            fixture.model.setScale(index.isMultiple(of: 2) ? 1.0 : 1.25, for: item)
        }
        let layoutRecords = fixture.model.operationRecords.filter { $0.category == .layout }
        try check(layoutRecords.count == 51, "布局历史数量不正确")
        try check(layoutRecords.first?.state == .viewOnly, "超出撤销深度的布局仍标记为可撤销")
        try check(layoutRecords.filter { $0.state == .applied }.count == 50, "可撤销布局数量没有限制为 50")
    }

    private static func testRenameConflictRequiresChoice() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        let first = fixture.folder.appendingPathComponent("alpha")
        let existing = fixture.folder.appendingPathComponent("beta")
        try Data("alpha".utf8).write(to: first)
        try Data("beta".utf8).write(to: existing)
        fixture.model.refreshItems()
        let item = try require(fixture.model.items.first(where: { $0.name == "alpha" }), "没有 alpha")
        fixture.model.rename(item, to: "beta")
        try check(fixture.model.pendingConflict != nil, "重命名冲突没有请求用户选择")
        try check(FileManager.default.fileExists(atPath: first.path), "选择前就改动了源文件")
        try check(FileManager.default.fileExists(atPath: existing.path), "选择前就覆盖了现有文件")
        fixture.model.resolvePendingConflict(.keepBoth)
        try check(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("beta 2").path), "保留两者没有创建唯一名称")
        try check(FileManager.default.fileExists(atPath: existing.path), "保留两者覆盖了原文件")
    }

    private static func testDiagnosticsPrivacy() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        let secretName = "秘密客户-张三-项目.xlsx"
        try Data("secret".utf8).write(to: fixture.folder.appendingPathComponent(secretName))
        fixture.model.refreshItems()
        let item = try require(fixture.model.items.first, "诊断测试文件缺失")
        fixture.model.move(item, to: CGPoint(x: 600, y: 400))
        let data = try fixture.model.diagnosticsData()
        let text = try require(String(data: data, encoding: .utf8), "诊断 JSON 不是 UTF-8")
        try check(!text.contains(secretName), "诊断信息泄露了文件名")
        try check(!text.contains(fixture.folder.path), "诊断信息泄露了完整路径")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PrivacySafeDiagnostics.self, from: data)
        try check(decoded.visibleItemCount == 1, "诊断项目数量不正确")
    }

    private static func testPendingOperationMarkedUnavailableOnRestart() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        let exportURL = fixture.base.appendingPathComponent("layout.json")
        try fixture.model.exportLayout(to: exportURL)
        let canvas = try JSONDecoder().decode(SavedCanvas.self, from: Data(contentsOf: exportURL))
        let rootID = try require(canvas.rootResourceID, "布局没有根标识")
        let key = fixture.store.canvasKey(for: rootID)
        let pending = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "未完成导入",
            state: .pending,
            actions: [.materialize(MaterializeAction(destinationPath: fixture.folder.appendingPathComponent("pending.txt").path))]
        )
        try fixture.operationStore.save(OperationHistoryDocument(records: [pending]), canvasKey: key)
        let reopened = FolderCanvasModel(
            layoutStore: fixture.store,
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: false,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false
        )
        reopened.open(folder: fixture.folder)
        try check(reopened.operationRecords.first?.state == .unavailable, "未完成操作没有标记为需核对")
        let persisted = try fixture.operationStore.load(canvasKey: key)
        try check(persisted.records.first?.state == .unavailable, "需核对状态没有持久化")
    }

    private static func testCorruptHistoryBlocksModelMutations() throws {
        let fixture = try makeFixture(itemCount: 0)
        defer { fixture.cleanup() }
        let exportURL = fixture.base.appendingPathComponent("layout.json")
        try fixture.model.exportLayout(to: exportURL)
        let canvas = try JSONDecoder().decode(SavedCanvas.self, from: Data(contentsOf: exportURL))
        let rootID = try require(canvas.rootResourceID, "布局没有根标识")
        let key = fixture.store.canvasKey(for: rootID)
        let historyURL = fixture.operationStore.historyURL(canvasKey: key)
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: historyURL)
        let reopened = FolderCanvasModel(
            layoutStore: fixture.store,
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
            userDefaults: fixture.defaults,
            autoOpenLastFolder: false,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false
        )
        reopened.open(folder: fixture.folder)
        try check(reopened.operationHistoryIsBlocked, "App 没有识别损坏操作记录")
        reopened.createFolder()
        try check(
            !FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("新建文件夹").path),
            "操作记录损坏时仍修改了真实文件"
        )
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
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
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
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
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
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
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
            operationStore: fixture.operationStore,
            fileOperationEngine: fixture.fileOperationEngine,
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
        let operationStore = OperationHistoryStore(directory: base.appendingPathComponent("Operations", isDirectory: true))
        let fileOperationEngine = FileOperationEngine(
            trashDirectoryForTesting: base.appendingPathComponent("Trash", isDirectory: true)
        )
        let model = FolderCanvasModel(
            layoutStore: store,
            operationStore: operationStore,
            fileOperationEngine: fileOperationEngine,
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
            operationStore: operationStore,
            fileOperationEngine: fileOperationEngine,
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
    let operationStore: OperationHistoryStore
    let fileOperationEngine: FileOperationEngine
    let defaults: UserDefaults
    let defaultsSuite: String
    let model: FolderCanvasModel

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
}
