import AppKit
import PuggleSheetsKit

/// Phase 5's edits: tables (Format ▸ Convert to table) and slicers (Data ▸ Add a slicer).
extension SpreadsheetController {
    // MARK: Filtering

    /// Applies an edit to filters, tables or slicers and hides, on every sheet, the rows that the sheet's
    /// filter, its tables and the slicers over it now reject, as one undoable step.
    func performFilterEdit(actionName: String, selection after: GridSelection? = nil, _ edit: (inout Workbook) -> Void) {
        var copy = workbook
        edit(&copy)
        let slicedSheets = Set(copy.sheets.enumerated().flatMap { index, sheet in
            sheet.objects.compactMap { $0.slicer }.compactMap { copy.resolve($0.range, onSheet: index)?.sheet }
        })
        var changes: [WorkbookChange] = []
        for index in copy.sheets.indices {
            var sheet = copy.sheets[index]
            if sheet.filter != nil || !sheet.tables.isEmpty || slicedSheets.contains(index) || !sheet.filteredRows.isEmpty {
                sheet.filteredRows = RuleEvaluator.filteredRows(sheetIndex: index, workbook: copy)
            }
            let layout = SheetLayout(sheet)
            if index < workbook.sheets.count, workbook.sheets[index].id == sheet.id, layout != SheetLayout(workbook.sheets[index]) {
                changes.append(.layout(sheet: sheet.id, layout))
            }
        }
        guard !changes.isEmpty else { return }
        perform(changes, actionName: actionName, selection: after)
    }

    // MARK: Tables

    /// "Table1", "Table2", … : the first name no table or named range uses.
    func nextTableName() -> String {
        var number = 1
        while workbook.table(named: "Table\(number)") != nil || workbook.namedRange("Table\(number)") != nil { number += 1 }
        return "Table\(number)"
    }

    /// Why a table can't have this name, or nil.
    func problem(namingTable name: String, replacing id: UUID?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard NamedRange.isValidName(trimmed) else {
            return "Table names can contain only letters, numbers, underscores and periods, must start with a letter or underscore, and can’t look like a cell reference."
        }
        if let other = workbook.table(named: trimmed)?.table, other.id != id { return "A table named “\(other.name)” already exists." }
        if workbook.namedRange(trimmed) != nil { return "A named range called “\(trimmed)” already exists." }
        return nil
    }

    /// Format ▸ Convert to table: the selection (or the data around the active cell) becomes a table with
    /// its first row as headers. Checkbox, date, percent and currency columns get those types.
    @discardableResult
    func convertToTable() -> UUID? {
        let range = selection.current.isSingleCell ? dataRegion(around: selection.active) : selection.current
        if let other = sheet.tables.first(where: { $0.range.intersects(range) }) {
            onProblem?("These cells are already part of \(other.name). Tables can’t overlap.")
            return nil
        }
        if let merge = sheet.merges.first(where: { $0.intersects(range) }) {
            onProblem?("Tables can’t contain merged cells (\(merge.a1)). Unmerge them first.")
            return nil
        }
        var types: [Int: TableColumnType] = [:]
        if range.rowCount > 1 {
            for column in range.columns {
                let cells = ((range.start.row + 1)...range.end.row).map { sheet[CellAddress(row: $0, column: column)] }.filter(\.hasContent)
                guard !cells.isEmpty else { continue }
                if cells.allSatisfy({ if case .boolean = $0.value { true } else { false } }) {
                    types[column] = .checkbox
                } else if cells.allSatisfy({ $0.value.numberValue != nil }) {
                    switch NumberFormatPresets.kind(of: cells[0].format.numberFormat) {
                    case .date: types[column] = .date
                    case .percent: types[column] = .percent
                    case .currency: types[column] = .currency
                    default: break
                    }
                }
            }
        }
        let table = SheetTable(name: nextTableName(), range: range, columnTypes: types,
                               color: SheetTable.colors[sheet.tables.count % SheetTable.colors.count])
        var changes: [WorkbookChange] = []
        var layout = SheetLayout(sheet)
        layout.tables.append(table)
        // Checkbox columns get checkboxes for their data cells.
        for (column, type) in types where type == .checkbox {
            guard let data = table.dataRange else { continue }
            let cells = CellRange(rows: data.rows, columns: column...column)
            layout.validations.append(DataValidationRule(ranges: [cells], criterion: .checkbox(checked: nil, unchecked: nil)))
        }
        changes.append(.layout(sheet: activeSheetID, layout))
        perform(changes, actionName: "Convert to Table")
        return table.id
    }

