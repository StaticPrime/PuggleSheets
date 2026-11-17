import Foundation

/// How a chart's ranges become series, following the chart module's rules, with the cells behind
/// every value so Excel series can be written as references, and the reverse for Excel charts.
///
/// The rules: resolve each range from the chart's sheet; join them side by side, rows lining up by
/// position; leave out hidden rows and columns; transpose when rows and columns are switched; the
/// first row names the series and the first column holds the labels when those options are on.
enum XLSXChartLayout {
    /// A run of cells on one sheet: a series' values, the labels, or a name.
    struct Line: Equatable {
        var sheet: Int
        /// Rectangular areas in order, each one row or one column. Hidden cells inside are included:
        /// Excel charts plot visible cells only, as the chart module does.
        var areas: [CellRange]

        /// Every cell of the areas, in order.
        var cells: [CellAddress] {
            areas.flatMap { area in area.rows.flatMap { row in area.columns.map { CellAddress(row: row, column: $0) } } }
        }

        var isEmpty: Bool { areas.isEmpty }
    }

    struct Series {
        /// The header cell naming the series.
        var name: Line?
        var values: Line
    }

    struct Layout {
        var labels: Line?
        var series: [Series]
    }

    // MARK: - Spec to series

    static func layout(for spec: ChartSpec, sheetIndex: Int, workbook: Workbook) -> Layout {
        let resolved = spec.ranges.compactMap { workbook.resolve($0, onSheet: sheetIndex) }
        guard let first = resolved.first else { return Layout(labels: nil, series: []) }

        // The joined block: its columns in order, and its rows by position.
        struct Column { var range: Int; var column: Int }
        var columns: [Column] = []
        for (index, item) in resolved.enumerated() {
            for column in item.range.columns { columns.append(Column(range: index, column: column)) }
            if columns.count > XLSXLimits.columns { break }
        }
        let rowCount = min(resolved.map(\.range.rowCount).max() ?? 0, XLSXLimits.rows)
        let firstSheet = workbook.sheets[first.sheet]
        func isVisible(_ column: Column) -> Bool {
            !workbook.sheets[resolved[column.range].sheet].isColumnHidden(column.column)
        }
        // Rows are judged by the first range's sheet rows, which the others line up with.
        func isVisible(row offset: Int) -> Bool { !firstSheet.isRowHidden(first.range.start.row + offset) }
        let visibleColumns = columns.indices.filter { isVisible(columns[$0]) }
        var visibleRows: [Int] = []
        for offset in 0..<rowCount where isVisible(row: offset) { visibleRows.append(offset) }

        /// One cell of the block, when its range reaches that far.
        func cell(_ columnIndex: Int, row offset: Int) -> (sheet: Int, address: CellAddress)? {
            let column = columns[columnIndex], item = resolved[column.range]
            guard offset < item.range.rowCount else { return nil }
            return (item.sheet, CellAddress(row: item.range.start.row + offset, column: column.column))
        }

        if !spec.switchRowsAndColumns {
            let header = spec.firstRowIsHeader ? visibleRows.first : nil
            let firstData = header.map { $0 + 1 } ?? 0
            let labelColumn = spec.firstColumnIsLabels ? visibleColumns.first : nil
            /// A column of the block from the first data row down, hidden rows included.
            func line(_ columnIndex: Int) -> Line {
                let column = columns[columnIndex], item = resolved[column.range]
                let last = item.range.rowCount - 1
                guard firstData <= last else { return Line(sheet: item.sheet, areas: []) }
                return Line(sheet: item.sheet, areas: [CellRange(rows: (item.range.start.row + firstData)...(item.range.start.row + last),
                                                                 columns: column.column...column.column)])
            }
            let labels = labelColumn.map(line)
            let series = visibleColumns.filter { $0 != labelColumn }.map { index -> Series in
                let name = header.flatMap { cell(index, row: $0) }.map { Line(sheet: $0.sheet, areas: [CellRange($0.address)]) }
                return Series(name: name, values: line(index))
            }
            return Layout(labels: labels, series: series)
        }

        // Switched: the block's rows are the series and its columns the points.
        let nameColumn = spec.firstRowIsHeader ? visibleColumns.first : nil
        let firstDataColumn = nameColumn.map { $0 + 1 } ?? 0
        let labelRow = spec.firstColumnIsLabels ? visibleRows.first : nil
        /// A row of the block from the first data column on, hidden columns included, as areas.
        func line(row offset: Int) -> Line? {
            var areas: [CellRange] = []
            var sheet: Int?
            for index in firstDataColumn..<max(firstDataColumn, columns.count) {
                guard let (cellSheet, address) = cell(index, row: offset) else { continue }
                // A series is drawn from one sheet; parts on other sheets are left out.
                if sheet == nil { sheet = cellSheet }
                guard cellSheet == sheet else { continue }
                if let last = areas.last, last.end.row == address.row, last.end.column + 1 == address.column {
                    areas[areas.count - 1] = CellRange(rows: last.rows, columns: last.start.column...address.column)
                } else {
                    areas.append(CellRange(address))
                }
            }
            return sheet.map { Line(sheet: $0, areas: areas) }
        }
        let labels = labelRow.flatMap { line(row: $0) }
        var series: [Series] = []
        for offset in visibleRows where offset != labelRow {
            let name = nameColumn.flatMap { cell($0, row: offset) }.map { Line(sheet: $0.sheet, areas: [CellRange($0.address)]) }
            series.append(Series(name: name, values: line(row: offset) ?? Line(sheet: first.sheet, areas: [])))
        }
        return Layout(labels: labels, series: series)
    }

