import Foundation

/// Rows, columns or cells inserted or deleted in one sheet.
public enum StructuralChange: Hashable, Sendable, Codable {
    case insertRows(at: Int, count: Int)
    case deleteRows(at: Int, count: Int)
    case insertColumns(at: Int, count: Int)
    case deleteColumns(at: Int, count: Int)
    /// Insert ▸ Cells: blank cells take the range's place, and the cells there and beyond move down
    /// (within the range's columns) or right (within its rows).
    case insertCells(CellRange, shiftDown: Bool)
    /// Delete ▸ Cells: the range goes, and the cells beyond it move up (within its columns) or left
    /// (within its rows).
    case deleteCells(CellRange, shiftUp: Bool)

    /// Whether things move up and down (rows) rather than sideways (columns).
    public var affectsRows: Bool {
        switch self {
        case .insertRows, .deleteRows: true
        case .insertColumns, .deleteColumns: false
        case .insertCells(_, let down): down
        case .deleteCells(_, let up): up
        }
    }

    /// For cell shifts, the columns (shifting up or down) or rows (shifting sideways) whose cells move;
    /// nil when whole rows or columns change.
    public var band: ClosedRange<Int>? {
        switch self {
        case .insertRows, .deleteRows, .insertColumns, .deleteColumns: nil
        case .insertCells(let range, let down), .deleteCells(let range, let down): down ? range.columns : range.rows
        }
    }

    /// The row or column insertion or deletion that happens inside the band (itself for whole rows or columns).
    public var axisChange: StructuralChange {
        switch self {
        case .insertRows, .deleteRows, .insertColumns, .deleteColumns:
            self
        case .insertCells(let range, let down):
            down ? .insertRows(at: range.start.row, count: range.rowCount) : .insertColumns(at: range.start.column, count: range.columnCount)
        case .deleteCells(let range, let up):
            up ? .deleteRows(at: range.start.row, count: range.rowCount) : .deleteColumns(at: range.start.column, count: range.columnCount)
        }
    }

    /// Where an index along the changed axis ends up (inside the band, for cell shifts); nil when deleted.
    public func map(_ index: Int) -> Int? {
        switch axisChange {
        case .insertRows(let at, let count), .insertColumns(let at, let count):
            return index >= at ? index + count : index
        case .deleteRows(let at, let count), .deleteColumns(let at, let count):
            if index < at { return index }
            return index >= at + count ? index - count : nil
        case .insertCells, .deleteCells:
            return index
        }
    }

    /// The surviving span of `lower...upper` along the changed axis (inside the band, for cell shifts).
    /// An insertion inside the span widens it.
    public func map(_ lower: Int, _ upper: Int) -> ClosedRange<Int>? {
        switch axisChange {
        case .insertRows(let at, let count), .insertColumns(let at, let count):
            if at <= lower { return (lower + count)...(upper + count) }
            if at <= upper { return lower...(upper + count) }
            return lower...upper
        case .deleteRows(let at, let count), .deleteColumns(let at, let count):
            let end = at + count
            if upper < at { return lower...upper }
            if lower >= end { return (lower - count)...(upper - count) }
            let newLower = lower < at ? lower : at
            let newUpper = upper >= end ? upper - count : at - 1
            return newLower <= newUpper ? newLower...newUpper : nil
        case .insertCells, .deleteCells:
            return lower...upper
        }
    }

    /// Where a cell ends up; nil when it was deleted.
    public func map(_ address: CellAddress) -> CellAddress? {
        let rows = affectsRows
        if let band, !band.contains(rows ? address.column : address.row) { return address }
        guard let index = map(rows ? address.row : address.column) else { return nil }
        return rows ? CellAddress(row: index, column: address.column) : CellAddress(row: address.row, column: index)
    }

    /// Where a range ends up: moved, widened or shrunk, or nil when all of it was deleted. For cell
    /// shifts, a range that isn't entirely inside the band stays where it is.
    public func map(_ range: CellRange) -> CellRange? {
        let rows = affectsRows
        if let band {
            let across = rows ? range.columns : range.rows
            guard band.contains(across.lowerBound), band.contains(across.upperBound) else { return range }
        }
        guard let span = rows ? map(range.start.row, range.end.row) : map(range.start.column, range.end.column) else { return nil }
        return rows ? CellRange(rows: span, columns: range.columns) : CellRange(rows: range.rows, columns: span)
    }
}
