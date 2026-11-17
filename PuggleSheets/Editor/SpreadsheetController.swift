import AppKit
import PuggleSheetsKit

/// Everything about a sheet except its cells and name.
struct SheetLayout: Equatable {
    var rowCount: Int
    var columnCount: Int
    var defaultColumnWidth: Double
    var defaultRowHeight: Double
    var columnWidths: [Int: Double]
    var rowHeights: [Int: Double]
    var frozenRows: Int
    var frozenColumns: Int
    var merges: [CellRange]
    var hiddenRows: Set<Int>
    var hiddenColumns: Set<Int>
    var showsGridlines: Bool
    var tabColor: RGBColor?
    var conditionalFormats: [ConditionalFormatRule]
    var validations: [DataValidationRule]
    var filter: SheetFilter?
    var filteredRows: Set<Int>
    var bandings: [Banding]
    var objects: [SheetObject]
    var pivotTables: [PivotTable]
    var filterViews: [FilterView]
    var protections: [ProtectedRange]
    var rowGroups: [OutlineGroup]
    var columnGroups: [OutlineGroup]
    var tables: [SheetTable]

    init(_ sheet: Sheet) {
        rowCount = sheet.rowCount
        columnCount = sheet.columnCount
        defaultColumnWidth = sheet.defaultColumnWidth
        defaultRowHeight = sheet.defaultRowHeight
        columnWidths = sheet.columnWidths
        rowHeights = sheet.rowHeights
        frozenRows = sheet.frozenRows
        frozenColumns = sheet.frozenColumns
        merges = sheet.merges
        hiddenRows = sheet.hiddenRows
        hiddenColumns = sheet.hiddenColumns
        showsGridlines = sheet.showsGridlines
        tabColor = sheet.tabColor
        conditionalFormats = sheet.conditionalFormats
        validations = sheet.validations
        filter = sheet.filter
        filteredRows = sheet.filteredRows
        bandings = sheet.bandings
        objects = sheet.objects
        pivotTables = sheet.pivotTables
        filterViews = sheet.filterViews
        protections = sheet.protections
        rowGroups = sheet.rowGroups
        columnGroups = sheet.columnGroups
        tables = sheet.tables
    }

    func apply(to sheet: inout Sheet) {
        sheet.rowCount = rowCount
        sheet.columnCount = columnCount
        sheet.defaultColumnWidth = defaultColumnWidth
        sheet.defaultRowHeight = defaultRowHeight
        sheet.columnWidths = columnWidths
        sheet.rowHeights = rowHeights
        sheet.frozenRows = frozenRows
        sheet.frozenColumns = frozenColumns
        sheet.merges = merges
        sheet.hiddenRows = hiddenRows
        sheet.hiddenColumns = hiddenColumns
        sheet.showsGridlines = showsGridlines
        sheet.tabColor = tabColor
        sheet.conditionalFormats = conditionalFormats
        sheet.validations = validations
        sheet.filter = filter
        sheet.filteredRows = filteredRows
        sheet.bandings = bandings
        sheet.objects = objects
        sheet.pivotTables = pivotTables
        sheet.filterViews = filterViews
        sheet.protections = protections
        sheet.rowGroups = rowGroups
        sheet.columnGroups = columnGroups
        sheet.tables = tables
    }
}

/// One step of an edit. Applying it returns the step that undoes it.
enum WorkbookChange {
    /// Replaces these cells of a sheet (an empty `Cell()` clears one).
    case cells(sheet: UUID, [CellAddress: Cell])
    case layout(sheet: UUID, SheetLayout)
    /// Replaces everything: used for edits that move cells or sheets around.
    case workbook(Workbook)
}

/// What changed, so views know what to refresh.
struct SpreadsheetUpdate: OptionSet {
    let rawValue: Int
    static let cells = SpreadsheetUpdate(rawValue: 1)
    static let layout = SpreadsheetUpdate(rawValue: 2)
    static let sheets = SpreadsheetUpdate(rawValue: 4)
    static let selection = SpreadsheetUpdate(rawValue: 8)
    static let activeSheet = SpreadsheetUpdate(rawValue: 16)
    static let all: SpreadsheetUpdate = [.cells, .layout, .sheets, .selection, .activeSheet]
}

/// Cells cut to the pasteboard, outlined until they're pasted.
struct CutRange: Equatable {
    var sheetID: UUID
    var range: CellRange
    var changeCount: Int
}

