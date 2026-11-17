import Foundation

/// Edits that change where cells are, so every formula in the workbook has to follow: formulas in
/// cells, formulas in rules (conditions, dropdown ranges), named ranges, chart ranges and pivot sources.
extension Workbook {
    /// Inserts or deletes rows, columns or cells in one sheet and rewrites every formula that refers to them.
    public mutating func apply(_ change: StructuralChange, toSheet index: Int) {
        let changedName = sheets[index].name
        let pivotSources = pivotSourcesAffected(by: change, onSheet: index)
        rewriteFormulas { formula, formulaSheet in
            FormulaRewriter.adjust(formula, for: change, inSheet: changedName, formulaSheet: formulaSheet)
        }
        // Pivot tables name source columns by position: follow inserted and deleted columns.
        for (sheetIndex, pivotIndex, oldRange) in pivotSources {
            guard let newRange = change.map(oldRange) else { continue }
            sheets[sheetIndex].pivotTables[pivotIndex].remapSourceColumns { column in
                change.map(oldRange.start.column + column).map { $0 - newRange.start.column }
            }
        }
        sheets[index].applyStructuralChange(change)
    }

    /// Pivot tables whose source columns move with a column change on sheet `index`.
    private func pivotSourcesAffected(by change: StructuralChange, onSheet index: Int) -> [(Int, Int, CellRange)] {
        guard !change.affectsRows else { return [] }
        var result: [(Int, Int, CellRange)] = []
        for (sheetIndex, sheet) in sheets.enumerated() {
            for (pivotIndex, pivot) in sheet.pivotTables.enumerated() {
                guard let source = resolve(pivot.source, onSheet: sheetIndex), source.sheet == index else { continue }
                if let band = change.band, !(band.contains(source.range.start.row) && band.contains(source.range.end.row)) { continue }
                result.append((sheetIndex, pivotIndex, source.range))
            }
        }
        return result
    }

    /// Renames a sheet and follows the rename in every formula.
    public mutating func renameSheet(at index: Int, to name: String) {
        let oldName = sheets[index].name
        guard oldName != name else { return }
        rewriteFormulas { formula, _ in FormulaRewriter.renameSheet(formula, from: oldName, to: name) }
        sheets[index].name = name
    }

    /// Deletes a sheet; formulas that referred to it show #REF!.
    public mutating func removeSheet(at index: Int) {
        let name = sheets[index].name
        sheets.remove(at: index)
        rewriteFormulas { formula, _ in FormulaRewriter.removeSheet(formula, named: name) }
    }

    /// Follows cells cut from `range` in sheet `index` and pasted `rows` down and `columns` across in
    /// sheet `destination`: formulas that pointed into the block now point to its new place.
    public mutating func followMove(of range: CellRange, inSheet index: Int, rows: Int, columns: Int, toSheet destination: Int) {
        let source = sheets[index].name, target = sheets[destination].name
        rewriteFormulas { formula, formulaSheet in
            FormulaRewriter.move(formula, range: range, inSheet: source, rows: rows, columns: columns,
                                 toSheet: target, formulaSheet: formulaSheet)
        }
    }

    /// Applies `rewrite` to every formula, keeping cells and rules whose formulas didn't change untouched.
    private mutating func rewriteFormulas(_ rewrite: (_ formula: String, _ formulaSheet: String) -> String) {
        for sheetIndex in sheets.indices {
            let sheetName = sheets[sheetIndex].name
            var updates: [CellAddress: Cell] = [:]
            for (address, cell) in sheets[sheetIndex].cells {
                guard let formula = cell.formula else { continue }
                let rewritten = rewrite(formula, sheetName)
                if rewritten != formula {
                    var updated = cell
                    updated.formula = rewritten
                    updates[address] = updated
                }
            }
            if !updates.isEmpty { sheets[sheetIndex].setCells(updates) }
            rewriteRules(inSheet: sheetIndex) { rewrite($0, sheetName) }
            rewriteReferences(inSheet: sheetIndex) { rewrite($0, sheetName) }
        }
        // Named ranges name their sheet; one that doesn't belongs to the first sheet.
        let firstSheet = sheets.first?.name ?? ""
        for index in namedRanges.indices {
            let reference = namedRanges[index].reference
            let rewritten = rewrite("=" + reference, firstSheet)
            if rewritten != "=" + reference { namedRanges[index].reference = String(rewritten.dropFirst()) }
        }
    }