    func updateTable(id: UUID, actionName: String = "Edit Table", _ change: (inout SheetTable) -> Void) {
        let sheetIndex = activeSheetIndex
        performFilterEdit(actionName: actionName) { workbook in
            guard let index = workbook.sheets[sheetIndex].tables.firstIndex(where: { $0.id == id }) else { return }
            change(&workbook.sheets[sheetIndex].tables[index])
        }
    }

    /// Renames a table (returns a problem instead when the name can't be used). Formulas follow.
    @discardableResult
    func renameTable(id: UUID, to name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let problem = problem(namingTable: trimmed, replacing: id) { return problem }
        guard let old = sheet.tables.first(where: { $0.id == id })?.name, old != trimmed else { return nil }
        let index = activeSheetIndex
        performWorkbookEdit(actionName: "Rename Table") { workbook in
            guard let tableIndex = workbook.sheets[index].tables.firstIndex(where: { $0.id == id }) else { return }
            workbook.sheets[index].tables[tableIndex].name = trimmed
            for sheetIndex in workbook.sheets.indices {
                var updates: [CellAddress: Cell] = [:]
                for (address, cell) in workbook.sheets[sheetIndex].cells {
                    guard let formula = cell.formula else { continue }
                    let rewritten = FormulaRewriter.renameTable(formula, from: old, to: trimmed)
                    if rewritten != formula {
                        var copy = cell
                        copy.formula = rewritten
                        updates[address] = copy
                    }
                }
                if !updates.isEmpty { workbook.sheets[sheetIndex].setCells(updates) }
            }
        }
        return nil
    }

    /// Removes a table but keeps its data and formatting ("Convert to range").
    func removeTable(id: UUID) {
        let sheetIndex = activeSheetIndex
        performFilterEdit(actionName: "Delete Table") { workbook in
            workbook.sheets[sheetIndex].tables.removeAll { $0.id == id }
        }
    }

    /// Sets a column's type: its data cells take the type's number format, and checkbox and dropdown
    /// columns get a data validation rule.
    func setTableColumnType(_ type: TableColumnType?, column: Int, tableID: UUID) {
        guard let table = sheet.tables.first(where: { $0.id == tableID }) else { return }
        var layout = SheetLayout(sheet)
        guard let index = layout.tables.firstIndex(where: { $0.id == tableID }) else { return }
        layout.tables[index].columnTypes[column] = type
        var updates: [CellAddress: Cell] = [:]
        if let data = table.dataRange {
            let cells = CellRange(rows: data.rows, columns: column...column)
            layout.validations.removeAll { $0.ranges == [cells] }
            switch type {
            case .checkbox?:
                layout.validations.append(DataValidationRule(ranges: [cells], criterion: .checkbox(checked: nil, unchecked: nil)))
            case .dropdown(let options)?:
                layout.validations.append(DataValidationRule(ranges: [cells], criterion: .list(options)))
            default:
                break
            }
            if let pattern = type?.numberFormat ?? (type == nil ? nil : "") {
                for row in data.rows {
                    let address = CellAddress(row: row, column: column)
                    var cell = sheet[address]
                    cell.format.numberFormat = pattern.isEmpty ? nil : pattern
                    updates[address] = cell
                }
            }
        }
        var changes: [WorkbookChange] = [.layout(sheet: activeSheetID, layout)]
        if !updates.isEmpty { changes.append(.cells(sheet: activeSheetID, updates)) }
        perform(changes, actionName: "Column Type")
    }

