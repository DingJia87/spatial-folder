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

    static func main() async {
        run("备份数量限制与恢复") { try testBackupRetentionAndRestore() }
        run("损坏布局自动恢复") { try testCorruptRecovery() }
        run("无备份损坏布局阻断") { try testCorruptWithoutBackupBlocks() }
        run("旧版路径布局迁移") { try testLegacyMigration() }
        run("跨文件夹布局导入拒绝") { try testWrongFolderImport() }
        run("操作记录持久化与数量限制") { try testOperationHistoryPersistence() }
        run("2.4 操作记录迁移到增量日志") { try testOperationJournalLegacyMigration() }
        run("增量日志重放与自动压缩") { try testOperationJournalReplayAndCompaction() }
        run("断电日志半行可安全忽略并继续追加") { try testOperationJournalRepairsPartialTail() }
        await runAsync("1000 次增量日志追加保持线性性能") { try await testOperationJournalPerformance() }
        run("重命名事务撤销与重做") { try testRelocateUndoRedo() }
        run("新建事务撤销后保留内容") { try testMaterializeUndoRedo() }
        run("废纸篓事务撤销与重做") { try testDiscardUndoRedo() }
        run("Finder 标签事务撤销与重做") { try testTagUndoRedo() }
        run("Finder 标签扫描保留颜色编号") { try testTagScanPreservesColorNumber() }
        run("恢复冲突保留两者") { try testConflictKeepBoth() }
        run("恢复冲突替换后可逆") { try testConflictReplaceRoundTrip() }
        run("多项撤销预检防止部分执行") { try testMultiActionPreflightPreventsPartialUndo() }
        run("损坏操作记录阻止静默覆盖") { try testCorruptOperationHistoryBlocks() }
        run("画布跨进程锁独占与释放") { try testCanvasSessionLockExclusivity() }
        run("第二个画布模型进入只读模式") { try testSecondModelUsesReadOnlySession() }
        run("2.3.2 偏好迁移到稳定版本") { try testPreferencesMigration() }
        run("3000 项目录扫描保持可接受耗时") { try testLargeFolderScanPerformance() }
        await runAsync("后台批量复制逐步记录并可撤销") { try await testCoordinatedTransferRoundTrip() }
        await runAsync("后台批量失败自动回滚") { try await testCoordinatedTransferFailureRollsBack() }
        await runAsync("模型生产路径异步导入不阻塞并落账") { try await testModelAsynchronousImport() }
        await runAsync("短文件操作生产路径全部后台执行") { try await testBackgroundShortFileOperations() }
        await runAsync("异常恢复分析只依据磁盘证据") { try await testRecoveryAnalyzerEvidence() }
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
        run("待放置区批量放回") { try testBatchInboxPlacement() }
        run("顶部筛选不隐藏待放置区") { try testCanvasFiltersDoNotHideInbox() }
        run("外部拖入按落点排列且不移动已有项目") { try testDropLocationPlacement() }
        run("多选整体拖动保持相对位置") { try testGroupDragPreservesRelativeLayout() }
        run("多选批量副本和废纸篓") { try testBatchDuplicateAndTrash() }
        run("筛选不会让隐藏选择参与批量操作") { try testFiltersExcludeHiddenSelection() }
        run("搜索和标签筛选切换空间后清空") { try testFiltersResetWhenOpeningSpace() }
        run("外部重命名保持位置") { try testExternalRenameKeepsPosition() }
        run("撤销、重做和锁定") { try testUndoRedoAndLock() }
        run("锁定状态按文件夹持久保存") { try testLockPersistsPerFolder() }
        run("跨屏往返不改写布局") { try testScreenSwitchDoesNotMutateLayout() }
        run("小屏视口统一缩放") { try testViewportScaleIsUniform() }
        run("全屏额外高度由画布背景覆盖") { try testPresentationCoversTallerViewport() }
        run("小视口不会缩短逻辑画布") { try testPresentationNeverShrinksLogicalCanvas() }
        run("普通窗口按宽度保持画布比例") { try testWindowAspectTracksWidth() }
        run("普通窗口按高度保持画布比例") { try testWindowAspectTracksHeight() }
        run("窗口比例受当前显示器范围限制") { try testWindowAspectFitsCurrentDisplay() }
        run("最大化窗口使用完整可见区域") { try testMaximumWindowBypassesAspectConstraint() }
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

    private static func runAsync(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
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

    private static func testOperationJournalLegacyMigration() throws {
        let directory = temporaryDirectory(prefix: "JournalMigration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = OperationHistoryStore(directory: directory, maximumRecords: 20)
        let key = "canvas"
        let record = OperationRecord(
            category: .file,
            kind: .createFolder,
            summary: "2.4 记录",
            state: .applied,
            actions: [.materialize(MaterializeAction(destinationPath: "/tmp/legacy"))]
        )
        try legacy.save(OperationHistoryDocument(records: [record]), canvasKey: key)

        let journal = OperationJournalDiskStore(
            directory: directory,
            maximumRecords: 20,
            compactionEventThreshold: 50
        )
        let loaded = try journal.load(canvasKey: key)
        try check(loaded.records.count == 1, "迁移后记录数量发生变化")
        try check(loaded.records.first?.id == record.id, "迁移后记录标识发生变化")
        try check(loaded.records.first?.summary == record.summary, "迁移后记录摘要发生变化")
        try check(loaded.records.first?.actions == record.actions, "迁移后可恢复动作发生变化")
        try check(FileManager.default.fileExists(atPath: journal.snapshotURL(canvasKey: key).path), "迁移没有生成快照")
        try check(FileManager.default.fileExists(atPath: journal.archivedLegacyURL(canvasKey: key).path), "2.4 原记录没有归档保留")
        try check(!FileManager.default.fileExists(atPath: journal.legacyURL(canvasKey: key).path), "迁移后仍重复读取旧记录")
    }

    private static func testOperationJournalReplayAndCompaction() throws {
        let directory = temporaryDirectory(prefix: "JournalReplay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OperationJournalDiskStore(
            directory: directory,
            maximumRecords: 20,
            compactionEventThreshold: 3,
            compactionByteThreshold: 1_000_000
        )
        let key = "canvas"
        var record = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "批量复制",
            state: .pending
        )
        let first = try journal.append(.upsert([record]), canvasKey: key)
        try check(first.appendedEventCount == 1 && !first.didCompact, "第一条事件错误触发压缩")
        record.actions.append(.materialize(MaterializeAction(destinationPath: "/tmp/a")))
        _ = try journal.append(.upsert([record]), canvasKey: key)
        record.state = .applied
        let compacted = try journal.append(.upsert([record]), canvasKey: key)
        try check(compacted.didCompact, "达到阈值后没有压缩日志")

        let loaded = try journal.load(canvasKey: key)
        try check(loaded.records.count == 1, "upsert 重放产生了重复记录")
        try check(loaded.records.first?.id == record.id, "重放没有保持记录标识")
        try check(loaded.records.first?.state == .applied, "重放没有恢复最终状态")
        try check(loaded.records.first?.actions == record.actions, "重放没有恢复逐步动作")
        let journalBytes = (try? Data(contentsOf: journal.journalURL(canvasKey: key)).count) ?? -1
        try check(journalBytes == 0, "生成快照后没有截断增量日志")
    }

    private static func testOperationJournalPerformance() async throws {
        let directory = temporaryDirectory(prefix: "JournalPerformance")
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskStore = OperationJournalDiskStore(
            directory: directory,
            maximumRecords: 200,
            compactionEventThreshold: 500,
            compactionByteThreshold: 10_000_000
        )
        let journal = OperationJournalStore(diskStore: diskStore)
        let key = "canvas"
        var record = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "性能基线",
            state: .pending
        )
        let started = ContinuousClock.now
        for index in 0..<1_000 {
            record.detail = "步骤 \(index)"
            _ = try await journal.upsert(record, canvasKey: key)
        }
        let elapsed = started.duration(to: .now)
        let loaded = try await journal.load(canvasKey: key)
        try check(loaded.records.count == 1, "1000 次 upsert 重放后产生重复记录")
        try check(loaded.records.first?.detail == "步骤 999", "1000 次追加没有恢复最终事件")
        try check(elapsed < .seconds(10), "1000 次增量日志追加超过 10 秒预算：\(elapsed)")
    }

    private static func testOperationJournalRepairsPartialTail() throws {
        let directory = temporaryDirectory(prefix: "JournalPartialTail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OperationJournalDiskStore(directory: directory, compactionEventThreshold: 100)
        let key = "partial-tail"
        let first = OperationRecord(
            category: .file,
            kind: .createDocument,
            summary: "已提交事件",
            state: .pending
        )
        _ = try journal.append(.upsert([first]), canvasKey: key)
        let journalURL = journal.journalURL(canvasKey: key)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"version\":1,\"mutation\":".utf8))
        try handle.close()

        let loadedBeforeRepair = try journal.load(canvasKey: key)
        try check(loadedBeforeRepair.records.first?.id == first.id, "未完整尾行破坏了已提交记录")

        var completed = first
        completed.state = .applied
        _ = try journal.append(.upsert([completed]), canvasKey: key)
        let loadedAfterRepair = try journal.load(canvasKey: key)
        try check(loadedAfterRepair.records.first?.state == .applied, "修剪半行后无法继续追加")

        let corruptKey = "complete-corrupt-line"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json\n".utf8).write(to: journal.journalURL(canvasKey: corruptKey))
        do {
            _ = try journal.load(canvasKey: corruptKey)
            throw SelfTestFailure(description: "已换行的损坏事件被错误忽略")
        } catch is OperationHistoryStoreError {
            // 完整行损坏必须严格阻断，只允许忽略最后未换行半行。
        }
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

    private static func testTagScanPreservesColorNumber() throws {
        let base = temporaryDirectory(prefix: "TagScan")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("tagged.txt")
        try Data("tag".utf8).write(to: file)
        try writeFinderTags(["自定义红色名称\n6"], to: file)

        let entries = try FolderDirectoryScanner().scan(folder: base)
        let entry = try require(entries.first, "扫描没有返回标签测试文件")
        try check(entry.tags.first?.contains("\n6") == true, "扫描丢失 Finder 标签颜色编号：\(entry.tags)")
        try check(FinderTagColor(finderTag: entry.tags[0]) == .red, "自定义标签没有按编号识别为红色")
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

    private static func testCanvasSessionLockExclusivity() throws {
        let directory = temporaryDirectory(prefix: "SessionLock")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstResult = try CanvasSessionLock.acquire(
            canvasKey: "canvas-a",
            directory: directory,
            processID: 111,
            appVersion: "2.4-test"
        )
        guard case let .acquired(firstLock) = firstResult else {
            throw SelfTestFailure(description: "第一次没有取得画布锁")
        }

        let secondResult = try CanvasSessionLock.acquire(
            canvasKey: "canvas-a",
            directory: directory,
            processID: 222,
            appVersion: "2.4-test"
        )
        guard case let .occupied(owner) = secondResult else {
            throw SelfTestFailure(description: "第二个会话错误取得了同一张画布的写入锁")
        }
        try check(owner?.processID == 111, "锁占用者信息没有正确保存")

        firstLock.release()
        let thirdResult = try CanvasSessionLock.acquire(
            canvasKey: "canvas-a",
            directory: directory,
            processID: 333,
            appVersion: "2.4-test"
        )
        guard case .acquired = thirdResult else {
            throw SelfTestFailure(description: "原会话释放后仍无法取得画布锁")
        }
    }

    private static func testSecondModelUsesReadOnlySession() throws {
        let base = temporaryDirectory(prefix: "ModelSessionLock")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Root", isDirectory: true)
        let locks = base.appendingPathComponent("Locks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let layoutStore = CanvasLayoutStore(layoutsDirectory: base.appendingPathComponent("Layouts"))
        let operationStore = OperationHistoryStore(directory: base.appendingPathComponent("Operations"))
        let fileEngine = FileOperationEngine(trashDirectoryForTesting: base.appendingPathComponent("Trash"))
        let writerDefaults = try require(UserDefaults(suiteName: "SessionWriter.\(UUID().uuidString)"), "无法创建写会话偏好")
        let readerDefaults = try require(UserDefaults(suiteName: "SessionReader.\(UUID().uuidString)"), "无法创建读会话偏好")

        var writer: FolderCanvasModel? = FolderCanvasModel(
            layoutStore: layoutStore,
            operationStore: operationStore,
            fileOperationEngine: fileEngine,
            userDefaults: writerDefaults,
            autoOpenLastFolder: false,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false,
            sessionLockDirectory: locks
        )
        writer?.open(folder: folder)
        try check(writer?.sessionIsReadOnly == false, "第一个模型错误进入只读模式")

        let reader = FolderCanvasModel(
            layoutStore: layoutStore,
            operationStore: operationStore,
            fileOperationEngine: fileEngine,
            userDefaults: readerDefaults,
            autoOpenLastFolder: false,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false,
            sessionLockDirectory: locks
        )
        reader.open(folder: folder)
        try check(reader.sessionIsReadOnly, "第二个模型没有进入只读模式")
        reader.createFolder()
        try check(
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("新建文件夹").path),
            "只读会话仍然修改了真实文件"
        )

        writer = nil
        let successor = FolderCanvasModel(
            layoutStore: layoutStore,
            operationStore: operationStore,
            fileOperationEngine: fileEngine,
            userDefaults: writerDefaults,
            autoOpenLastFolder: false,
            initialCanvasSize: CGSize(width: 1024, height: 768),
            monitorFolders: false,
            sessionLockDirectory: locks
        )
        successor.open(folder: folder)
        try check(!successor.sessionIsReadOnly, "写会话结束后新模型仍被错误阻止")
    }

    private static func testPreferencesMigration() throws {
        let destinationName = "PreferencesDestination.\(UUID().uuidString)"
        let newestName = "Preferences232.\(UUID().uuidString)"
        let olderName = "Preferences231.\(UUID().uuidString)"
        let destination = try require(UserDefaults(suiteName: destinationName), "无法创建目标偏好")
        let newest = try require(UserDefaults(suiteName: newestName), "无法创建新版偏好")
        let older = try require(UserDefaults(suiteName: olderName), "无法创建旧版偏好")
        defer {
            destination.removePersistentDomain(forName: destinationName)
            newest.removePersistentDomain(forName: newestName)
            older.removePersistentDomain(forName: olderName)
        }
        destination.removePersistentDomain(forName: destinationName)
        newest.removePersistentDomain(forName: newestName)
        older.removePersistentDomain(forName: olderName)

        destination.set("dark", forKey: "appearanceMode")
        newest.set("/tmp/latest", forKey: "lastOpenedFolderPath")
        newest.set(["/tmp/latest"], forKey: "recentFolderPaths")
        older.set("/tmp/older", forKey: "lastOpenedFolderPath")

        let report = PreferencesMigrator.migrateIfNeeded(
            destination: destination,
            sources: [(newestName, newest), (olderName, older)]
        )
        try check(destination.string(forKey: "appearanceMode") == "dark", "迁移覆盖了 2.4 已有设置")
        try check(destination.string(forKey: "lastOpenedFolderPath") == "/tmp/latest", "没有优先采用 2.3.2 设置")
        try check(destination.stringArray(forKey: "recentFolderPaths") == ["/tmp/latest"], "最近空间没有迁移")
        try check(report.sourceDomains == [newestName], "迁移来源记录不正确")
        try check(
            destination.integer(forKey: PreferencesMigrator.migrationVersionKey) == PreferencesMigrator.currentMigrationVersion,
            "迁移版本没有写入"
        )

        newest.set("/tmp/changed", forKey: "lastOpenedFolderPath")
        _ = PreferencesMigrator.migrateIfNeeded(
            destination: destination,
            sources: [(newestName, newest)]
        )
        try check(destination.string(forKey: "lastOpenedFolderPath") == "/tmp/latest", "重复迁移改变了已完成结果")
    }

    private static func testLargeFolderScanPerformance() throws {
        let base = temporaryDirectory(prefix: "LargeScan")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let payload = Data("scan".utf8)
        for index in 0..<3_000 {
            try payload.write(to: base.appendingPathComponent(String(format: "item-%05d.txt", index)))
        }
        let hidden = base.appendingPathComponent(".hidden.txt")
        try payload.write(to: hidden)

        let start = ContinuousClock.now
        let entries = try FolderDirectoryScanner().scan(folder: base)
        let elapsed = start.duration(to: .now)
        try check(entries.count == 3_000, "目录扫描数量不正确或错误包含隐藏文件")
        try check(entries.first?.url.lastPathComponent == "item-00000.txt", "扫描结果没有稳定排序")
        try check(elapsed < .seconds(10), "3000 项目录扫描耗时过长：\(elapsed)")
    }

    private static func testCoordinatedTransferRoundTrip() async throws {
        let base = temporaryDirectory(prefix: "CoordinatedTransfer")
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceFolder = base.appendingPathComponent("Source", isDirectory: true)
        let destinationFolder = base.appendingPathComponent("Destination", isDirectory: true)
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("report.txt")
        let destination = destinationFolder.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)

        let engine = FileOperationEngine(trashDirectoryForTesting: trash)
        let coordinator = FileOperationCoordinator(fileOperationEngine: engine)
        let collector = OperationEventCollector()
        let actions = try await coordinator.performTransfers([
            FileTransferPlan(
                source: source,
                destination: destination,
                move: false,
                replacesExistingDestination: true
            )
        ]) { event in
            await collector.append(event)
        }
        try check(actions.count == 2, "替换复制没有记录保护旧文件和创建新文件两个步骤")
        let copiedContent = try String(contentsOf: destination, encoding: .utf8)
        let appliedActionCount = await collector.appliedActionCount()
        try check(copiedContent == "new", "后台复制结果不正确")
        try check(appliedActionCount == 2, "协调器没有逐步上报完成动作")

        let record = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "测试后台复制",
            state: .applied,
            actions: actions
        )
        _ = try engine.transition(record, to: .undone, conflictChoice: .cancel)
        let restoredContent = try String(contentsOf: destination, encoding: .utf8)
        try check(restoredContent == "old", "撤销后没有恢复被替换的旧文件")
    }

    private static func testCoordinatedTransferFailureRollsBack() async throws {
        let base = temporaryDirectory(prefix: "CoordinatedRollback")
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceFolder = base.appendingPathComponent("Source", isDirectory: true)
        let destinationFolder = base.appendingPathComponent("Destination", isDirectory: true)
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let firstSource = sourceFolder.appendingPathComponent("first.txt")
        let missingSource = sourceFolder.appendingPathComponent("missing.txt")
        let firstDestination = destinationFolder.appendingPathComponent("first.txt")
        let missingDestination = destinationFolder.appendingPathComponent("missing.txt")
        try Data("first".utf8).write(to: firstSource)

        let coordinator = FileOperationCoordinator(fileOperationEngine: FileOperationEngine(
            trashDirectoryForTesting: trash
        ))
        do {
            _ = try await coordinator.performTransfers([
                FileTransferPlan(
                    source: firstSource,
                    destination: firstDestination,
                    move: false,
                    replacesExistingDestination: false
                ),
                FileTransferPlan(
                    source: missingSource,
                    destination: missingDestination,
                    move: false,
                    replacesExistingDestination: false
                )
            ]) { _ in }
            throw SelfTestFailure(description: "缺少源文件的批量操作被错误视为成功")
        } catch let failure as CoordinatedFileOperationFailure {
            try check(failure.rollbackSucceeded, "批量失败后没有完成自动回滚")
            try check(!FileManager.default.fileExists(atPath: firstDestination.path), "批量失败后留下已复制项目")
            try check(FileManager.default.fileExists(atPath: firstSource.path), "回滚错误修改了复制来源")
        }
    }

    /// 覆盖 App 真正使用的异步入口，而不只测试底层协调器。
    private static func testModelAsynchronousImport() async throws {
        let fixture = try makeFixture(itemCount: 1, fileOperationsAsynchronously: true)
        defer { fixture.cleanup() }
        let sourceFolder = fixture.base.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let sources = (0..<3).map { sourceFolder.appendingPathComponent("incoming-\($0).txt") }
        for source in sources { try Data(source.lastPathComponent.utf8).write(to: source) }

        try await waitForOperationHistory(in: fixture.model)
        fixture.model.importFiles(sources)
        try check(fixture.model.fileOperationProgress != nil, "异步导入没有立即显示进度")

        let deadline = Date().addingTimeInterval(5)
        while fixture.model.fileOperationProgress != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(fixture.model.fileOperationProgress == nil, "异步导入在期限内没有完成")
        try check(sources.allSatisfy {
            FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent($0.lastPathComponent).path)
        }, "异步导入缺少目标文件")
        let latest = try require(fixture.model.operationRecords.first, "异步导入没有操作记录")
        try check(latest.state == .applied, "异步导入记录没有落为已完成")
        try check(latest.actions.count == sources.count, "异步导入没有逐文件落账")
    }

    private static func testBackgroundShortFileOperations() async throws {
        let fixture = try makeFixture(itemCount: 1, fileOperationsAsynchronously: true)
        defer { fixture.cleanup() }

        try await waitForOperationHistory(in: fixture.model)
        fixture.model.createFolder()
        try await waitForFileOperation(in: fixture.model)
        try check(
            FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("新建文件夹").path),
            "后台新建文件夹没有创建真实目录"
        )

        let item = try require(fixture.model.items.first(where: { $0.name.hasSuffix(".txt") }), "后台操作测试文件缺失")
        fixture.model.toggleTag("红色\n6", for: item)
        try await waitForFileOperation(in: fixture.model)
        let tags = try item.url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        try check(tags.contains("红色"), "后台标签操作没有写入 Finder 标签：\(tags)")

        fixture.model.rename(item, to: "renamed.txt")
        try await waitForFileOperation(in: fixture.model)
        try check(
            FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("renamed.txt").path),
            "后台重命名没有生成目标文件"
        )

        try check(
            fixture.model.operationRecords.suffix(3).allSatisfy { $0.state == .applied },
            "短文件操作没有全部落为已完成"
        )
    }

    private static func testRecoveryAnalyzerEvidence() async throws {
        let base = temporaryDirectory(prefix: "RecoveryAnalyzer")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let created = base.appendingPathComponent("created.txt")
        try Data("created".utf8).write(to: created)
        let applied = OperationRecord(
            category: .file,
            kind: .createDocument,
            summary: "新建文件",
            state: .unavailable,
            actions: [.materialize(MaterializeAction(destinationPath: created.path))]
        )
        let original = base.appendingPathComponent("original.txt")
        let destination = base.appendingPathComponent("destination.txt")
        try Data().write(to: original)
        try Data().write(to: destination)
        let ambiguous = OperationRecord(
            category: .file,
            kind: .rename,
            summary: "重命名",
            state: .unavailable,
            actions: [.relocate(RelocateAction(
                originalPath: original.path,
                destinationPath: destination.path
            ))]
        )
        let empty = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "尚未开始",
            state: .pending
        )
        let partialTarget = base.appendingPathComponent("partial.txt")
        try Data().write(to: partialTarget)
        let partial = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "批量复制到一半",
            itemNames: ["partial.txt", "not-yet-copied.txt"],
            state: .pending,
            actions: [.materialize(MaterializeAction(destinationPath: partialTarget.path))]
        )
        let disappeared = OperationRecord(
            category: .file,
            kind: .createDocument,
            summary: "目标不明原因消失",
            state: .undoing,
            actions: [.materialize(MaterializeAction(destinationPath: base.appendingPathComponent("missing.txt").path))]
        )
        let cases = await RecoveryAnalyzer().analyze(records: [applied, ambiguous, empty, partial, disappeared])
        try check(cases.first(where: { $0.recordID == applied.id })?.suggestedOutcome == .applied, "存在的创建目标没有识别为已完成")
        try check(cases.first(where: { $0.recordID == ambiguous.id })?.suggestedOutcome == .manualReview, "原路径和目标同时存在时错误自动判断")
        try check(cases.first(where: { $0.recordID == empty.id })?.suggestedOutcome == .manualReview, "无已提交步骤的 pending 记录被不安全地建议自动存档")
        try check(cases.first(where: { $0.recordID == partial.id })?.suggestedOutcome == .manualReview, "部分批量步骤被误判为整批完成")
        try check(cases.first(where: { $0.recordID == disappeared.id })?.suggestedOutcome == .manualReview, "缺少废纸篓证据时误判为已回滚")
    }

    private static func waitForFileOperation(
        in model: FolderCanvasModel,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // 准备任务和执行任务之间会短暂切换 Task，但进度状态始终连续存在。
        while model.fileOperationProgress != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(model.fileOperationProgress == nil, "后台文件操作在期限内没有完成")
    }

    private static func waitForOperationHistory(
        in model: FolderCanvasModel,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLoadingOperationHistory, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(!model.isLoadingOperationHistory, "操作记录在期限内没有后台加载完成")
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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

    private static func testBatchInboxPlacement() throws {
        let fixture = try makeFixture(itemCount: 6)
        defer { fixture.cleanup() }
        let targets = Array(fixture.model.items.prefix(3))
        fixture.model.moveToInbox(targets)
        try check(targets.allSatisfy { fixture.model.inboxIDs.contains($0.id) }, "批量移入待放置区不完整")
        fixture.model.placeFromInbox(targets)
        try check(targets.allSatisfy { !fixture.model.inboxIDs.contains($0.id) }, "批量放回主画布不完整")
        try check(targets.allSatisfy { fixture.model.positions[$0.id] != nil }, "批量放回没有生成位置")
    }

    private static func testDropLocationPlacement() throws {
        let engine = CanvasLayoutEngine()
        let size = CGSize(width: 1_200, height: 800)
        let existing = [
            CanvasLayoutItem(id: "existing-a", scale: 1.25),
            CanvasLayoutItem(id: "existing-b", scale: 1.25)
        ]
        let before = [
            "existing-a": CanvasPoint(x: 120, y: 120),
            "existing-b": CanvasPoint(x: 360, y: 120)
        ]
        let imported = [
            CanvasLayoutItem(id: "new-a", scale: 1.25),
            CanvasLayoutItem(id: "new-b", scale: 1.25)
        ]
        let dropPoint = CGPoint(x: 900, y: 600)
        let result = engine.placeImportedItems(
            imported,
            near: dropPoint,
            existingItems: existing,
            positions: before,
            inboxIDs: [],
            canvasSize: size
        )
        try check(result.positions["existing-a"] == before["existing-a"], "拖入时移动了第一个已有项目")
        try check(result.positions["existing-b"] == before["existing-b"], "拖入时移动了第二个已有项目")
        let first = try require(result.positions["new-a"], "第一个拖入项目没有落位")
        let second = try require(result.positions["new-b"], "第二个拖入项目没有落位")
        try check(first != second, "多个拖入项目重叠")
        try check(abs(first.x - dropPoint.x) < 250 && abs(first.y - dropPoint.y) < 250, "首个项目没有放在落点附近")
    }

    private static func testGroupDragPreservesRelativeLayout() throws {
        let fixture = try makeFixture(itemCount: 2, canvasSize: CGSize(width: 1200, height: 800))
        defer { fixture.cleanup() }
        let first = fixture.model.items[0]
        let second = fixture.model.items[1]
        fixture.model.move(first, to: CGPoint(x: 240, y: 240))
        fixture.model.move(second, to: CGPoint(x: 480, y: 360))
        let firstBefore = try require(fixture.model.positions[first.id], "第一个项目没有位置")
        let secondBefore = try require(fixture.model.positions[second.id], "第二个项目没有位置")
        fixture.model.select(first, extendingSelection: false)
        fixture.model.select(second, extendingSelection: true)
        fixture.model.beginDragging(first)
        fixture.model.updateDrag(translation: CGSize(width: 2_000, height: 2_000))
        fixture.model.finishDrag()
        let firstAfter = try require(fixture.model.positions[first.id], "拖动后第一个项目没有位置")
        let secondAfter = try require(fixture.model.positions[second.id], "拖动后第二个项目没有位置")
        try check(
            secondAfter.x - firstAfter.x == secondBefore.x - firstBefore.x
                && secondAfter.y - firstAfter.y == secondBefore.y - firstBefore.y,
            "整体拖动改变了组内相对位置"
        )
        try assertItemsInsideBounds(fixture.model)
    }

    private static func testBatchDuplicateAndTrash() throws {
        let fixture = try makeFixture(itemCount: 3)
        defer { fixture.cleanup() }
        let targets = Array(fixture.model.items.prefix(2))
        fixture.model.duplicate(targets)
        try check(fixture.model.items.count == 5, "批量制作副本没有生成两个项目")
        fixture.model.trash(targets)
        try check(targets.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) }, "批量废纸篓仍保留原文件")
        try check(fixture.model.operationRecords.last?.kind == .trash, "批量废纸篓没有生成统一记录")
        try check(fixture.model.operationRecords.last?.actions.count == 2, "批量废纸篓没有逐项记录")
    }

    private static func testFiltersExcludeHiddenSelection() throws {
        let fixture = try makeFixture(itemCount: 3)
        defer { fixture.cleanup() }
        let firstURL = fixture.folder.appendingPathComponent("item-000.txt")
        let secondURL = fixture.folder.appendingPathComponent("item-001.txt")
        try writeFinderTags(["自定义红色\n6"], to: firstURL)
        try writeFinderTags(["自定义绿色\n2"], to: secondURL)
        fixture.model.refreshItems()

        let first = try require(
            fixture.model.items.first { $0.name == "item-000.txt" },
            "缺少红色测试项目，当前：\(fixture.model.items.map(\.name))"
        )
        let second = try require(
            fixture.model.items.first { $0.name == "item-001.txt" },
            "缺少绿色测试项目，当前：\(fixture.model.items.map(\.name))"
        )
        let third = try require(fixture.model.items.first { $0.id != first.id && $0.id != second.id }, "缺少无标签测试项目")
        let positionsBefore = fixture.model.positions

        fixture.model.select(first, extendingSelection: false)
        fixture.model.select(second, extendingSelection: true)
        fixture.model.select(third, extendingSelection: true)
        fixture.model.toggleTagFilter(.red)
        try check(fixture.model.displayedItems.map(\.id) == [first.id], "红色筛选结果不正确")
        try check(fixture.model.selectedIDs == [first.id], "标签筛选后仍保留隐藏项目选择")
        try check(fixture.model.contextItems(for: first).map(\.id) == [first.id], "批量菜单仍包含隐藏选择")

        fixture.model.toggleTagFilter(.green)
        try check(Set(fixture.model.displayedItems.map(\.id)) == [first.id, second.id], "多颜色筛选没有使用 OR")
        fixture.model.searchText = second.name
        try check(fixture.model.displayedItems.map(\.id) == [second.id], "搜索与标签筛选没有使用 AND")

        fixture.model.clearFilters()
        fixture.model.toggleUntaggedFilter()
        try check(fixture.model.displayedItems.map(\.id) == [third.id], "无标签筛选结果不正确")
        try check(fixture.model.positions == positionsBefore, "切换筛选改变了画布位置")
    }

    private static func testFiltersResetWhenOpeningSpace() throws {
        let fixture = try makeFixture(itemCount: 1)
        defer { fixture.cleanup() }
        fixture.model.searchText = "不会匹配"
        fixture.model.toggleTagFilter(.red)
        fixture.model.toggleUntaggedFilter()
        try check(fixture.model.hasActiveFilters, "测试没有建立筛选状态")

        fixture.model.open(folder: fixture.folder)

        try check(fixture.model.searchText.isEmpty, "切换空间后搜索没有清空")
        try check(fixture.model.selectedTagColors.isEmpty, "切换空间后颜色筛选没有清空")
        try check(!fixture.model.includesUntaggedInFilter, "切换空间后无标签筛选没有清空")
        try check(fixture.model.displayedItems.count == 1, "切换空间后项目仍被旧筛选隐藏")
    }

    private static func testCanvasFiltersDoNotHideInbox() throws {
        let fixture = try makeFixture(itemCount: 70)
        defer { fixture.cleanup() }
        let inboxBefore = fixture.model.inboxItems.map(\.id)
        try check(inboxBefore.count == 6, "测试没有建立待放置区")

        fixture.model.searchText = "不会匹配任何项目"
        fixture.model.toggleTagFilter(.red)

        try check(fixture.model.displayedItems.isEmpty, "主画布筛选没有生效")
        try check(fixture.model.inboxItems.map(\.id) == inboxBefore, "顶部筛选隐藏了待放置区项目")
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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

    private static func testPresentationCoversTallerViewport() throws {
        let logical = CGSize(width: 2560, height: 1440)
        let viewport = CGSize(width: 2048, height: 1300)
        let scale: CGFloat = 0.8
        let presentation = CanvasViewport.presentationSize(
            logicalSize: logical,
            viewportSize: viewport,
            displayScale: scale
        )
        try check(abs(presentation.width * scale - viewport.width) < 0.001, "背景没有覆盖视口宽度")
        try check(abs(presentation.height * scale - viewport.height) < 0.001, "背景没有覆盖全屏额外高度")
        try check(presentation.height > logical.height, "较高视口没有扩展显示背景")
    }

    private static func testPresentationNeverShrinksLogicalCanvas() throws {
        let logical = CGSize(width: 2560, height: 1440)
        let presentation = CanvasViewport.presentationSize(
            logicalSize: logical,
            viewportSize: CGSize(width: 1200, height: 700),
            displayScale: 0.8
        )
        try check(presentation == logical, "较小视口缩短了逻辑画布")
    }

    private static func testWindowAspectTracksWidth() throws {
        let size = WindowAspectSizing.constrainedContentSize(
            proposedSize: CGSize(width: 1280, height: 700),
            currentSize: CGSize(width: 1000, height: 700),
            canvasSize: CGSize(width: 1920, height: 1080),
            fixedChromeHeight: 56
        )
        try check(abs(size.width - 1280) < 0.01, "窗口宽度没有跟随拖动")
        try check(abs(size.height - 776) < 0.01, "没有在画布比例之外保留固定工具栏高度")
    }

    private static func testWindowAspectTracksHeight() throws {
        let size = WindowAspectSizing.constrainedContentSize(
            proposedSize: CGSize(width: 1000, height: 900),
            currentSize: CGSize(width: 1000, height: 700),
            canvasSize: CGSize(width: 1920, height: 1080),
            fixedChromeHeight: 56
        )
        try check(abs(size.width - 1500.4444) < 0.01, "窗口宽度没有跟随高度变化")
        try check(abs(size.height - 900) < 0.01, "窗口高度没有跟随拖动")
    }

    private static func testWindowAspectFitsCurrentDisplay() throws {
        let size = WindowAspectSizing.constrainedContentSize(
            proposedSize: CGSize(width: 2400, height: 1400),
            currentSize: CGSize(width: 1200, height: 731),
            canvasSize: CGSize(width: 1920, height: 1080),
            fixedChromeHeight: 56,
            minimumSize: CGSize(width: 900, height: 620),
            maximumSize: CGSize(width: 1440, height: 850)
        )
        try check(size.width <= 1440.01, "窗口宽度超出显示器")
        try check(size.height <= 850.01, "窗口高度超出显示器")
        let canvasRatio = size.width / (size.height - 56)
        try check(abs(canvasRatio - (1920.0 / 1080.0)) < 0.0001, "限制尺寸后画布比例改变")
    }

    private static func testMaximumWindowBypassesAspectConstraint() throws {
        let visibleFrame = CGSize(width: 1920, height: 1080)
        try check(
            WindowAspectSizing.isMaximumFrameProposal(
                proposedFrameSize: visibleFrame,
                visibleFrameSize: visibleFrame
            ),
            "完整可见区域没有被识别为最大化"
        )
        try check(
            WindowAspectSizing.isMaximumFrameProposal(
                proposedFrameSize: CGSize(width: 1919, height: 1079),
                visibleFrameSize: visibleFrame
            ),
            "系统舍入后的最大化尺寸没有被识别"
        )
        try check(
            !WindowAspectSizing.isMaximumFrameProposal(
                proposedFrameSize: CGSize(width: 1720, height: 1080),
                visibleFrameSize: visibleFrame
            ),
            "仅达到最大高度的普通窗口被误判为最大化"
        )
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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
            monitorFolders: false,
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: false
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
        canvasSize: CGSize = CGSize(width: 1024, height: 768),
        fileOperationsAsynchronously: Bool = false
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
            monitorFolders: false,
            sessionLockDirectory: base.appendingPathComponent("Locks", isDirectory: true),
            sessionLockingEnabled: false,
            scansAsynchronously: false,
            fileOperationsAsynchronously: fileOperationsAsynchronously
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

/// 线程安全地收集后台协调器事件，供异步自测检查逐步骤记录。
private actor OperationEventCollector {
    private var events: [CoordinatedFileOperationEvent] = []

    func append(_ event: CoordinatedFileOperationEvent) {
        events.append(event)
    }

    func appliedActionCount() -> Int {
        events.reduce(into: 0) { count, event in
            if case .didApply = event { count += 1 }
        }
    }
}
