import Foundation

/// One step of a change to a shared workbook, as it travels between Macs. Every Mac applies the same steps in the
/// same order (the shared log's), the same way (`Workbook.apply(_:)`), so every Mac ends up with the same workbook.
///
/// Cells and layout parts are set to values, each cell and part on its own, so changes to different cells or parts
/// made at the same time all stand; two changes to the same one leave whichever came later in the log. Inserting and
/// deleting rows, columns and cells travels as the change itself, so cells, formulas and ranges that other people
/// edit at the same time follow it. Comments never travel with cells: they go through the talk zone (see
/// `SharedComment`), so cell changes neither carry nor clobber them.
public enum WorkbookOp: Sendable {
    /// Sets these cells, without their comments; an empty `Cell()` clears one.
    case cells(sheet: UUID, cells: [CellAddress: Cell])
    case layout(sheet: UUID, patch: SheetLayoutPatch)
    /// Inserts or deletes rows, columns or cells, with every formula in the workbook following.
    case structure(sheet: UUID, change: StructuralChange)
    /// A new sheet, whole (without comments), at this place among the sheets.
    case insertSheet(sheet: Sheet, at: Int)
    case removeSheet(sheet: UUID)
    /// Renames a sheet, with every formula following.
    case renameSheet(sheet: UUID, name: String)
    case moveSheet(sheet: UUID, to: Int)
    /// Data ▸ Named ranges, all of them.
    case namedRanges([NamedRange])

    /// The op as it travels: a sheet it adds goes without its comments, which travel apart.
    public var withoutComments: WorkbookOp {
        if case .insertSheet(let sheet, let index) = self { return .insertSheet(sheet: sheet.withoutComments, at: index) }
        if case .cells(let sheet, let cells) = self, cells.values.contains(where: { $0.comment != nil }) {
            return .cells(sheet: sheet, cells: cells.mapValues(\.withoutComment))
        }
        return self
    }

    /// The sheet the op is on, if it's on one.
    public var sheet: UUID? {
        switch self {
        case .cells(let sheet, _), .layout(let sheet, _), .structure(let sheet, _), .removeSheet(let sheet), .renameSheet(let sheet, _),
             .moveSheet(let sheet, _):
            sheet
        case .insertSheet(let sheet, _):
            sheet.id
        case .namedRanges:
            nil
        }
    }

    /// Whether it sets values by key (cells, layout parts, named ranges) rather than moving things or changing which
    /// sheets there are.
    public var isKeyed: Bool {
        switch self {
        case .cells, .layout, .namedRanges: true
        case .structure, .insertSheet, .removeSheet, .renameSheet, .moveSheet: false
        }
    }

    /// Whether it moves cells, or takes a sheet away, or renames one: what places and references must follow.
    public var isMover: Bool {
        switch self {
        case .structure, .removeSheet, .renameSheet: true
        case .cells, .layout, .namedRanges, .insertSheet, .moveSheet: false
        }
    }

    /// Where a cell of sheet `sheet` is after this op; nil when the op deleted it.
    public func map(_ address: CellAddress, inSheet sheet: UUID) -> CellAddress? {
        switch self {
        case .structure(let changed, let change) where changed == sheet: change.map(address)
        case .removeSheet(let removed) where removed == sheet: nil
        default: address
        }
    }

    /// Where a cell of sheet `sheet` after this op was before it; nil when the op made it (an inserted row, say).
    public func unmap(_ address: CellAddress, inSheet sheet: UUID) -> CellAddress? {
        switch self {
        case .structure(let changed, let change) where changed == sheet: change.unmap(address)
        default: address
        }
    }
}

/// What one op sets, for telling which ops set the same thing.
enum OpKey: Hashable {
    case cell(UUID, CellAddress)
    case layout(UUID, String)
    case namedRanges
}

extension WorkbookOp {
    var keys: [OpKey] {
        switch self {
        case .cells(let sheet, let cells): cells.keys.map { .cell(sheet, $0) }
        case .layout(let sheet, let patch): patch.entries.keys.map { .layout(sheet, $0) }
        case .namedRanges: [.namedRanges]
        default: []
        }
    }

    /// The op without the parts that set `keys`; nil when nothing's left.
    func removing(_ keys: Set<OpKey>) -> WorkbookOp? {
        switch self {
        case .cells(let sheet, let cells):
            let kept = cells.filter { !keys.contains(.cell(sheet, $0.key)) }
            return kept.isEmpty ? nil : .cells(sheet: sheet, cells: kept)
        case .layout(let sheet, let patch):
            let kept = SheetLayoutPatch(entries: patch.entries.filter { !keys.contains(.layout(sheet, $0.key)) })
            return kept.isEmpty ? nil : .layout(sheet: sheet, patch: kept)
        case .namedRanges:
            return keys.contains(.namedRanges) ? nil : self
        default:
            return self
        }
    }
}

