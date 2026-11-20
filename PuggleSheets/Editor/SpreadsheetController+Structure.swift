import AppKit
import PuggleSheetsKit

extension SpreadsheetController {
    // MARK: Selected rows and columns

    /// Every row touched by the selection, sorted.
    var selectedRows: [Int] {
        Array(Set(selection.ranges.flatMap { Array($0.rows) })).sorted()
    }

    var selectedColumns: [Int] {
        Array(Set(selection.ranges.flatMap { Array($0.columns) })).sorted()
    }

    /// Consecutive runs, e.g. [1, 2, 3, 7] → [1...3, 7...7].
    static func runs(_ indexes: [Int]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for index in indexes.sorted() {
            if let last = runs.last, last.upperBound + 1 == index {
                runs[runs.count - 1] = last.lowerBound...index
            } else {
                runs.append(index...index)
            }
        }
        return runs
    }

    // MARK: Inserting and deleting

    /// Inserting at `index` splits any protected range across it.
    private func protectionAllowsInsert(at index: Int, rows: Bool) -> Bool {
        let protected = sheet.protections.contains { protection in
            switch protection.scope {
            case .range(let range): rows ? (range.start.row < index && index <= range.end.row) : (range.start.column < index && index <= range.end.column)
            case .sheet: true
            }
        }
        guard protected else { return true }
        let line = rows ? CellRange(rows: min(index, sheet.rowCount - 1)...min(index, sheet.rowCount - 1), columns: 0...(sheet.columnCount - 1))
            : CellRange(rows: 0...(sheet.rowCount - 1), columns: min(index, sheet.columnCount - 1)...min(index, sheet.columnCount - 1))
        return protectionAllows(range: line)
    }

    func insertRows(above: Bool) {
        let range = selection.current
        let count = range.rowCount
        let at = above ? range.start.row : range.end.row + 1
        guard protectionAllowsInsert(at: at, rows: true) else { return }
        var moved = selection
        if above {
            moved.active = moved.active.offsetBy(rows: count)
            moved.anchor = moved.anchor.offsetBy(rows: count)
            moved.ranges = moved.ranges.map { $0.start.row >= at ? $0.offsetBy(rows: count) : $0 }
        }
        performOps([.structure(sheet: activeSheetID, change: .insertRows(at: at, count: count))],
                   actionName: count == 1 ? "Insert Row" : "Insert Rows", selection: moved)
    }

    func insertColumns(left: Bool) {
        let range = selection.current
        let count = range.columnCount
        let at = left ? range.start.column : range.end.column + 1
        guard protectionAllowsInsert(at: at, rows: false) else { return }
        var moved = selection
        if left {
            moved.active = moved.active.offsetBy(columns: count)
            moved.anchor = moved.anchor.offsetBy(columns: count)
            moved.ranges = moved.ranges.map { $0.start.column >= at ? $0.offsetBy(columns: count) : $0 }
        }
        performOps([.structure(sheet: activeSheetID, change: .insertColumns(at: at, count: count))],
                   actionName: count == 1 ? "Insert Column" : "Insert Columns", selection: moved)
    }

    /// False when the selection covers every row (a sheet keeps at least one).
    var canDeleteRows: Bool { selectedRows.count < sheet.rowCount }
    var canDeleteColumns: Bool { selectedColumns.count < sheet.columnCount }

    func deleteSelectedRows() {
        let rows = selectedRows
        guard !rows.isEmpty, canDeleteRows else { return }
        for run in Self.runs(rows) {
            guard protectionAllows(range: CellRange(rows: run, columns: 0...(sheet.columnCount - 1))) else { return }
        }
        let remaining = sheet.rowCount - rows.count
        let next = GridSelection(CellAddress(row: min(rows[0], remaining - 1), column: selection.active.column))
        let id = activeSheetID
        performOps(Self.runs(rows).reversed().map { .structure(sheet: id, change: .deleteRows(at: $0.lowerBound, count: $0.count)) },
                   actionName: rows.count == 1 ? "Delete Row" : "Delete Rows", selection: next)
    }

    func deleteSelectedColumns() {
        let columns = selectedColumns
        guard !columns.isEmpty, canDeleteColumns else { return }
        for run in Self.runs(columns) {
            guard protectionAllows(range: CellRange(rows: 0...(sheet.rowCount - 1), columns: run)) else { return }
        }
        let remaining = sheet.columnCount - columns.count
        let next = GridSelection(CellAddress(row: selection.active.row, column: min(columns[0], remaining - 1)))
        let id = activeSheetID
        performOps(Self.runs(columns).reversed().map { .structure(sheet: id, change: .deleteColumns(at: $0.lowerBound, count: $0.count)) },
                   actionName: columns.count == 1 ? "Delete Column" : "Delete Columns", selection: next)
    }

    /// The "Add more rows at the bottom" button.
    func addRowsAtBottom(_ count: Int) {
        performLayoutEdit(actionName: "Add Rows") { $0.rowCount += count }
    }

    // MARK: Sizes

    func setColumnWidths(_ widths: [Int: Double], actionName: String = "Resize Columns") {
        performLayoutEdit(actionName: actionName) { layout in
            for (column, width) in widths {
                let width = min(max(width.rounded(), 2), 2000)
                layout.columnWidths[column] = width == layout.defaultColumnWidth ? nil : width
            }
        }
    }

