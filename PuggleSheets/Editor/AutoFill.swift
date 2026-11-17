import Foundation
import PuggleSheetsKit

/// What dragging the fill handle produces: series continue (1, 2 → 3, 4; Jan → Feb; Item 1 → Item 2;
/// dates by day or month), formulas are copied with relative references shifted, and anything else
/// repeats. Dragging up or left runs the series backwards.
enum AutoFill {
    static func fill(sheet: Sheet, source: CellRange, target: CellRange) -> [CellAddress: Cell] {
        var updates: [CellAddress: Cell] = [:]
        if target.rowCount > source.rowCount {
            let down = target.end.row > source.end.row
            let rows = down ? Array((source.end.row + 1)...target.end.row) : Array((target.start.row...(source.start.row - 1)).reversed())
            let sourceRows = down ? Array(source.rows) : Array(source.rows.reversed())
            for column in source.columns {
                let cells = sourceRows.map { sheet[$0, column] }
                for (index, cell) in series(after: cells, count: rows.count).enumerated() {
                    let patternRow = sourceRows[(cells.count + index) % cells.count]
                    updates[CellAddress(row: rows[index], column: column)] = shifted(cell, rows: rows[index] - patternRow, columns: 0)
                }
            }
        } else if target.columnCount > source.columnCount {
            let right = target.end.column > source.end.column
            let columns = right ? Array((source.end.column + 1)...target.end.column)
                : Array((target.start.column...(source.start.column - 1)).reversed())
            let sourceColumns = right ? Array(source.columns) : Array(source.columns.reversed())
            for row in source.rows {
                let cells = sourceColumns.map { sheet[row, $0] }
                for (index, cell) in series(after: cells, count: columns.count).enumerated() {
                    let patternColumn = sourceColumns[(cells.count + index) % cells.count]
                    updates[CellAddress(row: row, column: columns[index])] = shifted(cell, rows: 0, columns: columns[index] - patternColumn)
                }
            }
        }
        return updates
    }

    private static func shifted(_ cell: Cell, rows: Int, columns: Int) -> Cell {
        guard let formula = cell.formula else { return cell }
        var result = cell
        result.formula = FormulaRewriter.translate(formula, rows: rows, columns: columns)
        return result
    }

    /// The next `count` cells after `cells`, in fill order. Formula cells come back unshifted.
    static func series(after cells: [Cell], count: Int) -> [Cell] {
        guard !cells.isEmpty, count > 0 else { return [] }
        func pattern(_ index: Int) -> Cell { cells[(cells.count + index) % cells.count] }
        func withValue(_ index: Int, _ value: CellValue) -> Cell {
            var cell = pattern(index)
            cell.value = value
            return cell
        }
        let values = cells.map(\.value)
        let anyFormula = cells.contains { $0.formula != nil }

        if !anyFormula, let numbers = optionalNumbers(values) {
            let isDate = cells.allSatisfy { [.date, .dateTime].contains(NumberFormatPresets.kind(of: $0.format.numberFormat)) }
            if isDate, let months = monthlyStep(numbers) {
                let last = DateSerial.parts(of: numbers[numbers.count - 1])
                let fraction = numbers[numbers.count - 1] - numbers[numbers.count - 1].rounded(.down)
                return (0..<count).map { index in
                    withValue(index, .number(DateSerial.serial(year: last.year, month: last.month + months * (index + 1), day: last.day) + fraction))
                }
            }
            if numbers.count == 1 {
                // A single date counts up by days; a single number repeats.
                return (0..<count).map { withValue($0, .number(isDate ? numbers[0] + Double($0 + 1) : numbers[0])) }
            }
            let (intercept, slope) = linearFit(numbers)
            return (0..<count).map { index in
                let value = intercept + slope * Double(numbers.count + index)
                return withValue(index, .number((value * 1e10).rounded() / 1e10))
            }
        }

        if !anyFormula, let texts = optionalTexts(values) {
            if let series = nameSeries(texts, count: count) {
                return series.enumerated().map { withValue($0.offset, .text($0.element)) }
            }
            if let series = numberedTextSeries(texts, count: count) {
                return series.enumerated().map { withValue($0.offset, .text($0.element)) }
            }
        }
        return (0..<count).map { pattern($0) }
    }