// MARK: - Coding

extension WorkbookOp: Codable {
    private enum Kind: String, Codable {
        case cells, layout, structure, insertSheet, removeSheet, renameSheet, moveSheet, namedRanges
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "k", sheet = "s", cells = "c", patch = "p", change = "x", newSheet = "n", index = "i", name = "m", ranges = "r"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .cells:
            let entries = try container.decode([CellEntry].self, forKey: .cells)
            var cells: [CellAddress: Cell] = [:]
            for entry in entries { cells[CellAddress(row: entry.row, column: entry.column)] = entry.cell }
            self = .cells(sheet: try container.decode(UUID.self, forKey: .sheet), cells: cells)
        case .layout:
            self = .layout(sheet: try container.decode(UUID.self, forKey: .sheet), patch: try container.decode(SheetLayoutPatch.self, forKey: .patch))
        case .structure:
            self = .structure(sheet: try container.decode(UUID.self, forKey: .sheet), change: try container.decode(StructuralChange.self, forKey: .change))
        case .insertSheet:
            self = .insertSheet(sheet: try container.decode(Sheet.self, forKey: .newSheet), at: try container.decode(Int.self, forKey: .index))
        case .removeSheet:
            self = .removeSheet(sheet: try container.decode(UUID.self, forKey: .sheet))
        case .renameSheet:
            self = .renameSheet(sheet: try container.decode(UUID.self, forKey: .sheet), name: try container.decode(String.self, forKey: .name))
        case .moveSheet:
            self = .moveSheet(sheet: try container.decode(UUID.self, forKey: .sheet), to: try container.decode(Int.self, forKey: .index))
        case .namedRanges:
            self = .namedRanges(try container.decode([NamedRange].self, forKey: .ranges))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cells(let sheet, let cells):
            try container.encode(Kind.cells, forKey: .kind)
            try container.encode(sheet, forKey: .sheet)
            try container.encode(cells.sorted { $0.key < $1.key }.map { CellEntry(row: $0.key.row, column: $0.key.column, cell: $0.value) },
                                 forKey: .cells)
        case .layout(let sheet, let patch):
            try container.encode(Kind.layout, forKey: .kind)
            try container.encode(sheet, forKey: .sheet)
            try container.encode(patch, forKey: .patch)
        case .structure(let sheet, let change):
            try container.encode(Kind.structure, forKey: .kind)
            try container.encode(sheet, forKey: .sheet)
            try container.encode(change, forKey: .change)
        case .insertSheet(let sheet, let index):
            try container.encode(Kind.insertSheet, forKey: .kind)
            try container.encode(sheet, forKey: .newSheet)
            try container.encode(index, forKey: .index)
        case .removeSheet(let sheet):
            try container.encode(Kind.removeSheet, forKey: .kind)
            try container.encode(sheet, forKey: .sheet)
        case .renameSheet(let sheet, let name):
            try container.encode(Kind.renameSheet, forKey: .kind)
            try container.encode(sheet, forKey: .sheet)
            try container.encode(name, forKey: .name)
        case .moveSheet(let sheet, let index):
            try container.encode(Kind.moveSheet, forKey: .kind)
            try container.encode(sheet, forKey: .sheet)
            try container.encode(index, forKey: .index)
        case .namedRanges(let ranges):
            try container.encode(Kind.namedRanges, forKey: .kind)
            try container.encode(ranges, forKey: .ranges)
        }
    }
}

// MARK: - Applying

