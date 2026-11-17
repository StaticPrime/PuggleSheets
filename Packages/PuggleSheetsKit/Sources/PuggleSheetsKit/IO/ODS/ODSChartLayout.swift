import Foundation

/// A cell of some sheet.
struct ODSSheetCell: Hashable {
    var sheet: Int
    var address: CellAddress
}

/// A block of cells of some sheet.
struct ODSSheetRange: Hashable {
    var sheet: Int
    var range: CellRange
}

/// Which cells a chart's series and labels come from, by the chart module's layout rules:
///
/// 1. each of the spec's ranges is resolved from the chart's sheet;
/// 2. the ranges are joined side by side, rows lining up by position;
/// 3. hidden rows and columns are left out (rows judged by the first range's sheet rows);
/// 4. the table is transposed when rows and columns are switched;
/// 5. with a header row, row 0 names the series;
/// 6. with a labels column, column 0 holds the labels and every other column is a series.
///
/// Blocks span from a series' first to its last visible cell in each range; LibreOffice leaves out
/// the hidden cells inside them itself (`chart:include-hidden-cells="false"`). Cell lists stop at the
/// last row and column with content, so charts of whole columns of tall sheets stay cheap: rows past
/// the content add nothing to the values (their blocks still reach the range's end), and no series
/// when rows are series.
struct ODSChartLayout {
    struct Series {
        /// The visible cells holding the values, in order, up to the sheet's content.
        var cells: [ODSSheetCell]
        var blocks: [ODSSheetRange]
        /// The cell naming the series.
        var name: ODSSheetCell?
    }

    /// The resolved ranges.
    var sources: [ODSSheetRange]
    var series: [Series]
    /// The visible label cells, in order, and their blocks; empty without a labels column.
    var labelCells: [ODSSheetCell]
    var labelBlocks: [ODSSheetRange]

    init?(spec: ChartSpec, sheetIndex: Int, workbook: Workbook) {
        var sources: [ODSSheetRange] = []
        for reference in spec.ranges {
            guard let resolved = workbook.resolve(reference, onSheet: sheetIndex) else { continue }
            sources.append(ODSSheetRange(sheet: resolved.sheet, range: resolved.range))
        }
        guard let first = sources.first else { return nil }
        self.sources = sources
        let bounds = ODSContentBounds(workbook: workbook, sheets: sources.map(\.sheet))

        // Columns of the joined table: (source, sheet column).
        var columns: [(source: Int, column: Int)] = []
        for (index, source) in sources.enumerated() {
            let hidden = workbook.sheets[source.sheet].hiddenColumns
            for column in source.range.columns where !hidden.contains(column) { columns.append((index, column)) }
        }
        // Rows of the joined table, as offsets into the ranges: the visible ones up to the content, the first
        // ones (a header and the first values, or the labels when switched) and, for series down columns, the
        // last one, where their blocks end.
        let height = sources.map(\.range.rowCount).max() ?? 0
        let firstSheet = workbook.sheets[first.sheet]
        func visible(_ offset: Int) -> Bool { !firstSheet.isRowHidden(first.range.start.row + offset) }
        var contentRows = 0
        for source in sources { contentRows = max(contentRows, bounds.lastRow(source.sheet) - source.range.start.row + 1) }
        var offsets = Set<Int>()
        for offset in 0..<min(height, max(contentRows, 0)) where visible(offset) { offsets.insert(offset) }
        var leading = 0, offset = 0
        while offset < height, leading < (spec.switchRowsAndColumns ? 1 : 2) {
            if visible(offset) {
                offsets.insert(offset)
                leading += 1
            }
            offset += 1
        }
        if !spec.switchRowsAndColumns, let last = (0..<height).reversed().first(where: visible) { offsets.insert(last) }
        let rows = offsets.sorted()

        func cell(row: Int, column: Int) -> ODSSheetCell? {
            let item = columns[column], source = sources[item.source]
            let offset = rows[row]
            guard offset < source.range.rowCount else { return nil }
            return ODSSheetCell(sheet: source.sheet, address: CellAddress(row: source.range.start.row + offset, column: item.column))
        }

        // The table as its rows and columns after transposing.
        let switched = spec.switchRowsAndColumns
        let tableRows = switched ? columns.count : rows.count
        let tableColumns = switched ? rows.count : columns.count
        func tableCell(_ row: Int, _ column: Int) -> ODSSheetCell? {
            switched ? cell(row: column, column: row) : cell(row: row, column: column)
        }
        func tableSource(_ row: Int, _ column: Int) -> Int {
            columns[switched ? row : column].source
        }

        let firstDataRow = spec.firstRowIsHeader ? 1 : 0
        let firstSeriesColumn = spec.firstColumnIsLabels ? 1 : 0
        func line(column: Int) -> (cells: [ODSSheetCell], blocks: [ODSSheetRange]) {
            var cells: [ODSSheetCell] = []
            var groups: [(source: Int, first: ODSSheetCell, last: ODSSheetCell)] = []
            for row in stride(from: firstDataRow, to: tableRows, by: 1) {
                guard let item = tableCell(row, column) else { continue }
                if bounds.contains(item) { cells.append(item) }
                let origin = tableSource(row, column)
                if let last = groups.last, last.source == origin {
                    groups[groups.count - 1].last = item
                } else {
                    groups.append((origin, item, item))
                }
            }
            return (cells, groups.map { ODSSheetRange(sheet: $0.first.sheet, range: CellRange($0.first.address, $0.last.address)) })
        }

        if spec.firstColumnIsLabels, tableColumns > 0 {
            let labels = line(column: 0)
            labelCells = labels.cells
            labelBlocks = labels.blocks
        } else {
            labelCells = []
            labelBlocks = []
        }
        var series: [Series] = []
        for column in stride(from: firstSeriesColumn, to: tableColumns, by: 1) {
            let values = line(column: column)
            let name = spec.firstRowIsHeader && tableRows > 0 ? tableCell(0, column) : nil
            series.append(Series(cells: values.cells, blocks: values.blocks, name: name))
        }
        self.series = series
    }

