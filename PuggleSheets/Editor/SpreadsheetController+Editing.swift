import AppKit
import PuggleSheetsKit

enum BorderKind: Int, CaseIterable {
    case all, inner, horizontal, vertical, outer, left, top, right, bottom, clear

    var title: String {
        switch self {
        case .all: "All borders"
        case .inner: "Inner borders"
        case .horizontal: "Horizontal borders"
        case .vertical: "Vertical borders"
        case .outer: "Outer borders"
        case .left: "Left border"
        case .top: "Top border"
        case .right: "Right border"
        case .bottom: "Bottom border"
        case .clear: "Clear borders"
        }
    }
}

enum MergeKind: Int, CaseIterable {
    case all, vertically, horizontally, unmerge

    var title: String {
        switch self {
        case .all: "Merge all"
        case .vertically: "Merge vertically"
        case .horizontally: "Merge horizontally"
        case .unmerge: "Unmerge"
        }
    }
}

extension SpreadsheetController {
    // MARK: Entering values

    /// What the formula bar and the cell editor show for a cell.
    func editText(at address: CellAddress) -> String {
        CellDisplay.editText(for: sheet[address])
    }

    /// The cell that typing `text` into `old` produces.
    func cell(forInput text: String, replacing old: Cell) -> Cell {
        var cell = old
        // Typing replaces an image in the cell.
        cell.image = nil
        let parsed = InputParser.parse(text, currentFormat: old.format.numberFormat)
        if let formula = parsed.formula {
            cell.formula = Self.closingParentheses(formula)
            cell.value = .empty
        } else {
            cell.formula = nil
            cell.value = parsed.value
        }
        if old.format.numberFormat == nil, let implied = parsed.impliedFormat { cell.format.numberFormat = implied }
        return cell
    }

    /// Commits text typed into `address`, then selects `next` (the current selection when nil).
    func commitInput(_ text: String, at address: CellAddress, then next: GridSelection? = nil) {
        let old = sheet[address]
        let new = cell(forInput: text, replacing: old)
        if let message = rejection(for: new, at: address) {
            onRejectedInput?(message)
            return
        }
        guard new.formula != old.formula || new.value != old.value || new.format != old.format || old.formula != nil else {
            if let next { selection = next }
            return
        }
        var changes: [WorkbookChange] = [.cells(sheet: activeSheetID, [address: new])]
        changes += tableColumnRenames(at: address, from: old, to: new)
        if new.hasContent, let table = tableGrowing(into: address) {
            // Typing just below a table adds a row to it.
            var layout = SheetLayout(sheet)
            if let index = layout.tables.firstIndex(where: { $0.id == table.id }) {
                layout.tables[index].range = CellRange(rows: table.range.start.row...address.row, columns: table.range.columns)
                changes.insert(.layout(sheet: activeSheetID, layout), at: 0)
            }
        }
        perform(changes, actionName: "Typing", selection: next)
    }

