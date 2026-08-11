import Foundation

enum FileOperationSafetyError: LocalizedError, Equatable, Sendable {
    case invalidItemName
    case sourceOutsideAuthorizedFolder
    case destinationOutsideAuthorizedFolder
    case untrustedTrashLocation

    var errorDescription: String? {
        switch self {
        case .invalidItemName:
            return "名称不能为空、“.”或“..”，也不能包含路径分隔符。"
        case .sourceOutsideAuthorizedFolder:
            return "操作已取消：来源项目不在当前空间的第一层。"
        case .destinationOutsideAuthorizedFolder:
            return "操作已取消：目标位置超出当前空间。"
        case .untrustedTrashLocation:
            return "操作已取消：操作记录中的废纸篓位置无法验证。"
        }
    }
}

/// 一次真实文件操作只能在用户当前打开的空间边界内生效。
/// 所有协调器写入入口必须显式携带本上下文，避免新增功能时漏掉校验。
struct FileOperationAuthorizationContext: Equatable, Sendable {
    let folder: URL

    init(folder: URL) {
        self.folder = folder.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// 真实文件操作的通用边界检查。只解析父目录身份，不跟随子项符号链接的目标。
struct FileOperationPathValidator: Sendable {
    static func validateSources(
        _ urls: [URL],
        authorization: FileOperationAuthorizationContext
    ) throws {
        guard urls.allSatisfy({ isDirectChild($0, of: authorization.folder) }) else {
            throw FileOperationSafetyError.sourceOutsideAuthorizedFolder
        }
    }

    static func validateDestinations(
        _ urls: [URL],
        authorization: FileOperationAuthorizationContext
    ) throws {
        guard urls.allSatisfy({ isDirectChild($0, of: authorization.folder) }) else {
            throw FileOperationSafetyError.destinationOutsideAuthorizedFolder
        }
    }

    static func isDirectChild(_ url: URL, of folder: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent == folder
    }
}