    /// Rewrites the references of a sheet's charts and pivot tables, and the conditions of its filter views.
    private mutating func rewriteReferences(inSheet index: Int, _ rewrite: (String) -> String) {
        func rewritten(_ reference: String) -> String {
            let result = rewrite("=" + reference)
            return result.hasPrefix("=") ? String(result.dropFirst()) : result
        }
        var sheet = sheets[index]
        var changed = false
        for objectIndex in sheet.objects.indices {
            switch sheet.objects[objectIndex].content {
            case .chart(var spec):
                let ranges = spec.ranges.map(rewritten)
                guard ranges != spec.ranges else { continue }
                spec.ranges = ranges
                sheet.objects[objectIndex].content = .chart(spec)
                changed = true
            case .slicer(var spec):
                let range = rewritten(spec.range)
                guard range != spec.range else { continue }
                spec.range = range
                sheet.objects[objectIndex].content = .slicer(spec)
                changed = true
            case .image:
                continue
            }
        }
        for pivotIndex in sheet.pivotTables.indices {
            let source = rewritten(sheet.pivotTables[pivotIndex].source)
            guard source != sheet.pivotTables[pivotIndex].source else { continue }
            sheet.pivotTables[pivotIndex].source = source
            changed = true
        }
        for viewIndex in sheet.filterViews.indices {
            for (column, criterion) in sheet.filterViews[viewIndex].criteria {
                guard var condition = criterion.condition else { continue }
                let values = condition.values.map { $0.hasPrefix("=") ? rewrite($0) : $0 }
                guard values != condition.values else { continue }
                condition.values = values
                sheet.filterViews[viewIndex].criteria[column]?.condition = condition
                changed = true
            }
        }
        if changed { sheets[index] = sheet }
    }

    /// Rewrites the formulas inside a sheet's rules: condition values starting with "=", and dropdown ranges.
    private mutating func rewriteRules(inSheet index: Int, _ rewrite: (String) -> String) {
        func rewritten(_ condition: CellCondition) -> CellCondition {
            var condition = condition
            condition.values = condition.values.map { $0.hasPrefix("=") ? rewrite($0) : $0 }
            return condition
        }
        var sheet = sheets[index]
        var changed = false
        for ruleIndex in sheet.conditionalFormats.indices {
            guard case .condition(let condition, let format) = sheet.conditionalFormats[ruleIndex].style else { continue }
            let updated = rewritten(condition)
            if updated != condition {
                sheet.conditionalFormats[ruleIndex].style = .condition(updated, format)
                changed = true
            }
        }
        for ruleIndex in sheet.validations.indices {
            switch sheet.validations[ruleIndex].criterion {
            case .listFromRange(let reference):
                let updated = rewrite("=" + reference)
                if updated != "=" + reference {
                    sheet.validations[ruleIndex].criterion = .listFromRange(String(updated.dropFirst()))
                    changed = true
                }
            case .condition(let condition):
                let updated = rewritten(condition)
                if updated != condition {
                    sheet.validations[ruleIndex].criterion = .condition(updated)
                    changed = true
                }
            case .list, .checkbox:
                break
            }
        }
        if var filter = sheet.filter {
            for (column, criterion) in filter.criteria {
                guard let condition = criterion.condition else { continue }
                let updated = rewritten(condition)
                if updated != condition {
                    filter.criteria[column]?.condition = updated
                    changed = true
                }
            }
            sheet.filter = filter
        }
        if changed { sheets[index] = sheet }
    }
}
