import AppKit
import PuggleSheetsKit

/// Rules a sheet carries (data validation, conditional formatting, alternating colors, the filter)
/// and the workbook's named ranges. Each change is one undoable step.
extension SpreadsheetController {
    // MARK: Data validation

    func setValidation(_ rule: DataValidationRule) {
        performLayoutEdit(actionName: "Data Validation") { layout in
            if let index = layout.validations.firstIndex(where: { $0.id == rule.id }) {
                layout.validations[index] = rule
            } else {
                layout.validations.append(rule)
            }
        }
    }

    func removeValidation(id: UUID) {
        performLayoutEdit(actionName: "Remove Data Validation") { $0.validations.removeAll { $0.id == id } }
    }

    /// Removes validation from the selected cells, splitting or trimming rules that cover more.
    func removeValidations(in ranges: [CellRange]) {
        performLayoutEdit(actionName: "Remove Data Validation") { layout in
            layout.validations = layout.validations.compactMap { rule in
                var rule = rule
                rule.ranges = rule.ranges.flatMap { range in ranges.reduce([range]) { pieces, cut in pieces.flatMap { Self.subtract(cut, from: $0) } } }
                return rule.ranges.isEmpty ? nil : rule
            }
        }
    }

    /// `range` minus `cut`, as up to four rectangles.
    static func subtract(_ cut: CellRange, from range: CellRange) -> [CellRange] {
        guard let overlap = range.intersection(cut) else { return [range] }
        var pieces: [CellRange] = []
        if range.start.row < overlap.start.row {
            pieces.append(CellRange(rows: range.start.row...(overlap.start.row - 1), columns: range.columns))
        }
        if overlap.end.row < range.end.row {
            pieces.append(CellRange(rows: (overlap.end.row + 1)...range.end.row, columns: range.columns))
        }
        if range.start.column < overlap.start.column {
            pieces.append(CellRange(rows: overlap.rows, columns: range.start.column...(overlap.start.column - 1)))
        }
        if overlap.end.column < range.end.column {
            pieces.append(CellRange(rows: overlap.rows, columns: (overlap.end.column + 1)...range.end.column))
        }
        return pieces
    }

    /// Insert ▸ Checkbox: the selection becomes checkboxes; empty cells start unticked (FALSE).
    func insertCheckboxes() {
        let ranges = selection.ranges
        var layout = SheetLayout(sheet)
        layout.validations.append(DataValidationRule(ranges: ranges, criterion: .checkbox(checked: nil, unchecked: nil)))
        var updates: [CellAddress: Cell] = [:]
        for range in ranges {
            for address in range.addresses where !sheet[address].hasContent {
                var cell = sheet[address]
                cell.value = .boolean(false)
                cell.format.horizontalAlignment = cell.format.horizontalAlignment ?? .center
                updates[address] = cell
            }
        }
        perform([.layout(sheet: activeSheetID, layout), .cells(sheet: activeSheetID, updates)], actionName: "Insert Checkbox")
    }

    /// Whether the cell is a checkbox, and its rule.
    func checkboxRule(at address: CellAddress) -> DataValidationRule? {
        guard let rule = sheet.validation(at: address), case .checkbox = rule.criterion else { return nil }
        return rule
    }

    /// Clicking a checkbox, or Space on selected checkboxes: ticks them all if the active one is unticked.
    func toggleCheckboxes(at addresses: [CellAddress]) {
        guard let first = addresses.first, let firstRule = checkboxRule(at: first),
              case .checkbox(let checkedValue, _) = firstRule.criterion else { return }
        let tick = !GridView.isChecked(sheet.value(at: first), checkedValue: checkedValue)
        var updates: [CellAddress: Cell] = [:]
        for address in addresses {
            guard let rule = checkboxRule(at: address), case .checkbox(let checked, let unchecked) = rule.criterion else { continue }
            var cell = sheet[address]
            cell.formula = nil
            if tick {
                cell.value = checked.map { InputParser.parse($0, currentFormat: nil).value } ?? .boolean(true)
            } else {
                cell.value = unchecked.map { InputParser.parse($0, currentFormat: nil).value } ?? .boolean(false)
            }
            updates[address] = cell
        }
        guard !updates.isEmpty else { return }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Checkbox")
    }