/// Owns a window's editing: the active sheet, selections, edits with undo, and recalculation.
final class SpreadsheetController {
    unowned let document: SpreadsheetDocument
    let state: EditorState
    let engine = FormulaEngine()
    /// Tells this window's clipboard contents apart from other windows'.
    let documentID = UUID()
    private(set) var activeSheetID: UUID
    private var selections: [UUID: GridSelection] = [:]
    /// Called after every change with what needs refreshing.
    var onUpdate: ((SpreadsheetUpdate) -> Void)?
    /// Called with a message when data validation refuses typed input.
    var onRejectedInput: ((String) -> Void)?
    /// Called with a message when an edit can't be done (shifting cells through merged cells, for example).
    var onProblem: ((String) -> Void)?
    /// Asked before an edit touches a protected range: refuses (restricting protections) or warns.
    var onProtectedEdit: ((ProtectedRange) -> ProtectionAnswer)?
    /// "Don't show this again for 5 minutes" on the protected range warning.
    var protectionWarningsSilencedUntil: Date?
    var cutRange: CutRange? {
        didSet { if cutRange != oldValue { notify(.cells) } }
    }
    /// Rows this window made taller to fit their text, which may shrink back. Rows sized by hand never change.
    private var autoSizedRows: [UUID: Set<Int>] = [:]
    /// The image or chart selected on the active sheet, if any.
    var selectedObjectID: UUID? {
        didSet { if selectedObjectID != oldValue { notify(.selection) } }
    }
    /// The filter view open on each sheet in this window (sheet id → view id).
    var openFilterViews: [UUID: UUID] = [:]
    /// Counts edits, so views can cache what they compute from the workbook.
    private(set) var editGeneration = 0
    /// The rows the open filter view hides, kept until the next edit.
    var filterViewRowCache: (view: FilterView, generation: Int, sheet: UUID, rows: Set<Int>)?

    init(document: SpreadsheetDocument, state: EditorState) {
        self.document = document
        self.state = state
        let index = min(max(document.activeSheetIndex, 0), document.workbook.sheets.count - 1)
        activeSheetID = document.workbook.sheets[index].id
        engine.recalculateAll(&document.workbook)
    }

    var workbook: Workbook { document.workbook }
    var undoManager: UndoManager? { document.undoManager }

    var activeSheetIndex: Int { workbook.sheetIndex(id: activeSheetID) ?? 0 }
    var sheet: Sheet { workbook.sheets[activeSheetIndex] }

    var selection: GridSelection {
        get { selections[activeSheetID] ?? defaultSelection }
        set { setSelection(newValue, for: activeSheetID) }
    }

    /// A1, or the merged block that starts there.
    private var defaultSelection: GridSelection {
        let origin = CellAddress(row: 0, column: 0)
        return GridSelection(range: sheet.merge(containing: origin) ?? CellRange(origin), active: origin)
    }

    private func setSelection(_ selection: GridSelection, for sheetID: UUID) {
        guard let index = workbook.sheetIndex(id: sheetID) else { return }
        let sheet = workbook.sheets[index]
        var result = selection.clamped(rowCount: sheet.rowCount, columnCount: sheet.columnCount)
        if !sheet.merges.isEmpty, let last = result.ranges.indices.last {
            result.ranges[last] = GridSelection.expanding(result.ranges[last], toInclude: sheet.merges)
        }
        guard selections[sheetID] != result else { return }
        selections[sheetID] = result
        if sheetID == activeSheetID { notify(.selection) }
    }

    /// Called when the document's contents were replaced (Revert).
    func reloadFromDocument() {
        selections = [:]
        let index = min(max(document.activeSheetIndex, 0), workbook.sheets.count - 1)
        activeSheetID = workbook.sheets[index].id
        engine.recalculateAll(&document.workbook)
        notify(.all)
    }

    func showSheet(id: UUID) {
        guard id != activeSheetID, let index = workbook.sheetIndex(id: id) else { return }
        selectedObjectID = nil
        activeSheetID = id
        document.activeSheetIndex = index
        notify([.activeSheet, .layout, .cells, .selection, .sheets])
    }

    func notify(_ update: SpreadsheetUpdate) {
        onUpdate?(update)
    }

    // MARK: Edits with undo