    /// The visible cells of blocks, in order (down columns, then across; across for blocks of one row), up
    /// to each sheet's content.
    static func visibleCells(_ blocks: [ODSSheetRange], in workbook: Workbook) -> [ODSSheetCell] {
        let bounds = ODSContentBounds(workbook: workbook, sheets: blocks.map(\.sheet))
        var result: [ODSSheetCell] = []
        for block in blocks where workbook.sheets.indices.contains(block.sheet) {
            let sheet = workbook.sheets[block.sheet]
            let range = block.range
            let lastRow = min(range.end.row, bounds.lastRow(block.sheet)), lastColumn = min(range.end.column, bounds.lastColumn(block.sheet))
            guard range.start.row <= lastRow, range.start.column <= lastColumn else { continue }
            let rows = range.start.row...lastRow, columns = range.start.column...lastColumn
            if range.rowCount == 1, range.columnCount > 1 {
                for row in rows where !sheet.isRowHidden(row) {
                    for column in columns where !sheet.hiddenColumns.contains(column) {
                        result.append(ODSSheetCell(sheet: block.sheet, address: CellAddress(row: row, column: column)))
                    }
                }
            } else {
                for column in columns where !sheet.hiddenColumns.contains(column) {
                    for row in rows where !sheet.isRowHidden(row) {
                        result.append(ODSSheetCell(sheet: block.sheet, address: CellAddress(row: row, column: column)))
                    }
                }
            }
        }
        return result
    }
}

/// The last row and column with content (a value, formula, image or spilled value) of some sheets.
struct ODSContentBounds {
    private var bounds: [Int: (row: Int, column: Int)] = [:]

    init(workbook: Workbook, sheets: [Int]) {
        for index in Set(sheets) where workbook.sheets.indices.contains(index) {
            let sheet = workbook.sheets[index]
            var row = -1, column = -1
            for (address, cell) in sheet.cells where cell.hasContent {
                row = max(row, address.row)
                column = max(column, address.column)
            }
            for address in sheet.spilledValues.keys {
                row = max(row, address.row)
                column = max(column, address.column)
            }
            bounds[index] = (row, column)
        }
    }

    func lastRow(_ sheet: Int) -> Int { bounds[sheet]?.row ?? -1 }
    func lastColumn(_ sheet: Int) -> Int { bounds[sheet]?.column ?? -1 }

    func contains(_ cell: ODSSheetCell) -> Bool {
        guard let bound = bounds[cell.sheet] else { return false }
        return cell.address.row <= bound.row && cell.address.column <= bound.column
    }
}
