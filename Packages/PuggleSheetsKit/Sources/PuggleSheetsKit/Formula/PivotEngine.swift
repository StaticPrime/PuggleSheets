import Foundation

/// Computes pivot tables (Insert ▸ Pivot table): their layout and summaries.
///
/// The source's first row holds the headings; every row below it that isn't entirely empty is a record.
/// Filters leave out records the way a sheet filter hides rows. Row groups run down the left, one column
/// each, outer to inner; column groups run across the top, one header row each; with several values they
/// sit side by side under every column group (or stack under every row group with `valuesInRows`).
///
/// - Header rows: with column groups, the first header row holds the value's heading in its top-left
///   cell (when there is exactly one value) and the column groups' names side by side ("Values" for the
///   value columns); then one row of labels per column group; the last header row also holds the row
///   groups' names on the left ("Values" over stacked value headings). Without column groups there is
///   one header row: the row groups' names, then the value headings.
/// - Labels sort ascending or descending by type and value (numbers, then text ignoring case,
///   then booleans, then errors), or by a value's summary for the group (`sortByValue`). Blank labels
///   form one group, shown as an empty label; it sorts before everything else ascending and after
///   everything descending. Text labels differing only in case are separate groups.
/// - Totals: a group with `showsTotals` gets a "<label> Total" row or column after its members when an
///   inner group follows it; the outermost group's `showsTotals` controls the "Grand Total" row or column.
/// - Values follow the functions of the same names over the group's records: SUM, AVERAGE, MAX, MIN,
///   MEDIAN, PRODUCT, STDEV, STDEVP, VAR and VARP read numbers only and pass the first error on; COUNTA
///   counts non-empty values, COUNT numbers, COUNTUNIQUE distinct values. Combinations without records
///   stay empty. "% of" options divide by the row's, column's or grand total and use "0.00%".
public enum PivotEngine {
    /// The pivot table's cells, roles and number formats, from the workbook's current values (values
    /// spilled into the source count). Empty when nothing is configured or the source can't be resolved
    /// (the formula engine then shows #REF! in the anchor cell), or beyond 10 million cells.
    public static func output(for pivot: PivotTable, sheetIndex: Int, workbook: Workbook) -> PivotOutput {
        output(for: pivot, sheetIndex: sheetIndex, workbook: workbook, now: Date())
    }

    /// `output(for:sheetIndex:workbook:)`, with `now` as the current date for date filter conditions.
    public static func output(for pivot: PivotTable, sheetIndex: Int, workbook: Workbook, now: Date) -> PivotOutput {
        guard workbook.sheets.indices.contains(sheetIndex) else { return PivotOutput() }
        let evaluator = Evaluator(workbook: workbook, sheetIndex: sheetIndex, address: pivot.anchor, now: now)
        return evaluate(effective(pivot, sheetIndex: sheetIndex, workbook: workbook), sheetIndex: sheetIndex, evaluator: evaluator,
                        now: now, limit: nil).output ?? PivotOutput()
    }

    /// The pivot table with the filters of the slicers that apply to it: slicers on any sheet with
    /// `appliesToPivotTables` on, whose range is the pivot table's source (same sheet and cells).
    static func effective(_ pivot: PivotTable, sheetIndex: Int, workbook: Workbook) -> PivotTable {
        guard let source = source(of: pivot, sheetIndex: sheetIndex, workbook: workbook) else { return pivot }
        var result = pivot
        for (index, sheet) in workbook.sheets.enumerated() {
            for object in sheet.objects {
                guard let slicer = object.slicer, slicer.appliesToPivotTables, !slicer.criterion.isEmpty,
                      let range = workbook.resolve(slicer.range, onSheet: index),
                      range.sheet == source.sheet, range.range == source.range else { continue }
                result.filters.append(PivotFilter(sourceColumn: slicer.column, criterion: slicer.criterion))
            }
        }
        return result
    }

    /// The source's headings, one per source column: the first row's shown text, or "Column C" (the
    /// sheet column's letter) for empty cells. Empty when the source can't be resolved.
    public static func sourceHeaders(for pivot: PivotTable, sheetIndex: Int, workbook: Workbook) -> [String] {
        guard workbook.sheets.indices.contains(sheetIndex), let source = source(of: pivot, sheetIndex: sheetIndex, workbook: workbook) else {
            return []
        }
        let sheet = workbook.sheets[source.sheet]
        return source.range.columns.map { column in
            let address = CellAddress(row: source.range.start.row, column: column)
            return heading(sheet.value(at: address), format: sheet.cells[address]?.format.numberFormat, column: column)
        }
    }