    /// Applies `changes` as one undoable step. `selection` is what to select afterwards (the current
    /// selection by default); undo brings back the selection from before.
    func perform(_ changes: [WorkbookChange], actionName: String, selection after: GridSelection? = nil, showing sheetID: UUID? = nil) {
        guard protectionAllows(changes) else { return }
        var changes = changes
        if let rowHeights = automaticRowHeights(for: changes) { changes.append(rowHeights) }
        let before = (activeSheetID, selection)
        let inverse = apply(changes)
        if let sheetID { showSheet(id: sheetID) }
        if let after { selection = after }
        let afterState = (activeSheetID, selection)
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.applyRecorded(inverse, actionName: actionName, show: before, then: afterState)
        }
        undoManager?.setActionName(actionName)
    }

    private func applyRecorded(_ changes: [WorkbookChange], actionName: String,
                               show shown: (UUID, GridSelection), then other: (UUID, GridSelection)) {
        let inverse = apply(changes)
        if workbook.sheetIndex(id: shown.0) != nil {
            showSheet(id: shown.0)
            setSelection(shown.1, for: shown.0)
        }
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.applyRecorded(inverse, actionName: actionName, show: other, then: shown)
        }
        undoManager?.setActionName(actionName)
    }

    /// Applies changes, recalculates and returns the changes that undo them (in order).
    private func apply(_ changes: [WorkbookChange]) -> [WorkbookChange] {
        editGeneration += 1
        var inverse: [WorkbookChange] = []
        var changedCells: [SheetCell] = []
        var recalculateEverything = false
        var pivotTablesChanged = false
        var update: SpreadsheetUpdate = []
        for change in changes {
            switch change {
            case .cells(let id, let cells):
                guard let index = workbook.sheetIndex(id: id) else { continue }
                var old: [CellAddress: Cell] = [:]
                old.reserveCapacity(cells.count)
                for address in cells.keys { old[address] = document.workbook.sheets[index][address] }
                document.workbook.sheets[index].setCells(cells)
                inverse.append(.cells(sheet: id, old))
                changedCells.append(contentsOf: cells.keys.map { SheetCell(sheet: id, address: $0) })
                update.insert(.cells)
            case .layout(let id, let layout):
                guard let index = workbook.sheetIndex(id: id) else { continue }
                inverse.append(.layout(sheet: id, SheetLayout(document.workbook.sheets[index])))
                if document.workbook.sheets[index].pivotTables != layout.pivotTables || document.workbook.sheets[index].tables != layout.tables
                    || document.workbook.sheets[index].objects.compactMap(\.slicer) != layout.objects.compactMap(\.slicer) {
                    // The engine notices changed pivot tables, tables and slicers and recomputes what depends on them.
                    pivotTablesChanged = true
                }
                layout.apply(to: &document.workbook.sheets[index])
                update.formUnion([.layout, .cells, .sheets])
            case .workbook(let replacement):
                inverse.append(.workbook(document.workbook))
                document.workbook = replacement
                recalculateEverything = true
                update.formUnion([.layout, .cells, .sheets])
            }
        }
        if recalculateEverything {
            engine.recalculateAll(&document.workbook)
        } else if !changedCells.isEmpty || pivotTablesChanged {
            // The engine notices changed pivot tables itself and recomputes them.
            engine.recalculate(&document.workbook, changed: changedCells)
        }
        if let id = selectedObjectID, !sheet.objects.contains(where: { $0.id == id }) { selectedObjectID = nil }
        if workbook.sheetIndex(id: activeSheetID) == nil {
            activeSheetID = workbook.sheets[min(document.activeSheetIndex, workbook.sheets.count - 1)].id
            update.insert(.activeSheet)
        }
        document.activeSheetIndex = activeSheetIndex
        // Keep selections inside sheets that shrank.
        for (id, selection) in selections {
            if workbook.sheetIndex(id: id) == nil { selections[id] = nil } else { setSelection(selection, for: id) }
        }
        notify(update.union(.selection))
        return inverse.reversed()
    }

    /// Rows that should grow (or shrink back) to fit wrapped, multi-line or larger text after `changes`,
    /// among rows whose height wasn't set by hand.
    private func automaticRowHeights(for changes: [WorkbookChange]) -> WorkbookChange? {
        var updated: [CellAddress: Cell] = [:]
        for case .cells(let id, let cells) in changes where id == activeSheetID {
            updated.merge(cells) { $1 }
        }
        let rows = Set(updated.keys.map(\.row))
        guard !rows.isEmpty, rows.count <= 5000 else { return nil }
        let sheet = self.sheet
        var layout = SheetLayout(sheet)
        var automatic = autoSizedRows[activeSheetID] ?? []
        for row in rows {
            if layout.rowHeights[row] != nil, !automatic.contains(row) { continue }
            var cells: [CellAddress: Cell] = [:]
            for (address, cell) in sheet.cells(in: CellRange(rows: row...row, columns: 0...(sheet.columnCount - 1))) { cells[address] = cell }
            for (address, cell) in updated where address.row == row { cells[address] = cell }
            var needed = layout.defaultRowHeight
            for (address, cell) in cells where cell.hasContent && sheet.merge(containing: address) == nil {
                let tall = cell.format.resolvedWrap == .wrap || cell.format.resolvedFontSize > CellFormat.defaultFontSize
                    || (cell.value.textValue?.contains("\n") ?? false) || cell.format.textRotation != nil
                guard tall else { continue }
                needed = max(needed, Double(CellRenderer.neededHeight(cell, width: CGFloat(sheet.columnWidth(address.column)))))
            }
            let current = layout.rowHeights[row] ?? layout.defaultRowHeight
            guard needed != current else { continue }
            layout.rowHeights[row] = needed == layout.defaultRowHeight ? nil : needed
            if needed > layout.defaultRowHeight { automatic.insert(row) } else { automatic.remove(row) }
        }
        autoSizedRows[activeSheetID] = automatic
        return layout == SheetLayout(sheet) ? nil : .layout(sheet: activeSheetID, layout)
    }

    /// Cells an edit changes on sheets with protected ranges: cell edits, and merges made or undone.
    private func protectionAllows(_ changes: [WorkbookChange]) -> Bool {
        var touched: [(sheetID: UUID, addresses: [CellAddress])] = []
        for change in changes {
            switch change {
            case .cells(let id, let cells):
                guard let index = workbook.sheetIndex(id: id), !workbook.sheets[index].protections.isEmpty else { continue }
                let sheet = workbook.sheets[index]
                // Only real changes count, so formatting a range around protected cells doesn't stop at them.
                let changed = cells.filter { sheet[$0.key] != $0.value }.map(\.key)
                if !changed.isEmpty { touched.append((id, changed)) }
            case .layout(let id, let layout):
                guard let index = workbook.sheetIndex(id: id), !workbook.sheets[index].protections.isEmpty else { continue }
                let old = Set(workbook.sheets[index].merges), new = Set(layout.merges)
                let merges = old.symmetricDifference(new).map(\.start)
                if !merges.isEmpty { touched.append((id, merges)) }
            case .workbook:
                continue
            }
        }
        return touched.isEmpty || protectionAllows(touched)
    }

    /// The sheet as a workbook-wide edit: copies the workbook, lets `edit` change it, and performs it.
    func performWorkbookEdit(actionName: String, selection: GridSelection? = nil, showing sheetID: UUID? = nil,
                             _ edit: (inout Workbook) -> Void) {
        var copy = workbook
        edit(&copy)
        perform([.workbook(copy)], actionName: actionName, selection: selection, showing: sheetID)
    }

    /// Changes the active sheet's layout as one undoable step.
    func performLayoutEdit(actionName: String, _ edit: (inout SheetLayout) -> Void) {
        var layout = SheetLayout(sheet)
        let original = layout
        edit(&layout)
        guard layout != original else { return }
        perform([.layout(sheet: activeSheetID, layout)], actionName: actionName)
    }

    // MARK: Reading

    func cell(at address: CellAddress) -> Cell { sheet[address] }

    /// What a cell shows: its content, or the value an array formula spilled into it.
    func shownCell(at address: CellAddress, in sheet: Sheet) -> Cell {
        var cell = sheet[address]
        if !cell.hasContent, let spilled = sheet.spilledValues[address] { cell.value = spilled }
        return cell
    }

    /// The formula that spilled a value into an empty cell, shown grayed out in the formula bar.
    func spillingFormula(at address: CellAddress) -> String? {
        guard !sheet[address].hasContent, let source = sheet.spillSource(of: address) else { return nil }
        return sheet[source].formula
    }

    /// The block a cell belongs to when merged, or the cell itself.
    func mergedRange(at address: CellAddress) -> CellRange {
        sheet.merge(containing: address) ?? CellRange(address)
    }

    /// Statistics for the bottom-right summary.
    func selectionStatistics() -> SelectionStatistics {
        var statistics = SelectionStatistics()
        var seen = Set<CellAddress>()
        func add(_ value: CellValue) {
            switch value {
            case .empty: return
            case .number(let number):
                statistics.count += 1
                statistics.numbers.append(number)
            default:
                statistics.count += 1
            }
        }
        let sheet = self.sheet
        for range in selection.ranges {
            for (address, cell) in sheet.cells(in: range) where cell.hasContent && seen.insert(address).inserted {
                add(cell.value)
            }
            // Values spilled from array formulas count too.
            for (address, value) in sheet.spilledValues where range.contains(address) && !(sheet.cells[address]?.hasContent ?? false) {
                if seen.insert(address).inserted { add(value) }
            }
        }
        return statistics
    }
}
