import CoreGraphics

/// Which tile is selected, and how keys move the selection through a grid.
struct SwitcherSelection: Equatable {
    let count: Int
    let columns: Int
    private(set) var index: Int

    /// Forward starts on the previous window (index 1), backward on the last one, so a quick
    /// ⌘Tab flips between the two most recent windows. When the first window isn't the active
    /// app's (`firstIsActive` false), it is the one you came from, so forward starts on it.
    init(count: Int, columns: Int, forward: Bool, firstIsActive: Bool = true) {
        self.count = max(0, count)
        self.columns = max(1, columns)
        if count <= 1 {
            index = 0
        } else if forward {
            index = firstIsActive ? 1 : 0
        } else {
            index = count - 1
        }
    }

    mutating func next() {
        guard count > 0 else { return }
        index = (index + 1) % count
    }

    mutating func previous() {
        guard count > 0 else { return }
        index = (index - 1 + count) % count
    }

    mutating func select(_ newIndex: Int) {
        guard (0 ..< count).contains(newIndex) else { return }
        index = newIndex
    }

    /// Left/right step through the list; up/down keep the column and wrap rows, landing on the
    /// last tile when the target row is too short.
    mutating func move(_ direction: SwitcherDirection) {
        switch direction {
        case .left: previous()
        case .right: next()
        case .up, .down:
            guard count > 0 else { return }
            let rows = SwitcherLayout.rows(count: count, columns: columns)
            guard rows > 1 else { return }
            let row = index / columns
            let column = index % columns
            let step = direction == .down ? 1 : rows - 1
            index = min(((row + step) % rows) * columns + column, count - 1)
        }
    }
}

/// Geometry of the switcher panel. Tiles are a fixed size, laid out left to right and top to
/// bottom, so the SwiftUI view and the mouse hit-testing share these numbers.
enum SwitcherLayout {
    static let tileSize = CGSize(width: 200, height: 150)
    static let tileInset: CGFloat = 10
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 16
    static let titleSpacing: CGFloat = 12
    static let titleHeight: CGFloat = 18

    static var thumbnailSize: CGSize {
        CGSize(width: tileSize.width - tileInset * 2, height: tileSize.height - tileInset * 2)
    }

    /// Tiles per row: all of them if they fit, otherwise as many as fit (at least one).
    static func columns(count: Int, availableWidth: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let usable = availableWidth - padding * 2 + spacing
        let fit = max(1, Int(usable / (tileSize.width + spacing)))
        return min(count, fit)
    }

    /// Rows that fit in `availableHeight`, leaving room for the title line (at least one).
    static func maxRows(availableHeight: CGFloat) -> Int {
        let usable = availableHeight - padding * 2 - titleSpacing - titleHeight + spacing
        return max(1, Int(usable / (tileSize.height + spacing)))
    }

    static func rows(count: Int, columns: Int) -> Int {
        let columns = max(1, columns)
        return max(1, (count + columns - 1) / columns)
    }

    static func gridSize(count: Int, columns: Int) -> CGSize {
        let columns = CGFloat(max(1, columns))
        let rows = CGFloat(rows(count: count, columns: Int(columns)))
        return CGSize(
            width: columns * tileSize.width + (columns - 1) * spacing,
            height: rows * tileSize.height + (rows - 1) * spacing
        )
    }

    static func panelSize(count: Int, columns: Int) -> CGSize {
        let grid = gridSize(count: count, columns: columns)
        return CGSize(
            width: grid.width + padding * 2,
            height: grid.height + padding * 2 + titleSpacing + titleHeight
        )
    }

    /// The tile under `point`, measured from the panel's top-left corner, or nil for padding,
    /// gaps and empty cells.
    static func tileIndex(at point: CGPoint, columns: Int, count: Int) -> Int? {
        let x = point.x - padding
        let y = point.y - padding
        guard x >= 0, y >= 0, columns > 0 else { return nil }
        let strideX = tileSize.width + spacing
        let strideY = tileSize.height + spacing
        let column = Int(x / strideX)
        let row = Int(y / strideY)
        guard column < columns,
              x - CGFloat(column) * strideX < tileSize.width,
              y - CGFloat(row) * strideY < tileSize.height else { return nil }
        let index = row * columns + column
        return index < count ? index : nil
    }
}
