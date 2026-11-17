import Foundation

/// A spreadsheet: its sheets, in tab order.
public struct Workbook: Sendable {
    public var sheets: [Sheet]
    /// Data ▸ Named ranges.
    public var namedRanges: [NamedRange] = []

    public init(sheets: [Sheet] = [Sheet(name: "Sheet1")], namedRanges: [NamedRange] = []) {
        self.sheets = sheets.isEmpty ? [Sheet(name: "Sheet1")] : sheets
        self.namedRanges = namedRanges
    }

    /// Names are matched without regard to case, as in formulas.
    public func namedRange(_ name: String) -> NamedRange? {
        namedRanges.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A table by name (without regard to case) and the sheet that holds it.
    public func table(named name: String) -> (sheet: Int, table: SheetTable)? {
        for (index, sheet) in sheets.enumerated() {
            if let table = sheet.tables.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return (index, table) }
        }
        return nil
    }

    /// Where a table reference points: "Table1" or "Table1[#ALL]" (the whole table), "Table1[#DATA]"
    /// (its data rows), "Table1[#HEADERS]" (its header row), or "Table1[Column]" (a column's data).
    public func resolveTableReference(_ reference: String) -> (sheet: Int, range: CellRange)? {
        var text = reference.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        var name = text, part = ""
        if let open = text.firstIndex(of: "["), text.hasSuffix("]") {
            name = String(text[..<open])
            part = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            if part.hasPrefix("["), part.hasSuffix("]") { part = String(part.dropFirst().dropLast()) }
        }
        guard let (sheetIndex, table) = table(named: name) else { return nil }
        let data = table.dataRange ?? CellRange(rows: table.range.rows, columns: table.range.columns)
        switch part.uppercased() {
        case "", "#ALL": return (sheetIndex, table.range)
        case "#DATA": return (sheetIndex, data)
        case "#HEADERS": return (sheetIndex, CellRange(rows: table.headerRow...table.headerRow, columns: table.range.columns))
        default:
            let sheet = sheets[sheetIndex]
            for column in table.range.columns {
                let header = sheet.value(at: CellAddress(row: table.headerRow, column: column))
                if CellDisplay.text(for: header, pattern: nil).text.caseInsensitiveCompare(part) == .orderedSame {
                    return (sheetIndex, CellRange(rows: data.rows, columns: column...column))
                }
            }
            return nil
        }
    }

    /// Sheet names are matched without regard to case, as in formulas.
    public func sheetIndex(named name: String) -> Int? {
        sheets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func sheetIndex(id: UUID) -> Int? {
        sheets.firstIndex { $0.id == id }
    }

    /// Where a reference points: "B2:D10" on sheet `defaultSheet`, "Sheet2!B2:D10", "'My data'!A:C",
    /// "2:5", an open range like "A2:A", or a named range. Whole and open ranges end at the sheet's edge.
    public func resolve(_ reference: String, onSheet defaultSheet: Int) -> (sheet: Int, range: CellRange)? {
        resolve(reference, onSheet: defaultSheet, depth: 0)
    }

    private func resolve(_ reference: String, onSheet defaultSheet: Int, depth: Int) -> (sheet: Int, range: CellRange)? {
        var text = reference.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        guard !text.isEmpty, depth < 4 else { return nil }
        if !text.contains("!"), !text.contains(":"), let named = namedRange(text) {
            return resolve(named.reference, onSheet: 0, depth: depth + 1)
        }
        if !text.contains("!"), !text.contains(":"), let table = resolveTableReference(text) { return table }
        var sheetIndex = defaultSheet
        if let bang = text.lastIndex(of: "!") {
            var name = String(text[..<bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard let index = self.sheetIndex(named: name) else { return nil }
            sheetIndex = index
            text = String(text[text.index(after: bang)...])
        }
        guard sheets.indices.contains(sheetIndex) else { return nil }
        let sheet = sheets[sheetIndex]
        let parts = text.replacingOccurrences(of: "$", with: "").uppercased().split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        // Each end: a column letter, a row number, or both.
        func end(_ part: String) -> (column: Int?, row: Int?)? {
            let letters = part.prefix { $0.isLetter }, digits = part.dropFirst(letters.count)
            guard !part.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let column = letters.isEmpty ? nil : CellAddress.columnIndex(String(letters))
            if !letters.isEmpty, column == nil { return nil }
            let row = digits.isEmpty ? nil : Int(digits).map { $0 - 1 }
            if let row, row < 0 { return nil }
            return (column, row)
        }
        guard let first = end(parts[0]) else { return nil }
        let second = parts.count == 2 ? end(parts[1]) : first
        guard let second else { return nil }
        if parts.count == 1, first.column == nil || first.row == nil { return nil }
        let lastRow = max(0, sheet.rowCount - 1), lastColumn = max(0, sheet.columnCount - 1)
        let top = min(first.row ?? 0, second.row ?? (first.row ?? 0))
        let bottom = (first.row == nil || second.row == nil) ? lastRow : max(first.row!, second.row!)
        let left = min(first.column ?? 0, second.column ?? (first.column ?? 0))
        let right = (first.column == nil || second.column == nil) ? lastColumn : max(first.column!, second.column!)
        guard top <= bottom, left <= right else { return nil }
        return (sheetIndex, CellRange(rows: top...min(bottom, max(top, lastRow)), columns: left...min(right, max(left, lastColumn))))
    }

    /// "Sheet2", "Sheet3", … for new sheets: the first free number from the sheet count up.
    public func newSheetName() -> String {
        var number = sheets.count + 1
        while sheetIndex(named: "Sheet\(number)") != nil { number += 1 }
        return "Sheet\(number)"
    }

    /// "Copy of Sales", then "Copy of Sales 2", …
    public func copyName(for name: String) -> String {
        let base = "Copy of \(name)"
        guard sheetIndex(named: base) != nil else { return base }
        var number = 2
        while sheetIndex(named: "\(base) \(number)") != nil { number += 1 }
        return "\(base) \(number)"
    }
}