    /// The shown values of source column `column` (0 is the source's first column) with how many records
    /// show each, ordered like a filter's value list: "" (empty cells) first, then numbers, text and
    /// booleans. Other filters don't narrow the list.
    public static func sourceValues(column: Int, for pivot: PivotTable, sheetIndex: Int,
                                    workbook: Workbook) -> [(value: String, count: Int)] {
        guard workbook.sheets.indices.contains(sheetIndex), let source = source(of: pivot, sheetIndex: sheetIndex, workbook: workbook),
              (0..<source.range.columnCount).contains(column) else { return [] }
        let evaluator = Evaluator(workbook: workbook, sheetIndex: sheetIndex, address: pivot.anchor, now: Date())
        let data = read(source, columns: [column], evaluator: evaluator)
        let values = data.columns[column] ?? []
        let sheetColumn = source.range.start.column + column
        var shown = ShownText(sheet: workbook.sheets[source.sheet])
        var counts: [String: (count: Int, sample: CellValue)] = [:]
        for (record, value) in values.enumerated() {
            let text = shown.text(value, at: CellAddress(row: data.recordRows[record], column: sheetColumn))
            if let entry = counts[text] {
                counts[text] = (entry.count + 1, entry.sample)
            } else {
                counts[text] = (1, value)
            }
        }
        return RuleEvaluator.sortedValueCounts(counts)
    }

    // MARK: Source

    /// A pivot table's source block.
    struct Source {
        let sheet: Int
        let range: CellRange
    }

    static func source(of pivot: PivotTable, sheetIndex: Int, workbook: Workbook) -> Source? {
        guard let resolved = workbook.resolve(pivot.source, onSheet: sheetIndex) else { return nil }
        return Source(sheet: resolved.sheet, range: resolved.range)
    }

    /// Why a source doesn't resolve: "Unresolved sheet name 'Old'." or "Unable to parse range: …".
    static func sourceError(_ text: String, workbook: Workbook) -> CellError {
        var reference = text.trimmingCharacters(in: .whitespaces)
        if reference.hasPrefix("=") { reference.removeFirst() }
        if let bang = reference.lastIndex(of: "!") {
            var name = String(reference[..<bang])
            if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            if workbook.sheetIndex(named: name) == nil { return FormulaErrors.unresolvedSheet(name) }
        }
        return CellError(.reference, "Unable to parse range: \(reference)")
    }

    /// A heading's text: the cell's shown text, or "Column C" when it's empty.
    static func heading(_ value: CellValue, format: String?, column: Int) -> String {
        let text = CellDisplay.text(for: value, pattern: format).text
        return text.isEmpty ? "Column \(CellAddress.columnName(column))" : text
    }

    /// What a pivot table reads from its source.
    struct SourceData {
        /// The first row's values, one per source column.
        var headings: [CellValue]
        /// Sheet rows of the records (data rows that aren't entirely empty), top to bottom.
        var recordRows: [Int]
        /// The records' values in the requested source columns.
        var columns: [Int: [CellValue]]
    }

