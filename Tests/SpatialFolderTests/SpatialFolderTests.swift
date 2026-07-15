import Foundation
import Testing
@testable import SpatialFolder

/// 2.4 的标准 SwiftPM 测试入口。
/// 大型兼容性矩阵仍保留在 SelfTests；这里覆盖 CI 最需要尽早拦截的并发、性能和窗口状态。
@Suite("空间文件夹 2.4 核心回归")
struct SpatialFolderTests {
    @Test("画布锁只允许一个写入者")
    func sessionLockIsExclusive() throws {
        let directory = temporaryDirectory("Locks")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try CanvasSessionLock.acquire(
            canvasKey: "test-canvas",
            directory: directory,
            processID: 100,
            appVersion: "2.4.0"
        )
        guard case let .acquired(lock) = first else {
            Issue.record("第一个会话没有取得锁")
            return
        }
        let second = try CanvasSessionLock.acquire(
            canvasKey: "test-canvas",
            directory: directory,
            processID: 200,
            appVersion: "2.4.0"
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
            appVersion: "2.4.0"
        ) else {
            Issue.record("原会话释放后仍无法取得锁")
            return
        }
    }

    @Test("3000 项扫描保持在性能预算内")
    func largeFirstLevelScan() throws {
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
    func coordinatedTransferRollsBack() async throws {
        let root = temporaryDirectory("Coordinator")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
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
            _ = try await FileOperationCoordinator().performTransfers(plans) { _ in }
            Issue.record("缺失来源没有触发失败")
        } catch let failure as CoordinatedFileOperationFailure {
            #expect(failure.rollbackSucceeded)
            #expect(!FileManager.default.fileExists(
                atPath: target.appendingPathComponent("valid.txt").path
            ))
        }
    }

    @Test("普通窗口随宽度保持比例")
    func normalWindowKeepsAspectRatio() {
        let result = WindowAspectSizing.constrainedContentSize(
            proposedSize: CGSize(width: 1_000, height: 600),
            currentSize: CGSize(width: 800, height: 550),
            canvasSize: CGSize(width: 1_600, height: 900),
            fixedChromeHeight: 50
        )
        #expect(result == CGSize(width: 1_000, height: 612.5))
    }

    @Test("最大化窗口可绕开普通比例约束")
    func maximumWindowProposalIsRecognized() {
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
    func fullScreenPresentationCoversViewport() {
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
}
