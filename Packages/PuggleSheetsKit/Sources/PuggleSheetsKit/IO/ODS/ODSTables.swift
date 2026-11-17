import Foundation

/// Tables (Format ▸ Convert to table) as LibreOffice's named database ranges: the table's range with its
/// header row, filter buttons and filter. LibreOffice has no table colors or column types: PuggleSheets'
/// settings keep them, and the exact criteria (see `ODSTableExtras`). LibreOffice's own named ranges
/// with a header row read as tables; its unnamed ones are sheet filters.
enum ODSTables {
    /// LibreOffice's names for a sheet's own database range (its filter) and for other unnamed ones.
    static let sheetRangePrefix = "__Anonymous_Sheet_DB__"
    static let anonymousRangePrefix = "__Anonymous_DB__"

    /// A `table:database-range` as a file has it.
    struct DatabaseRange {
        var name: String
        var sheet: String?
        var range: CellRange
        /// The first row names the columns (the default).
        var hasHeader: Bool
        /// The last row holds totals (LibreOffice's extension).
        var hasFooter: Bool
        /// Sorted and filtered by rows (the default), rather than by columns.
        var byRow: Bool
        var showsButtons: Bool
        var filter: XNode?

        var isAnonymous: Bool { name.hasPrefix(ODSTables.sheetRangePrefix) || name.hasPrefix(ODSTables.anonymousRangePrefix) }
        /// A named range with a header row, which reads as a table.
        var isTable: Bool { !isAnonymous && hasHeader && byRow }
    }

    /// The ranges of `table:database-ranges`, in file order.
    static func databaseRanges(_ node: XNode?) -> [DatabaseRange] {
        guard let node else { return [] }
        return node.children("database-range").compactMap { item in
            guard let address = item["target-range-address"].flatMap({ ODSFormula.parseAddressList($0).first }) else { return nil }
            // LibreOffice names a range without a name as a sheet's own.
            return DatabaseRange(name: item["name"] ?? sheetRangePrefix, sheet: address.sheet, range: address.range,
                                 hasHeader: item["contains-header"].map { $0 == "true" } ?? true,
                                 hasFooter: item["contains-footer"] == "true", byRow: item["orientation"] != "column",
                                 showsButtons: XLSXValue.isTrue(item["display-filter-buttons"]), filter: item.child("filter"))
        }
    }

    // MARK: - Writing

    /// The `table:database-range` of each of a sheet's tables, named after it, and what PuggleSheets'
    /// settings keep for them.
    static func write(_ sheet: Sheet, sheetName: String, into body: inout XMLWriter) -> [ODSTableExtras] {
        var extras: [ODSTableExtras] = []
        for table in sheet.tables where table.range.start.row >= 0 && table.range.start.column >= 0
            && table.range.end.row < ODSWriter.maximumRows && table.range.end.column < ODSWriter.maximumColumns {
            let fingerprint = ODSRules.writeDatabaseRange(name: table.name, sheetName: sheetName, range: table.range, criteria: table.criteria,
                                                          sheet: sheet, containsHeader: true, into: &body)
            extras.append(ODSTableExtras(table, filterFingerprint: fingerprint))
        }
        return extras
    }

    // MARK: - Reading

