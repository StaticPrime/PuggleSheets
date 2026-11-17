import Foundation
import PuggleSheetsKit

/// The selected cells of one sheet: one or more ranges and the active cell, which receives typing.
struct GridSelection: Equatable {
    /// The cell that typing goes into.
    var active: CellAddress
    /// The corner the last range grows from with Shift-click and Shift-arrow.
    var anchor: CellAddress
    /// Selected ranges, oldest first; the last one contains `active`.
    var ranges: [CellRange]

    init(_ address: CellAddress) {
        active = address
        anchor = address
        ranges = [CellRange(address)]
    }

    init(range: CellRange, active: CellAddress? = nil) {
        self.active = active ?? range.start
        anchor = range.start
        ranges = [range]
    }

    var current: CellRange { ranges.last ?? CellRange(active) }
    var isSingleCell: Bool { ranges.count == 1 && current.isSingleCell }

    func contains(_ address: CellAddress) -> Bool { ranges.contains { $0.contains(address) } }

    /// The smallest range covering every selected range.
    var bounds: CellRange { ranges.dropFirst().reduce(ranges[0]) { $0.union($1) } }

    /// Whole rows are selected when a range spans every column.
    func selectsWholeRows(columnCount: Int) -> Bool {
        ranges.allSatisfy { $0.start.column == 0 && $0.end.column >= columnCount - 1 }
    }

    func selectsWholeColumns(rowCount: Int) -> Bool {
        ranges.allSatisfy { $0.start.row == 0 && $0.end.row >= rowCount - 1 }
    }

    /// Grows `range` until no merged block sticks out of it.
    static func expanding(_ range: CellRange, toInclude merges: [CellRange]) -> CellRange {
        var result = range
        var changed = true
        while changed {
            changed = false
            for merge in merges where merge.intersects(result) && !result.contains(merge) {
                result = result.union(merge)
                changed = true
            }
        }
        return result
    }

    /// Clamps every range to a sheet of the given size.
    func clamped(rowCount: Int, columnCount: Int) -> GridSelection {
        func clamp(_ address: CellAddress) -> CellAddress {
            CellAddress(row: min(max(address.row, 0), rowCount - 1), column: min(max(address.column, 0), columnCount - 1))
        }
        var result = self
        result.active = clamp(active)
        result.anchor = clamp(anchor)
        result.ranges = ranges.map { CellRange(clamp($0.start), clamp($0.end)) }
        return result
    }
}
