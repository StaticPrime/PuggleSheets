import AppKit
import PuggleSheetsKit

/// Shifting cells (Insert ▸ Cells, Edit ▸ Delete ▸ Cells) and Data ▸ Split text to columns and Data cleanup.
extension SpreadsheetController {
    // MARK: Shifting cells

    /// Why the cells of `range` can't shift (down or right when `vertical`), or nil when they can:
    /// merged cells that straddle the cells that move aren't split.
    func cellShiftProblem(_ range: CellRange, vertical: Bool) -> String? {
        let band = vertical
            ? CellRange(rows: range.start.row...max(range.start.row, sheet.rowCount - 1), columns: range.columns)
            : CellRange(rows: range.rows, columns: range.start.column...max(range.start.column, sheet.columnCount - 1))
        for merge in sheet.merges where merge.intersection(band) != nil && !band.contains(merge) {
            return "You can’t do that because it would break apart merged cells (\(merge.a1)). Unmerge them first."
        }
        return nil
    }

    /// Insert ▸ Cells: moves the selected cells, and the rest of their columns (or rows), down (or right).
    func insertCells(shiftDown: Bool) {
        let range = selection.current
        if let problem = cellShiftProblem(range, vertical: shiftDown) { return onProblem?(problem) ?? () }
        let band = shiftDown ? CellRange(rows: range.start.row...(sheet.rowCount - 1), columns: range.columns)
            : CellRange(rows: range.rows, columns: range.start.column...(sheet.columnCount - 1))
        guard protectionAllows(range: band) else { return }
        let index = activeSheetIndex
        performWorkbookEdit(actionName: "Insert Cells") { $0.apply(.insertCells(range, shiftDown: shiftDown), toSheet: index) }
    }

    /// Edit ▸ Delete ▸ Cells: removes the selected cells and pulls the cells below (or to the right) into their place.
    func deleteCells(shiftUp: Bool) {
        let range = selection.current
        if let problem = cellShiftProblem(range, vertical: shiftUp) { return onProblem?(problem) ?? () }
        let band = shiftUp ? CellRange(rows: range.start.row...(sheet.rowCount - 1), columns: range.columns)
            : CellRange(rows: range.rows, columns: range.start.column...(sheet.columnCount - 1))
        guard protectionAllows(range: band) else { return }
        let index = activeSheetIndex
        performWorkbookEdit(actionName: "Delete Cells", selection: GridSelection(range: range, active: range.start)) {
            $0.apply(.deleteCells(range, shiftUp: shiftUp), toSheet: index)
        }
    }

    // MARK: Split text to columns

    /// Separators Data ▸ Split text to columns offers. nil is "Detect automatically".
    static let splitSeparators: [(title: String, separator: String?)] = [
        ("Detect automatically", nil), ("Comma", ","), ("Semicolon", ";"), ("Period", "."), ("Space", " "),
    ]

    /// The separator most of the texts contain (comma, then semicolon, tab, pipe and space).
    static func detectSeparator(in texts: [String]) -> String? {
        var best: (separator: String, count: Int)?
        for candidate in [",", ";", "\t", "|", " "] {
            let count = texts.filter { $0.contains(candidate) }.count
            if count > 0, count > (best?.count ?? 0) { best = (candidate, count) }
        }
        return best?.separator
    }

    /// Why the selection can't be split, or nil.
    var splitProblem: String? {
        selection.ranges.count == 1 && selection.current.columnCount == 1 ? nil : "Select a single column of text to split."
    }

    /// Splits the text of the selected column at `separator` (detected when nil) into the columns to its right,
    /// replacing what's there. Returns the separator used, or nil when there was nothing to split.
    @discardableResult
    func splitTextToColumns(separator: String?) -> String? {
        guard splitProblem == nil else { return nil }
        let range = selection.current
        let column = range.start.column
        let sheet = self.sheet
        var texts: [(row: Int, text: String)] = []
        for row in range.rows {
            let cell = sheet[CellAddress(row: row, column: column)]
            guard cell.hasContent, cell.formula == nil else { continue }
            texts.append((row, CellDisplay.editText(for: cell)))
        }
        guard let used = separator ?? Self.detectSeparator(in: texts.map(\.text)) else { return nil }
        var updates: [CellAddress: Cell] = [:]
        var widest = 0
        for (row, text) in texts {
            let parts = text.components(separatedBy: used).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count > 1 else { continue }
            widest = max(widest, parts.count)
            for (offset, part) in parts.enumerated() {
                let address = CellAddress(row: row, column: column + offset)
                updates[address] = cell(forInput: part, replacing: updates[address] ?? sheet[address])
            }
        }
        guard !updates.isEmpty else { return nil }
        var changes: [WorkbookChange] = []
        if column + widest > sheet.columnCount {
            var layout = SheetLayout(sheet)
            layout.columnCount = column + widest
            changes.append(.layout(sheet: activeSheetID, layout))
        }
        changes.append(.cells(sheet: activeSheetID, updates))
        perform(changes, actionName: "Split Text to Columns")
        return used
    }

    // MARK: Data cleanup

    /// Data ▸ Data cleanup ▸ Remove duplicates: keeps the first of the rows of `range` whose values match in
    /// `columns` (ignoring case and formatting), moves the kept rows up and clears the rest.
    @discardableResult
    func removeDuplicates(in range: CellRange, columns: [Int], hasHeader: Bool) -> (removed: Int, remaining: Int) {
        let sheet = self.sheet
        let first = range.start.row + (hasHeader ? 1 : 0)
        guard first <= range.end.row, !columns.isEmpty else { return (0, 0) }
        var seen = Set<[String]>()
        var kept: [Int] = []
        for row in first...range.end.row {
            let key = columns.map { column -> String in
                let value = sheet.value(at: CellAddress(row: row, column: column))
                return CellDisplay.text(for: value, pattern: nil).text.lowercased()
            }
            if seen.insert(key).inserted { kept.append(row) }
        }
        let removed = range.end.row - first + 1 - kept.count
        guard removed > 0 else { return (0, kept.count) }
        var updates: [CellAddress: Cell] = [:]
        for (offset, row) in kept.enumerated() where first + offset != row {
            for column in range.columns {
                updates[CellAddress(row: first + offset, column: column)] = sheet[CellAddress(row: row, column: column)]
            }
        }
        for row in (first + kept.count)...range.end.row {
            for column in range.columns { updates[CellAddress(row: row, column: column)] = Cell() }
        }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Remove Duplicates",
                selection: GridSelection(range: CellRange(rows: range.start.row...(first + kept.count - 1), columns: range.columns),
                                         active: range.start))
        return (removed, kept.count)
    }

    /// Data ▸ Data cleanup ▸ Trim whitespace: removes leading, trailing and repeated spaces from the selected
    /// text. Returns how many cells changed.
    @discardableResult
    func trimWhitespace() -> Int {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for (address, cell) in sheet.cells(in: range) where cell.formula == nil {
                guard case .text(let text) = cell.value else { continue }
                let trimmed = Self.trimmed(text)
                guard trimmed != text else { continue }
                var copy = cell
                copy.value = .text(trimmed)
                updates[address] = copy
            }
        }
        guard !updates.isEmpty else { return 0 }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Trim Whitespace")
        return updates.count
    }

    static func trimmed(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
