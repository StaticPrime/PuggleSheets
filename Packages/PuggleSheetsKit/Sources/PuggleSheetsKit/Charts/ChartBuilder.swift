import Foundation

/// Reads a chart's data from the workbook, and makes the first guess for new charts.
///
/// The table follows the rules Excel and OpenDocument import and export use too:
/// 1. Each reference in `spec.ranges` resolves from the chart's sheet; references that don't are skipped.
/// 2. Each range leaves out the rows hidden by hand or by a filter and the hidden columns of its own
///    sheet. Trailing empty rows and columns are trimmed, so "A:C" ends at the last row with data.
/// 3. The ranges are joined side by side, first range first; rows line up by position and shorter
///    ranges are padded with empty cells.
/// 4. "Switch rows / columns" transposes the joined table.
/// 5. With a header row, row 0 names the series and its first cell is the labels' heading.
/// 6. With a label column, column 0 holds the labels and every other column is a series; without
///    one, every column is a series and the labels are 1, 2, 3, …
/// 7. Numbers (dates included) are values; text, booleans, errors and empty cells are gaps.
/// 8. Labels are the cells' formatted text; `labelValues` holds the numbers behind number and date labels.
/// 9. "Aggregate" combines rows whose labels read the same, in first-appearance order.
///
/// Series without a header are named "Series 1", "Series 2", … by their position.
public enum ChartBuilder {
    /// The default series colors, in order.
    public static let palette: [RGBColor] = ["4285F4", "EA4335", "FBBC04", "34A853", "FF6D01", "46BDC6",
                                             "7BAAF7", "F07B72", "FCD04F", "71C287", "FF994D", "7ED1D7"].compactMap(RGBColor.init(hex:))

    /// The color of series `index` (or of pie slice `index`): its style's color, else the palette's.
    public static func color(ofSeries index: Int, in spec: ChartSpec) -> RGBColor {
        spec.style(ofSeries: index).color ?? palette[((index % palette.count) + palette.count) % palette.count]
    }

    /// The labels and series `spec` shows, read from its ranges (references resolve from sheet `sheetIndex`).
    public static func table(for spec: ChartSpec, sheetIndex: Int, workbook: Workbook) -> ChartTable {
        var grid = ChartGrid(references: spec.ranges, sheetIndex: sheetIndex, workbook: workbook)
        if spec.switchRowsAndColumns { grid = grid.transposed() }
        return table(from: grid, firstRowIsHeader: spec.firstRowIsHeader, firstColumnIsLabels: spec.firstColumnIsLabels,
                     aggregation: spec.aggregation)
    }

