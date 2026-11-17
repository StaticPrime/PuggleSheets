import Foundation

/// Positions along one axis of a sheet (its columns or its rows), in pixels at 100% zoom.
///
/// OpenDocument places shapes anchored to a cell as if no row or column were hidden; shapes anchored
/// to the page sit where they are drawn, with hidden rows and columns taking no space.
struct ODSAxisGeometry {
    private let defaultSize: Double
    /// Indexes whose size differs from the default, in order, with their size, start and the sum of
    /// the differences from the default up to and including them.
    private let overrides: [(index: Int, size: Double, start: Double, deltaAfter: Double)]

    init(defaultSize: Double, sizes: [Int: Double], hidden: Set<Int> = [], hiddenAsZero: Bool = false) {
        self.defaultSize = max(defaultSize, 0)
        var merged = sizes.filter { $0.key >= 0 }
        if hiddenAsZero {
            for index in hidden where index >= 0 { merged[index] = 0 }
        }
        var list: [(index: Int, size: Double, start: Double, deltaAfter: Double)] = []
        list.reserveCapacity(merged.count)
        var delta = 0.0
        for (index, size) in merged.sorted(by: { $0.key < $1.key }) where max(size, 0) != self.defaultSize {
            let size = max(size, 0)
            let start = Double(index) * self.defaultSize + delta
            delta += size - self.defaultSize
            list.append((index, size, start, delta))
        }
        overrides = list
    }

    /// The axis of a sheet's columns.
    static func columns(of sheet: Sheet, hiddenAsZero: Bool = false) -> ODSAxisGeometry {
        ODSAxisGeometry(defaultSize: sheet.defaultColumnWidth, sizes: sheet.columnWidths, hidden: sheet.hiddenColumns,
                        hiddenAsZero: hiddenAsZero)
    }

    /// The axis of a sheet's rows.
    static func rows(of sheet: Sheet, hiddenAsZero: Bool = false) -> ODSAxisGeometry {
        ODSAxisGeometry(defaultSize: sheet.defaultRowHeight, sizes: sheet.rowHeights, hidden: sheet.hiddenRows.union(sheet.filteredRows),
                        hiddenAsZero: hiddenAsZero)
    }

    /// The number of overrides with an index below `index`.
    private func overridesBefore(_ index: Int) -> Int {
        var low = 0, high = overrides.count
        while low < high {
            let middle = (low + high) / 2
            if overrides[middle].index < index { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func size(of index: Int) -> Double {
        let position = overridesBefore(index)
        if position < overrides.count, overrides[position].index == index { return overrides[position].size }
        return defaultSize
    }

    /// Where `index` starts.
    func start(of index: Int) -> Double {
        let count = overridesBefore(max(index, 0))
        let delta = count == 0 ? 0 : overrides[count - 1].deltaAfter
        return Double(max(index, 0)) * defaultSize + delta
    }

    /// Positions beyond this many pixels are taken as this far (rows of a billion pixels are far past any grid).
    static let farthest = 1e12

    /// The index holding `position`, and how far into it the position is.
    func locate(_ position: Double) -> (index: Int, offset: Double) {
        let position = position.isFinite ? min(max(position, 0), ODSAxisGeometry.farthest) : 0
        // The last override starting at or before the position.
        var low = 0, high = overrides.count
        while low < high {
            let middle = (low + high) / 2
            if overrides[middle].start <= position { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else {
            guard defaultSize > 0 else { return (0, position) }
            let index = Int((position / defaultSize).rounded(.down))
            return (index, position - Double(index) * defaultSize)
        }
        let item = overrides[low - 1]
        if position < item.start + item.size { return (item.index, position - item.start) }
        let rest = position - (item.start + item.size)
        guard defaultSize > 0 else { return (item.index + 1, rest) }
        let steps = Int((rest / defaultSize).rounded(.down))
        var index = item.index + 1 + steps
        var offset = rest - Double(steps) * defaultSize
        // Rounding must not step past the next override.
        if low < overrides.count, index >= overrides[low].index {
            index = overrides[low].index
            offset = max(0, position - overrides[low].start)
        }
        return (index, offset)
    }
}

/// A sheet's columns and rows together.
struct ODSSheetGeometry {
    let columns: ODSAxisGeometry
    let rows: ODSAxisGeometry

    init(_ sheet: Sheet, hiddenAsZero: Bool = false) {
        columns = .columns(of: sheet, hiddenAsZero: hiddenAsZero)
        rows = .rows(of: sheet, hiddenAsZero: hiddenAsZero)
    }

    /// The top-left corner of a cell.
    func origin(of cell: CellAddress) -> (x: Double, y: Double) {
        (columns.start(of: cell.column), rows.start(of: cell.row))
    }

    /// The cell holding a point, and the point's offset into it.
    func locate(x: Double, y: Double) -> (cell: CellAddress, offsetX: Double, offsetY: Double) {
        let column = columns.locate(x), row = rows.locate(y)
        return (CellAddress(row: row.index, column: column.index), column.offset, row.offset)
    }

    /// The cell holding an object's bottom-right corner and the corner's offset into it, as
    /// `table:end-cell-address`, `table:end-x` and `table:end-y` give it.
    func end(of anchor: ObjectAnchor) -> (cell: CellAddress, offsetX: Double, offsetY: Double) {
        let origin = origin(of: anchor.cell)
        return locate(x: origin.x + max(anchor.offsetX, 0) + max(anchor.width, 0), y: origin.y + max(anchor.offsetY, 0) + max(anchor.height, 0))
    }
}

/// Lengths for drawing attributes.
extension ODSLength {
    /// A length for `svg:x`, `svg:width` and the like: points, rounded to a thousandth.
    static func drawing(pixels: Double) -> String {
        let points = (max(0, pixels) * 0.75 * 1000).rounded() / 1000
        return XLSXValue.string(points) + "pt"
    }
}
