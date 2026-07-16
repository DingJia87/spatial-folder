import Foundation

/// 2.5 的增量日志事件。每次状态变化只追加受影响的记录，避免重复编码整个历史文档。
enum OperationJournalMutation: Codable, Equatable, Sendable {
    case upsert([OperationRecord])
    case replaceAll([OperationRecord])
}

struct OperationJournalEntry: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var id = UUID()
    var writtenAt = Date()
    var mutation: OperationJournalMutation
}

struct OperationJournalMetrics: Equatable, Sendable {
    var appendedEventCount: Int
    var journalByteCount: Int64
    var didCompact: Bool
}

/// 磁盘格式仍由一个值类型负责，便于在无并发的迁移测试中直接验证；生产环境只能通过
/// `OperationJournalStore` actor 调用它，确保同一画布的事件顺序与真实文件操作顺序一致。
struct OperationJournalDiskStore: Sendable {
    let directory: URL
    let maximumRecords: Int
    let compactionEventThreshold: Int
    let compactionByteThreshold: Int64

    init(
        directory: URL? = nil,
        maximumRecords: Int = 200,
        compactionEventThreshold: Int = 500,
        compactionByteThreshold: Int64 = 1_048_576
    ) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("SpatialFolder/Operations", isDirectory: true)
        }
        self.maximumRecords = max(20, maximumRecords)
        self.compactionEventThreshold = max(2, compactionEventThreshold)
        self.compactionByteThreshold = max(4_096, compactionByteThreshold)
    }

    init(legacyStore: OperationHistoryStore) {
        self.init(directory: legacyStore.directory, maximumRecords: legacyStore.maximumRecords)
    }

    func snapshotURL(canvasKey: String) -> URL {
        directory.appendingPathComponent(canvasKey).appendingPathExtension("snapshot.json")
    }

    func journalURL(canvasKey: String) -> URL {
        directory.appendingPathComponent(canvasKey).appendingPathExtension("journal.jsonl")
    }

    func legacyURL(canvasKey: String) -> URL {
        directory.appendingPathComponent(canvasKey).appendingPathExtension("json")
    }

    func archivedLegacyURL(canvasKey: String) -> URL {
        directory.appendingPathComponent(canvasKey).appendingPathExtension("2.4.json")
    }

    /// 加载顺序是快照 → 增量日志。只有 2.5 文件都不存在时才读取 2.4 的单文件历史。
    func load(canvasKey: String, migrateLegacy: Bool = true) throws -> OperationHistoryDocument {
        let fileManager = FileManager.default
        var document: OperationHistoryDocument
        let snapshot = snapshotURL(canvasKey: canvasKey)
        let legacy = legacyURL(canvasKey: canvasKey)

        if fileManager.fileExists(atPath: snapshot.path) {
            document = try decodeDocument(at: snapshot)
        } else if fileManager.fileExists(atPath: legacy.path) {
            document = try decodeDocument(at: legacy)
            if migrateLegacy {
                try migrate(document: document, canvasKey: canvasKey)
            }
        } else {
            document = OperationHistoryDocument()
        }

        let journal = journalURL(canvasKey: canvasKey)
        if fileManager.fileExists(atPath: journal.path) {
            document = try replayJournal(at: journal, startingFrom: document)
        }
        document.records = trimmed(document.records)
        return document
    }

    @discardableResult
    func append(
        _ mutation: OperationJournalMutation,
        canvasKey: String,
        knownEventCount: Int? = nil
    ) throws -> OperationJournalMetrics {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = OperationJournalEntry(mutation: mutation)
        let encoder = makeEncoder()
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let url = journalURL(canvasKey: canvasKey)
        // actor 会传入内存计数；值类型测试或修复工具首次调用时才扫描一次现有日志。
        let previousEventCount: Int
        if let knownEventCount {
            previousEventCount = knownEventCount
        } else {
            previousEventCount = try repairTrailingPartialEventAndCount(at: url)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()

        let eventCount = previousEventCount + 1
        let byteCount = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count)
        let shouldCompact = eventCount >= compactionEventThreshold || byteCount >= compactionByteThreshold
        if shouldCompact {
            let document = try load(canvasKey: canvasKey, migrateLegacy: false)
            try compact(document, canvasKey: canvasKey)
        }
        return OperationJournalMetrics(
            appendedEventCount: eventCount,
            journalByteCount: byteCount,
            didCompact: shouldCompact
        )
    }

    func compact(_ document: OperationHistoryDocument, canvasKey: String) throws {
        var snapshot = document
        snapshot.records = trimmed(snapshot.records)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeEncoder().encode(snapshot).write(
            to: snapshotURL(canvasKey: canvasKey),
            options: .atomic
        )
        // 快照已原子替换后才清空日志；崩溃最多造成事件被重放两次，upsert 本身是幂等的。
        try Data().write(to: journalURL(canvasKey: canvasKey), options: .atomic)
    }

    func archiveCorruptHistoryAndReset(canvasKey: String) throws -> URL {
        let corruptDirectory = directory.appendingPathComponent("Corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let stamp = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds)
        let archive = corruptDirectory.appendingPathComponent("\(canvasKey)-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for source in [
            snapshotURL(canvasKey: canvasKey),
            journalURL(canvasKey: canvasKey),
            legacyURL(canvasKey: canvasKey)
        ] where FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(
                at: source,
                to: archive.appendingPathComponent(source.lastPathComponent)
            )
        }
        try compact(OperationHistoryDocument(), canvasKey: canvasKey)
        return archive
    }

    private func migrate(document: OperationHistoryDocument, canvasKey: String) throws {
        try compact(document, canvasKey: canvasKey)
        let legacy = legacyURL(canvasKey: canvasKey)
        let archive = archivedLegacyURL(canvasKey: canvasKey)
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        try FileManager.default.moveItem(at: legacy, to: archive)
    }

    private func replayJournal(
        at url: URL,
        startingFrom document: OperationHistoryDocument
    ) throws -> OperationHistoryDocument {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return document }
        // 一次追加在断电时可能只留下没有换行终止的最后半行。pending
        // 写入只有在整行 synchronize 成功后才会放行真实文件操作，因此可安全
        // 忽略这段未提交尾部。已有换行但无法解码的事件仍视为真实损坏。
        let committedData: Data
        if data.last == 0x0A {
            committedData = data
        } else if let finalNewline = data.lastIndex(of: 0x0A) {
            committedData = data.prefix(through: finalNewline)
        } else {
            committedData = Data()
        }
        guard !committedData.isEmpty else { return document }
        var result = document
        let decoder = makeDecoder()
        for line in committedData.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(OperationJournalEntry.self, from: Data(line)),
                  entry.version == OperationJournalEntry.currentVersion else {
                throw OperationHistoryStoreError.corruptHistory
            }
            apply(entry.mutation, to: &result)
        }
        result.records = trimmed(result.records)
        return result
    }

    private func apply(_ mutation: OperationJournalMutation, to document: inout OperationHistoryDocument) {
        switch mutation {
        case let .upsert(records):
            for record in records {
                if let index = document.records.firstIndex(where: { $0.id == record.id }) {
                    document.records[index] = record
                } else {
                    document.records.append(record)
                }
            }
        case let .replaceAll(records):
            document.records = records
        }
    }

    private func trimmed(_ records: [OperationRecord]) -> [OperationRecord] {
        records.count > maximumRecords ? Array(records.suffix(maximumRecords)) : records
    }

    private func decodeDocument(at url: URL) throws -> OperationHistoryDocument {
        guard let document = try? makeDecoder().decode(
            OperationHistoryDocument.self,
            from: Data(contentsOf: url)
        ) else {
            throw OperationHistoryStoreError.corruptHistory
        }
        return document
    }

    /// 第一次追加时同时修剪断电遗留的半行，避免新 JSON 与旧尾部粘连。
    private func repairTrailingPartialEventAndCount(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var data = try Data(contentsOf: url)
        if !data.isEmpty, data.last != 0x0A {
            if let finalNewline = data.lastIndex(of: 0x0A) {
                data = data.prefix(through: finalNewline)
            } else {
                data = Data()
            }
            try data.write(to: url, options: .atomic)
        }
        return data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// 生产环境的唯一日志入口。actor 串行化追加、迁移和压缩，调用方可以在修改真实文件前
/// `await` 确认 pending 记录已经同步到磁盘。
actor OperationJournalStore {
    private let diskStore: OperationJournalDiskStore
    private var eventCounts: [String: Int] = [:]

    init(diskStore: OperationJournalDiskStore = OperationJournalDiskStore()) {
        self.diskStore = diskStore
    }

    init(legacyStore: OperationHistoryStore) {
        diskStore = OperationJournalDiskStore(legacyStore: legacyStore)
    }

    func load(canvasKey: String) throws -> OperationHistoryDocument {
        let document = try diskStore.load(canvasKey: canvasKey)
        eventCounts[canvasKey] = nil
        return document
    }

    @discardableResult
    func upsert(_ record: OperationRecord, canvasKey: String) throws -> OperationJournalMetrics {
        try append(.upsert([record]), canvasKey: canvasKey)
    }

    @discardableResult
    func upsert(_ records: [OperationRecord], canvasKey: String) throws -> OperationJournalMetrics {
        try append(.upsert(records), canvasKey: canvasKey)
    }

    @discardableResult
    func replaceAll(_ records: [OperationRecord], canvasKey: String) throws -> OperationJournalMetrics {
        try append(.replaceAll(records), canvasKey: canvasKey)
    }

    func compact(_ document: OperationHistoryDocument, canvasKey: String) throws {
        try diskStore.compact(document, canvasKey: canvasKey)
        eventCounts[canvasKey] = 0
    }

    func archiveCorruptHistoryAndReset(canvasKey: String) throws -> URL {
        let url = try diskStore.archiveCorruptHistoryAndReset(canvasKey: canvasKey)
        eventCounts[canvasKey] = 0
        return url
    }

    private func append(
        _ mutation: OperationJournalMutation,
        canvasKey: String
    ) throws -> OperationJournalMetrics {
        let knownCount: Int
        if let cached = eventCounts[canvasKey] {
            knownCount = cached
        } else {
            // 传 nil 时磁盘层只在本次扫描既有日志；后续追加都是 O(本事件大小)。
            let metrics = try diskStore.append(mutation, canvasKey: canvasKey)
            eventCounts[canvasKey] = metrics.didCompact ? 0 : metrics.appendedEventCount
            return metrics
        }
        let metrics = try diskStore.append(
            mutation,
            canvasKey: canvasKey,
            knownEventCount: knownCount
        )
        eventCounts[canvasKey] = metrics.didCompact ? 0 : metrics.appendedEventCount
        return metrics
    }
}
