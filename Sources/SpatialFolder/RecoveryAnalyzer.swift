import Foundation

enum RecoveryOutcome: String, Codable, Equatable, Sendable {
    case applied
    case undone
    case archived
    case manualReview

    var title: String {
        switch self {
        case .applied: "确认已完成"
        case .undone: "确认已回滚"
        case .archived: "仅存档记录"
        case .manualReview: "需要人工核对"
        }
    }
}

struct RecoveryEvidence: Identifiable, Equatable, Sendable {
    let id: String
    var itemName: String
    var observation: String
    var supportsApplied: Bool
    var supportsUndone: Bool
}

struct RecoveryCase: Identifiable, Equatable, Sendable {
    var id: UUID { recordID }
    var recordID: UUID
    var summary: String
    var currentState: OperationState
    var evidence: [RecoveryEvidence]
    var suggestedOutcome: RecoveryOutcome
    var explanation: String
}

/// 只读分析真实文件当前状态。它不修复、不移动文件，只把证据和建议交给用户确认。
actor RecoveryAnalyzer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func analyze(records: [OperationRecord]) -> [RecoveryCase] {
        records
            .filter { [.pending, .undoing, .redoing, .unavailable].contains($0.state) }
            .map(analyze)
    }

    private func analyze(_ record: OperationRecord) -> RecoveryCase {
        var evidence: [RecoveryEvidence] = record.actions.enumerated().map { index, action in
            self.evidence(for: action, index: index)
        }
        if !record.displacements.isEmpty {
            evidence.append(RecoveryEvidence(
                id: "displacements",
                itemName: "同名项目保护记录",
                observation: "本操作包含 \(record.displacements.count) 个冲突保护项，必须人工核对。",
                supportsApplied: false,
                supportsUndone: false
            ))
        }

        let outcome: RecoveryOutcome
        let explanation: String
        if evidence.isEmpty {
            outcome = .manualReview
            explanation = "日志中没有已提交的文件步骤，但无法排除中断发生在文件修改与动作落盘之间。请先在访达核对。"
        } else if hasCompleteAppliedCoverage(record), evidence.allSatisfy({ $0.supportsApplied }) {
            outcome = .applied
            explanation = "所有已记录步骤的磁盘状态都与“操作已完成”一致。"
        } else if evidence.allSatisfy({ $0.supportsUndone }) {
            outcome = .undone
            explanation = "所有已记录步骤的磁盘状态都与“操作已回滚”一致。"
        } else {
            outcome = .manualReview
            explanation = "磁盘证据不一致或同时存在两种状态，App 不会自动猜测。请先在访达核对。"
        }
        return RecoveryCase(
            recordID: record.id,
            summary: record.summary,
            currentState: record.state,
            evidence: evidence,
            suggestedOutcome: outcome,
            explanation: explanation
        )
    }

    private func evidence(for action: ReversibleFileAction, index: Int) -> RecoveryEvidence {
        switch action {
        case let .relocate(value):
            let originalExists = exists(value.originalPath)
            let destinationExists = exists(value.destinationPath)
            return RecoveryEvidence(
                id: "\(index)-relocate",
                itemName: URL(fileURLWithPath: value.destinationPath).lastPathComponent,
                observation: existenceText(original: originalExists, destination: destinationExists),
                supportsApplied: destinationExists && !originalExists,
                supportsUndone: originalExists && !destinationExists
            )
        case let .materialize(value):
            let destinationExists = exists(value.destinationPath)
            let trashExists = value.undoTrashPath.map(exists) ?? false
            return RecoveryEvidence(
                id: "\(index)-materialize",
                itemName: URL(fileURLWithPath: value.destinationPath).lastPathComponent,
                observation: destinationExists ? "目标项目存在" : (trashExists ? "目标不存在，撤销副本仍在废纸篓" : "目标项目不存在"),
                supportsApplied: destinationExists,
                // “目标不存在”也可能是用户在访达中另行删除。只有撤销记录中的
                // 废纸篓路径真实存在时，才能证明 materialize 已被回滚。
                supportsUndone: !destinationExists && value.undoTrashPath != nil && trashExists
            )
        case let .discard(value):
            let originalExists = exists(value.originalPath)
            let trashExists = value.trashPath.map(exists) ?? false
            return RecoveryEvidence(
                id: "\(index)-discard",
                itemName: URL(fileURLWithPath: value.originalPath).lastPathComponent,
                observation: originalExists ? "原位置项目存在" : (trashExists ? "原位置不存在，废纸篓项目存在" : "原位置和记录的废纸篓位置都不存在"),
                supportsApplied: !originalExists && trashExists,
                supportsUndone: originalExists && !trashExists
            )
        case let .tags(value):
            let url = URL(fileURLWithPath: value.path)
            let current = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            let normalizedCurrent = normalizedTags(current)
            return RecoveryEvidence(
                id: "\(index)-tags",
                itemName: url.lastPathComponent,
                observation: "当前标签数：\(current.count)",
                supportsApplied: normalizedCurrent == normalizedTags(value.after),
                supportsUndone: normalizedCurrent == normalizedTags(value.before)
            )
        }
    }

    private func exists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    private func existenceText(original: Bool, destination: Bool) -> String {
        switch (original, destination) {
        case (true, false): "仅原位置存在"
        case (false, true): "仅目标位置存在"
        case (true, true): "原位置和目标位置都存在"
        case (false, false): "原位置和目标位置都不存在"
        }
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        tags.map { $0.components(separatedBy: "\n").first ?? $0 }.sorted()
    }

    /// 单个动作的磁盘证据清晰，不代表整个批量操作已完成。例如复制 3 个文件时
    /// 崩溃在第 1 个之后，日志中会有 1 个 materialize，但不能因此宣布整批完成。
    private func hasCompleteAppliedCoverage(_ record: OperationRecord) -> Bool {
        switch record.kind {
        case .layout:
            return false
        case .rename:
            return record.actions.contains { action in
                if case .relocate = action { return true }
                return false
            }
        case .createFolder, .createDocument:
            return record.actions.contains { action in
                if case .materialize = action { return true }
                return false
            }
        case .trash:
            return actionCount(in: record, matching: .discard) >= max(1, record.itemNames.count)
        case .tags:
            return actionCount(in: record, matching: .tags) >= max(1, record.itemNames.count)
        case .duplicate, .copyItems, .compress:
            return actionCount(in: record, matching: .materialize) >= max(1, record.itemNames.count)
        case .moveItems:
            return actionCount(in: record, matching: .relocate) >= max(1, record.itemNames.count)
        }
    }

    private enum ActionType {
        case relocate
        case materialize
        case discard
        case tags
    }

    private func actionCount(in record: OperationRecord, matching type: ActionType) -> Int {
        record.actions.reduce(into: 0) { count, action in
            switch (action, type) {
            case (.relocate, .relocate), (.materialize, .materialize), (.discard, .discard), (.tags, .tags):
                count += 1
            default:
                break
            }
        }
    }
}
