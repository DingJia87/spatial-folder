import Foundation

@main
struct SpatialFolderPerformanceBaseline {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpatialFolderPerformance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var scans: [String: Double] = [:]
        for count in [64, 500, 3_000] {
            let folder = root.appendingPathComponent("scan-\(count)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<count {
                let url = folder.appendingPathComponent(String(format: "item-%05d.txt", index))
                _ = FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            let started = ContinuousClock.now
            let entries = try FolderDirectoryScanner().scan(folder: folder)
            let elapsed = started.duration(to: .now)
            guard entries.count == count else { throw CocoaError(.fileReadCorruptFile) }
            scans[String(count)] = seconds(elapsed)
        }

        let journalDirectory = root.appendingPathComponent("journal", isDirectory: true)
        let diskStore = OperationJournalDiskStore(
            directory: journalDirectory,
            maximumRecords: 200,
            compactionEventThreshold: 500,
            compactionByteThreshold: 10_000_000
        )
        let journal = OperationJournalStore(diskStore: diskStore)
        var record = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "性能基线",
            state: .pending
        )
        let appendStarted = ContinuousClock.now
        for index in 0..<1_000 {
            record.detail = "步骤 \(index)"
            _ = try await journal.upsert(record, canvasKey: "canvas")
        }
        let appendElapsed = appendStarted.duration(to: .now)
        let replayStarted = ContinuousClock.now
        let loaded = try await journal.load(canvasKey: "canvas")
        let replayElapsed = replayStarted.duration(to: .now)
        guard loaded.records.first?.detail == "步骤 999" else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let journalBytes = Int64((try? diskStore.journalURL(canvasKey: "canvas")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let snapshotBytes = Int64((try? diskStore.snapshotURL(canvasKey: "canvas")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let result: [String: Any] = [
            "scan_seconds": scans,
            "journal_1000_append_seconds": seconds(appendElapsed),
            "journal_replay_seconds": seconds(replayElapsed),
            "journal_bytes_after_compaction": journalBytes,
            "snapshot_bytes": snapshotBytes
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
