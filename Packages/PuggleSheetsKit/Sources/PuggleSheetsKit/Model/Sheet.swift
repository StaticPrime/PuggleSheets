import Foundation

/// One tab of a spreadsheet: a fixed-size grid (1000 × 26 by default) with sparse cells.
public struct Sheet: Identifiable, Sendable {
    public static let defaultRowCount = 1000
    public static let defaultColumnCount = 26
    /// Sizes in pixels at 100% zoom.
    public static let standardColumnWidth = 100.0
    public static let standardRowHeight = 21.0

    public let id: UUID
    public var name: String
    public var rowCount: Int
    public var columnCount: Int
    /// Cells with content or formatting. Absent cells are empty.
    public private(set) var cells: [CellAddress: Cell] = [:]
    public var defaultColumnWidth = Sheet.standardColumnWidth
    public var defaultRowHeight = Sheet.standardRowHeight
    public var columnWidths: [Int: Double] = [:]
    public var rowHeights: [Int: Double] = [:]
    public var frozenRows = 0
    public var frozenColumns = 0
    public var merges: [CellRange] = []
    public var hiddenRows: Set<Int> = []
    public var hiddenColumns: Set<Int> = []
    public var showsGridlines = true
    public var tabColor: RGBColor?
    /// Format ▸ Conditional formatting, in priority order.
    public var conditionalFormats: [ConditionalFormatRule] = []
    /// Data ▸ Data validation.
    public var validations: [DataValidationRule] = []
    /// Data ▸ Create a filter.
    public var filter: SheetFilter?
    /// Rows the filter hides. Kept apart from `hiddenRows`, which the user hid by hand.
    public var filteredRows: Set<Int> = []
    /// Format ▸ Alternating colors.
    public var bandings: [Banding] = []
    /// Values array formulas spill into neighboring cells (not the formula's own cell). The formula
    /// engine keeps these up to date; they aren't typed values.
    public var spilledValues: [CellAddress: CellValue] = [:]
    /// Each spilling formula's cell → the whole range its result covers, including itself. Pivot
    /// tables spill from their anchor cell the same way.
    public var spillRanges: [CellAddress: CellRange] = [:]
    /// Images and charts over the grid, back to front.
    public var objects: [SheetObject] = []
    /// Insert ▸ Pivot table: the pivot tables whose results show on this sheet.
    public var pivotTables: [PivotTable] = []
    /// Data ▸ Filter views.
    public var filterViews: [FilterView] = []
    /// Links of cells whose formula's result came from HYPERLINK. The formula engine keeps these up to date.
    public var formulaLinks: [CellAddress: String] = [:]
    /// Data ▸ Protect sheets and ranges.
    public var protections: [ProtectedRange] = []
    /// Data ▸ Group rows and Group columns.
    public var rowGroups: [OutlineGroup] = []
    public var columnGroups: [OutlineGroup] = []
    /// Format ▸ Convert to table.
    public var tables: [SheetTable] = []
    /// SPARKLINE formulas' charts by cell. The formula engine keeps these up to date.
    public var sparklines: [CellAddress: SparklineSpec] = [:]

    public init(name: String, id: UUID = UUID(), rowCount: Int = Sheet.defaultRowCount, columnCount: Int = Sheet.defaultColumnCount) {
        self.id = id
        self.name = name
        self.rowCount = rowCount
        self.columnCount = columnCount
    }

    public subscript(address: CellAddress) -> Cell {
        get { cells[address] ?? Cell() }
        set { cells[address] = newValue.isEmpty ? nil : newValue }
    }

    public subscript(row: Int, column: Int) -> Cell {
        get { self[CellAddress(row: row, column: column)] }
        set { self[CellAddress(row: row, column: column)] = newValue }
    }

    /// The value a cell shows: its own, or one spilled into it by an array formula.
    public func value(at address: CellAddress) -> CellValue {
        if let cell = cells[address], cell.hasContent { return cell.value }
        return spilledValues[address] ?? .empty
    }

    /// The spilling formula's cell whose result covers `address` (not counting the formula's own cell).
    public func spillSource(of address: CellAddress) -> CellAddress? {
        guard spilledValues[address] != nil else { return nil }
        return spillRanges.first { $0.key != address && $0.value.contains(address) }?.key
    }

    public func columnWidth(_ column: Int) -> Double { columnWidths[column] ?? defaultColumnWidth }
    public func rowHeight(_ row: Int) -> Double { rowHeights[row] ?? defaultRowHeight }

    /// Hidden by hand, by the filter or by a collapsed group.
    public func isRowHidden(_ row: Int) -> Bool {
        hiddenRows.contains(row) || filteredRows.contains(row) || rowGroups.contains { $0.isCollapsed && $0.range.contains(row) }
    }

    /// Hidden by hand or by a collapsed group.
    public func isColumnHidden(_ column: Int) -> Bool {
        hiddenColumns.contains(column) || columnGroups.contains { $0.isCollapsed && $0.range.contains(column) }
    }