extension Workbook {
    /// Applies an op the way every Mac does. Ops on sheets that are gone do nothing; names that clash get a number.
    public mutating func apply(_ op: WorkbookOp) {
        switch op {
        case .cells(let id, let cells):
            guard let index = sheetIndex(id: id) else { return }
            var updates: [CellAddress: Cell] = [:]
            updates.reserveCapacity(cells.count)
            for (address, cell) in cells {
                var cell = cell
                // The comment on the cell here stays: comments travel apart. (Nothing else changes with a cell, not
                // even the sheet's size, so cells and layout parts set at the same time never interfere.)
                cell.comment = sheets[index].cells[address]?.comment
                updates[address] = cell
            }
            sheets[index].setCells(updates)
        case .layout(let id, let patch):
            guard let index = sheetIndex(id: id) else { return }
            patch.apply(to: &sheets[index])
        case .structure(let id, let change):
            guard let index = sheetIndex(id: id) else { return }
            apply(change, toSheet: index)
        case .insertSheet(let sheet, let at):
            guard sheetIndex(id: sheet.id) == nil else { return }
            var sheet = sheet
            sheet.name = uniqueSheetName(sheet.name, for: sheet.id)
            sheets.insert(sheet, at: min(max(at, 0), sheets.count))
        case .removeSheet(let id):
            guard let index = sheetIndex(id: id), sheets.count > 1 else { return }
            removeSheet(at: index)
        case .renameSheet(let id, let name):
            guard let index = sheetIndex(id: id) else { return }
            renameSheet(at: index, to: uniqueSheetName(name, for: id))
        case .moveSheet(let id, let to):
            guard let index = sheetIndex(id: id) else { return }
            let sheet = sheets.remove(at: index)
            sheets.insert(sheet, at: min(max(to, 0), sheets.count))
        case .namedRanges(let ranges):
            namedRanges = ranges
        }
    }

    public mutating func apply(_ ops: [WorkbookOp]) {
        for op in ops { apply(op) }
    }

    public func applying(_ ops: [WorkbookOp]) -> Workbook {
        var workbook = self
        workbook.apply(ops)
        return workbook
    }

