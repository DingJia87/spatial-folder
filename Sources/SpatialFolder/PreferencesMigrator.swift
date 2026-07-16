import Foundation

/// 记录一次偏好迁移的来源和复制内容，便于测试与后续诊断。
struct PreferencesMigrationReport: Equatable, Sendable {
    var sourceDomains: Set<String> = []
    var copiedKeys: Set<String> = []
}

/// 把旧测试版 Bundle ID 下的用户偏好迁移到 2.4 起使用的稳定偏好域。
///
/// 布局与文件操作记录一直存放在固定的 Application Support 目录，不需要在这里迁移；
/// 这里只处理 UserDefaults 中的“上次文件夹、最近空间、外观”等入口状态。
enum PreferencesMigrator {
    static let currentMigrationVersion = 1
    static let migrationVersionKey = "preferencesMigrationVersion"

    /// 从新到旧排列；同一个键优先采用用户最近使用过的版本。
    static let legacyBundleIdentifiers = [
        "local.spatialfolder.app.v232",
        "local.spatialfolder.app.v231",
        "local.spatialfolder.app.v23",
        "local.spatialfolder.app.v22",
        "local.spatialfolder.app.v20"
    ]

    static let migratedKeys = [
        "appearanceMode",
        "recentFolderPaths",
        "recentFolderBookmarksV2",
        "lastOpenedFolderBookmarkV2",
        "lastOpenedFolderPath"
    ]

    /// App 启动时调用的便利入口。
    @discardableResult
    static func migrateIfNeeded(destination: UserDefaults = .standard) -> PreferencesMigrationReport {
        let sources = legacyBundleIdentifiers.compactMap { identifier -> (String, UserDefaults)? in
            guard let defaults = UserDefaults(suiteName: identifier) else { return nil }
            return (identifier, defaults)
        }
        return migrateIfNeeded(destination: destination, sources: sources)
    }

    /// 可注入偏好存储的核心实现，避免测试依赖当前机器真实的用户设置。
    @discardableResult
    static func migrateIfNeeded(
        destination: UserDefaults,
        sources: [(name: String, defaults: UserDefaults)]
    ) -> PreferencesMigrationReport {
        guard destination.integer(forKey: migrationVersionKey) < currentMigrationVersion else {
            return PreferencesMigrationReport()
        }

        var report = PreferencesMigrationReport()
        for key in migratedKeys where destination.object(forKey: key) == nil {
            guard let source = sources.first(where: { $0.defaults.object(forKey: key) != nil }),
                  let value = source.defaults.object(forKey: key) else { continue }
            destination.set(value, forKey: key)
            report.sourceDomains.insert(source.name)
            report.copiedKeys.insert(key)
        }
        destination.set(currentMigrationVersion, forKey: migrationVersionKey)
        return report
    }
}
