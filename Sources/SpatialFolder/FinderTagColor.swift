import Foundation

/// Finder 标签把显示名称和颜色编号编码为“名称\n编号”。
/// 名称可以由用户修改，因此颜色筛选必须优先依据编号，而不是本地化名称。
enum FinderTagColor: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    static let displayOrder: [FinderTagColor] = [
        .red, .orange, .yellow, .green, .blue, .purple, .gray
    ]

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .gray: "灰色"
        }
    }

    var encodedValue: String { "\(title)\n\(rawValue)" }

    init?(finderTag: String) {
        let components = finderTag.components(separatedBy: "\n")
        if components.count > 1,
           let color = components.dropFirst().reversed().lazy.compactMap({ component in
               Int(component).flatMap(FinderTagColor.init(rawValue:))
           }).first {
            self = color
            return
        }

        switch components.first?.lowercased() {
        case "红色", "red": self = .red
        case "橙色", "orange": self = .orange
        case "黄色", "yellow": self = .yellow
        case "绿色", "green": self = .green
        case "蓝色", "blue": self = .blue
        case "紫色", "purple": self = .purple
        case "灰色", "gray", "grey": self = .gray
        default: return nil
        }
    }
}

struct CanvasItemFilter: Equatable, Sendable {
    var query = ""
    var tagColors: Set<FinderTagColor> = []
    var includesUntagged = false

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !tagColors.isEmpty || includesUntagged
    }

    func matches(_ item: FolderItem) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesQuery = normalizedQuery.isEmpty ||
            item.name.localizedCaseInsensitiveContains(normalizedQuery) ||
            item.tags.contains {
                normalizedTagName($0).localizedCaseInsensitiveContains(normalizedQuery)
            }
        guard matchesQuery else { return false }

        guard !tagColors.isEmpty || includesUntagged else { return true }
        if item.tags.isEmpty { return includesUntagged }
        return item.tags.contains { tag in
            FinderTagColor(finderTag: tag).map(tagColors.contains) ?? false
        }
    }

    private func normalizedTagName(_ tag: String) -> String {
        tag.components(separatedBy: "\n").first ?? tag
    }
}