    /// Reads the source's headings and the records' values in `wanted` columns through `evaluator`, so a
    /// recalculation supplies fresh formula results and spilled values. Values are what `Sheet.value(at:)`
    /// shows: a cell's content, else a value spilled into it.
    static func read(_ source: Source, columns wanted: Set<Int>, evaluator: Evaluator) -> SourceData {
        let range = source.range
        let cells = evaluator.workbook.sheets[source.sheet].cells
        let top = range.start.row, left = range.start.column
        let width = range.columnCount, dataCount = range.rowCount - 1
        var headings = [CellValue](repeating: .empty, count: width)
        let columnList = wanted.filter { (0..<width).contains($0) }.sorted()
        var slot = [Int](repeating: -1, count: width)
        for (index, column) in columnList.enumerated() { slot[column] = index }
        var values = [[CellValue]](repeating: [CellValue](repeating: .empty, count: max(0, dataCount)), count: columnList.count)
        var filled = [Bool](repeating: false, count: max(0, dataCount))

        func record(_ address: CellAddress, _ value: CellValue) {
            let row = address.row - top, column = address.column - left
            if row == 0 {
                headings[column] = value
                return
            }
            if !RuleContext.isBlank(value) { filled[row - 1] = true }
            let index = slot[column]
            if index >= 0 { values[index][row - 1] = value }
        }
        func visit(_ address: CellAddress, _ cell: Cell) {
            guard cell.hasContent else { return }
            if cell.formula != nil, let pass = evaluator.pass {
                record(address, pass.value(sheet: source.sheet, address: address, stored: cell.value, evaluator: evaluator))
            } else {
                record(address, cell.value)
            }
        }
        // Looking cells up hops around memory; walking the whole dictionary is several times cheaper per
        // cell, so it wins unless the source is a small part of the sheet.
        if range.cellCount * 4 <= cells.count {
            for row in range.rows {
                for column in range.columns {
                    let address = CellAddress(row: row, column: column)
                    if let cell = cells[address] { visit(address, cell) }
                }
            }
        } else {
            for (address, cell) in cells where range.contains(address) { visit(address, cell) }
        }
        for (address, value) in evaluator.spilledEntries(sheet: source.sheet, in: range) where cells[address]?.hasContent != true {
            record(address, value)
        }

        var recordIndexes: [Int] = []
        recordIndexes.reserveCapacity(max(0, dataCount))
        for index in 0..<max(0, dataCount) where filled[index] { recordIndexes.append(index) }
        var columns: [Int: [CellValue]] = [:]
        for (index, column) in columnList.enumerated() {
            columns[column] = recordIndexes.count == dataCount ? values[index] : recordIndexes.map { values[index][$0] }
        }
        return SourceData(headings: headings, recordRows: recordIndexes.map { top + 1 + $0 }, columns: columns)
    }

    /// Shown texts of source cells (value and the cell's number format), cached by value and format.
    struct ShownText {
        let sheet: Sheet
        private var cache: [ShownKey: String] = [:]

        private struct ShownKey: Hashable {
            var value: CellValue
            var pattern: String?
        }

        init(sheet: Sheet) {
            self.sheet = sheet
        }

        mutating func text(_ value: CellValue, at address: CellAddress) -> String {
            let pattern = sheet.cells[address]?.format.numberFormat
            switch value {
            case .empty: return ""
            case .text(let text) where pattern == nil: return text
            default: break
            }
            let key = ShownKey(value: value, pattern: pattern)
            if let cached = cache[key] { return cached }
            let text = CellDisplay.text(for: value, pattern: pattern).text
            cache[key] = text
            return text
        }
    }

    // MARK: Evaluating

    /// Which labels each row and column of a pivot table's output stands for (GETPIVOTDATA looks values up with it).
    struct Axes {
        /// A data row or column: the labels of its groups, outer first (fewer than the groups for totals,
        /// none for the grand total), and the value it shows when the values sit on this axis (-1 otherwise).
        struct Line {
            var path: [CellValue]
            var value: Int
        }

        var headerRows: Int
        var labelColumns: Int
        /// Output rows from `headerRows` down.
        var rows: [Line]
        /// Output columns from `labelColumns` on.
        var columns: [Line]
        /// Headings of the row groups', column groups' and values' source columns.
        var rowGroups: [String]
        var columnGroups: [String]
        var valueColumns: [String]
        /// "SUM of Sales", or the value's own name.
        var valueNames: [String]
    }

    /// A pivot table's result for the formula engine.
    struct Evaluation {
        /// The cells; nil when there's nothing to show, the source is invalid, or the result exceeds the limit.
        var output: PivotOutput?
        var axes: Axes?
        /// The output's cell values, row by row.
        var values: ValueMatrix?
        var rowCount = 0
        var columnCount = 0
        /// Why the source couldn't be read; the engine shows it in the anchor cell.
        var error: CellError?
    }

    /// The cell limit: the largest output computed when no limit is given.
    static let maximumCells = 10_000_000

    /// Computes a pivot table through `evaluator`. When the output would have more rows or columns than
    /// `limit`, only its size is returned.
    static func evaluate(_ pivot: PivotTable, sheetIndex: Int, evaluator: Evaluator, now: Date,
                         limit: (rows: Int, columns: Int)?) -> Evaluation {
        let workbook = evaluator.workbook
        guard let source = source(of: pivot, sheetIndex: sheetIndex, workbook: workbook) else {
            return Evaluation(error: sourceError(pivot.source, workbook: workbook))
        }
        guard !(pivot.rows.isEmpty && pivot.columns.isEmpty && pivot.values.isEmpty) else { return Evaluation() }
        let builder = PivotBuilder(pivot: pivot, source: source, evaluator: evaluator, now: now)
        return builder.build(limit: limit)
    }
}