    /// `name`, or the first of "name (2)", "name (3)"… that no other sheet has.
    func uniqueSheetName(_ name: String, for id: UUID) -> String {
        func taken(_ candidate: String) -> Bool {
            sheets.contains { $0.id != id && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        guard taken(name) else { return name }
        var number = 2
        while taken("\(name) (\(number))") { number += 1 }
        return "\(name) (\(number))"
    }

    /// The workbook's sheets without their cells, for working out where things move.
    var skeleton: Workbook {
        Workbook(sheets: sheets.map(\.skeleton), namedRanges: namedRanges)
    }
}

// MARK: - Working out ops

extension WorkbookOp {
    /// The ops that turn `old` into `new`, comments aside: sheets that came, went, moved or were renamed, then each
    /// sheet's changed cells and layout, then named ranges. Applied to `old` they give `new` exactly.
    public static func changes(from old: Workbook, to new: Workbook) -> [WorkbookOp] {
        let ops = diff(from: old, to: new)
        return ops + corrections(after: ops, from: old, to: new)
    }

    /// `ops`, made by an edit that turned `old` into `new`, with whatever else it takes to give `new` exactly when
    /// they're applied to `old`.
    public static func checked(_ ops: [WorkbookOp], from old: Workbook, to new: Workbook) -> [WorkbookOp] {
        ops + corrections(after: ops, from: old, to: new)
    }

    private static func corrections(after ops: [WorkbookOp], from old: Workbook, to new: Workbook) -> [WorkbookOp] {
        let applied = old.withoutComments.applying(ops)
        let fixes = diff(from: applied, to: new.withoutComments)
        return fixes
    }

    static func diff(from old: Workbook, to new: Workbook) -> [WorkbookOp] {
        var ops: [WorkbookOp] = []
        var current = old.skeleton
        let newIDs = Set(new.sheets.map(\.id))
        let oldIDs = Set(old.sheets.map(\.id))
        for sheet in old.sheets where !newIDs.contains(sheet.id) {
            let op = WorkbookOp.removeSheet(sheet: sheet.id)
            ops.append(op)
            current.sheets.removeAll { $0.id == sheet.id }
        }
        for (index, sheet) in new.sheets.enumerated() where !oldIDs.contains(sheet.id) {
            ops.append(.insertSheet(sheet: sheet.withoutComments, at: index))
            current.sheets.insert(sheet.skeleton, at: min(index, current.sheets.count))
        }
        for (index, sheet) in new.sheets.enumerated() where index < current.sheets.count && current.sheets[index].id != sheet.id {
            guard let from = current.sheets.firstIndex(where: { $0.id == sheet.id }) else { continue }
            ops.append(.moveSheet(sheet: sheet.id, to: index))
            current.sheets.insert(current.sheets.remove(at: from), at: index)
        }
        for sheet in new.sheets {
            guard let oldIndex = old.sheetIndex(id: sheet.id) else { continue }
            let before = old.sheets[oldIndex]
            if before.name != sheet.name { ops.append(.renameSheet(sheet: sheet.id, name: sheet.name)) }
            let cells = cellChanges(from: before, to: sheet)
            if !cells.isEmpty { ops.append(.cells(sheet: sheet.id, cells: cells)) }
            let patch = SheetLayoutPatch.diff(from: before, to: sheet)
            if !patch.isEmpty { ops.append(.layout(sheet: sheet.id, patch: patch)) }
        }
        if old.namedRanges != new.namedRanges { ops.append(.namedRanges(new.namedRanges)) }
        return ops
    }

    /// The cells that differ, comments and formulas' latest results aside, as they are in `new` (empty where `new`
    /// has none).
    public static func cellChanges(from old: Sheet, to new: Sheet) -> [CellAddress: Cell] {
        var result: [CellAddress: Cell] = [:]
        for (address, cell) in new.cells {
            let bare = cell.withoutComment
            if !(old.cells[address]?.withoutComment ?? Cell()).hasSameContent(as: bare) { result[address] = bare }
        }
        for (address, cell) in old.cells where new.cells[address] == nil && !cell.withoutComment.isEmpty {
            result[address] = Cell()
        }
        return result
    }

    // MARK: Undoing

    /// The ops that take `ops` back: applied to `after` (what `ops` made of `before`), they give `before` again,
    /// comments aside.
    public static func inverse(of ops: [WorkbookOp], before: Workbook, after: Workbook) -> [WorkbookOp] {
        if ops.allSatisfy(\.isKeyed) {
            // Values set by key move nothing: what each key held before puts it back, exactly.
            return Array(ops.map { before.inverse(of: $0) }.reversed().joined())
        }
        var state = before.withoutComments
        var steps: [[WorkbookOp]] = []
        for op in ops {
            steps.append(state.inverse(of: op))
            state.apply(op)
        }
        let undo = Array(steps.reversed().joined())
        return checked(undo, from: after.withoutComments, to: before.withoutComments)
    }
}

extension Workbook {
    /// What takes `op` back, as far as the op itself goes (from the workbook as it is before the op).
    fileprivate func inverse(of op: WorkbookOp) -> [WorkbookOp] {
        switch op {
        case .cells(let id, let cells):
            guard let index = sheetIndex(id: id) else { return [] }
            var old: [CellAddress: Cell] = [:]
            for address in cells.keys { old[address] = sheets[index].cells[address]?.withoutComment ?? Cell() }
            return [.cells(sheet: id, cells: old)]
        case .layout(let id, let patch):
            guard let index = sheetIndex(id: id) else { return [] }
            return [.layout(sheet: id, patch: SheetLayoutPatch.current(patch.entries.keys, of: sheets[index]))]
        case .structure(let id, let change):
            return [.structure(sheet: id, change: change.inverse)]
        case .insertSheet(let sheet, _):
            return [.removeSheet(sheet: sheet.id)]
        case .removeSheet(let id):
            guard let index = sheetIndex(id: id) else { return [] }
            return [.insertSheet(sheet: sheets[index], at: index)]
        case .renameSheet(let id, _):
            guard let index = sheetIndex(id: id) else { return [] }
            return [.renameSheet(sheet: id, name: sheets[index].name)]
        case .moveSheet(let id, _):
            guard let index = sheetIndex(id: id) else { return [] }
            return [.moveSheet(sheet: id, to: index)]
        case .namedRanges:
            return [.namedRanges(namedRanges)]
        }
    }
}

extension StructuralChange {
    /// The change that takes this one back, place for place (what was deleted comes back empty).
    public var inverse: StructuralChange {
        switch self {
        case .insertRows(let at, let count): .deleteRows(at: at, count: count)
        case .deleteRows(let at, let count): .insertRows(at: at, count: count)
        case .insertColumns(let at, let count): .deleteColumns(at: at, count: count)
        case .deleteColumns(let at, let count): .insertColumns(at: at, count: count)
        case .insertCells(let range, let down): .deleteCells(range, shiftUp: down)
        case .deleteCells(let range, let up): .insertCells(range, shiftDown: up)
        }
    }

    /// Where a cell after this change was before it; nil for a cell the change inserted.
    public func unmap(_ address: CellAddress) -> CellAddress? {
        let rows = affectsRows
        if let band, !band.contains(rows ? address.column : address.row) { return address }
        let index = rows ? address.row : address.column
        let before: Int?
        switch axisChange {
        case .insertRows(let at, let count), .insertColumns(let at, let count):
            before = index < at ? index : (index < at + count ? nil : index - count)
        case .deleteRows(let at, let count), .deleteColumns(let at, let count):
            before = index < at ? index : index + count
        case .insertCells, .deleteCells:
            before = index
        }
        guard let before else { return nil }
        return rows ? CellAddress(row: before, column: address.column) : CellAddress(row: address.row, column: before)
    }
}
