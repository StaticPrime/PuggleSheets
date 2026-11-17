import Foundation

/// Evaluates the rules a sheet carries: conditional formatting, data validation and filters.
public enum RuleEvaluator {
    /// Whether `condition` holds for the cell at `address` in sheet `sheetIndex`. Relative references
    /// in the condition's formulas count from `origin`, the top-left cell of the rule's range.
    public static func test(_ condition: CellCondition, at address: CellAddress, origin: CellAddress,
                            sheetIndex: Int, workbook: Workbook, now: Date = Date()) -> Bool {
        guard workbook.sheets.indices.contains(sheetIndex) else { return false }
        return RuleContext(workbook: workbook, sheetIndex: sheetIndex, now: now).test(condition, at: address, origin: origin)
    }

    /// The formatting conditional rules give the cells of `range` (color scales as fill colors), for
    /// drawing. Cells no rule touches are left out. For each part of the format the first rule that
    /// applies wins.
    public static func conditionalFormats(in range: CellRange, sheetIndex: Int, workbook: Workbook,
                                          now: Date = Date()) -> [CellAddress: ConditionalFormat] {
        guard workbook.sheets.indices.contains(sheetIndex) else { return [:] }
        let rules = workbook.sheets[sheetIndex].conditionalFormats
        guard !rules.isEmpty else { return [:] }
        let context = RuleContext(workbook: workbook, sheetIndex: sheetIndex, now: now)
        var result: [CellAddress: ConditionalFormat] = [:]
        for rule in rules {
            guard let origin = rule.ranges.first?.start else { continue }
            let visible = rule.ranges.compactMap { $0.intersection(range) }
            guard !visible.isEmpty else { continue }
            switch rule.style {
            case .condition(let condition, let format):
                guard !format.isEmpty else { continue }
                for area in visible {
                    for row in area.rows {
                        for column in area.columns {
                            let address = CellAddress(row: row, column: column)
                            let current = result[address] ?? ConditionalFormat()
                            // Earlier rules already set everything this one would.
                            let combined = current.filling(from: format)
                            guard combined != current else { continue }
                            if context.test(condition, at: address, origin: origin) { result[address] = combined }
                        }
                    }
                }
            case .colorScale(let scale):
                guard let gradient = context.gradient(for: scale, over: rule.ranges) else { continue }
                for area in visible {
                    for row in area.rows {
                        for column in area.columns {
                            let address = CellAddress(row: row, column: column)
                            guard result[address]?.fillColor == nil, case .number(let number) = context.value(at: address) else { continue }
                            result[address, default: ConditionalFormat()].fillColor = gradient.color(for: number)
                        }
                    }
                }
            }
        }
        return result
    }

    /// Whether `value` (a cell's value, or what's being typed into it) passes `rule` at `address`.
    /// Empty values always pass.
    public static func isValid(_ value: CellValue, for rule: DataValidationRule, at address: CellAddress,
                               sheetIndex: Int, workbook: Workbook, now: Date = Date()) -> Bool {
        if RuleContext.isBlank(value) { return true }
        guard workbook.sheets.indices.contains(sheetIndex) else { return true }
        let context = RuleContext(workbook: workbook, sheetIndex: sheetIndex, now: now)
        switch rule.criterion {
        case .list(let items):
            return context.list(items.map(RuleContext.ListItem.init(typed:)), accepts: value, at: address)
        case .listFromRange(let reference):
            return context.list(context.items(in: reference), accepts: value, at: address)
        case .checkbox(let checked, let unchecked):
            return RuleContext.checkbox(accepts: value, checked: checked ?? "TRUE", unchecked: unchecked ?? "FALSE")
        case .condition(let condition):
            return context.test(condition, at: address, origin: rule.ranges.first?.start ?? address, value: value)
        }
    }