    /// The protection covering a cell, if any (restricting ones first).
    public func protection(covering address: CellAddress) -> ProtectedRange? {
        protections.first { !$0.warningOnly && $0.covers(address) } ?? protections.first { $0.covers(address) }
    }

    /// The whole grid.
    public var gridRange: CellRange {
        CellRange(rows: 0...max(0, rowCount - 1), columns: 0...max(0, columnCount - 1))
    }

    /// The smallest range holding every cell with content or formatting.
    public var usedRange: CellRange? { boundingRange(of: cells.keys) }

    /// The smallest range holding every cell with a value or formula, or a spilled value.
    public var contentRange: CellRange? {
        boundingRange(of: Array(cells.lazy.filter { $0.value.hasContent }.map(\.key)) + Array(spilledValues.keys))
    }

    private func boundingRange(of addresses: some Sequence<CellAddress>) -> CellRange? {
        var top = Int.max, left = Int.max, bottom = -1, right = -1
        for address in addresses {
            top = min(top, address.row)
            bottom = max(bottom, address.row)
            left = min(left, address.column)
            right = max(right, address.column)
        }
        guard bottom >= 0 else { return nil }
        return CellRange(rows: top...bottom, columns: left...right)
    }

    /// Stored (non-empty) cells inside `range`, in no particular order.
    public func cells(in range: CellRange) -> [(address: CellAddress, cell: Cell)] {
        if range.cellCount <= cells.count {
            var result: [(address: CellAddress, cell: Cell)] = []
            for row in range.rows {
                for column in range.columns {
                    let address = CellAddress(row: row, column: column)
                    if let cell = cells[address] { result.append((address, cell)) }
                }
            }
            return result
        }
        return cells.compactMap { range.contains($0.key) ? ($0.key, $0.value) : nil }
    }

    /// The merged block that covers `address`, if any.
    public func merge(containing address: CellAddress) -> CellRange? {
        merges.first { $0.contains(address) }
    }

    /// The table whose range holds `address`, if any.
    public func table(containing address: CellAddress) -> SheetTable? {
        tables.first { $0.range.contains(address) }
    }

    /// The pivot table anchored at `address`, if any.
    public func pivotTable(at address: CellAddress) -> PivotTable? {
        pivotTables.first { $0.anchor == address }
    }

    /// The pivot table whose results cover `address`, if any.
    public func pivotTable(covering address: CellAddress) -> PivotTable? {
        pivotTables.first { $0.anchor == address || (spillRanges[$0.anchor]?.contains(address) ?? false) }
    }

    /// Where a cell's link goes: its own link, a HYPERLINK formula's, or the address its text spells out.
    public func link(at address: CellAddress) -> String? {
        if let cell = cells[address] {
            if let link = cell.link { return link }
            if cell.formula != nil { return formulaLinks[address] }
            if case .text(let text) = cell.value { return LinkTarget.detectedURL(in: text) }
            return nil
        }
        if case .text(let text)? = spilledValues[address] { return LinkTarget.detectedURL(in: text) }
        return nil
    }

    /// The data validation rule for a cell, if any (the last rule listed wins).
    public func validation(at address: CellAddress) -> DataValidationRule? {
        validations.last { rule in rule.ranges.contains { $0.contains(address) } }
    }

    /// Replaces cells; empty cells are removed.
    public mutating func setCells(_ updates: [CellAddress: Cell]) {
        for (address, cell) in updates { self[address] = cell }
    }

    public mutating func removeCells(in range: CellRange) {
        for (address, _) in cells(in: range) { cells[address] = nil }
    }

