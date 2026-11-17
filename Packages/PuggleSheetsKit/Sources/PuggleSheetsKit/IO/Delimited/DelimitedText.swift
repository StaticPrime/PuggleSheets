import Foundation

/// The field separator of a delimited text file.
enum CSVDelimiter: UInt8 {
    case comma = 0x2C
    case tab = 0x09

    var character: Character { Character(Unicode.Scalar(rawValue)) }
}

/// Reads CSV and TSV files (RFC 4180, leniently) into a one-sheet workbook.
enum DelimitedReader {
    /// Every field is interpreted as if typed into an empty cell: numbers, dates, percentages and
    /// formulas become values, formulas and number formats. Formula results are left for the app to
    /// calculate.
    static func read(_ data: Data, delimiter: CSVDelimiter) -> SpreadsheetFile {
        let records = records(in: DelimitedTextDecoding.decode(data), delimiter: delimiter)
        var sheet = Sheet(name: "Sheet1")
        var widest = 0
        for (row, record) in records.enumerated() {
            widest = max(widest, record.count)
            for (column, field) in record.enumerated() where !field.isEmpty {
                let parsed = InputParser.parse(field, currentFormat: nil)
                var cell = Cell(value: parsed.value, formula: parsed.formula)
                cell.format.numberFormat = parsed.impliedFormat
                sheet[row, column] = cell
            }
        }
        sheet.rowCount = max(Sheet.defaultRowCount, records.count)
        sheet.columnCount = max(Sheet.defaultColumnCount, widest)
        return SpreadsheetFile(workbook: Workbook(sheets: [sheet]))
    }

    /// Splits text into records of fields. Quoted fields may hold delimiters, line breaks and doubled
    /// quotes; CRLF, LF and CR all end records, and a final line break doesn't start another one.
    /// Line breaks inside quoted fields become "\n".
    static func records(in text: String, delimiter: CSVDelimiter) -> [[String]] {
        var text = text
        return text.withUTF8 { records(in: $0, delimiter: delimiter.rawValue) }
    }

    private static func records(in bytes: UnsafeBufferPointer<UInt8>, delimiter: UInt8) -> [[String]] {
        let quote = UInt8(ascii: "\""), carriageReturn = UInt8(ascii: "\r"), lineFeed = UInt8(ascii: "\n")
        let count = bytes.count
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var index = 0
        while index < count {
            if bytes[index] == quote {
                field.removeAll(keepingCapacity: true)
                index += 1
                while index < count {
                    let byte = bytes[index]
                    index += 1
                    if byte == quote {
                        guard index < count, bytes[index] == quote else { break }
                        field.append(quote)
                        index += 1
                    } else if byte == carriageReturn {
                        field.append(lineFeed)
                        if index < count, bytes[index] == lineFeed { index += 1 }
                    } else {
                        field.append(byte)
                    }
                }
                // Anything between the closing quote and the delimiter is kept as typed.
                while index < count, bytes[index] != delimiter, bytes[index] != lineFeed, bytes[index] != carriageReturn {
                    field.append(bytes[index])
                    index += 1
                }
                record.append(String(decoding: field, as: UTF8.self))
            } else {
                let start = index
                while index < count, bytes[index] != delimiter, bytes[index] != lineFeed, bytes[index] != carriageReturn {
                    index += 1
                }
                record.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
            }

            guard index < count else { break }
            if bytes[index] == delimiter {
                index += 1
                // A delimiter at the very end leaves one more, empty, field.
                if index == count { record.append("") }
                continue
            }
            index += bytes[index] == carriageReturn && index + 1 < count && bytes[index + 1] == lineFeed ? 2 : 1
            records.append(record)
            record = []
        }
        if !record.isEmpty { records.append(record) }
        return records
    }
}

/// Writes the values of one sheet as CSV or TSV.
enum DelimitedWriter {
    /// The active sheet from A1 to its last row and column with content (spilled results included),
    /// values as displayed, rows separated by CRLF with no line break at the end, UTF-8 without a byte
    /// order mark.
    static func write(_ workbook: Workbook, activeSheet: Int, delimiter: CSVDelimiter) -> Data {
        guard !workbook.sheets.isEmpty else { return Data() }
        let sheet = workbook.sheets[min(max(activeSheet, 0), workbook.sheets.count - 1)]
        guard let content = sheet.contentRange, content.end.row >= 0, content.end.column >= 0 else { return Data() }
        var output = ""
        for row in 0...content.end.row {
            if row > 0 { output += "\r\n" }
            for column in 0...content.end.column {
                if column > 0 { output.append(delimiter.character) }
                let address = CellAddress(row: row, column: column)
                let value = sheet.value(at: address)
                guard value != .empty else { continue }
                output += field(CellDisplay.text(for: value, pattern: sheet.cells[address]?.format.numberFormat).text, delimiter: delimiter)
            }
        }
        return Data(output.utf8)
    }

    /// Quotes text holding the delimiter, quotes or line breaks, or with leading or trailing spaces.
    static func field(_ text: String, delimiter: CSVDelimiter) -> String {
        let needsQuotes = text.utf8.contains { $0 == delimiter.rawValue || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }
            || text.hasPrefix(" ") || text.hasSuffix(" ")
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
