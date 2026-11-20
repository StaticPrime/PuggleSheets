import Foundation

// Rewriting ops to follow others.
//
// A Mac's changes that aren't in the log yet were made on the workbook as that Mac had it. When someone else's change
// gets into the log first, they're rewritten to follow it (see `SyncClient`): a cell typed into row 10 goes to row 12
// once two rows are inserted above it, a formula pointing at a deleted column shows #REF!, and so on, the same way the
// workbook itself moves things for its own edits. That rewriting only has to keep what each person meant; it doesn't
// decide what every Mac ends up with. The log does: every Mac applies the same ops in the same order.

extension WorkbookOp {
    /// This op, made on the same workbook as `other` (`context`: its sheets' names and sizes), rewritten to come
    /// after it. It may become several ops, or none.
    func rebased(over other: WorkbookOp, context: Workbook) -> [WorkbookOp] {
        switch other {
        case .cells, .layout, .namedRanges, .moveSheet, .insertSheet:
            // Values set elsewhere, or sheets added or reordered: nothing here moves.
            return [self]
        case .structure, .removeSheet, .renameSheet:
            break
        }
        switch self {
        case .cells(let sheet, let cells):
            return Self.rebased(cells: cells, onSheet: sheet, over: other, context: context)
        case .layout(let sheet, let patch):
            let moved: SheetLayoutPatch
            switch other {
            case .structure(let changed, let change):
                moved = patch.following(change, inSheet: changed, patchSheet: sheet, workbook: context)
            case .removeSheet(let removed):
                if removed == sheet { return [] }
                moved = patch.following(removal: removed, patchSheet: sheet, workbook: context)
            case .renameSheet(let renamed, let name):
                moved = patch.following(rename: renamed, to: context.uniqueSheetName(name, for: renamed), patchSheet: sheet, workbook: context)
            default:
                moved = patch
            }
            return moved.isEmpty ? [] : [.layout(sheet: sheet, patch: moved)]
        case .structure(let sheet, let change):
            switch other {
            case .structure(let changed, let otherChange) where changed == sheet:
                return change.rebased(over: otherChange).map { .structure(sheet: sheet, change: $0) }
            case .removeSheet(let removed) where removed == sheet:
                return []
            default:
                return [self]
            }
        case .insertSheet(let new, let index):
            // A sheet of its own: its formulas and rules follow the other sheets' changes.
            var scratch = context
            scratch.sheets.removeAll { $0.id == new.id }
            scratch.sheets.append(new)
            scratch.apply(other)
            guard let moved = scratch.sheetIndex(id: new.id) else { return [] }
            return [.insertSheet(sheet: scratch.sheets[moved], at: index)]
        case .namedRanges(let ranges):
            var scratch = context
            scratch.namedRanges = ranges
            scratch.apply(other)
            return [.namedRanges(scratch.namedRanges)]
        case .removeSheet, .renameSheet, .moveSheet:
            return [self]
        }
    }

    private static func rebased(cells: [CellAddress: Cell], onSheet sheet: UUID, over other: WorkbookOp, context: Workbook) -> [WorkbookOp] {
        func name(_ id: UUID) -> String? { context.sheetIndex(id: id).map { context.sheets[$0].name } }
        let ownName = name(sheet) ?? sheet.uuidString
        var result: [CellAddress: Cell] = [:]
        result.reserveCapacity(cells.count)
        switch other {
        case .structure(let changed, let change):
            guard let changedName = name(changed) else { return [.cells(sheet: sheet, cells: cells)] }
            for (address, cell) in cells {
                guard let target = changed == sheet ? change.map(address) : address else { continue }
                var cell = cell
                if let formula = cell.formula {
                    cell.formula = FormulaRewriter.adjust(formula, for: change, inSheet: changedName,
                                                          formulaSheet: changed == sheet ? changedName : ownName)
                }
                result[target] = cell
            }
        case .removeSheet(let removed):
            if removed == sheet { return [] }
            guard let removedName = name(removed) else { return [.cells(sheet: sheet, cells: cells)] }
            for (address, cell) in cells {
                var cell = cell
                if let formula = cell.formula { cell.formula = FormulaRewriter.removeSheet(formula, named: removedName) }
                result[address] = cell
            }
        case .renameSheet(let renamed, let newName):
            guard let oldName = name(renamed) else { return [.cells(sheet: sheet, cells: cells)] }
            let effective = context.uniqueSheetName(newName, for: renamed)
            for (address, cell) in cells {
                var cell = cell
                if let formula = cell.formula { cell.formula = FormulaRewriter.renameSheet(formula, from: oldName, to: effective) }
                result[address] = cell
            }
        default:
            return [.cells(sheet: sheet, cells: cells)]
        }
        return result.isEmpty ? [] : [.cells(sheet: sheet, cells: result)]
    }
}