    // MARK: - Series to spec

    /// A series as an Excel chart references it.
    struct ExcelSeries {
        var values: (sheet: Int, range: CellRange)?
        var categories: (sheet: Int, range: CellRange)?
        var name: (sheet: Int, address: CellAddress)?
        /// A name given as text rather than a cell.
        var hasLiteralName = false
    }

    /// The ranges and options that rebuild Excel's series under the layout rules.
    struct Inferred {
        var ranges: [String]
        var firstRowIsHeader: Bool
        var firstColumnIsLabels: Bool
        var switchRowsAndColumns: Bool
        /// For each Excel series, its position among the chart's series (nil for one in hidden cells,
        /// which isn't drawn).
        var seriesPositions: [Int?]
        /// Something about the series couldn't be represented exactly.
        var isApproximate: Bool
    }

    /// Nil when no series references cells, or the series run in different directions.
    static func infer(_ series: [ExcelSeries], chartSheet: Int, sheets: [Sheet], sheetNames: [String]) -> Inferred? {
        let referenced = series.compactMap(\.values)
        guard !referenced.isEmpty else { return nil }
        var approximate = referenced.count != series.count

        // Series down columns, or along rows (switched).
        let allColumns = referenced.allSatisfy { $0.range.columnCount == 1 }
        let allRows = referenced.allSatisfy { $0.range.rowCount == 1 }
        let switched: Bool
        if allColumns && allRows {
            // Single points: the categories' direction decides.
            switched = (series.first?.categories?.range.rowCount ?? 2) == 1 && (series.first?.categories?.range.columnCount ?? 1) > 1
        } else if allColumns {
            switched = false
        } else if allRows {
            switched = true
        } else {
            return nil
        }
        // Work as if series ran down columns.
        func normal(_ range: CellRange) -> CellRange { switched ? CellRange(rows: range.columns, columns: range.rows) : range }
        func normal(_ address: CellAddress) -> CellAddress { switched ? CellAddress(row: address.column, column: address.row) : address }
        func isHidden(sheet: Int, normalColumn column: Int) -> Bool {
            switched ? sheets[sheet].isRowHidden(column) : sheets[sheet].isColumnHidden(column)
        }

        let withValues = series.filter { $0.values != nil }
        // A header row when every series is named by the cell just above its values.
        let named = withValues.filter { $0.name != nil || $0.hasLiteralName }.count
        var header = named == withValues.count && withValues.allSatisfy { item in
            guard let name = item.name, let values = item.values, name.sheet == values.sheet else { return false }
            let area = normal(values.range), cell = normal(name.address)
            return area.start.row >= 1 && cell == CellAddress(row: area.start.row - 1, column: area.start.column)
        }
        if named > 0 && !header { approximate = true }

        // Labels: the first series' categories, one column wide.
        var labels: (sheet: Int, range: CellRange)?
        if let categories = withValues.first?.categories {
            let area = normal(categories.range)
            if area.columnCount == 1 {
                labels = (categories.sheet, area)
            } else {
                approximate = true
            }
            if withValues.contains(where: { item in
                guard let other = item.categories else { return true }
                return other.sheet != categories.sheet || other.range != categories.range
            }) {
                approximate = true
            }
        }
        if header, let label = labels, label.range.start.row == 0 {
            header = false
            approximate = true
        }

        // The ranges, in normal orientation: labels first, then each series.
        var ranges: [(sheet: Int, range: CellRange)] = []
        if let label = labels {
            ranges.append((label.sheet, header ? CellRange(rows: (label.range.start.row - 1)...label.range.end.row,
                                                            columns: label.range.columns) : label.range))
        }
        var positions: [Int?] = []
        var position = 0
        for item in series {
            guard let values = item.values else {
                positions.append(nil)
                continue
            }
            let area = normal(values.range)
            ranges.append((values.sheet, header ? CellRange(rows: (area.start.row - 1)...area.end.row, columns: area.columns) : area))
            if isHidden(sheet: values.sheet, normalColumn: area.start.column) {
                positions.append(nil)
            } else {
                positions.append(position)
                position += 1
            }
        }

        // Neighbors merge, also across columns that are hidden (the layout leaves those out anyway).
        var merged: [(sheet: Int, range: CellRange)] = []
        for item in ranges {
            if let last = merged.last, last.sheet == item.sheet, last.range.rows == item.range.rows,
               item.range.start.column > last.range.end.column,
               ((last.range.end.column + 1)..<item.range.start.column).allSatisfy({ isHidden(sheet: item.sheet, normalColumn: $0) }) {
                merged[merged.count - 1] = (last.sheet, CellRange(rows: last.range.rows, columns: last.range.start.column...item.range.end.column))
            } else {
                merged.append(item)
            }
        }

        let texts = merged.map { item -> String in
            let range = normal(item.range)
            if item.sheet == chartSheet { return range.a1 }
            return SheetNames.quoted(sheetNames[item.sheet]) + "!" + range.a1
        }
        return Inferred(ranges: texts, firstRowIsHeader: header, firstColumnIsLabels: labels != nil, switchRowsAndColumns: switched,
                        seriesPositions: positions, isApproximate: approximate)
    }

