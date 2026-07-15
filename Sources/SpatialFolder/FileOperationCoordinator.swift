import Foundation

/// 描述一次批量复制或移动中的单个项目计划。
struct FileTransferPlan: Equatable, Sendable {
    let source: URL
    let destination: URL
    let move: Bool
    let replacesExistingDestination: Bool
}

struct FileCompressionPlan: Equatable, Sendable {
    let source: URL
    let destination: URL
}

/// 协调器向主模型报告的细粒度事件。模型会在每一步完成后立即持久化事务记录。
enum CoordinatedFileOperationEvent: Sendable {
    case willBegin(step: Int, total: Int, detail: String)
    case didApply(action: ReversibleFileAction, completed: Int, total: Int)
    case rollingBack(detail: String)
}

/// 操作失败时同时携带已经完成的动作和回滚结果，不能只返回一条字符串。
struct CoordinatedFileOperationFailure: LocalizedError, Sendable {
    let message: String
    let actions: [ReversibleFileAction]
    let displacements: [ConflictDisplacement]
    let rollbackSucceeded: Bool
    let wasCancelled: Bool

    var errorDescription: String? { message }
}

/// 串行执行耗时文件操作。Actor 隔离保证同一模型不会并行复制两批文件。
actor FileOperationCoordinator {
    typealias EventHandler = @Sendable (CoordinatedFileOperationEvent) async throws -> Void

    private let fileManager: FileManager
    private let fileOperationEngine: FileOperationEngine

    init(fileOperationEngine: FileOperationEngine = FileOperationEngine()) {
        self.fileOperationEngine = fileOperationEngine
        fileManager = fileOperationEngine.fileManager
    }

    /// 执行一批复制/移动。取消不能强行打断 FileManager 正在进行的单文件复制，
    /// 但会在该系统调用返回后立刻停止下一项，并安全回滚本批次已完成内容。
    func performTransfers(
        _ plans: [FileTransferPlan],
        eventHandler: EventHandler
    ) async throws -> [ReversibleFileAction] {
        var actions: [ReversibleFileAction] = []
        let totalSteps = plans.reduce(0) { $0 + ($1.replacesExistingDestination ? 2 : 1) }
        var completed = 0

        do {
            for plan in plans {
                try Task.checkCancellation()
                if plan.replacesExistingDestination,
                   fileManager.fileExists(atPath: plan.destination.path) {
                    try await eventHandler(.willBegin(
                        step: completed + 1,
                        total: totalSteps,
                        detail: "正在保护同名项目“\(plan.destination.lastPathComponent)”"
                    ))
                    let trashURL = try fileOperationEngine.moveToTrash(plan.destination)
                    let action = ReversibleFileAction.discard(DiscardAction(
                        originalPath: plan.destination.path,
                        trashPath: trashURL.path
                    ))
                    actions.append(action)
                    completed += 1
                    try await eventHandler(.didApply(action: action, completed: completed, total: totalSteps))
                }

                try Task.checkCancellation()
                let verb = plan.move ? "移动" : "复制"
                try await eventHandler(.willBegin(
                    step: completed + 1,
                    total: totalSteps,
                    detail: "正在\(verb)“\(plan.source.lastPathComponent)”"
                ))
                do {
                    if plan.move {
                        try fileManager.moveItem(at: plan.source, to: plan.destination)
                    } else {
                        try fileManager.copyItem(at: plan.source, to: plan.destination)
                    }
                } catch {
                    // 某些文件系统失败时会留下部分目标；把它登记为可回滚动作。
                    if fileManager.fileExists(atPath: plan.destination.path) {
                        let sourceStillExists = fileManager.fileExists(atPath: plan.source.path)
                        let partialAction: ReversibleFileAction = plan.move && !sourceStillExists
                            ? .relocate(RelocateAction(
                                originalPath: plan.source.path,
                                destinationPath: plan.destination.path
                            ))
                            : .materialize(MaterializeAction(destinationPath: plan.destination.path))
                        actions.append(partialAction)
                        completed += 1
                        try await eventHandler(.didApply(
                            action: partialAction,
                            completed: completed,
                            total: totalSteps
                        ))
                    }
                    throw error
                }

                let action: ReversibleFileAction = plan.move
                    ? .relocate(RelocateAction(
                        originalPath: plan.source.path,
                        destinationPath: plan.destination.path
                    ))
                    : .materialize(MaterializeAction(destinationPath: plan.destination.path))
                actions.append(action)
                completed += 1
                try await eventHandler(.didApply(action: action, completed: completed, total: totalSteps))
            }
            try Task.checkCancellation()
            return actions
        } catch {
            let cancelled = error is CancellationError
            try? await eventHandler(.rollingBack(
                detail: cancelled ? "正在取消并恢复本批次已完成内容" : "操作失败，正在恢复已完成内容"
            ))
            let rollback = rollback(actions: actions)
            throw CoordinatedFileOperationFailure(
                message: cancelled ? "操作已取消。" : error.localizedDescription,
                actions: rollback.actions,
                displacements: rollback.displacements,
                rollbackSucceeded: rollback.succeeded,
                wasCancelled: cancelled
            )
        }
    }

    /// 在后台执行系统 ditto 压缩；失败或取消后移除已产生的半成品压缩包。
    func compress(
        source: URL,
        destination: URL,
        eventHandler: EventHandler
    ) async throws -> [ReversibleFileAction] {
        try await performCompressions(
            [FileCompressionPlan(source: source, destination: destination)],
            eventHandler: eventHandler
        )
    }

    func performCompressions(
        _ plans: [FileCompressionPlan],
        eventHandler: EventHandler
    ) async throws -> [ReversibleFileAction] {
        var actions: [ReversibleFileAction] = []
        do {
            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                try await eventHandler(.willBegin(
                    step: index + 1,
                    total: plans.count,
                    detail: "正在压缩“\(plan.source.lastPathComponent)”"
                ))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", plan.source.path, plan.destination.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let action = ReversibleFileAction.materialize(MaterializeAction(
                    destinationPath: plan.destination.path
                ))
                actions.append(action)
                try await eventHandler(.didApply(
                    action: action,
                    completed: index + 1,
                    total: plans.count
                ))
            }
            try Task.checkCancellation()
            return actions
        } catch {
            // 失败的当前压缩也可能留下半成品，把尚未登记的目标补入回滚列表。
            for plan in plans where
                fileManager.fileExists(atPath: plan.destination.path) &&
                !actions.contains(where: { action in
                    if case let .materialize(value) = action { return value.destinationPath == plan.destination.path }
                    return false
                }) {
                let partial = ReversibleFileAction.materialize(MaterializeAction(
                    destinationPath: plan.destination.path
                ))
                actions.append(partial)
                try? await eventHandler(.didApply(
                    action: partial,
                    completed: actions.count,
                    total: plans.count
                ))
            }
            try? await eventHandler(.rollingBack(detail: "正在清理本批次未完成的压缩包"))
            let rollback = rollback(actions: actions)
            throw CoordinatedFileOperationFailure(
                message: error is CancellationError ? "压缩已取消。" : error.localizedDescription,
                actions: rollback.actions,
                displacements: rollback.displacements,
                rollbackSucceeded: rollback.succeeded,
                wasCancelled: error is CancellationError
            )
        }
    }

    /// 批量移至废纸篓。每个项目的真实废纸篓路径会逐项返回并立即写入事务记录。
    func performTrash(
        _ urls: [URL],
        eventHandler: EventHandler
    ) async throws -> [ReversibleFileAction] {
        var actions: [ReversibleFileAction] = []
        do {
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                try await eventHandler(.willBegin(
                    step: index + 1,
                    total: urls.count,
                    detail: "正在将“\(url.lastPathComponent)”移至废纸篓"
                ))
                let trashURL = try fileOperationEngine.moveToTrash(url)
                let action = ReversibleFileAction.discard(DiscardAction(
                    originalPath: url.path,
                    trashPath: trashURL.path
                ))
                actions.append(action)
                try await eventHandler(.didApply(
                    action: action,
                    completed: index + 1,
                    total: urls.count
                ))
            }
            try Task.checkCancellation()
            return actions
        } catch {
            let cancelled = error is CancellationError
            try? await eventHandler(.rollingBack(
                detail: cancelled ? "正在取消并恢复废纸篓项目" : "删除未完成，正在恢复已移动项目"
            ))
            let rollback = rollback(actions: actions)
            throw CoordinatedFileOperationFailure(
                message: cancelled ? "移至废纸篓已取消。" : error.localizedDescription,
                actions: rollback.actions,
                displacements: rollback.displacements,
                rollbackSucceeded: rollback.succeeded,
                wasCancelled: cancelled
            )
        }
    }

    /// 把可能包含大量项目的撤销/重做放到后台 Actor；调用方会在启动前把记录标成过渡状态，
    /// 因而即使 App 中途退出，下一次启动也不会把未知状态误报为成功。
    func transition(
        record: OperationRecord,
        to targetState: OperationState,
        conflictChoice: ConflictChoice,
        eventHandler: EventHandler
    ) async throws -> OperationRecord {
        let verb = targetState == .undone ? "撤销" : "重做"
        try await eventHandler(.willBegin(
            step: 1,
            total: 1,
            detail: "正在\(verb)“\(record.summary)”"
        ))
        let updated = try fileOperationEngine.transition(
            record,
            to: targetState,
            conflictChoice: conflictChoice
        )
        return updated
    }

    private func rollback(
        actions: [ReversibleFileAction]
    ) -> (actions: [ReversibleFileAction], displacements: [ConflictDisplacement], succeeded: Bool) {
        guard !actions.isEmpty else { return ([], [], true) }
        let temporaryRecord = OperationRecord(
            category: .file,
            kind: .copyItems,
            summary: "回滚未完成操作",
            state: .applied,
            actions: actions
        )
        do {
            let rolledBack = try fileOperationEngine.transition(
                temporaryRecord,
                to: .undone,
                conflictChoice: .cancel
            )
            return (rolledBack.actions, rolledBack.displacements, true)
        } catch {
            return (actions, [], false)
        }
    }
}

/// 主界面展示的进度状态，不包含用户文件的完整路径。
struct FileOperationProgressState: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    var detail: String
    var completedUnitCount: Int
    var totalUnitCount: Int
    var isCancelling: Bool
    let allowsCancellation: Bool

    var fractionCompleted: Double? {
        guard totalUnitCount > 0 else { return nil }
        return Double(completedUnitCount) / Double(totalUnitCount)
    }
}
