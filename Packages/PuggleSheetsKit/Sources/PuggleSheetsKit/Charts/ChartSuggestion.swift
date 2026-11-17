import Foundation

/// Insert ▸ Chart's first guess.
///
/// - The data: the selection, trimmed to the cells with values. A single selected cell grows to the
///   block of data around it.
/// - Header row: the first row holds text and no numbers, and the rows below hold numbers or dates.
/// - Label column: there are at least two columns and most of the first column's values (below the
///   header) are text or dates.
/// - Kind:
///   - a line chart when the labels are dates;
///   - when there's no label column but the first column holds plain numbers and other columns hold
///     numbers too, the first column becomes the labels: a line chart when it is ordered (strictly
///     rising or falling) with 10 rows or more, otherwise a scatter chart;
///   - otherwise a column chart.
/// - Title, from the headers: one series gives "Sales vs. Month" (just "Sales" without a labels'
///   heading), two give "Sales and Costs", three "Sales, Costs and Profit"; more series, or no
///   header row, give no title.
/// - Axis titles: the horizontal axis shows the labels' heading, and
///   the vertical axis shows the series name when there is only one series.
extension ChartBuilder {
    /// The first guess for a new chart of `range`: the chart type, headers and labels.
    public static func suggestedSpec(for range: CellRange, sheetIndex: Int, workbook: Workbook) -> ChartSpec {
        guard workbook.sheets.indices.contains(sheetIndex) else { return ChartSpec(ranges: [range.a1]) }
        let sheet = workbook.sheets[sheetIndex]
        let selection = range.isSingleCell ? dataRegion(around: range.start, in: sheet) : range
        let region = contentRange(of: selection, in: sheet) ?? selection
        let reference = region.a1
        let grid = ChartGrid(references: [reference], sheetIndex: sheetIndex, workbook: workbook)
        let guess = ChartGuess(grid)

        var spec = ChartSpec(kind: guess.kind, ranges: [reference], firstRowIsHeader: guess.header,
                             firstColumnIsLabels: guess.labels)
        guard guess.header else { return spec }
        let table = table(from: grid, firstRowIsHeader: true, firstColumnIsLabels: guess.labels, aggregation: nil)
        let names = table.series.map(\.name)
        spec.title = defaultTitle(seriesNames: names, labelHeading: table.labelHeading)
        spec.horizontalAxisTitle = table.labelHeading
        if names.count == 1 { spec.verticalAxisTitle = names[0] }
        return spec
    }

    /// The automatic title: "Sales vs. Month" for one series, "Sales and Costs" for two,
    /// "Sales, Costs and Profit" for three; none for more.
    public static func defaultTitle(seriesNames names: [String], labelHeading: String) -> String {
        switch names.count {
        case 1: return labelHeading.isEmpty ? names[0] : "\(names[0]) vs. \(labelHeading)"
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return ""
        }
    }

    /// The block of data around `address`: grows while a neighboring row or column (diagonals too)
    /// holds a value. Just the cell when everything around it is empty.
    static func dataRegion(around address: CellAddress, in sheet: Sheet) -> CellRange {
        let lastRow = max(0, sheet.rowCount - 1), lastColumn = max(0, sheet.columnCount - 1)
        var top = address.row, bottom = address.row, left = address.column, right = address.column
        let spills = !sheet.spilledValues.isEmpty
        func filled(_ row: Int, _ column: Int) -> Bool {
            !ChartGrid.read(CellAddress(row: row, column: column), in: sheet, spills: spills).isBlank
        }
        func rowFilled(_ row: Int) -> Bool {
            (max(0, left - 1)...min(lastColumn, right + 1)).contains { filled(row, $0) }
        }
        func columnFilled(_ column: Int) -> Bool {
            (max(0, top - 1)...min(lastRow, bottom + 1)).contains { filled($0, column) }
        }
        var changed = true
        while changed {
            changed = false
            while bottom < lastRow, rowFilled(bottom + 1) { bottom += 1; changed = true }
            while top > 0, rowFilled(top - 1) { top -= 1; changed = true }
            while right < lastColumn, columnFilled(right + 1) { right += 1; changed = true }
            while left > 0, columnFilled(left - 1) { left -= 1; changed = true }
        }
        return CellRange(rows: top...bottom, columns: left...right)
    }