    // MARK: - References

    /// An Excel reference to a line: "Sheet1!$B$2:$B$9", or several areas in parentheses.
    static func reference(_ line: Line, sheetNames: [String]) -> String {
        let sheet = SheetNames.quoted(sheetNames[line.sheet])
        let parts = line.areas.map { sheet + "!" + $0.absoluteA1 }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: ",") + ")"
    }

    /// Parses an Excel series reference into its sheet name and areas. Nil for names, external
    /// workbooks and anything else that isn't plain cell references.
    static func parseReference(_ text: String) -> (sheet: String?, areas: [CellRange])? {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("="), body.count > 1 { body.removeFirst() }
        if body.hasPrefix("("), body.hasSuffix(")"), body.count >= 2 { body = String(body.dropFirst().dropLast()) }
        var sheet: String?
        var areas: [CellRange] = []
        for part in splitOutsideQuotes(body, at: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let bang = lastIndexOutsideQuotes(piece, of: "!") else {
                // A bare range belongs to the chart's own sheet.
                guard let range = CellRange(a1: piece.replacingOccurrences(of: "$", with: "")) else { return nil }
                areas.append(range)
                continue
            }
            var name = String(piece[..<bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            // "[1]Sheet1" points into another workbook.
            if name.hasPrefix("[") { return nil }
            if let sheet, sheet.caseInsensitiveCompare(name) != .orderedSame { return nil }
            sheet = name
            guard let range = CellRange(a1: piece[piece.index(after: bang)...].replacingOccurrences(of: "$", with: "")),
                  range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns else { return nil }
            areas.append(range)
        }
        return areas.isEmpty ? nil : (sheet, areas)
    }

    /// One range for several areas of a series: their bounding block when they lie on one line.
    static func singleArea(_ areas: [CellRange]) -> (range: CellRange, isExact: Bool)? {
        guard var bounds = areas.first else { return nil }
        for area in areas.dropFirst() { bounds = bounds.union(area) }
        guard bounds.columnCount == 1 || bounds.rowCount == 1 else { return nil }
        let covered = areas.reduce(0) { $0 + $1.cellCount }
        return (bounds, covered == bounds.cellCount && areas.count == 1)
    }

    private static func splitOutsideQuotes(_ text: String, at separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "'" { quoted.toggle() }
            if character == separator, !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func lastIndexOutsideQuotes(_ text: String, of target: Character) -> String.Index? {
        var quoted = false
        var found: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "'" { quoted.toggle() }
            if character == target, !quoted { found = index }
            index = text.index(after: index)
        }
        return found
    }
}