    private static func optionalNumbers(_ values: [CellValue]) -> [Double]? {
        let numbers = values.compactMap(\.numberValue)
        return numbers.count == values.count ? numbers : nil
    }

    private static func optionalTexts(_ values: [CellValue]) -> [String]? {
        let texts = values.compactMap(\.textValue)
        return texts.count == values.count ? texts : nil
    }

    /// Least-squares line through (0, y0), (1, y1), …
    private static func linearFit(_ values: [Double]) -> (intercept: Double, slope: Double) {
        let n = Double(values.count)
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var numerator = 0.0, denominator = 0.0
        for (index, value) in values.enumerated() {
            numerator += (Double(index) - meanX) * (value - meanY)
            denominator += (Double(index) - meanX) * (Double(index) - meanX)
        }
        let slope = denominator == 0 ? 0 : numerator / denominator
        return (meanY - slope * meanX, slope)
    }

    /// Dates on the same day of the month, a whole number of months apart.
    private static func monthlyStep(_ serials: [Double]) -> Int? {
        guard serials.count >= 2 else { return nil }
        let parts = serials.map { DateSerial.parts(of: $0) }
        guard parts.allSatisfy({ $0.day == parts[0].day }) else { return nil }
        let months = parts.map { $0.year * 12 + $0.month }
        let step = months[1] - months[0]
        guard step != 0, zip(months, months.dropFirst()).allSatisfy({ $1 - $0 == step }) else { return nil }
        return step
    }

    /// "Item 1", "Item 2" → "Item 3"…, keeping zero padding ("Q01" → "Q02").
    private static func numberedTextSeries(_ texts: [String], count: Int) -> [String]? {
        let parts = texts.compactMap(splitTrailingNumber)
        guard parts.count == texts.count, Set(parts.map(\.prefix)).count == 1 else { return nil }
        let numbers = parts.map(\.number)
        let step = numbers.count > 1 ? numbers[1] - numbers[0] : 1
        guard numbers.count == 1 || zip(numbers, numbers.dropFirst()).allSatisfy({ $1 - $0 == step }) else { return nil }
        let last = parts[parts.count - 1]
        return (1...count).map { index in
            let number = last.number + step * index
            let digits = String(abs(number))
            let padded = String(repeating: "0", count: max(0, last.width - digits.count)) + digits
            return last.prefix + (number < 0 ? "-" : "") + padded
        }
    }

    private static func splitTrailingNumber(_ text: String) -> (prefix: String, number: Int, width: Int)? {
        let digits = text.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < 10, digits.count < text.count else { return nil }
        let prefix = String(text.dropLast(digits.count))
        return (prefix, Int(String(digits.reversed()))!, digits.count)
    }

    private static let nameLists: [[String]] = {
        let english = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = english
        return [calendar.weekdaySymbols, calendar.shortWeekdaySymbols, calendar.monthSymbols, calendar.shortMonthSymbols]
    }()

    /// Weekday and month names continue round the week or year, keeping their capitalization.
    private static func nameSeries(_ texts: [String], count: Int) -> [String]? {
        for list in nameLists {
            let indexes = texts.compactMap { text in list.firstIndex { $0.caseInsensitiveCompare(text) == .orderedSame } }
            guard indexes.count == texts.count else { continue }
            let step = indexes.count > 1 ? indexes[1] - indexes[0] : 1
            let last = texts[texts.count - 1]
            return (1...count).map { index in
                let name = list[((indexes[indexes.count - 1] + step * index) % list.count + list.count) % list.count]
                if last == last.uppercased() { return name.uppercased() }
                if last == last.lowercased() { return name.lowercased() }
                return name
            }
        }
        return nil
    }
}