extension Array where Element == WorkbookOp {
    /// These ops, applied one after another to `context`, rewritten to come after `others` (made on the same
    /// workbook). Answers them, and `others` rewritten to come after them, for whatever follows.
    public func rebased(over others: [WorkbookOp], context: Workbook) -> (ops: [WorkbookOp], others: [WorkbookOp]) {
        let movers = others.filter(\.isMover)
        var result: [WorkbookOp] = []
        var state = context.skeleton
        var remaining = movers
        for op in self {
            // This op past each of the others, in the workbook as each of them finds it.
            var moving = [op]
            var passing = state
            for other in remaining {
                moving = moving.flatMap { $0.rebased(over: other, context: passing) }
                passing.apply(other)
            }
            // The others past this op, for the ops after it.
            remaining = remaining.flatMap { $0.rebased(over: op, context: state) }
            result += moving
            if let skeletal = op.skeletal { state.apply(skeletal) }
        }
        return (result, remaining)
    }
}

extension WorkbookOp {
    /// The op as it affects a workbook's sheets without their cells: their names, sizes and order.
    var skeletal: WorkbookOp? {
        switch self {
        case .insertSheet(let sheet, let index): .insertSheet(sheet: sheet.skeleton, at: index)
        case .cells: nil
        default: self
        }
    }
}

extension StructuralChange {
    /// This change, made on the same sheet as `other`, rewritten to come after it: inserting where the same rows or
    /// columns are now, deleting those that are left.
    func rebased(over other: StructuralChange) -> [StructuralChange] {
        let sameAxis = affectsRows == other.affectsRows
        // Cell shifts move ranges; whole rows and columns stay put for them and for changes along the other axis.
        if band != nil || other.band != nil {
            guard sameAxis else { return [self] }
            switch self {
            case .insertCells(let range, let down):
                return other.map(range).map { [.insertCells($0, shiftDown: down)] } ?? []
            case .deleteCells(let range, let up):
                return other.map(range).map { [.deleteCells($0, shiftUp: up)] } ?? []
            default:
                return [self]
            }
        }
        guard sameAxis else { return [self] }
        switch (self, other) {
        case (.insertRows(let at, let count), _):
            return [.insertRows(at: Self.insertionPoint(at, after: other), count: count)]
        case (.insertColumns(let at, let count), _):
            return [.insertColumns(at: Self.insertionPoint(at, after: other), count: count)]
        case (.deleteRows(let at, let count), _):
            return Self.deletions(at, count, after: other).map { .deleteRows(at: $0.at, count: $0.count) }
        case (.deleteColumns(let at, let count), _):
            return Self.deletions(at, count, after: other).map { .deleteColumns(at: $0.at, count: $0.count) }
        default:
            return [self]
        }
    }

    /// Where an insertion at `index` goes once `other` is made.
    private static func insertionPoint(_ index: Int, after other: StructuralChange) -> Int {
        switch other {
        case .insertRows(let at, let count), .insertColumns(let at, let count):
            return at <= index ? index + count : index
        case .deleteRows(let at, let count), .deleteColumns(let at, let count):
            if index <= at { return index }
            return index >= at + count ? index - count : at
        default:
            return index
        }
    }

    /// The rows or columns `at..<at+count` still there once `other` is made, as deletions to make one after
    /// another (the later ones first, so the earlier stay where they are).
    private static func deletions(_ at: Int, _ count: Int, after other: StructuralChange) -> [(at: Int, count: Int)] {
        switch other {
        case .insertRows(let insertAt, let inserted), .insertColumns(let insertAt, let inserted):
            if insertAt <= at { return [(at + inserted, count)] }
            if insertAt >= at + count { return [(at, count)] }
            // Rows inserted inside the deleted ones stay.
            return [(insertAt + inserted, at + count - insertAt), (at, insertAt - at)]
        case .deleteRows, .deleteColumns:
            guard let left = other.map(at, at + count - 1) else { return [] }
            return [(left.lowerBound, left.count)]
        default:
            return [(at, count)]
        }
    }
}