    /// A table header's filter button: sets one column's criterion and hides the rows it rejects.
    func setTableCriterion(_ criterion: FilterCriterion?, column: Int, tableID: UUID) {
        updateTable(id: tableID, actionName: "Filter") { table in
            table.criteria[column] = (criterion?.isEmpty ?? true) ? nil : criterion
        }
    }

    /// Sorts a table's data rows by one of its columns.
    func sortTable(id: UUID, by column: Int, ascending: Bool) {
        guard let data = sheet.tables.first(where: { $0.id == id })?.dataRange, data.rowCount > 1 else { return }
        sort(data, by: column, ascending: ascending)
    }

    /// Formulas that name a table column follow when its header cell changes ("Sales[Amount]" → "Sales[Total]").
    func tableColumnRenames(at address: CellAddress, from old: Cell, to new: Cell) -> [WorkbookChange] {
        guard let table = sheet.tables.first(where: { $0.headerRow == address.row && $0.range.columns.contains(address.column) }) else { return [] }
        let before = CellDisplay.text(for: old.value, pattern: nil).text, after = CellDisplay.text(for: new.value, pattern: nil).text
        guard !before.isEmpty, !after.isEmpty, before != after else { return [] }
        var changes: [WorkbookChange] = []
        for target in workbook.sheets {
            var updates: [CellAddress: Cell] = [:]
            for (cellAddress, cell) in target.cells {
                guard let formula = cell.formula else { continue }
                let rewritten = FormulaRewriter.renameTableColumn(formula, table: table.name, from: before, to: after)
                if rewritten != formula {
                    var copy = cell
                    copy.formula = rewritten
                    updates[cellAddress] = copy
                }
            }
            if !updates.isEmpty { changes.append(.cells(sheet: target.id, updates)) }
        }
        return changes
    }

    /// Typing just below a table makes the table one row longer.
    func tableGrowing(into address: CellAddress) -> SheetTable? {
        sheet.tables.first { $0.range.end.row + 1 == address.row && $0.range.columns.contains(address.column) }
    }

    // MARK: Slicers

    /// Data ▸ Add a slicer: filters the selected data (or the data around the active cell) by its first column.
    @discardableResult
    func addSlicer() -> UUID {
        let range = sheet.table(containing: selection.active)?.range
            ?? (selection.current.isSingleCell ? dataRegion(around: selection.active) : selection.current)
        let reference = Self.quotedSheetName(sheet.name) + "!" + range.a1
        let cell = CellAddress(row: range.start.row, column: min(range.end.column + 2, sheet.columnCount - 1))
        let object = SheetObject(anchor: ObjectAnchor(cell: cell, width: 220, height: 64), content: .slicer(SlicerSpec(range: reference)))
        addObject(object, actionName: "Add Slicer")
        return object.id
    }

    /// Changes a slicer, and the rows it hides wherever its data is, as one undoable step.
    func updateSlicer(id: UUID, actionName: String = "Edit Slicer", _ change: @escaping (inout SlicerSpec) -> Void) {
        let sheetIndex = activeSheetIndex
        performFilterEdit(actionName: actionName) { workbook in
            guard let index = workbook.sheets[sheetIndex].objects.firstIndex(where: { $0.id == id }),
                  case .slicer(var spec) = workbook.sheets[sheetIndex].objects[index].content else { return }
            change(&spec)
            workbook.sheets[sheetIndex].objects[index].content = .slicer(spec)
        }
    }

    /// The values a slicer lists: its column's values within its range.
    func slicerValues(_ spec: SlicerSpec) -> [(value: String, count: Int)] {
        RuleEvaluator.filterValues(forSlicer: spec, onSheet: activeSheetIndex, workbook: workbook)
    }

    /// The headings of a slicer's range, for its column picker.
    func slicerHeadings(_ spec: SlicerSpec) -> [String] {
        guard let target = workbook.resolve(spec.range, onSheet: activeSheetIndex) else { return [] }
        let source = workbook.sheets[target.sheet]
        return target.range.columns.map { column in
            let text = CellDisplay.text(for: source.value(at: CellAddress(row: target.range.start.row, column: column)), pattern: nil).text
            return text.isEmpty ? "Column \(CellAddress.columnName(column))" : text
        }
    }
}