    /// The message for invalid input, such as "Input must be an item on the specified list."
    public static func invalidMessage(for rule: DataValidationRule) -> String {
        if let help = rule.helpText?.trimmingCharacters(in: .whitespacesAndNewlines), !help.isEmpty { return help }
        switch rule.criterion {
        case .list, .listFromRange:
            return "Input must be an item on the specified list."
        case .checkbox(let checked, let unchecked):
            guard checked != nil || unchecked != nil else { return "Input must be either TRUE or FALSE." }
            return "Input must be either \"\(checked ?? "TRUE")\" or \"\(unchecked ?? "FALSE")\"."
        case .condition(let condition):
            return RuleContext.message(for: condition)
        }
    }

    /// A dropdown's items: its list, or the shown values of its range (unique, in order, blanks skipped).
    public static func dropdownItems(for rule: DataValidationRule, sheetIndex: Int, workbook: Workbook) -> [String] {
        switch rule.criterion {
        case .list(let items):
            return items
        case .listFromRange(let reference):
            guard workbook.sheets.indices.contains(sheetIndex) else { return [] }
            var seen = Set<String>()
            return RuleContext(workbook: workbook, sheetIndex: sheetIndex, now: Date()).items(in: reference)
                .map(\.text)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        case .checkbox, .condition:
            return []
        }
    }

    /// The rows hidden now on a sheet (for `Sheet.filteredRows`): those its filter hides, those its tables'
    /// filters hide, and those slicers on any sheet hide in this sheet's data. Header rows never are.
    public static func filteredRows(sheetIndex: Int, workbook: Workbook, now: Date = Date()) -> Set<Int> {
        guard workbook.sheets.indices.contains(sheetIndex) else { return [] }
        let filters = activeFilters(onSheet: sheetIndex, workbook: workbook, excluding: nil)
        guard !filters.isEmpty else { return [] }
        let context = RuleContext(workbook: workbook, sheetIndex: sheetIndex, now: now)
        var hidden = Set<Int>()
        for filter in filters { hidden.formUnion(context.hiddenRows(by: filter)) }
        return hidden
    }

    /// The shown values in a slicer's column (for its value list), sorted, with how many rows show each;
    /// "" stands for empty cells. Rows that the other slicers, the sheet's filter or its tables' filters hide
    /// are left out. `sheetIndex` is the sheet holding the slicer (its range may name another sheet).
    public static func filterValues(forSlicer slicer: SlicerSpec, onSheet sheetIndex: Int, workbook: Workbook,
                                    now: Date = Date()) -> [(value: String, count: Int)] {
        guard workbook.sheets.indices.contains(sheetIndex), let (target, range) = workbook.resolve(slicer.range, onSheet: sheetIndex),
              (0..<range.columnCount).contains(slicer.column), range.rowCount > 1 else { return [] }
        let context = RuleContext(workbook: workbook, sheetIndex: target, now: now)
        var hidden = Set<Int>()
        for filter in activeFilters(onSheet: target, workbook: workbook, excluding: slicer) { hidden.formUnion(context.hiddenRows(by: filter)) }
        let column = range.start.column + slicer.column
        var counts: [String: (count: Int, sample: CellValue)] = [:]
        for row in (range.start.row + 1)...range.end.row where !hidden.contains(row) {
            let address = CellAddress(row: row, column: column)
            let text = context.shownText(at: address)
            if let entry = counts[text] {
                counts[text] = (entry.count + 1, entry.sample)
            } else {
                counts[text] = (1, context.value(at: address))
            }
        }
        return sortedValueCounts(counts)
    }