    /// Moves cells, sizes, merges, frozen panes, rules, filters, objects and pivot tables for inserted
    /// or deleted rows, columns or cells. Formulas are not rewritten here; `Workbook.apply(_:toSheet:)` does that for
    /// every sheet. Spilled values are cleared: the formula engine recomputes them.
    public mutating func applyStructuralChange(_ change: StructuralChange) {
        var moved: [CellAddress: Cell] = [:]
        moved.reserveCapacity(cells.count)
        var lastRow = 0, lastColumn = 0
        for (address, cell) in cells {
            guard let target = change.map(address) else { continue }
            moved[target] = cell
            lastRow = max(lastRow, target.row)
            lastColumn = max(lastColumn, target.column)
        }
        cells = moved
        spilledValues = [:]
        spillRanges = [:]
        formulaLinks = [:]
        sparklines = [:]

        // Objects move with their anchor cell; when it's deleted, they stay at the deletion point.
        func surviving(_ address: CellAddress) -> CellAddress {
            if let mapped = change.map(address) { return mapped }
            var point = address
            switch change {
            case .deleteRows(let at, let count):
                point.row = max(0, min(at, rowCount - count - 1))
            case .deleteColumns(let at, let count):
                point.column = max(0, min(at, columnCount - count - 1))
            case .deleteCells(let range, let up):
                if up { point.row = range.start.row } else { point.column = range.start.column }
            default:
                break
            }
            return point
        }
        for index in objects.indices { objects[index].anchor.cell = surviving(objects[index].anchor.cell) }
        // A pivot table goes with its anchor cell.
        pivotTables = pivotTables.compactMap { pivot in
            guard let anchor = change.map(pivot.anchor) else { return nil }
            var pivot = pivot
            pivot.anchor = anchor
            return pivot
        }

        func mapRanges(_ ranges: [CellRange]) -> [CellRange] { ranges.compactMap { change.map($0) } }
        merges = mapRanges(merges).filter { !$0.isSingleCell }
        conditionalFormats = conditionalFormats.compactMap { rule in
            var rule = rule
            rule.ranges = mapRanges(rule.ranges)
            return rule.ranges.isEmpty ? nil : rule
        }
        validations = validations.compactMap { rule in
            var rule = rule
            rule.ranges = mapRanges(rule.ranges)
            return rule.ranges.isEmpty ? nil : rule
        }
        bandings = bandings.compactMap { banding in
            guard let range = change.map(banding.range) else { return nil }
            var banding = banding
            banding.range = range
            return banding
        }
        func mappedCriteria(_ criteria: [Int: FilterCriterion], in range: CellRange) -> [Int: FilterCriterion] {
            var result: [Int: FilterCriterion] = [:]
            for (column, criterion) in criteria {
                let mapped = change.affectsRows ? column : change.map(column)
                if let mapped, range.columns.contains(mapped) { result[mapped] = criterion }
            }
            return result
        }
        if let current = filter {
            if let range = change.map(current.range) {
                filter = SheetFilter(range: range, criteria: mappedCriteria(current.criteria, in: range))
            } else {
                filter = nil
            }
        }
        protections = protections.compactMap { protection in
            var protection = protection
            switch protection.scope {
            case .range(let range):
                guard let mapped = change.map(range) else { return nil }
                protection.scope = .range(mapped)
            case .sheet(let except):
                protection.scope = .sheet(except: mapRanges(except))
            }
            return protection
        }
        tables = tables.compactMap { table in
            guard let range = change.map(table.range) else { return nil }
            var table = table
            table.criteria = mappedCriteria(table.criteria, in: range)
            var types: [Int: TableColumnType] = [:]
            for (column, type) in table.columnTypes {
                let mapped = change.affectsRows ? column : change.map(column)
                if let mapped, range.columns.contains(mapped) { types[mapped] = type }
            }
            table.columnTypes = types
            table.range = range
            return table
        }
        filterViews = filterViews.compactMap { view in
            guard let range = change.map(view.range) else { return nil }
            var view = view
            view.criteria = mappedCriteria(view.criteria, in: range)
            view.range = range
            return view
        }

        guard change.band == nil else {
            // Shifting cells can push them past the grid's edge, which grows to keep them.
            rowCount = max(rowCount, lastRow + 1)
            columnCount = max(columnCount, lastColumn + 1)
            return
        }
        func remap(_ sizes: [Int: Double]) -> [Int: Double] {
            var result: [Int: Double] = [:]
            for (index, size) in sizes {
                if let newIndex = change.map(index) { result[newIndex] = size }
            }
            return result
        }
        func mapGroups(_ groups: [OutlineGroup]) -> [OutlineGroup] {
            var seen = Set<ClosedRange<Int>>()
            return groups.compactMap { group in
                guard let range = change.map(group.range.lowerBound, group.range.upperBound), seen.insert(range).inserted else { return nil }
                return OutlineGroup(range: range, isCollapsed: group.isCollapsed)
            }
        }
        if change.affectsRows {
            hiddenRows = Set(hiddenRows.compactMap { change.map($0) })
            filteredRows = Set(filteredRows.compactMap { change.map($0) })
            rowGroups = mapGroups(rowGroups)
        } else {
            hiddenColumns = Set(hiddenColumns.compactMap { change.map($0) })
            columnGroups = mapGroups(columnGroups)
        }
        switch change {
        case .insertRows(let at, let count):
            rowHeights = remap(rowHeights)
            rowCount += count
            if at < frozenRows { frozenRows += count }
        case .deleteRows(let at, let count):
            rowHeights = remap(rowHeights)
            frozenRows -= max(0, min(frozenRows, at + count) - at)
            rowCount = max(1, rowCount - count)
        case .insertColumns(let at, let count):
            columnWidths = remap(columnWidths)
            columnCount += count
            if at < frozenColumns { frozenColumns += count }
        case .deleteColumns(let at, let count):
            columnWidths = remap(columnWidths)
            frozenColumns -= max(0, min(frozenColumns, at + count) - at)
            columnCount = max(1, columnCount - count)
        case .insertCells, .deleteCells:
            break
        }
    }
}