    func setRowHeights(_ heights: [Int: Double], actionName: String = "Resize Rows") {
        performLayoutEdit(actionName: actionName) { layout in
            for (row, height) in heights {
                let height = min(max(height.rounded(), 2), 2000)
                layout.rowHeights[row] = height == layout.defaultRowHeight ? nil : height
            }
        }
    }

    func hideRows(_ rows: [Int]) {
        guard rows.count < sheet.rowCount - sheet.hiddenRows.count else { return }
        performLayoutEdit(actionName: rows.count == 1 ? "Hide Row" : "Hide Rows") { $0.hiddenRows.formUnion(rows) }
    }

    func hideColumns(_ columns: [Int]) {
        guard columns.count < sheet.columnCount - sheet.hiddenColumns.count else { return }
        performLayoutEdit(actionName: columns.count == 1 ? "Hide Column" : "Hide Columns") { $0.hiddenColumns.formUnion(columns) }
    }

    /// Unhides hidden rows inside the selection (or right next to it).
    func unhideRows() {
        let rows = selectedRows
        guard let first = rows.first, let last = rows.last else { return }
        performLayoutEdit(actionName: "Unhide Rows") { layout in
            layout.hiddenRows = layout.hiddenRows.filter { $0 < first - 1 || $0 > last + 1 }
        }
    }

    func unhideColumns() {
        let columns = selectedColumns
        guard let first = columns.first, let last = columns.last else { return }
        performLayoutEdit(actionName: "Unhide Columns") { layout in
            layout.hiddenColumns = layout.hiddenColumns.filter { $0 < first - 1 || $0 > last + 1 }
        }
    }

    var selectionTouchesHiddenRows: Bool {
        let rows = selectedRows
        guard let first = rows.first, let last = rows.last else { return false }
        return sheet.hiddenRows.contains { $0 >= first - 1 && $0 <= last + 1 }
    }

    var selectionTouchesHiddenColumns: Bool {
        let columns = selectedColumns
        guard let first = columns.first, let last = columns.last else { return false }
        return sheet.hiddenColumns.contains { $0 >= first - 1 && $0 <= last + 1 }
    }

    // MARK: View options

    /// View ▸ Freeze. nil leaves that axis alone.
    func freeze(rows: Int?, columns: Int?) {
        performLayoutEdit(actionName: "Freeze") { layout in
            if let rows { layout.frozenRows = min(max(rows, 0), layout.rowCount - 1) }
            if let columns { layout.frozenColumns = min(max(columns, 0), layout.columnCount - 1) }
        }
    }

    func toggleGridlines() {
        performLayoutEdit(actionName: "Gridlines") { $0.showsGridlines.toggle() }
    }

    // MARK: Sheets

    func addSheet() {
        let new = Sheet(name: workbook.newSheetName())
        performOps([.insertSheet(sheet: new, at: workbook.sheets.count)], actionName: "Add Sheet", showing: new.id)
    }

    func duplicateSheet(id: UUID) {
        guard let index = workbook.sheetIndex(id: id) else { return }
        let original = workbook.sheets[index]
        var copy = Sheet(name: workbook.copyName(for: original.name), rowCount: original.rowCount, columnCount: original.columnCount)
        SheetLayout(original).apply(to: &copy)
        // The copy's comments are discussions of their own, apart from the original's.
        copy.setCells(original.cells.mapValues { cell in
            var cell = cell
            cell.comment = cell.comment?.copiedAnew()
            return cell
        })
        performOps([.insertSheet(sheet: copy, at: index + 1)], actionName: "Duplicate Sheet", showing: copy.id)
    }

    func deleteSheet(id: UUID) {
        guard workbook.sheets.count > 1, let index = workbook.sheetIndex(id: id) else { return }
        let neighbor = workbook.sheets[index == workbook.sheets.count - 1 ? index - 1 : index + 1].id
        performOps([.removeSheet(sheet: id)], actionName: "Delete Sheet", showing: neighbor)
    }

    /// Why `name` can't be used for the sheet, or nil when it can.
    func problem(renaming id: UUID, to name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Please enter a valid sheet name." }
        if trimmed.count > 100 { return "Sheet names can’t be longer than 100 characters." }
        if let existing = workbook.sheetIndex(named: trimmed), workbook.sheets[existing].id != id {
            return "A sheet with the name “\(trimmed)” already exists. Please enter another name."
        }
        if trimmed.contains(where: { "[]:*?/\\".contains($0) }) {
            return "Sheet names can’t contain [ ] : * ? / or \\ (Excel doesn’t allow them)."
        }
        return nil
    }

    func renameSheet(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard problem(renaming: id, to: trimmed) == nil, let index = workbook.sheetIndex(id: id),
              workbook.sheets[index].name != trimmed else { return }
        performOps([.renameSheet(sheet: id, name: trimmed)], actionName: "Rename Sheet")
    }

    func moveSheet(id: UUID, by offset: Int) {
        guard let index = workbook.sheetIndex(id: id) else { return }
        let destination = index + offset
        guard destination >= 0, destination < workbook.sheets.count else { return }
        performOps([.moveSheet(sheet: id, to: destination)], actionName: "Move Sheet")
    }

    func setTabColor(id: UUID, _ color: RGBColor?) {
        guard let index = workbook.sheetIndex(id: id) else { return }
        var layout = SheetLayout(workbook.sheets[index])
        guard layout.tabColor != color else { return }
        layout.tabColor = color
        perform([.layout(sheet: id, layout)], actionName: "Tab Color")
    }
}