    /// Every filter hiding rows on a sheet: its own, its tables', and slicers' (on any sheet) whose range
    /// lies on it, leaving out slicers equal to `excluded`.
    static func activeFilters(onSheet sheetIndex: Int, workbook: Workbook, excluding excluded: SlicerSpec?) -> [SheetFilter] {
        let sheet = workbook.sheets[sheetIndex]
        var filters: [SheetFilter] = []
        if let filter = sheet.filter { filters.append(filter) }
        filters += sheet.tables.filter { !$0.criteria.isEmpty }.map(\.asFilter)
        for (index, other) in workbook.sheets.enumerated() {
            for object in other.objects {
                guard let slicer = object.slicer, slicer != excluded, !slicer.criterion.isEmpty,
                      let (target, range) = workbook.resolve(slicer.range, onSheet: index), target == sheetIndex,
                      (0..<range.columnCount).contains(slicer.column) else { continue }
                filters.append(SheetFilter(range: range, criteria: [range.start.column + slicer.column: slicer.criterion]))
            }
        }
        return filters
    }

    /// The rows `filter` would hide in sheet `sheetIndex` (never its header row): for a filter view,
    /// `view.asFilter`.
    public static func filteredRows(for filter: SheetFilter, sheetIndex: Int, workbook: Workbook, now: Date = Date()) -> Set<Int> {
        guard workbook.sheets.indices.contains(sheetIndex) else { return [] }
        return RuleContext(workbook: workbook, sheetIndex: sheetIndex, now: now).hiddenRows(by: filter)
    }

    /// The shown values in one column of the filter (for "Filter by values"), sorted, with how many
    /// rows show each; "" stands for empty cells. Rows hidden by other columns' criteria are left out.
    public static func filterValues(column: Int, sheetIndex: Int, workbook: Workbook) -> [(value: String, count: Int)] {
        guard workbook.sheets.indices.contains(sheetIndex), let filter = workbook.sheets[sheetIndex].filter else { return [] }
        return filterValues(column: column, filter: filter, sheetIndex: sheetIndex, workbook: workbook)
    }

    /// The shown values in one column of `range`'s data rows (every row but the first), sorted, with how
    /// many rows show each; "" stands for empty cells.
    public static func filterValues(column: Int, range: CellRange, sheetIndex: Int, workbook: Workbook) -> [(value: String, count: Int)] {
        filterValues(column: column, filter: SheetFilter(range: range), sheetIndex: sheetIndex, workbook: workbook)
    }

    /// The shown values in one column of `filter`'s data rows, leaving out rows that the criteria of its
    /// other columns hide (for a filter view's "Filter by values": `view.asFilter`).
    public static func filterValues(column: Int, filter: SheetFilter, sheetIndex: Int, workbook: Workbook,
                                    now: Date = Date()) -> [(value: String, count: Int)] {
        guard workbook.sheets.indices.contains(sheetIndex), filter.range.columns.contains(column), filter.range.rowCount > 1 else {
            return []
        }
        let context = RuleContext(workbook: workbook, sheetIndex: sheetIndex, now: now)
        var others = filter
        others.criteria[column] = nil
        let hidden = others.criteria.isEmpty ? [] : context.hiddenRows(by: others)
        var counts: [String: (count: Int, sample: CellValue)] = [:]
        for row in (filter.range.start.row + 1)...filter.range.end.row where !hidden.contains(row) {
            let address = CellAddress(row: row, column: column)
            let text = context.shownText(at: address)
            if let entry = counts[text] {
                counts[text] = (entry.count + 1, entry.sample)
            } else {
                counts[text] = (1, context.value(at: address))
            }
        }
        return sortedValueCounts(counts)
    }

    /// Value counts in filter-list order: blanks first, then numbers by value, text ignoring case,
    /// booleans and errors (each value compared through the first cell that showed it).
    static func sortedValueCounts(_ counts: [String: (count: Int, sample: CellValue)]) -> [(value: String, count: Int)] {
        counts.sorted { a, b in
            if a.key.isEmpty != b.key.isEmpty { return a.key.isEmpty }
            let order = Coercion.compare(a.value.sample, b.value.sample)
            if order != 0 { return order < 0 }
            return a.key < b.key
        }
        .map { ($0.key, $0.value.count) }
    }
}
