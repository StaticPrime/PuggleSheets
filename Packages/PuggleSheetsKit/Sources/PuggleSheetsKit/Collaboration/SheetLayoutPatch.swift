import Foundation

/// Changes to everything about a sheet besides its cells and name: a value for each part that changed, so that
/// changes to different parts of a sheet made at the same time on different Macs all stand. Column widths, row heights
/// and hidden rows and columns go column by column and row by row, so two people sizing different columns both keep
/// their sizes; everything else (merges, rules, filters, objects, frozen panes…) goes as a whole.
public struct SheetLayoutPatch: Codable, Equatable, Sendable {
    public enum Entry: Codable, Equatable, Sendable {
        case set(Data)
        case removed
    }

    /// By key: a whole part's name (`Field`), or "cw:", "rh:", "hr:" or "hc:" and a column or row number.
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The parts of a sheet that change as a whole.
    enum Field: String, CaseIterable {
        case rowCount, columnCount, defaultColumnWidth, defaultRowHeight, frozenRows, frozenColumns, merges, showsGridlines
        case tabColor, conditionalFormats, validations, filter, filteredRows, bandings, objects, pivotTables, filterViews
        case protections, rowGroups, columnGroups, tables
    }

    /// The parts that go one row or column at a time.
    enum Indexed: String, CaseIterable {
        case columnWidth = "cw", rowHeight = "rh", hiddenRow = "hr", hiddenColumn = "hc"

        var isRow: Bool { self == .rowHeight || self == .hiddenRow }

        func key(_ index: Int) -> String { "\(rawValue):\(index)" }

        static func parse(_ key: String) -> (Indexed, Int)? {
            guard let colon = key.firstIndex(of: ":"), let kind = Indexed(rawValue: String(key[..<colon])),
                  let index = Int(key[key.index(after: colon)...]) else { return nil }
            return (kind, index)
        }
    }

    // MARK: Making patches

    /// What changed from `old` to `new` (the same sheet).
    public static func diff(from old: Sheet, to new: Sheet) -> SheetLayoutPatch {
        var patch = SheetLayoutPatch()
        for field in Field.allCases where !Self.same(field, old, new) {
            patch.entries[field.rawValue] = .set(Self.encode(field, of: new))
        }
        func indexed<V: Codable & Equatable>(_ kind: Indexed, _ old: [Int: V], _ new: [Int: V]) {
            for index in Set(old.keys).union(new.keys) where old[index] != new[index] {
                patch.entries[kind.key(index)] = new[index].map { .set(SyncCoding.encode($0)) } ?? .removed
            }
        }
        indexed(.columnWidth, old.columnWidths, new.columnWidths)
        indexed(.rowHeight, old.rowHeights, new.rowHeights)
        for index in old.hiddenRows.symmetricDifference(new.hiddenRows) {
            patch.entries[Indexed.hiddenRow.key(index)] = new.hiddenRows.contains(index) ? .set(SyncCoding.encode(true)) : .removed
        }
        for index in old.hiddenColumns.symmetricDifference(new.hiddenColumns) {
            patch.entries[Indexed.hiddenColumn.key(index)] = new.hiddenColumns.contains(index) ? .set(SyncCoding.encode(true)) : .removed
        }
        return patch
    }

    /// The sheet's values for the parts `keys` name: what puts them back as they are now.
    public static func current(_ keys: some Sequence<String>, of sheet: Sheet) -> SheetLayoutPatch {
        var patch = SheetLayoutPatch()
        for key in keys {
            if let field = Field(rawValue: key) {
                patch.entries[key] = .set(encode(field, of: sheet))
            } else if let (kind, index) = Indexed.parse(key) {
                switch kind {
                case .columnWidth: patch.entries[key] = sheet.columnWidths[index].map { .set(SyncCoding.encode($0)) } ?? .removed
                case .rowHeight: patch.entries[key] = sheet.rowHeights[index].map { .set(SyncCoding.encode($0)) } ?? .removed
                case .hiddenRow: patch.entries[key] = sheet.hiddenRows.contains(index) ? .set(SyncCoding.encode(true)) : .removed
                case .hiddenColumn: patch.entries[key] = sheet.hiddenColumns.contains(index) ? .set(SyncCoding.encode(true)) : .removed
                }
            }
        }
        return patch
    }

    /// This patch followed by `later`, as one.
    public func merging(_ later: SheetLayoutPatch) -> SheetLayoutPatch {
        SheetLayoutPatch(entries: entries.merging(later.entries) { $1 })
    }

    /// The patch without the parts `keys` name.
    public func removing(_ keys: Set<String>) -> SheetLayoutPatch {
        SheetLayoutPatch(entries: entries.filter { !keys.contains($0.key) })
    }

    // MARK: Applying