    /// The table a named database range with a header row stands for. `kept` is what PuggleSheets'
    /// settings hold for it; its criteria apply while the file's filter is still the one written.
    /// Names already taken (by named ranges or other tables) or that formulas can't use get a new one.
    static func table(_ item: DatabaseRange, sheet: Sheet, kept: ODSTableExtras?, usedNames: inout Set<String>,
                      warnings: inout Set<ImportWarning>) -> SheetTable? {
        var range = item.range
        // A totals row isn't part of a PuggleSheets table.
        if item.hasFooter, range.rowCount > 1 { range = CellRange(rows: range.start.row...(range.end.row - 1), columns: range.columns) }
        func byColumn<Value>(_ values: [Int: Value]) -> [Int: Value] {
            var result: [Int: Value] = [:]
            for (offset, value) in values where offset >= 0 && offset < range.columnCount { result[range.start.column + offset] = value }
            return result
        }
        let criteria: [Int: FilterCriterion]
        if let kept, kept.filterFingerprint == ODSRules.filterFingerprint(item.filter) {
            criteria = byColumn(kept.criteria)
        } else {
            let read = ODSRules.filterCriteria(item.filter, range: range, sheet: sheet)
            if read.unsupported { warnings.insert(.filters) }
            criteria = read.criteria
        }
        return SheetTable(id: kept?.id ?? UUID(), name: uniqueName(kept?.name ?? item.name, used: &usedNames), range: range,
                          columnTypes: byColumn(kept?.columnTypes ?? [:]), color: kept?.color ?? SheetTable.colors[0], criteria: criteria)
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let base = NamedRange.isValidName(name) ? name : "Table1"
        var candidate = base
        var number = 1
        while used.contains(candidate.lowercased()) || !NamedRange.isValidName(candidate) {
            number += 1
            candidate = "\(base)_\(number)"
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}

/// Structured references (Table1[Column], Table1[#ALL], Table1[[#HEADERS],[Column]], Table1[[First]:[Last]])
/// as the cells they cover. OpenFormula has no table references; LibreOffice writes them so too.
struct ODSTableReferences {
    private struct Table {
        /// The sheet's name as written.
        var sheet: String
        var range: CellRange
        var dataRows: ClosedRange<Int>
        /// Each column's header as shown.
        var headers: [(column: Int, text: String)]

        func column(named name: String) -> Int? {
            if let match = headers.first(where: { $0.text.caseInsensitiveCompare(name) == .orderedSame }) { return match.column }
            // Excel's escapes: "'" before "[", "]", "#" and "'" in column names.
            guard name.contains("'") else { return nil }
            var plain = ""
            var escaped = false
            for character in name {
                if character == "'", !escaped {
                    escaped = true
                    continue
                }
                plain.append(character)
                escaped = false
            }
            return headers.first(where: { $0.text.caseInsensitiveCompare(plain) == .orderedSame })?.column
        }
    }

    private enum Item: String {
        case all = "#ALL", data = "#DATA", headers = "#HEADERS", totals = "#TOTALS", thisRow = "#THIS ROW"
    }

    /// Tables by upper-cased name: the first of a name wins, as in formulas.
    private var tables: [String: Table] = [:]

    /// `names`: the sheets' names as written, by index.
    init(workbook: Workbook, names: [String]) {
        for (index, sheet) in workbook.sheets.enumerated() where index < names.count {
            for table in sheet.tables where tables[table.name.uppercased()] == nil {
                let headers = table.range.columns.map { column in
                    (column, CellDisplay.text(for: sheet.value(at: CellAddress(row: table.headerRow, column: column)), pattern: nil).text)
                }
                // A table that's only a header row has no data rows of its own; its data is its header, as in formulas.
                let data = table.dataRange ?? table.range
                tables[table.name.uppercased()] = Table(sheet: names[index], range: table.range, dataRows: data.rows, headers: headers)
            }
        }
    }

    /// The OpenFormula text for table `name` and its bracketed part ("[Column]", "[#HEADERS]",
    /// "[[#HEADERS],[Column]]", "[[First]:[Last]]", "[@Column]"): a reference to the cells, or an error
    /// value where the table or the part doesn't exist. `row` is the formula's row, for [#This Row].
    func reference(_ name: String, _ specifier: String, row: Int) -> String {
        guard let table = tables[name.uppercased()], let parts = Self.parse(specifier) else { return "#REF!" }
        var columns = table.range.columns
        if let names = parts.columns {
            guard let first = table.column(named: names.first), let last = table.column(named: names.last) else { return "#REF!" }
            columns = min(first, last)...max(first, last)
        }
        let header = table.range.start.row
        var rows: ClosedRange<Int>
        if parts.items.contains(.thisRow) {
            guard table.dataRows.contains(row) else { return "#VALUE!" }
            rows = row...row
        } else if parts.items.contains(.all) || (parts.items.isEmpty && parts.columns == nil) {
            // Table1 and Table1[] are the whole table, header included.
            rows = table.range.rows
        } else if parts.items.contains(.headers) {
            rows = parts.items.contains(.data) ? header...table.dataRows.upperBound : header...header
        } else if parts.items.contains(.data) || parts.items.isEmpty {
            rows = table.dataRows
        } else {
            // Only totals, which PuggleSheets' tables don't have.
            return "#REF!"
        }
        return "[" + ODSFormula.address(sheet: table.sheet, range: CellRange(rows: rows, columns: columns), absolute: true) + "]"
    }

    /// The special items and the column (or column range) of a structured reference's bracketed part.
    private static func parse(_ specifier: String) -> (items: Set<Item>, columns: (first: String, last: String)?)? {
        guard specifier.hasPrefix("["), specifier.hasSuffix("]"), specifier.count >= 2 else { return nil }
        let inner = specifier.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return ([], nil) }
        if !inner.hasPrefix("[") {
            // One part: "#ALL", "@Column", "@[Column]" or "Column".
            if inner.hasPrefix("#") { return Item(rawValue: inner.uppercased()).map { ([$0], nil) } }
            if inner.hasPrefix("@") {
                var column = inner.dropFirst().trimmingCharacters(in: .whitespaces)
                if column.hasPrefix("["), column.hasSuffix("]"), column.count >= 2 { column = String(column.dropFirst().dropLast()) }
                return ([.thisRow], column.isEmpty ? nil : (column, column))
            }
            return ([], (inner, inner))
        }
        // Parts in brackets, separated by "," or, between two columns, ":".
        var groups: [String] = []
        var separators: [Character] = []
        var index = inner.startIndex
        while index < inner.endIndex {
            let character = inner[index]
            if character == "[" {
                var end = inner.index(after: index)
                var group = ""
                while end < inner.endIndex, inner[end] != "]" {
                    if inner[end] == "'", inner.index(after: end) < inner.endIndex {
                        group.append("'")
                        end = inner.index(after: end)
                    }
                    group.append(inner[end])
                    end = inner.index(after: end)
                }
                guard end < inner.endIndex else { return nil }
                groups.append(group.trimmingCharacters(in: .whitespaces))
                index = inner.index(after: end)
            } else if character == "," || character == ":" {
                separators.append(character)
                index = inner.index(after: index)
            } else if character.isWhitespace {
                index = inner.index(after: index)
            } else {
                return nil
            }
        }
        guard groups.count == separators.count + 1 else { return nil }
        var items = Set<Item>()
        var columns: [String] = []
        for (position, group) in groups.enumerated() {
            if group.hasPrefix("#") {
                guard let item = Item(rawValue: group.uppercased()), columns.isEmpty else { return nil }
                items.insert(item)
            } else if group == "@" {
                items.insert(.thisRow)
            } else {
                // A second column only after ":".
                guard columns.count < 2, columns.isEmpty || separators[position - 1] == ":" else { return nil }
                columns.append(group)
            }
        }
        return (items, columns.first.map { ($0, columns.last ?? $0) })
    }
}