    /// The items a dropdown cell offers.
    func dropdownItems(at address: CellAddress) -> [String]? {
        guard let rule = sheet.validation(at: address) else { return nil }
        switch rule.criterion {
        case .list, .listFromRange:
            return RuleEvaluator.dropdownItems(for: rule, sheetIndex: activeSheetIndex, workbook: workbook)
        case .checkbox, .condition:
            return nil
        }
    }

    /// Typed input a rule refuses, with the message to show; nil when the input may go in.
    func rejection(for cell: Cell, at address: CellAddress) -> String? {
        guard cell.formula == nil, let rule = sheet.validation(at: address), rule.rejectsInvalid,
              !RuleEvaluator.isValid(cell.value, for: rule, at: address, sheetIndex: activeSheetIndex, workbook: workbook) else { return nil }
        return RuleEvaluator.invalidMessage(for: rule)
    }

    // MARK: Conditional formatting

    func setConditionalFormat(_ rule: ConditionalFormatRule) {
        performLayoutEdit(actionName: "Conditional Formatting") { layout in
            if let index = layout.conditionalFormats.firstIndex(where: { $0.id == rule.id }) {
                layout.conditionalFormats[index] = rule
            } else {
                layout.conditionalFormats.append(rule)
            }
        }
    }

    func removeConditionalFormat(id: UUID) {
        performLayoutEdit(actionName: "Remove Conditional Formatting") { $0.conditionalFormats.removeAll { $0.id == id } }
    }

    /// Rules earlier in the list win; this moves one up or down.
    func moveConditionalFormat(id: UUID, by offset: Int) {
        performLayoutEdit(actionName: "Reorder Conditional Formatting") { layout in
            guard let index = layout.conditionalFormats.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard layout.conditionalFormats.indices.contains(target) else { return }
            layout.conditionalFormats.swapAt(index, target)
        }
    }

    // MARK: Alternating colors

    func setBanding(_ banding: Banding) {
        performLayoutEdit(actionName: "Alternating Colors") { layout in
            if let index = layout.bandings.firstIndex(where: { $0.id == banding.id }) {
                layout.bandings[index] = banding
            } else {
                layout.bandings.removeAll { $0.range.intersects(banding.range) }
                layout.bandings.append(banding)
            }
        }
    }

    func removeBanding(id: UUID) {
        performLayoutEdit(actionName: "Remove Alternating Colors") { $0.bandings.removeAll { $0.id == id } }
    }

    /// The alternating colors covering the selection, if any.
    var selectedBanding: Banding? {
        sheet.bandings.first { $0.range.intersects(selection.current) }
    }

    // MARK: Named ranges

    /// A reference to `range` in the active sheet, as named ranges store it: "Sheet1!$A$1:$B$5".
    func absoluteReference(_ range: CellRange, sheetName: String? = nil) -> String {
        func absolute(_ address: CellAddress) -> String { "$\(CellAddress.columnName(address.column))$\(address.row + 1)" }
        let cells = range.isSingleCell ? absolute(range.start) : absolute(range.start) + ":" + absolute(range.end)
        return Self.quotedSheetName(sheetName ?? sheet.name) + "!" + cells
    }

