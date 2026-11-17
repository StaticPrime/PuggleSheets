import Foundation

/// A sheet's cells the way files store them: typed cells and formulas, the values array formulas
/// spill into neighboring cells (which other apps show only if they're written as cached values), and
/// the fills of alternating colors (which files can't express as a rule).
struct SheetExport {
    struct Entry {
        var value: CellValue
        var formula: String?
        var format: CellFormat
        /// For a formula whose result spills: the whole block it covers, its own cell included.
        var spillRange: CellRange?
        /// A value spilled from another cell's formula.
        var isSpilled = false

        var hasContent: Bool { formula != nil || value != .empty }
    }

    /// Entries in row-major order.
    let entries: [(address: CellAddress, entry: Entry)]

    /// Cells outside `0..<rowLimit` × `0..<columnLimit` are left out.
    init(_ sheet: Sheet, rowLimit: Int, columnLimit: Int) {
        func inside(_ address: CellAddress) -> Bool {
            address.row >= 0 && address.column >= 0 && address.row < rowLimit && address.column < columnLimit
        }
        var map: [CellAddress: Entry] = [:]
        map.reserveCapacity(sheet.cells.count + sheet.spilledValues.count)
        for (address, cell) in sheet.cells where inside(address) {
            var spill: CellRange?
            if cell.formula != nil, let range = sheet.spillRanges[address], !range.isSingleCell, range.start == address,
               inside(range.end) {
                spill = range
            }
            map[address] = Entry(value: cell.value, formula: cell.formula, format: cell.format, spillRange: spill)
        }
        for (address, value) in sheet.spilledValues where inside(address) && value != .empty {
            if var entry = map[address] {
                guard !entry.hasContent else { continue }
                entry.value = value
                entry.isSpilled = true
                map[address] = entry
            } else {
                map[address] = Entry(value: value, formula: nil, format: CellFormat(), isSpilled: true)
            }
        }
        // Alternating colors become fills, except where a cell has its own. The work is bounded for
        // bands over whole columns of huge sheets.
        var budget = 2_000_000
        for banding in sheet.bandings {
            guard let range = banding.range.intersection(CellRange(rows: 0...max(0, rowLimit - 1), columns: 0...max(0, columnLimit - 1))),
                  range.cellCount <= budget else { continue }
            budget -= range.cellCount
            for row in range.rows {
                guard let color = banding.color(forRow: row) else { continue }
                for column in range.columns {
                    let address = CellAddress(row: row, column: column)
                    if var entry = map[address] {
                        guard entry.format.fillColor == nil else { continue }
                        entry.format.fillColor = color
                        map[address] = entry
                    } else {
                        var format = CellFormat()
                        format.fillColor = color
                        map[address] = Entry(value: .empty, formula: nil, format: format)
                    }
                }
            }
        }
        entries = map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The smallest range holding every entry.
    var usedRange: CellRange? {
        guard let first = entries.first else { return nil }
        var top = first.address.row, bottom = first.address.row, left = first.address.column, right = first.address.column
        for (address, _) in entries {
            top = min(top, address.row)
            bottom = max(bottom, address.row)
            left = min(left, address.column)
            right = max(right, address.column)
        }
        return CellRange(rows: top...bottom, columns: left...right)
    }
}