    /// Sets the parts this patch changes. Parts that don't decode (from a later version, say) are left alone.
    public func apply(to sheet: inout Sheet) {
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
            if let field = Field(rawValue: key) {
                guard case .set(let data) = entry else { continue }
                Self.set(field, from: data, on: &sheet)
            } else if let (kind, index) = Indexed.parse(key) {
                switch (kind, entry) {
                case (.columnWidth, .set(let data)): sheet.columnWidths[index] = try? SyncCoding.decode(Double.self, from: data)
                case (.columnWidth, .removed): sheet.columnWidths[index] = nil
                case (.rowHeight, .set(let data)): sheet.rowHeights[index] = try? SyncCoding.decode(Double.self, from: data)
                case (.rowHeight, .removed): sheet.rowHeights[index] = nil
                case (.hiddenRow, .set): sheet.hiddenRows.insert(index)
                case (.hiddenRow, .removed): sheet.hiddenRows.remove(index)
                case (.hiddenColumn, .set): sheet.hiddenColumns.insert(index)
                case (.hiddenColumn, .removed): sheet.hiddenColumns.remove(index)
                }
            }
        }
    }

    /// Whether the patch changes row heights, column widths or what's hidden: only the grid's geometry, nothing that
    /// rules or formulas depend on.
    var touchesOnlyGeometry: Bool {
        entries.keys.allSatisfy { Indexed.parse($0) != nil }
    }

    // MARK: Fields

    private static func same(_ field: Field, _ a: Sheet, _ b: Sheet) -> Bool {
        switch field {
        case .rowCount: a.rowCount == b.rowCount
        case .columnCount: a.columnCount == b.columnCount
        case .defaultColumnWidth: a.defaultColumnWidth == b.defaultColumnWidth
        case .defaultRowHeight: a.defaultRowHeight == b.defaultRowHeight
        case .frozenRows: a.frozenRows == b.frozenRows
        case .frozenColumns: a.frozenColumns == b.frozenColumns
        case .merges: a.merges == b.merges
        case .showsGridlines: a.showsGridlines == b.showsGridlines
        case .tabColor: a.tabColor == b.tabColor
        case .conditionalFormats: a.conditionalFormats == b.conditionalFormats
        case .validations: a.validations == b.validations
        case .filter: a.filter == b.filter
        case .filteredRows: a.filteredRows == b.filteredRows
        case .bandings: a.bandings == b.bandings
        case .objects: a.objects == b.objects
        case .pivotTables: a.pivotTables == b.pivotTables
        case .filterViews: a.filterViews == b.filterViews
        case .protections: a.protections == b.protections
        case .rowGroups: a.rowGroups == b.rowGroups
        case .columnGroups: a.columnGroups == b.columnGroups
        case .tables: a.tables == b.tables
        }
    }

    private static func encode(_ field: Field, of sheet: Sheet) -> Data {
        switch field {
        case .rowCount: SyncCoding.encode(sheet.rowCount)
        case .columnCount: SyncCoding.encode(sheet.columnCount)
        case .defaultColumnWidth: SyncCoding.encode(sheet.defaultColumnWidth)
        case .defaultRowHeight: SyncCoding.encode(sheet.defaultRowHeight)
        case .frozenRows: SyncCoding.encode(sheet.frozenRows)
        case .frozenColumns: SyncCoding.encode(sheet.frozenColumns)
        case .merges: SyncCoding.encode(sheet.merges)
        case .showsGridlines: SyncCoding.encode(sheet.showsGridlines)
        case .tabColor: SyncCoding.encode(sheet.tabColor)
        case .conditionalFormats: SyncCoding.encode(sheet.conditionalFormats)
        case .validations: SyncCoding.encode(sheet.validations)
        case .filter: SyncCoding.encode(sheet.filter)
        case .filteredRows: SyncCoding.encode(sheet.filteredRows.sorted())
        case .bandings: SyncCoding.encode(sheet.bandings)
        case .objects: SyncCoding.encode(sheet.objects)
        case .pivotTables: SyncCoding.encode(sheet.pivotTables)
        case .filterViews: SyncCoding.encode(sheet.filterViews)
        case .protections: SyncCoding.encode(sheet.protections)
        case .rowGroups: SyncCoding.encode(sheet.rowGroups)
        case .columnGroups: SyncCoding.encode(sheet.columnGroups)
        case .tables: SyncCoding.encode(sheet.tables)
        }
    }

    private static func set(_ field: Field, from data: Data, on sheet: inout Sheet) {
        func value<T: Decodable>(_ type: T.Type) -> T? { try? SyncCoding.decode(type, from: data) }
        switch field {
        case .rowCount: if let count = value(Int.self) { sheet.rowCount = max(1, count) }
        case .columnCount: if let count = value(Int.self) { sheet.columnCount = max(1, count) }
        case .defaultColumnWidth: if let width = value(Double.self) { sheet.defaultColumnWidth = width }
        case .defaultRowHeight: if let height = value(Double.self) { sheet.defaultRowHeight = height }
        case .frozenRows: if let rows = value(Int.self) { sheet.frozenRows = rows }
        case .frozenColumns: if let columns = value(Int.self) { sheet.frozenColumns = columns }
        case .merges: if let merges = value([CellRange].self) { sheet.merges = merges }
        case .showsGridlines: if let shows = value(Bool.self) { sheet.showsGridlines = shows }
        case .tabColor: if let color = value(RGBColor?.self) { sheet.tabColor = color }
        case .conditionalFormats: if let rules = value([ConditionalFormatRule].self) { sheet.conditionalFormats = rules }
        case .validations: if let rules = value([DataValidationRule].self) { sheet.validations = rules }
        case .filter: if let filter = value(SheetFilter?.self) { sheet.filter = filter }
        case .filteredRows: if let rows = value([Int].self) { sheet.filteredRows = Set(rows) }
        case .bandings: if let bandings = value([Banding].self) { sheet.bandings = bandings }
        case .objects: if let objects = value([SheetObject].self) { sheet.objects = objects }
        case .pivotTables: if let pivots = value([PivotTable].self) { sheet.pivotTables = pivots }
        case .filterViews: if let views = value([FilterView].self) { sheet.filterViews = views }
        case .protections: if let protections = value([ProtectedRange].self) { sheet.protections = protections }
        case .rowGroups: if let groups = value([OutlineGroup].self) { sheet.rowGroups = groups }
        case .columnGroups: if let groups = value([OutlineGroup].self) { sheet.columnGroups = groups }
        case .tables: if let tables = value([SheetTable].self) { sheet.tables = tables }
        }
    }

    // MARK: Following structural changes

    /// The patch, made before `change` to sheet `sheet` was made, rewritten to follow it: rows and columns it names
    /// moved, and ranges and references in its rules, filters and objects moved too. `workbook` gives the sheets'
    /// names and sizes.
    func following(_ change: StructuralChange, inSheet changed: UUID, patchSheet: UUID, workbook: Workbook) -> SheetLayoutPatch {
        rewritten(patchSheet: patchSheet, workbook: workbook) { scratch in
            guard let index = scratch.sheetIndex(id: changed) else { return }
            scratch.apply(change, toSheet: index)
        } mapIndex: { kind, index in
            guard changed == patchSheet, change.band == nil, kind.isRow == change.affectsRows else { return index }
            return change.map(index)
        }
    }

    /// The patch, made before sheet `renamed` took the name `name`, rewritten to follow: references to the sheet by
    /// its old name use the new one.
    func following(rename renamed: UUID, to name: String, patchSheet: UUID, workbook: Workbook) -> SheetLayoutPatch {
        rewritten(patchSheet: patchSheet, workbook: workbook) { scratch in
            guard let index = scratch.sheetIndex(id: renamed) else { return }
            scratch.renameSheet(at: index, to: name)
        } mapIndex: { _, index in index }
    }

    /// The patch, made before sheet `removed` went, rewritten to follow: references to it become #REF!.
    func following(removal removed: UUID, patchSheet: UUID, workbook: Workbook) -> SheetLayoutPatch {
        rewritten(patchSheet: patchSheet, workbook: workbook) { scratch in
            guard let index = scratch.sheetIndex(id: removed), scratch.sheets.count > 1 else { return }
            scratch.removeSheet(at: index)
        } mapIndex: { _, index in index }
    }

    /// Runs `change` on a stand-in workbook holding the patch's parts, and reads them back: the workbook's own
    /// editing moves and rewrites them exactly as it moves and rewrites the real ones.
    private func rewritten(patchSheet: UUID, workbook: Workbook, _ change: (inout Workbook) -> Void,
                           mapIndex: (Indexed, Int) -> Int?) -> SheetLayoutPatch {
        let wholeFields = entries.keys.compactMap(Field.init(rawValue:))
        var result = SheetLayoutPatch()
        if !wholeFields.isEmpty {
            var scratch = Workbook(sheets: workbook.sheets.map(\.skeleton), namedRanges: workbook.namedRanges)
            if scratch.sheetIndex(id: patchSheet) == nil { scratch.sheets.append(Sheet(name: patchSheet.uuidString, id: patchSheet)) }
            let index = scratch.sheetIndex(id: patchSheet)!
            SheetLayoutPatch(entries: entries.filter { Field(rawValue: $0.key) != nil }).apply(to: &scratch.sheets[index])
            change(&scratch)
            if let after = scratch.sheetIndex(id: patchSheet) {
                for field in wholeFields { result.entries[field.rawValue] = .set(Self.encode(field, of: scratch.sheets[after])) }
            }
        }
        for (key, entry) in entries {
            guard let (kind, index) = Indexed.parse(key) else { continue }
            if let mapped = mapIndex(kind, index) { result.entries[kind.key(mapped)] = entry }
        }
        return result
    }
}