    /// ⌘Return: the same entry in every selected cell; formulas shift relative to the active cell.
    func commitInputToSelection(_ text: String) {
        let origin = selection.active
        let typed = cell(forInput: text, replacing: sheet[origin])
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for address in range.addresses {
                var cell = sheet[address]
                cell.value = typed.value
                cell.formula = typed.formula.map {
                    FormulaRewriter.translate($0, rows: address.row - origin.row, columns: address.column - origin.column)
                }
                if cell.format.numberFormat == nil { cell.format.numberFormat = typed.format.numberFormat }
                updates[address] = cell
            }
        }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Typing")
    }

    /// Adds the closing parentheses a formula is missing ("=SUM(A1:A3" → "=SUM(A1:A3)").
    static func closingParentheses(_ formula: String) -> String {
        var depth = 0
        var inString = false
        for character in formula {
            if character == "\"" { inString.toggle() }
            guard !inString else { continue }
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) }
        }
        return depth > 0 && !inString ? formula + String(repeating: ")", count: depth) : formula
    }

    /// Delete: removes values, formulas, images and links but keeps formatting.
    /// Clearing a pivot table's top-left cell deletes the pivot table.
    func clearContents() {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for (address, cell) in sheet.cells(in: range) where cell.hasContent || cell.link != nil {
                updates[address] = Cell(format: cell.format)
            }
        }
        var changes: [WorkbookChange] = []
        let removed = sheet.pivotTables.filter { pivot in selection.ranges.contains { $0.contains(pivot.anchor) } }.map(\.id)
        if !removed.isEmpty {
            var layout = SheetLayout(sheet)
            layout.pivotTables.removeAll { removed.contains($0.id) }
            changes.append(.layout(sheet: activeSheetID, layout))
        }
        if !updates.isEmpty { changes.append(.cells(sheet: activeSheetID, updates)) }
        guard !changes.isEmpty else { return }
        perform(changes, actionName: removed.isEmpty ? "Delete" : "Delete Pivot Table")
    }

    /// ⌘; and friends: today's date, the current time, or both, as values.
    func insertNow(date: Bool, time: Bool) {
        let serial = DateSerial.serial(from: Date())
        let value = date && !time ? serial.rounded(.down) : (time && !date ? serial - serial.rounded(.down) : serial)
        var cell = sheet[selection.active]
        cell.formula = nil
        cell.value = .number(value)
        cell.format.numberFormat = date && time ? NumberFormatPresets.dateTime.pattern
            : (date ? NumberFormatPresets.date.pattern : NumberFormatPresets.time.pattern)
        perform([.cells(sheet: activeSheetID, [selection.active: cell])], actionName: "Typing")
    }

    // MARK: Formatting

    /// Changes the format of every selected cell.
    func updateFormat(actionName: String, _ change: (inout CellFormat) -> Void) {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for address in range.addresses where updates[address] == nil {
                var cell = sheet[address]
                change(&cell.format)
                updates[address] = cell
            }
        }
        perform([.cells(sheet: activeSheetID, updates)], actionName: actionName)
    }

    private var activeFormat: CellFormat { sheet[selection.active].format }

    func toggleBold() {
        let on = !activeFormat.bold
        updateFormat(actionName: "Bold") { $0.bold = on }
    }

    func toggleItalic() {
        let on = !activeFormat.italic
        updateFormat(actionName: "Italic") { $0.italic = on }
    }

    func toggleUnderline() {
        let on = !activeFormat.underline
        updateFormat(actionName: "Underline") { $0.underline = on }
    }

    func toggleStrikethrough() {
        let on = !activeFormat.strikethrough
        updateFormat(actionName: "Strikethrough") { $0.strikethrough = on }
    }

    func setFontFamily(_ family: String) {
        updateFormat(actionName: "Font") { $0.fontFamily = family == CellFormat.defaultFontFamily ? nil : family }
    }

    func setFontSize(_ size: Double) {
        let size = min(max(size, 1), 400)
        updateFormat(actionName: "Font Size") { $0.fontSize = size == CellFormat.defaultFontSize ? nil : size }
    }

    func stepFontSize(by step: Double) {
        setFontSize(activeFormat.resolvedFontSize + step)
    }

    func setTextColor(_ color: RGBColor?) {
        updateFormat(actionName: "Text Color") { $0.textColor = color == .black ? nil : color }
    }

    func setFillColor(_ color: RGBColor?) {
        updateFormat(actionName: "Fill Color") { $0.fillColor = color == .white ? nil : color }
    }

    func setHorizontalAlignment(_ alignment: HorizontalAlignment?) {
        updateFormat(actionName: "Align") { $0.horizontalAlignment = alignment }
    }

    func setVerticalAlignment(_ alignment: VerticalAlignment) {
        updateFormat(actionName: "Align") { $0.verticalAlignment = alignment == .bottom ? nil : alignment }
    }

    func setWrap(_ wrap: WrapStrategy) {
        updateFormat(actionName: "Text Wrapping") { $0.wrap = wrap == .overflow ? nil : wrap }
    }

    func setNumberFormat(_ pattern: String?) {
        updateFormat(actionName: "Number Format") { $0.numberFormat = pattern }
    }

    /// The toolbar's decimal place buttons, applied to each cell's own format.
    func adjustDecimals(by delta: Int) {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for address in range.addresses where updates[address] == nil {
                var cell = sheet[address]
                cell.format.numberFormat = NumberFormatPresets.adjustingDecimals(cell.format.numberFormat, by: delta, for: cell.value)
                updates[address] = cell
            }
        }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Number Format")
    }

    /// ⌘\: back to the default look, number format and borders included.
    func clearFormatting() {
        updateFormat(actionName: "Clear Formatting") { $0 = CellFormat() }
    }

    func applyBorders(_ kind: BorderKind, line: BorderLine) {
        var updates: [CellAddress: Cell] = [:]
        func edit(_ address: CellAddress, _ change: (inout CellBorders) -> Void) {
            guard address.row >= 0, address.column >= 0 else { return }
            var cell = updates[address] ?? sheet[address]
            change(&cell.format.borders)
            updates[address] = cell
        }
        for range in selection.ranges {
            for address in range.addresses {
                let top = address.row == range.start.row, bottom = address.row == range.end.row
                let left = address.column == range.start.column, right = address.column == range.end.column
                switch kind {
                case .all:
                    edit(address) { $0 = CellBorders(top: line, left: line, bottom: line, right: line) }
                case .inner:
                    edit(address) { borders in
                        if !top { borders.top = line }
                        if !bottom { borders.bottom = line }
                        if !left { borders.left = line }
                        if !right { borders.right = line }
                    }
                case .horizontal:
                    edit(address) { borders in
                        if !top { borders.top = line }
                        if !bottom { borders.bottom = line }
                    }
                case .vertical:
                    edit(address) { borders in
                        if !left { borders.left = line }
                        if !right { borders.right = line }
                    }
                case .outer:
                    edit(address) { borders in
                        if top { borders.top = line }
                        if bottom { borders.bottom = line }
                        if left { borders.left = line }
                        if right { borders.right = line }
                    }
                case .left: if left { edit(address) { $0.left = line } }
                case .top: if top { edit(address) { $0.top = line } }
                case .right: if right { edit(address) { $0.right = line } }
                case .bottom: if bottom { edit(address) { $0.bottom = line } }
                case .clear:
                    edit(address) { $0 = CellBorders() }
                    // Lines stored on the neighbors' facing sides belong to this range too.
                    if top { edit(address.offsetBy(rows: -1)) { $0.bottom = nil } }
                    if bottom { edit(address.offsetBy(rows: 1)) { $0.top = nil } }
                    if left { edit(address.offsetBy(columns: -1)) { $0.right = nil } }
                    if right { edit(address.offsetBy(columns: 1)) { $0.left = nil } }
                }
            }
        }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Borders")
    }

    // MARK: Merging

    /// Whether merging would throw away values other than the top-left ones (if so, merging asks first).
    func mergeDiscardsValues(_ kind: MergeKind) -> Bool {
        merges(for: kind).contains { merge in sheet.cells(in: merge).contains { $0.address != merge.start && $0.cell.hasContent } }
    }

    private func merges(for kind: MergeKind) -> [CellRange] {
        let range = selection.current
        switch kind {
        case .all: return range.isSingleCell ? [] : [range]
        case .horizontally: return range.columnCount > 1 ? range.rows.map { CellRange(rows: $0...$0, columns: range.columns) } : []
        case .vertically: return range.rowCount > 1 ? range.columns.map { CellRange(rows: range.rows, columns: $0...$0) } : []
        case .unmerge: return []
        }
    }

    func canMerge(_ kind: MergeKind) -> Bool {
        kind == .unmerge ? sheet.merges.contains { $0.intersects(selection.current) } : !merges(for: kind).isEmpty
    }

    func merge(_ kind: MergeKind) {
        let range = selection.current
        let newMerges = merges(for: kind)
        var layout = SheetLayout(sheet)
        layout.merges.removeAll { $0.intersects(range) }
        layout.merges.append(contentsOf: newMerges)
        var updates: [CellAddress: Cell] = [:]
        for merge in newMerges {
            for (address, cell) in sheet.cells(in: merge) where address != merge.start && cell.hasContent {
                updates[address] = Cell(format: cell.format)
            }
        }
        var changes: [WorkbookChange] = [.layout(sheet: activeSheetID, layout)]
        if !updates.isEmpty { changes.append(.cells(sheet: activeSheetID, updates)) }
        perform(changes, actionName: kind == .unmerge ? "Unmerge" : "Merge Cells", selection: GridSelection(range: range, active: range.start))
    }

    // MARK: Fill

    /// A copy of `cell` with its formula shifted as if copied `rows` down and `columns` across.
    func translated(_ cell: Cell, rows: Int, columns: Int) -> Cell {
        guard let formula = cell.formula else { return cell }
        var result = cell
        result.formula = FormulaRewriter.translate(formula, rows: rows, columns: columns)
        return result
    }

    /// ⌘D: copies each selected range's top row down through it (or the row above a one-row selection).
    func fillDown() {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            let sourceRow = range.rowCount > 1 ? range.start.row : range.start.row - 1
            guard sourceRow >= 0 else { continue }
            for column in range.columns {
                let source = sheet[sourceRow, column]
                for row in range.rows where row != sourceRow {
                    updates[CellAddress(row: row, column: column)] = translated(source, rows: row - sourceRow, columns: 0)
                }
            }
        }
        guard !updates.isEmpty else { return }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Fill Down")
    }

    /// ⌘R: copies each selected range's left column across it (or the column to the left).
    func fillRight() {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            let sourceColumn = range.columnCount > 1 ? range.start.column : range.start.column - 1
            guard sourceColumn >= 0 else { continue }
            for row in range.rows {
                let source = sheet[row, sourceColumn]
                for column in range.columns where column != sourceColumn {
                    updates[CellAddress(row: row, column: column)] = translated(source, rows: 0, columns: column - sourceColumn)
                }
            }
        }
        guard !updates.isEmpty else { return }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Fill Right")
    }

    /// Dragging the fill handle from `source` to `target` (which contains it): continues series.
    func autoFill(from source: CellRange, to target: CellRange) {
        guard target != source, target.contains(source) else { return }
        let updates = AutoFill.fill(sheet: sheet, source: source, target: target)
        guard !updates.isEmpty else { return }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Autofill", selection: GridSelection(range: target, active: selection.active))
    }

    // MARK: Paint format

    /// The formats of the selected block, copied by the paint format button.
    func copiedFormats() -> [[CellFormat]] {
        let range = selection.current
        return range.rows.map { row in range.columns.map { sheet[row, $0].format } }
    }

    /// Repeats `formats` across the selection.
    func paste(formats: [[CellFormat]]) {
        guard let width = formats.first?.count, width > 0 else { return }
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for address in range.addresses {
                var cell = sheet[address]
                cell.format = formats[(address.row - range.start.row) % formats.count][(address.column - range.start.column) % width]
                updates[address] = cell
            }
        }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Paint Format")
    }
}
