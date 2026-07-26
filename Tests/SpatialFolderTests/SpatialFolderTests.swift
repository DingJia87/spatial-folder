import AppKit
import Carbon
import Foundation
import Testing
@testable import SpatialFolder

@Suite("空间文件夹 4.3 核心回归")
struct SpatialFolderTests {
    @Test("桌面收纳确认信息区分文件和文件夹")
    func testDesktopCollectionConfirmationSummary() {
        let confirmation = DesktopCollectionConfirmation(
            id: UUID(),
            destinationName: "工作桌面",
            fileCount: 8,
            folderCount: 4
        )
        #expect(confirmation.totalCount == 12)
        #expect(confirmation.countDescription == "8 个文件、4 个文件夹")
    }

    @Test("默认全局快捷键清晰且需要安全修饰键")
    func testGlobalShortcutValidationAndDisplay() {
        #expect(GlobalShortcut.defaultToggle.displayName == "⌃⌥空格")
        #expect(GlobalShortcut.defaultToggle.isAllowed)
        #expect(!GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: 0,
            keyLabel: "A"
        ).isAllowed)
        #expect(GlobalShortcut(
            keyCode: UInt32(kVK_F13),
            carbonModifiers: 0,
            keyLabel: "F13"
        ).isAllowed)
    }

    @MainActor
    @Test("快捷键冲突保留原组合并持久化成功设置")
    func testGlobalShortcutConflictRollbackAndPersistence() {
        let suiteName = "SpatialFolderShortcutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registrar = ShortcutRegistrarSpy()
        let settings = GlobalShortcutSettings(
            userDefaults: defaults,
            registrar: registrar
        )
        let accepted = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            carbonModifiers: UInt32(cmdKey | optionKey),
            keyLabel: "K"
        )
        #expect(settings.updateShortcut(accepted))
        #expect(settings.shortcut == accepted)

        registrar.nextError = .conflict
        let rejected = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_J),
            carbonModifiers: UInt32(cmdKey | optionKey),
            keyLabel: "J"
        )
        #expect(!settings.updateShortcut(rejected))
        #expect(settings.shortcut == accepted)
        #expect(settings.registrationMessage?.contains("占用") == true)

        let restored = GlobalShortcutSettings(
            userDefaults: defaults,
            registrar: ShortcutRegistrarSpy()
        )
        #expect(restored.shortcut == accepted)
        #expect(restored.isEnabled)
    }

    @MainActor
    @Test("外部修改 Finder 标签后监听器刷新内存项目")
    func testExternalTagChangeRefreshesModelItems() async throws {
        let base = temporaryDirectory("AsyncTags")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let taggedFolder = folder.appendingPathComponent("tagged-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: taggedFolder, withIntermediateDirectories: true)
        let suiteName = "SpatialFolderAsyncTagTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = FolderCanvasModel(
            layoutStore: CanvasLayoutStore(
                layoutsDirectory: base.appendingPathComponent("Layouts", isDirectory: true)
            ),
            operationStore: OperationHistoryStore(
                directory: base.appendingPathComponent("Operations", isDirectory: true)
            ),
            fileOperationEngine: FileOperationEngine(
                trashDirectoryForTesting: base.appendingPathComponent("Trash", isDirectory: true)
            ),
            userDefaults: defaults,
            autoOpenLastFolder: false,
            monitorFolders: true,
            sessionLockDirectory: base.appendingPathComponent("Locks", isDirectory: true),
            sessionLockingEnabled: false,
            scansAsynchronously: true,
            fileOperationsAsynchronously: true,
            desktopDirectoryURL: base.appendingPathComponent("Desktop", isDirectory: true)
        )
        model.open(folder: folder)
        try await waitUntil { model.items.count == 1 && !model.isRefreshing }
        let item = try #require(model.items.first)
        #expect(item.isDirectory)
        try writeFinderTags([FinderTagColor.red.encodedValue], to: item.url)
        try await waitUntil {
            !model.isRefreshing &&
                model.items.first?.tags.contains(where: {
                    FinderTagColor(finderTag: $0) == .red
                }) == true
        }
        let refreshedFolder = try #require(model.items.first)
        #expect(model.folderTagColor(for: refreshedFolder) == .red)
        model.clearTags(for: refreshedFolder)
        try await waitUntil {
            !model.isFileOperationInProgress && model.items.first?.tags.isEmpty == true
        }
        model.toggleTag(FinderTagColor.green.encodedValue, for: refreshedFolder)
        try await waitUntil {
            !model.isFileOperationInProgress &&
                model.items.first?.tags.count == 1 &&
                model.items.first?.tags.contains(where: {
                    FinderTagColor(finderTag: $0) == .green
                }) == true
        }
        let retaggedFolder = try #require(model.items.first)
        #expect(retaggedFolder.tags.count == 1)
        #expect(model.folderTagColor(for: retaggedFolder) == .green)
        try Data("new".utf8).write(to: folder.appendingPathComponent("new-item.txt"))
        try await waitUntil {
            !model.isRefreshing && model.items.count == 2
        }
    }

    @Test("桌面收纳筛选保留文件夹并排除危险项目")
    func testDesktopCollectionSourceFiltering() async throws {
        let root = temporaryDirectory("DesktopCollection")
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let targetContainer = desktop.appendingPathComponent("目标容器", isDirectory: true)
        let destination = targetContainer.appendingPathComponent("当前空间", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("report".utf8).write(to: desktop.appendingPathComponent("报告.txt"))
        let project = desktop.appendingPathComponent("项目资料", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: project.appendingPathComponent("内部.txt"))
        try Data("hidden".utf8).write(to: desktop.appendingPathComponent(".hidden"))
        try Data("pending".utf8).write(to: desktop.appendingPathComponent("下载中.crdownload"))

        let sources = try await FolderAccessRepository().desktopCollectionSources(
            in: desktop,
            destinationFolder: destination
        )
        #expect(sources.map(\.lastPathComponent) == ["报告.txt", "项目资料"])
    }

    @Test("Finder 标签颜色按编号识别")
    func testFinderTagColorUsesEncodedNumber() {
        #expect(FinderTagColor(finderTag: "紧急\n6") == .red)
        #expect(FinderTagColor(finderTag: "紧急\n6\n0") == .red)
        #expect(FinderTagColor(finderTag: "自定义名称\n2") == .green)
        #expect(FinderTagColor(finderTag: "Blue") == .blue)
        #expect(FinderTagColor(finderTag: "无颜色") == nil)
    }

    @MainActor
    @Test("标签菜单图标保留七种原色而不是模板单色")
    func testFinderTagMenuIconsPreserveOriginalColors() throws {
        for tag in FinderTagColor.displayOrder {
            let image = tag.menuIcon(selected: false)
            #expect(!image.isTemplate)
            let tiff = try #require(image.tiffRepresentation)
            let representation = try #require(NSBitmapImageRep(data: tiff))
            let actual = try #require(
                representation.colorAt(
                    x: representation.pixelsWide / 2,
                    y: representation.pixelsHigh / 2
                )?.usingColorSpace(.deviceRGB)
            )
            let expected = try #require(tag.menuColor.usingColorSpace(.deviceRGB))
            #expect(abs(actual.redComponent - expected.redComponent) < 0.18)
            #expect(abs(actual.greenComponent - expected.greenComponent) < 0.18)
            #expect(abs(actual.blueComponent - expected.blueComponent) < 0.18)
        }
    }

    @Test("搜索和多标签筛选按 AND 与 OR 组合")
    func testCanvasItemFilterCombination() {
        let red = FolderItem(
            url: URL(fileURLWithPath: "/tmp/季度报告.txt"),
            tags: ["紧急\n6"],
            resourceID: nil
        )
        let green = FolderItem(
            url: URL(fileURLWithPath: "/tmp/季度预算.txt"),
            tags: ["财务\n2"],
            resourceID: nil
        )
        let untagged = FolderItem(
            url: URL(fileURLWithPath: "/tmp/会议记录.txt"),
            tags: [],
            resourceID: nil
        )
        let filter = CanvasItemFilter(
            query: "季度",
            tagColors: [.red, .green],
            includesUntagged: false
        )
        #expect(filter.matches(red))
        #expect(filter.matches(green))
        #expect(!filter.matches(untagged))
        #expect(CanvasItemFilter(includesUntagged: true).matches(untagged))
    }

    @Test("画布锁只允许一个写入者")
    func testSessionLockIsExclusive() throws {
        let directory = temporaryDirectory("Locks")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try CanvasSessionLock.acquire(
            canvasKey: "test-canvas",
            directory: directory,
            processID: 100,
            appVersion: "2.6.0"
        )
        guard case let .acquired(lock) = first else {
            Issue.record("第一个会话没有取得锁")
            return
        }
        let second = try CanvasSessionLock.acquire(
            canvasKey: "test-canvas",
            directory: directory,
            processID: 200,
            appVersion: "2.6.0"
        )
        guard case let .occupied(owner) = second else {
            Issue.record("第二个会话错误地取得了写入权")
            return
        }
        #expect(owner?.processID == 100)
        lock.release()
        guard case .acquired = try CanvasSessionLock.acquire(
            canvasKey: "test-canvas",
            directory: directory,
            processID: 300,
            appVersion: "2.6.0"
        ) else {
            Issue.record("原会话释放后仍无法取得锁")
            return
        }
    }

    @Test("3000 项扫描保持在性能预算内")
    func testLargeFirstLevelScan() throws {
        let folder = temporaryDirectory("Scan")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3_000 {
            let url = folder.appendingPathComponent(String(format: "item-%04d.txt", index))
            _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let started = Date()
        let entries = try FolderDirectoryScanner().scan(folder: folder)
        #expect(entries.count == 3_000)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("批量复制失败会回滚本批次")
    func testCoordinatedTransferRollsBack() async throws {
        let root = temporaryDirectory("Coordinator")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let valid = source.appendingPathComponent("valid.txt")
        let missing = source.appendingPathComponent("missing.txt")
        try Data("valid".utf8).write(to: valid)
        let plans = [
            FileTransferPlan(
                source: valid,
                destination: target.appendingPathComponent("valid.txt"),
                move: false,
                replacesExistingDestination: false
            ),
            FileTransferPlan(
                source: missing,
                destination: target.appendingPathComponent("missing.txt"),
                move: false,
                replacesExistingDestination: false
            )
        ]
        do {
            _ = try await FileOperationCoordinator(fileOperationEngine: FileOperationEngine(
                trashDirectoryForTesting: trash
            )).performTransfers(plans) { _ in }
            Issue.record("缺失来源没有触发失败")
        } catch let failure as CoordinatedFileOperationFailure {
            #expect(failure.rollbackSucceeded)
            #expect(!FileManager.default.fileExists(
                atPath: target.appendingPathComponent("valid.txt").path
            ))
        }
    }

    @Test("增量日志重放最终状态")
    func testIncrementalJournalReplaysLatestState() async throws {
        let directory = temporaryDirectory("Journal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationJournalStore(diskStore: OperationJournalDiskStore(
            directory: directory,
            compactionEventThreshold: 50
        ))
        var record = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "导入",
            state: .pending
        )
        _ = try await store.upsert(record, canvasKey: "canvas")
        record.state = .applied
        record.actions = [.materialize(MaterializeAction(destinationPath: "/tmp/result"))]
        _ = try await store.upsert(record, canvasKey: "canvas")
        let loaded = try await store.load(canvasKey: "canvas")
        #expect(loaded.records.count == 1)
        #expect(loaded.records.first?.state == .applied)
        #expect(loaded.records.first?.actions == record.actions)
    }

    @Test("投放点布局不移动已有项目")
    func testDropPlacementPreservesExistingItems() {
        let engine = CanvasLayoutEngine()
        let before = ["existing": CanvasPoint(x: 120, y: 120)]
        let result = engine.placeImportedItems(
            [CanvasLayoutItem(id: "incoming", scale: 1.25)],
            near: CGPoint(x: 800, y: 500),
            existingItems: [CanvasLayoutItem(id: "existing", scale: 1.25)],
            positions: before,
            inboxIDs: [],
            canvasSize: CGSize(width: 1_000, height: 700)
        )
        #expect(result.positions["existing"] == before["existing"])
        #expect(result.positions["incoming"] != nil)
    }

    @Test("桌面收纳项目叠放并整体避开已有图标")
    func testDesktopCollectionStackPlacement() {
        let engine = CanvasLayoutEngine()
        let occupiedAnchor = CanvasPoint(x: 1_080, y: 624)
        let before = ["existing": occupiedAnchor]
        let imported = [
            CanvasLayoutItem(id: "folder", scale: 1.25),
            CanvasLayoutItem(id: "file-a", scale: 1.25),
            CanvasLayoutItem(id: "file-b", scale: 1.25)
        ]
        let requestedResult = engine.stackImportedItems(
            imported,
            near: CGPoint(x: 1_068, y: 620),
            existingItems: [],
            positions: [:],
            inboxIDs: [],
            canvasSize: CGSize(width: 1_200, height: 800)
        )
        #expect(requestedResult.positions["folder"] == occupiedAnchor)

        let result = engine.stackImportedItems(
            imported,
            near: CGPoint(x: 1_068, y: 620),
            existingItems: [CanvasLayoutItem(id: "existing", scale: 1.25)],
            positions: before,
            inboxIDs: [],
            canvasSize: CGSize(width: 1_200, height: 800)
        )
        #expect(result.positions["existing"] == occupiedAnchor)
        let stackPoints = imported.compactMap { result.positions[$0.id] }
        #expect(stackPoints.count == imported.count)
        #expect(stackPoints.allSatisfy { $0 == stackPoints.first })
        #expect(stackPoints.first != occupiedAnchor)
        #expect(result.placedIDs == imported.map(\.id))
    }

    @Test("普通窗口随宽度保持比例")
    func testNormalWindowKeepsAspectRatio() {
        let result = WindowAspectSizing.constrainedContentSize(
            proposedSize: CGSize(width: 1_000, height: 600),
            currentSize: CGSize(width: 800, height: 550),
            canvasSize: CGSize(width: 1_600, height: 900),
            fixedChromeHeight: 50
        )
        #expect(result == CGSize(width: 1_000, height: 612.5))
    }

    @Test("最大化窗口可绕开普通比例约束")
    func testMaximumWindowProposalIsRecognized() {
        #expect(WindowAspectSizing.isMaximumFrameProposal(
            proposedFrameSize: CGSize(width: 1_510, height: 980),
            visibleFrameSize: CGSize(width: 1_512, height: 982)
        ))
        #expect(!WindowAspectSizing.isMaximumFrameProposal(
            proposedFrameSize: CGSize(width: 1_200, height: 800),
            visibleFrameSize: CGSize(width: 1_512, height: 982)
        ))
    }

    @Test("全屏额外高度由背景覆盖")
    func testFullScreenPresentationCoversViewport() {
        let size = CanvasViewport.presentationSize(
            logicalSize: CGSize(width: 1_600, height: 900),
            viewportSize: CGSize(width: 1_600, height: 1_050),
            displayScale: 1
        )
        #expect(size == CGSize(width: 1_600, height: 1_050))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SpatialFolderStandardTests-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

private final class ShortcutRegistrarSpy: GlobalHotKeyRegistering {
    var nextError: GlobalHotKeyRegistrationError?
    private(set) var registeredShortcut: GlobalShortcut?

    func replaceShortcut(_ shortcut: GlobalShortcut) throws {
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        registeredShortcut = shortcut
    }

    func unregister() {
        registeredShortcut = nil
    }
}
