import Foundation

struct CanvasLayoutItem: Equatable, Sendable {
    var id: String
    var scale: CGFloat
}

struct CanvasPlacementResult: Equatable, Sendable {
    var positions: [String: CanvasPoint]
    var inboxIDs: Set<String>
    var placedIDs: [String]
}

/// 纯坐标引擎：不访问磁盘、不发布 UI 状态。主模型只负责把输入快照交给它并应用结果。
struct CanvasLayoutEngine: Sendable {
    let capacity: Int
    let columns: Int
    let grid: CGFloat

    init(capacity: Int = 64, columns: Int = 8, grid: CGFloat = 24) {
        self.capacity = capacity
        self.columns = columns
        self.grid = grid
    }

    func initialLayout(for items: [CanvasLayoutItem], canvasSize: CGSize) -> CanvasPlacementResult {
        var positions: [String: CanvasPoint] = [:]
        var inbox = Set<String>()
        for (index, item) in items.enumerated() {
            if index < capacity {
                positions[item.id] = gridPoint(for: index, scale: item.scale, canvasSize: canvasSize)
            } else {
                inbox.insert(item.id)
            }
        }
        return CanvasPlacementResult(
            positions: positions,
            inboxIDs: inbox,
            placedIDs: Array(items.prefix(capacity).map(\.id))
        )
    }

    /// 新项目使用第一个空网格；已有项目的位置不会参与重排。
    func assignNewItems(
        _ items: [CanvasLayoutItem],
        positions: [String: CanvasPoint],
        inboxIDs: Set<String>,
        canvasSize: CGSize
    ) -> CanvasPlacementResult {
        var resultPositions = positions
        var resultInbox = inboxIDs
        var active = items.filter { !resultInbox.contains($0.id) && resultPositions[$0.id] != nil }
        var placed: [String] = []
        for item in items where resultPositions[item.id] == nil && !resultInbox.contains(item.id) {
            if active.count < capacity,
               let point = nextAvailableGridPoint(
                   for: item,
                   activeItems: active,
                   positions: resultPositions,
                   canvasSize: canvasSize
               ) {
                resultPositions[item.id] = point
                active.append(item)
                placed.append(item.id)
            } else {
                resultInbox.insert(item.id)
            }
        }
        return CanvasPlacementResult(positions: resultPositions, inboxIDs: resultInbox, placedIDs: placed)
    }

    /// 外部拖入从鼠标落点附近开始寻找最近空网格。多个项目按“由近到远、由上到下、由左到右”
    /// 稳定排列；没有空间时只把溢出项目送入待放置区，不挪动任何已有图标。
    func placeImportedItems(
        _ importedItems: [CanvasLayoutItem],
        near requestedPoint: CGPoint,
        existingItems: [CanvasLayoutItem],
        positions: [String: CanvasPoint],
        inboxIDs: Set<String>,
        canvasSize: CGSize
    ) -> CanvasPlacementResult {
        let importedIDs = Set(importedItems.map(\.id))
        var resultPositions = positions.filter { !importedIDs.contains($0.key) }
        var resultInbox = inboxIDs.subtracting(importedIDs)
        var occupied = existingItems
            .filter { !importedIDs.contains($0.id) && !resultInbox.contains($0.id) }
            .compactMap { item -> CGRect? in
                guard let point = resultPositions[item.id] else { return nil }
                return iconRect(at: point, scale: item.scale)
            }
        var placed: [String] = []

        for item in importedItems {
            let candidates = (0..<capacity)
                .map { gridPoint(for: $0, scale: item.scale, canvasSize: canvasSize) }
                .sorted { lhs, rhs in
                    let leftDistance = squaredDistance(lhs, requestedPoint)
                    let rightDistance = squaredDistance(rhs, requestedPoint)
                    if leftDistance != rightDistance { return leftDistance < rightDistance }
                    if lhs.y != rhs.y { return lhs.y < rhs.y }
                    return lhs.x < rhs.x
                }
            guard occupied.count < capacity,
                  let point = candidates.first(where: { candidate in
                      let rect = iconRect(at: candidate, scale: item.scale).insetBy(dx: -4, dy: -4)
                      return !occupied.contains(where: { $0.intersects(rect) })
                  }) else {
                resultInbox.insert(item.id)
                continue
            }
            resultPositions[item.id] = point
            occupied.append(iconRect(at: point, scale: item.scale))
            placed.append(item.id)
        }
        return CanvasPlacementResult(positions: resultPositions, inboxIDs: resultInbox, placedIDs: placed)
    }

    func snapped(_ point: CGPoint, scale: CGFloat, canvasSize: CGSize) -> CanvasPoint {
        let halfWidth = max(grid, 52 * scale)
        let halfHeight = max(grid, 48 * scale)
        let maximumX = max(halfWidth, canvasSize.width - halfWidth)
        let maximumY = max(halfHeight, canvasSize.height - halfHeight)
        let snappedX = (point.x / grid).rounded() * grid
        let snappedY = (point.y / grid).rounded() * grid
        return CanvasPoint(
            x: min(maximumX, max(halfWidth, snappedX)),
            y: min(maximumY, max(halfHeight, snappedY))
        )
    }

    func gridPoint(for index: Int, scale: CGFloat, canvasSize: CGSize) -> CanvasPoint {
        let column = index % columns
        let row = index / columns
        let cellWidth = canvasSize.width / CGFloat(columns)
        let cellHeight = canvasSize.height / CGFloat(columns)
        return snapped(
            CGPoint(
                x: cellWidth * (CGFloat(column) + 0.5),
                y: cellHeight * (CGFloat(row) + 0.5)
            ),
            scale: scale,
            canvasSize: canvasSize
        )
    }

    func iconRect(at point: CanvasPoint, scale: CGFloat) -> CGRect {
        let halfWidth = 52 * scale
        let halfHeight = 48 * scale
        return CGRect(
            x: point.x - halfWidth,
            y: point.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    func isInsideBounds(_ point: CanvasPoint, scale: CGFloat, canvasSize: CGSize) -> Bool {
        let rect = iconRect(at: point, scale: scale)
        return rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= canvasSize.width && rect.maxY <= canvasSize.height
    }

    private func nextAvailableGridPoint(
        for item: CanvasLayoutItem,
        activeItems: [CanvasLayoutItem],
        positions: [String: CanvasPoint],
        canvasSize: CGSize
    ) -> CanvasPoint? {
        let occupied = activeItems.compactMap { active -> CGRect? in
            guard let point = positions[active.id] else { return nil }
            return iconRect(at: point, scale: active.scale)
        }
        return (0..<capacity).lazy
            .map { gridPoint(for: $0, scale: item.scale, canvasSize: canvasSize) }
            .first { point in
                let candidate = iconRect(at: point, scale: item.scale).insetBy(dx: -4, dy: -4)
                return !occupied.contains(where: { $0.intersects(candidate) })
            }
    }

    private func squaredDistance(_ point: CanvasPoint, _ requested: CGPoint) -> CGFloat {
        let dx = point.x - requested.x
        let dy = point.y - requested.y
        return dx * dx + dy * dy
    }
}