    /// The part of `range` that holds values; nil when it's all empty.
    static func contentRange(of range: CellRange, in sheet: Sheet) -> CellRange? {
        var top = Int.max, left = Int.max, bottom = -1, right = -1
        func include(_ address: CellAddress) {
            top = min(top, address.row)
            bottom = max(bottom, address.row)
            left = min(left, address.column)
            right = max(right, address.column)
        }
        let spills = !sheet.spilledValues.isEmpty
        if range.cellCount <= sheet.cells.count + sheet.spilledValues.count {
            for row in range.rows {
                for column in range.columns {
                    let address = CellAddress(row: row, column: column)
                    if !ChartGrid.read(address, in: sheet, spills: spills).isBlank { include(address) }
                }
            }
        } else {
            for (address, cell) in sheet.cells where range.contains(address) && cell.hasContent {
                if !ChartGrid.read(address, in: sheet, spills: spills).isBlank { include(address) }
            }
            for (address, value) in sheet.spilledValues where range.contains(address) && !ChartGridCell(value: value).isBlank {
                include(address)
            }
        }
        guard bottom >= 0 else { return nil }
        return CellRange(rows: top...bottom, columns: left...right)
    }
}

/// What Insert ▸ Chart concludes about a block of cells.
struct ChartGuess {
    enum Kind { case blank, text, date, number, other }

    var header = false
    var labels = false
    var kind: ChartSpec.Kind = .column

    init(_ grid: ChartGrid) {
        guard grid.rowCount > 0, grid.columnCount > 0 else { return }
        let kinds = (0..<grid.rowCount).map { row in (0..<grid.columnCount).map { ChartGuess.kind(of: grid[row, $0]) } }

        // A header row: text on top, numbers below.
        if grid.rowCount >= 2 {
            let top = kinds[0]
            let numbersBelow = kinds.dropFirst().contains { $0.contains { $0 == .number || $0 == .date } }
            header = top.contains(.text) && !top.contains(.number) && !top.contains(.date) && numbersBelow
        }
        let body = kinds.dropFirst(header ? 1 : 0)
        guard !body.isEmpty else { return }

        let first = body.map { $0[0] }
        let textCount = first.filter { $0 == .text || $0 == .other }.count
        let dateCount = first.filter { $0 == .date }.count
        let numberCount = first.filter { $0 == .number }.count
        let othersHaveNumbers = grid.columnCount >= 2 && body.contains { $0.dropFirst().contains { $0 == .number || $0 == .date } }

        if grid.columnCount >= 2, textCount + dateCount > numberCount {
            labels = true
            kind = dateCount > textCount ? .line : .column
            return
        }
        if numberCount > 0, numberCount >= textCount + dateCount, othersHaveNumbers {
            labels = true
            let firstRow = header ? 1 : 0
            let values = (firstRow..<grid.rowCount).compactMap { grid[$0, 0].number }
            kind = values.count >= 10 && ChartGuess.isOrdered(values) ? .line : .scatter
        }
    }

    static func kind(of cell: ChartGridCell) -> Kind {
        switch cell.value {
        case .empty:
            return .blank
        case .text(let text):
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? .blank : .text
        case .number:
            switch NumberFormatPresets.kind(of: cell.format) {
            case .date, .dateTime, .time: return .date
            default: return .number
            }
        case .boolean, .error:
            return .other
        }
    }

    /// Strictly rising or strictly falling.
    static func isOrdered(_ values: [Double]) -> Bool {
        guard values.count >= 2 else { return false }
        let rising = zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
        return rising || zip(values, values.dropFirst()).allSatisfy { $0 > $1 }
    }
}

extension ChartGridCell {
    init(value: CellValue) {
        self.init(value: value, format: nil)
    }
}
