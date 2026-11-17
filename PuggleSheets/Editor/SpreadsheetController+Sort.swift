import Foundation
import PuggleSheetsKit

extension SpreadsheetController {
    /// The sort order: numbers, then text (ignoring case), then booleans, then errors;
    /// empty cells always go last, whichever the direction.
    static func sortKey(_ value: CellValue) -> (rank: Int, number: Double, text: String) {
        switch value {
        case .number(let number): (0, number, "")
        case .text(let text): (1, 0, text)
        case .boolean(let boolean): (2, boolean ? 1 : 0, "")
        case .error: (3, 0, "")
        case .empty: (4, 0, "")
        }
    }

    static func precedes(_ a: CellValue, _ b: CellValue, ascending: Bool) -> Bool {
        let left = sortKey(a), right = sortKey(b)
        if left.rank == 4 || right.rank == 4 { return left.rank < right.rank }
        if left.rank != right.rank { return ascending ? left.rank < right.rank : left.rank > right.rank }
        if left.rank == 1 {
            let order = left.text.localizedStandardCompare(right.text)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return ascending ? left.number < right.number : left.number > right.number
    }

    /// Why `range` can't be sorted, or nil.
    func sortProblem(_ range: CellRange) -> String? {
        sheet.merges.contains { $0.intersects(range) } ? "You can’t sort a range that contains merged cells." : nil
    }

    /// Reorders the rows of `range` by the values in `column`. Formulas move with their rows and
    /// their relative references shift with them.
    func sort(_ range: CellRange, by column: Int, ascending: Bool) {
        guard range.rowCount > 1, sortProblem(range) == nil else { return }
        let rows = Array(range.rows)
        let order = rows.indices.sorted { a, b in
            let left = sheet[rows[a], column].value, right = sheet[rows[b], column].value
            if Self.precedes(left, right, ascending: ascending) { return true }
            if Self.precedes(right, left, ascending: ascending) { return false }
            return a < b
        }
        var updates: [CellAddress: Cell] = [:]
        for (target, source) in order.enumerated() where target != source {
            for column in range.columns {
                let cell = sheet[rows[source], column]
                updates[CellAddress(row: rows[target], column: column)] = translated(cell, rows: rows[target] - rows[source], columns: 0)
            }
        }
        guard !updates.isEmpty else { return }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Sort")
    }

    /// The rows Data ▸ Sort sheet reorders: everything below the frozen rows that has data.
    var sheetSortRange: CellRange? {
        guard let content = sheet.contentRange else { return nil }
        let first = sheet.frozenRows
        guard content.end.row > first else { return nil }
        return CellRange(rows: first...content.end.row, columns: 0...content.end.column)
    }
}