    /// Rules 5–9: the table a joined, transposed grid makes.
    static func table(from grid: ChartGrid, firstRowIsHeader: Bool, firstColumnIsLabels: Bool,
                      aggregation: ChartSpec.Aggregation?) -> ChartTable {
        guard grid.rowCount > 0, grid.columnCount > 0 else { return ChartTable() }
        let firstDataRow = firstRowIsHeader ? 1 : 0
        let firstSeriesColumn = firstColumnIsLabels ? 1 : 0
        let rowCount = max(0, grid.rowCount - firstDataRow)

        var labels: [String] = []
        var labelValues: [Double?] = []
        var labelFormat: String?
        var heading = ""
        if firstColumnIsLabels {
            labels.reserveCapacity(rowCount)
            labelValues.reserveCapacity(rowCount)
            var numericFormat: String??
            var textFormat: String??
            for row in firstDataRow..<grid.rowCount {
                let cell = grid[row, 0]
                labels.append(displayText(cell))
                let number = cell.number
                labelValues.append(number)
                if number != nil {
                    if numericFormat == nil { numericFormat = .some(cell.format) }
                } else if textFormat == nil, !cell.isBlank {
                    textFormat = .some(cell.format)
                }
            }
            labelFormat = (numericFormat ?? textFormat) ?? nil
            if firstRowIsHeader { heading = displayText(grid[0, 0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            labels = (0..<rowCount).map { String($0 + 1) }
            labelValues = (0..<rowCount).map { Double($0 + 1) }
        }

        var series: [ChartTable.Series] = []
        if firstSeriesColumn < grid.columnCount {
            for column in firstSeriesColumn..<grid.columnCount {
                var values: [Double?] = []
                values.reserveCapacity(rowCount)
                var format: String??
                for row in firstDataRow..<grid.rowCount {
                    let cell = grid[row, column]
                    let number = cell.number
                    values.append(number)
                    if number != nil, format == nil { format = .some(cell.format) }
                }
                var name = firstRowIsHeader ? displayText(grid[0, column]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if name.isEmpty { name = "Series \(series.count + 1)" }
                series.append(ChartTable.Series(name: name, values: values, numberFormat: format ?? nil))
            }
        }

        let table = ChartTable(labels: labels, labelValues: labelValues, labelFormat: labelFormat, labelHeading: heading, series: series)
        guard let aggregation else { return table }
        return aggregated(table, by: aggregation)
    }

    static func displayText(_ cell: ChartGridCell) -> String {
        CellDisplay.text(for: cell.value, pattern: cell.format).text
    }

    /// Rule 9: rows with the same label become one, in first-appearance order. Counting counts the
    /// numbers; the other functions leave a gap where a label has no numbers.
    static func aggregated(_ table: ChartTable, by function: ChartSpec.Aggregation) -> ChartTable {
        var groupOfLabel: [String: Int] = [:]
        var firstRows: [Int] = []
        var members: [[Int]] = []
        for (row, label) in table.labels.enumerated() {
            if let group = groupOfLabel[label] {
                members[group].append(row)
            } else {
                groupOfLabel[label] = firstRows.count
                firstRows.append(row)
                members.append([row])
            }
        }
        guard firstRows.count < table.labels.count else { return table }
        var result = table
        result.labels = firstRows.map { table.labels[$0] }
        result.labelValues = firstRows.map { $0 < table.labelValues.count ? table.labelValues[$0] : nil }
        result.series = table.series.map { series in
            var combined = series
            combined.values = members.map { rows in
                combine(rows.compactMap { $0 < series.values.count ? series.values[$0] : nil }, function)
            }
            if function == .count { combined.numberFormat = nil }
            return combined
        }
        return result
    }

    static func combine(_ values: [Double], _ function: ChartSpec.Aggregation) -> Double? {
        if function == .count { return Double(values.count) }
        guard !values.isEmpty else { return nil }
        switch function {
        case .sum: return values.reduce(0, +)
        case .average: return values.reduce(0, +) / Double(values.count)
        case .count: return Double(values.count)
        case .max: return values.max()
        case .min: return values.min()
        case .median:
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }
    }
}

/// A cell as charts read it: the value it shows (spilled values included) and its number format.
struct ChartGridCell: Sendable {
    var value: CellValue
    var format: String?

    static let empty = ChartGridCell(value: .empty, format: nil)

    /// Numbers, dates included; nil for anything else.
    var number: Double? {
        if case .number(let number) = value, number.isFinite { return number }
        return nil
    }

    var isBlank: Bool {
        switch value {
        case .empty: return true
        case .text(let text): return text.isEmpty
        default: return false
        }
    }
}

/// The cells of a chart's ranges, joined side by side (rules 1–4).
struct ChartGrid: Sendable {
    private(set) var cells: [ChartGridCell]
    private(set) var rowCount: Int
    private(set) var columnCount: Int

    init(rowCount: Int, columnCount: Int, cells: [ChartGridCell]) {
        precondition(cells.count == rowCount * columnCount)
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cells = cells
    }

    subscript(row: Int, column: Int) -> ChartGridCell { cells[row * columnCount + column] }

    init(references: [String], sheetIndex: Int, workbook: Workbook) {
        var blocks: [ChartGrid] = []
        for reference in references {
            guard let (index, range) = workbook.resolve(reference, onSheet: sheetIndex), workbook.sheets.indices.contains(index) else { continue }
            blocks.append(ChartGrid(range: range, of: workbook.sheets[index]))
        }
        let rows = blocks.map(\.rowCount).max() ?? 0
        let columns = blocks.reduce(0) { $0 + $1.columnCount }
        var cells = [ChartGridCell](repeating: .empty, count: rows * columns)
        var offset = 0
        for block in blocks {
            for row in 0..<block.rowCount {
                for column in 0..<block.columnCount {
                    cells[row * columns + offset + column] = block[row, column]
                }
            }
            offset += block.columnCount
        }
        self.init(rowCount: rows, columnCount: columns, cells: cells)
        trimTrailingBlanks()
    }

    /// One range's visible cells. Rows end at the range's last row with content.
    init(range: CellRange, of sheet: Sheet) {
        let bound = ChartGrid.contentBound(of: range, in: sheet)
        let lastRow = bound?.row ?? range.start.row - 1
        let lastColumn = bound?.column ?? range.end.column
        let rows = lastRow >= range.start.row ? (range.start.row...lastRow).filter { !sheet.isRowHidden($0) } : []
        let columns = (range.start.column...max(range.start.column, lastColumn)).filter { !sheet.hiddenColumns.contains($0) }
        let hasSpills = !sheet.spilledValues.isEmpty
        var cells: [ChartGridCell] = []
        cells.reserveCapacity(rows.count * columns.count)
        for row in rows {
            for column in columns {
                cells.append(ChartGrid.read(CellAddress(row: row, column: column), in: sheet, spills: hasSpills))
            }
        }
        self.init(rowCount: rows.count, columnCount: columns.count, cells: cells)
    }

    static func read(_ address: CellAddress, in sheet: Sheet, spills: Bool) -> ChartGridCell {
        if let cell = sheet.cells[address] {
            if cell.hasContent { return ChartGridCell(value: cell.value, format: cell.format.numberFormat) }
            return ChartGridCell(value: spills ? sheet.spilledValues[address] ?? .empty : .empty, format: cell.format.numberFormat)
        }
        if spills, let value = sheet.spilledValues[address] { return ChartGridCell(value: value, format: nil) }
        return .empty
    }

    /// The last row and column of `range` holding content, found from the sheet's cells when the range
    /// is big (whole columns), so "A:C" doesn't walk a million empty rows. Small ranges are read
    /// whole and trimmed afterwards. Nil when a big range is empty.
    static func contentBound(of range: CellRange, in sheet: Sheet) -> (row: Int, column: Int)? {
        guard range.rowCount > 256 || range.columnCount > 64 else { return (range.end.row, range.end.column) }
        var lastRow = -1, lastColumn = -1
        for (address, cell) in sheet.cells where cell.hasContent && range.contains(address) {
            lastRow = max(lastRow, address.row)
            lastColumn = max(lastColumn, address.column)
        }
        for address in sheet.spilledValues.keys where range.contains(address) {
            lastRow = max(lastRow, address.row)
            lastColumn = max(lastColumn, address.column)
        }
        guard lastRow >= 0 else { return nil }
        // Wide ranges keep their columns unless they're very wide (whole rows).
        return (lastRow, range.columnCount > 64 ? lastColumn : range.end.column)
    }

    /// Drops trailing rows and columns without values.
    mutating func trimTrailingBlanks() {
        var rows = rowCount
        while rows > 0, (0..<columnCount).allSatisfy({ self[rows - 1, $0].isBlank }) { rows -= 1 }
        var columns = columnCount
        while columns > 0, (0..<rows).allSatisfy({ self[$0, columns - 1].isBlank }) { columns -= 1 }
        guard rows != rowCount || columns != columnCount else { return }
        var trimmed: [ChartGridCell] = []
        trimmed.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns { trimmed.append(self[row, column]) }
        }
        self = ChartGrid(rowCount: columns == 0 ? 0 : rows, columnCount: rows == 0 ? 0 : columns,
                         cells: columns == 0 || rows == 0 ? [] : trimmed)
    }

    func transposed() -> ChartGrid {
        var result: [ChartGridCell] = []
        result.reserveCapacity(cells.count)
        for column in 0..<columnCount {
            for row in 0..<rowCount { result.append(self[row, column]) }
        }
        return ChartGrid(rowCount: columnCount, columnCount: rowCount, cells: result)
    }
}