    /// A sheet name as references write it: quoted when it has spaces or looks like a cell.
    static func quotedSheetName(_ name: String) -> String {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && CellAddress(a1: name) == nil
            ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A typed reference as a named range keeps it: on its sheet (the active one unless it names
    /// another) and absolute, like "Sheet1!$A$1:$B$5".
    func namedRangeReference(_ typed: String) -> String {
        let reference = typed.trimmingCharacters(in: .whitespaces)
        if let target = resolve(NamedRange(name: "_", reference: reference)) {
            return absoluteReference(target.range, sheetName: workbook.sheets[target.sheet].name)
        }
        return reference.contains("!") ? reference : Self.quotedSheetName(sheet.name) + "!" + reference
    }

    /// Why a name can't be used (or replaces `existing`), or nil when it can.
    func problem(namingRange name: String, replacing existing: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard NamedRange.isValidName(trimmed) else {
            return "Range names can contain only letters, numbers, underscores and periods, must start with a letter or underscore, and can’t look like a cell reference (A1) or TRUE/FALSE."
        }
        if let other = workbook.namedRange(trimmed), other.name.caseInsensitiveCompare(existing ?? "") != .orderedSame {
            return "A range named “\(other.name)” already exists."
        }
        return nil
    }

    /// Adds or changes a named range (`existing` is its old name when editing).
    func setNamedRange(name: String, reference: String, replacing existing: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let reference = namedRangeReference(reference)
        performWorkbookEdit(actionName: existing == nil ? "Add Named Range" : "Edit Named Range") { workbook in
            if let existing, let index = workbook.namedRanges.firstIndex(where: { $0.name.caseInsensitiveCompare(existing) == .orderedSame }) {
                workbook.namedRanges[index] = NamedRange(name: trimmed, reference: reference)
            } else {
                workbook.namedRanges.append(NamedRange(name: trimmed, reference: reference))
            }
        }
    }

    func removeNamedRange(_ name: String) {
        performWorkbookEdit(actionName: "Remove Named Range") { workbook in
            workbook.namedRanges.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Where a named range points: its sheet index and cells, when it's a plain reference.
    func resolve(_ named: NamedRange) -> (sheet: Int, range: CellRange)? {
        var text = named.reference
        var sheetIndex = activeSheetIndex
        if let bang = text.lastIndex(of: "!") {
            var name = String(text[..<bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard let index = workbook.sheetIndex(named: name) else { return nil }
            sheetIndex = index
            text = String(text[text.index(after: bang)...])
        }
        guard let range = CellRange(a1: text.replacingOccurrences(of: "$", with: "")) else { return nil }
        return (sheetIndex, range)
    }

    // MARK: Filters

    /// The block a new filter covers: the selection, or the data around the active cell.
    var filterRangeForSelection: CellRange {
        let current = selection.current
        guard current.isSingleCell else { return current }
        return dataRegion(around: current.start)
    }

    /// The contiguous block of filled cells around `address` (what ⌘A selects in Sheets' first press).
    func dataRegion(around address: CellAddress) -> CellRange {
        var region = CellRange(address)
        var grew = true
        func filled(_ row: Int, _ column: Int) -> Bool {
            row >= 0 && column >= 0 && row < sheet.rowCount && column < sheet.columnCount
                && sheet.value(at: CellAddress(row: row, column: column)) != .empty
        }
        while grew {
            grew = false
            let top = region.start.row, bottom = region.end.row, left = region.start.column, right = region.end.column
            if (left...right).contains(where: { filled(top - 1, $0) }) || filled(top - 1, left - 1) || filled(top - 1, right + 1) {
                region = region.union(CellRange(CellAddress(row: top - 1, column: left)))
                grew = true
            }
            if (left...right).contains(where: { filled(bottom + 1, $0) }) || filled(bottom + 1, left - 1) || filled(bottom + 1, right + 1) {
                region = region.union(CellRange(CellAddress(row: bottom + 1, column: left)))
                grew = true
            }
            if (region.start.row...region.end.row).contains(where: { filled($0, left - 1) }) {
                region = region.union(CellRange(CellAddress(row: region.start.row, column: left - 1)))
                grew = true
            }
            if (region.start.row...region.end.row).contains(where: { filled($0, right + 1) }) {
                region = region.union(CellRange(CellAddress(row: region.start.row, column: right + 1)))
                grew = true
            }
        }
        return region
    }

    /// Data ▸ Create a filter.
    func createFilter() {
        let range = filterRangeForSelection
        let index = activeSheetIndex
        performFilterEdit(actionName: "Create Filter") { $0.sheets[index].filter = SheetFilter(range: range) }
    }

    /// Data ▸ Remove filter: every filtered row shows again.
    func removeFilter() {
        let index = activeSheetIndex
        performFilterEdit(actionName: "Remove Filter") { $0.sheets[index].filter = nil }
    }

    /// Sets (or clears, with nil) one column's criterion and hides the rows the filter now rejects.
    func setFilterCriterion(_ criterion: FilterCriterion?, column: Int) {
        guard var filter = sheet.filter else { return }
        filter.criteria[column] = criterion?.isEmpty == false ? criterion : nil
        let index = activeSheetIndex
        performFilterEdit(actionName: "Filter") { $0.sheets[index].filter = filter }
    }

    /// The filter popover's sort: the data rows (not the header) by `column`.
    func sortFilter(by column: Int, ascending: Bool) {
        guard let filter = displayedFilter, filter.range.rowCount > 1 else { return }
        let data = CellRange(rows: (filter.range.start.row + 1)...filter.range.end.row, columns: filter.range.columns)
        sort(data, by: column, ascending: ascending)
    }
}
