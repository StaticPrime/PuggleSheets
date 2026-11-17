import Foundation

/// Writes pivot tables as Excel pivot tables: a cache definition over the source range (refreshed
/// when Excel opens the file) and a table definition laid over the results, which are also written
/// as plain cells so other apps show them.
enum XLSXPivotWriter {
    struct Context {
        let workbook: Workbook
        let sheetIndex: Int
        let sheetNames: [String]
    }

    /// A cache the workbook lists in `<pivotCaches>`.
    struct Cache {
        var id: Int
        /// Relative to the workbook part.
        var target: String
    }

    /// The source's distinct values in one column, as the cache's shared items.
    enum Item: Hashable {
        case blank
        case text(String)
        case number(Double)
        case date(Double)
        case boolean(Bool)
        case error(String)
    }

    struct Field {
        var name: String
        var items: [Item] = []
        var indexes: [Item: Int] = [:]
        /// Each item's shown text, for filters.
        var shownTexts: [Item: String] = [:]
        var hasText = false, hasBlank = false, hasNumber = false, hasDate = false, hasBoolean = false, hasError = false
        var allIntegers = true
        var minimum = Double.infinity, maximum = -Double.infinity
        var minimumDate = Double.infinity, maximumDate = -Double.infinity
        var hasLongText = false
    }

    /// Writes one pivot table and its cache into `parts`. Returns the table's target relative to its
    /// worksheet and the cache for the workbook, or nil when the source can't be found.
    static func write(_ pivot: PivotTable, number: Int, sheet: Sheet, context: Context, counters: inout XLSXPartCounters,
                      parts: inout XLSXExtraParts) -> (table: String, cache: Cache)? {
        guard let source = context.workbook.resolve(pivot.source, onSheet: context.sheetIndex),
              source.range.end.row < XLSXLimits.rows, source.range.end.column < XLSXLimits.columns else { return nil }
        let sourceSheet = context.workbook.sheets[source.sheet]
        let range = source.range
        let axisColumns = Set(pivot.rows.map(\.sourceColumn) + pivot.columns.map(\.sourceColumn) + pivot.filters.map(\.sourceColumn))
        guard pivot.usedSourceColumns.allSatisfy({ $0 >= 0 && $0 < range.columnCount }) else { return nil }

        let fields = self.fields(of: sourceSheet, range: range, axisColumns: axisColumns)
        counters.pivotCaches += 1
        counters.pivotTables += 1
        let cacheNumber = counters.pivotCaches, tableNumber = counters.pivotTables
        let cachePath = "xl/pivotCache/pivotCacheDefinition\(cacheNumber).xml"
        parts.add(cachePath, cacheDefinition(fields: fields, source: range, sheetName: context.sheetNames[source.sheet],
                                             recordCount: max(0, range.rowCount - 1)),
                  contentType: XLSXContentType.pivotCacheDefinition)

        let hidden = hiddenItems(pivot, fields: fields, sourceSheet: source.sheet, range: range, workbook: context.workbook)
        let location = sheet.spillRanges[pivot.anchor].flatMap { $0.start == pivot.anchor ? $0 : nil } ?? CellRange(pivot.anchor)
        let tablePath = "xl/pivotTables/pivotTable\(tableNumber).xml"
        parts.add(tablePath, tableDefinition(pivot, name: "PivotTable\(number)", cacheID: cacheNumber, fields: fields, hidden: hidden,
                                             location: location),
                  contentType: XLSXContentType.pivotTable)
        var relationships = XLSXRelationshipsWriter()
        _ = relationships.add(type: XLSXRelationshipType.pivotCacheDefinition, target: "../pivotCache/pivotCacheDefinition\(cacheNumber).xml")
        parts.add("xl/pivotTables/_rels/pivotTable\(tableNumber).xml.rels", relationships.data())
        return ("../pivotTables/pivotTable\(tableNumber).xml", Cache(id: cacheNumber, target: "pivotCache/pivotCacheDefinition\(cacheNumber).xml"))
    }

    // MARK: - Source fields

    /// The source's columns as cache fields: unique names from the header row, and for the columns the
    /// pivot groups or filters by, their distinct values.
    static func fields(of sheet: Sheet, range: CellRange, axisColumns: Set<Int>) -> [Field] {
        var fields: [Field] = []
        var usedNames = Set<String>()
        for offset in 0..<range.columnCount {
            let column = range.start.column + offset
            let header = CellAddress(row: range.start.row, column: column)
            var name = CellDisplay.text(for: sheet.value(at: header), pattern: sheet.cells[header]?.format.numberFormat).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "Column \(CellAddress.columnName(column))" }
            var candidate = name
            var number = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(name) \(number)"
                number += 1
            }
            usedNames.insert(candidate.lowercased())
            var field = Field(name: candidate)
            let keepsItems = axisColumns.contains(offset)
            if range.rowCount > 1 {
                for row in (range.start.row + 1)...range.end.row {
                    let address = CellAddress(row: row, column: column)
                    let pattern = sheet.cells[address]?.format.numberFormat
                    let item = self.item(sheet.value(at: address), pattern: pattern)
                    note(item, in: &field)
                    if keepsItems, field.indexes[item] == nil {
                        field.indexes[item] = field.items.count
                        field.items.append(item)
                        field.shownTexts[item] = CellDisplay.text(for: sheet.value(at: address), pattern: pattern).text
                    }
                }
            }
            fields.append(field)
        }
        return fields
    }

    static func item(_ value: CellValue, pattern: String?) -> Item {
        switch value {
        case .empty: return .blank
        case .text(let text): return text.isEmpty ? .blank : .text(text)
        case .number(let number):
            guard number.isFinite else { return .error("#NUM!") }
            return XLSXNumberFormats.showsDate(pattern) ? .date(number) : .number(number)
        case .boolean(let flag): return .boolean(flag)
        case .error(let error): return .error(error.kind == .parse ? CellError.Kind.name.rawValue : error.code)
        }
    }

    private static func note(_ item: Item, in field: inout Field) {
        switch item {
        case .blank: field.hasBlank = true
        case .text(let text):
            field.hasText = true
            if text.count > 255 { field.hasLongText = true }
        case .number(let number):
            field.hasNumber = true
            if number != number.rounded() { field.allIntegers = false }
            field.minimum = min(field.minimum, number)
            field.maximum = max(field.maximum, number)
        case .date(let serial):
            field.hasDate = true
            field.minimumDate = min(field.minimumDate, serial)
            field.maximumDate = max(field.maximumDate, serial)
        case .boolean: field.hasBoolean = true
        case .error: field.hasError = true
        }
    }

    // MARK: - Cache definition

    private static func cacheDefinition(fields: [Field], source: CellRange, sheetName: String, recordCount: Int) -> Data {
        var xml = XMLWriter(reservingCapacity: 2048 + fields.reduce(0) { $0 + $1.items.count * 24 })
        // Without saved records Excel rebuilds the cache from the source when it opens the file.
        xml.raw("<pivotCacheDefinition xmlns=\"\(XLSXNamespace.main)\" xmlns:r=\"\(XLSXNamespace.relationships)\" "
            + "saveData=\"0\" refreshOnLoad=\"1\" createdVersion=\"6\" refreshedVersion=\"6\" minRefreshableVersion=\"3\" "
            + "recordCount=\"\(recordCount)\">")
        xml.raw("<cacheSource type=\"worksheet\"><worksheetSource ref=\"\(source.a1)\"")
        xml.attribute("sheet", sheetName)
        xml.raw("/></cacheSource>")
        xml.raw("<cacheFields count=\"\(fields.count)\">")
        for field in fields {
            xml.raw("<cacheField")
            xml.attribute("name", field.name)
            xml.raw(" numFmtId=\"\(field.hasDate && !field.hasNumber ? 14 : 0)\"><sharedItems")
            writeSharedItemsAttributes(field, into: &xml)
            guard !field.items.isEmpty else {
                xml.raw("/></cacheField>")
                continue
            }
            xml.raw(" count=\"\(field.items.count)\">")
            for item in field.items { writeItem(item, into: &xml) }
            xml.raw("</sharedItems></cacheField>")
        }
        xml.raw("</cacheFields></pivotCacheDefinition>")
        return xml.data
    }

    private static func writeSharedItemsAttributes(_ field: Field, into xml: inout XMLWriter) {
        let kinds = [field.hasText, field.hasNumber, field.hasDate, field.hasBoolean, field.hasError].filter { $0 }.count
        let textLike = field.hasText || field.hasBoolean || field.hasError
        if !textLike { xml.raw(" containsSemiMixedTypes=\"0\"") }
        if field.hasDate && !field.hasNumber && !textLike { xml.raw(" containsNonDate=\"0\"") }
        if field.hasDate { xml.raw(" containsDate=\"1\"") }
        if !field.hasText { xml.raw(" containsString=\"0\"") }
        if field.hasBlank { xml.raw(" containsBlank=\"1\"") }
        if kinds > 1 { xml.raw(" containsMixedTypes=\"1\"") }
        if field.hasNumber {
            xml.raw(" containsNumber=\"1\"")
            if field.allIntegers { xml.raw(" containsInteger=\"1\"") }
            xml.raw(" minValue=\"\(XLSXValue.string(field.minimum))\" maxValue=\"\(XLSXValue.string(field.maximum))\"")
        }
        if field.hasDate {
            xml.raw(" minDate=\"\(isoDate(field.minimumDate))\" maxDate=\"\(isoDate(field.maximumDate))\"")
        }
        if field.hasLongText { xml.raw(" longText=\"1\"") }
    }

    private static func writeItem(_ item: Item, into xml: inout XMLWriter) {
        switch item {
        case .blank:
            xml.raw("<m/>")
        case .text(let text):
            xml.raw("<s")
            xml.attribute("v", text)
            xml.raw("/>")
        case .number(let number):
            xml.raw("<n v=\"\(XLSXValue.string(number))\"/>")
        case .date(let serial):
            xml.raw("<d v=\"\(isoDate(serial))\"/>")
        case .boolean(let flag):
            xml.raw("<b v=\"\(flag ? 1 : 0)\"/>")
        case .error(let code):
            xml.raw("<e")
            xml.attribute("v", code)
            xml.raw("/>")
        }
    }

    /// A serial number as an xsd:dateTime ("2026-01-02T00:00:00").
    static func isoDate(_ serial: Double) -> String {
        let parts = DateSerial.parts(of: serial)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second)
    }

    // MARK: - Filters

    /// For each filtered source column, the indexes of its items the pivot leaves out.
    static func hiddenItems(_ pivot: PivotTable, fields: [Field], sourceSheet: Int, range: CellRange, workbook: Workbook) -> [Int: Set<Int>] {
        var result: [Int: Set<Int>] = [:]
        for filter in pivot.filters where filter.sourceColumn < fields.count {
            let field = fields[filter.sourceColumn]
            var hidden = Set<Int>()
            if !filter.criterion.hiddenValues.isEmpty {
                for (item, index) in field.indexes where filter.criterion.hiddenValues.contains(field.shownTexts[item] ?? "") {
                    hidden.insert(index)
                }
            }
            // A condition becomes the items no row passes with.
            if let condition = filter.criterion.condition, range.rowCount > 1 {
                let column = range.start.column + filter.sourceColumn
                let origin = CellAddress(row: range.start.row + 1, column: column)
                var passing = Set<Int>()
                let sheet = workbook.sheets[sourceSheet]
                for row in (range.start.row + 1)...range.end.row {
                    let address = CellAddress(row: row, column: column)
                    let item = self.item(sheet.value(at: address), pattern: sheet.cells[address]?.format.numberFormat)
                    guard let index = field.indexes[item], !passing.contains(index) else { continue }
                    if RuleEvaluator.test(condition, at: address, origin: origin, sheetIndex: sourceSheet, workbook: workbook) {
                        passing.insert(index)
                    }
                }
                hidden.formUnion(Set(field.items.indices).subtracting(passing))
            }
            if !hidden.isEmpty { result[filter.sourceColumn, default: []].formUnion(hidden) }
        }
        return result
    }

    // MARK: - Table definition

    /// Excel's function for a summary; COUNTUNIQUE and MEDIAN have none, so they become
    /// COUNTA and AVERAGE.
    static func subtotal(_ summary: PivotValue.Summary) -> String {
        switch summary {
        case .sum: "sum"
        case .countA, .countUnique: "count"
        case .count: "countNums"
        case .average, .median: "average"
        case .max: "max"
        case .min: "min"
        case .product: "product"
        case .stdev: "stdDev"
        case .stdevp: "stdDevp"
        case .variance: "var"
        case .variancep: "varp"
        }
    }

    /// The summary a heading names by default ("SUM", or "AVERAGE" for summaries Excel can't do).
    static func defaultHeadingWord(_ summary: PivotValue.Summary) -> String {
        switch summary {
        case .countUnique: PivotValue.Summary.countA.rawValue
        case .median: PivotValue.Summary.average.rawValue
        default: summary.rawValue
        }
    }

    static func showDataAs(_ showAs: PivotValue.ShowAs) -> String? {
        switch showAs {
        case .default: nil
        case .percentOfRow: "percentOfRow"
        case .percentOfColumn: "percentOfCol"
        case .percentOfGrandTotal: "percentOfTotal"
        }
    }

    private static func tableDefinition(_ pivot: PivotTable, name: String, cacheID: Int, fields: [Field], hidden: [Int: Set<Int>],
                                        location: CellRange) -> Data {
        let rowColumns = pivot.rows.map(\.sourceColumn)
        let columnColumns = pivot.columns.map(\.sourceColumn)
        let groups = Dictionary(pivot.rows.map { ($0.sourceColumn, $0) } + pivot.columns.map { ($0.sourceColumn, $0) },
                                uniquingKeysWith: { first, _ in first })
        // Filters on columns that aren't rows or columns become report filters (page fields).
        var pageColumns: [Int] = []
        for filter in pivot.filters where !groups.keys.contains(filter.sourceColumn) && !pageColumns.contains(filter.sourceColumn) {
            pageColumns.append(filter.sourceColumn)
        }
        let dataColumns = Set(pivot.values.map(\.sourceColumn))
        let multipleValues = pivot.values.count > 1

        var xml = XMLWriter(reservingCapacity: 4096)
        xml.raw("<pivotTableDefinition xmlns=\"\(XLSXNamespace.main)\"")
        xml.attribute("name", name)
        xml.raw(" cacheId=\"\(cacheID)\" applyNumberFormats=\"0\" applyBorderFormats=\"0\" applyFontFormats=\"0\" applyPatternFormats=\"0\" "
            + "applyAlignmentFormats=\"0\" applyWidthHeightFormats=\"1\" dataCaption=\"Values\" updatedVersion=\"6\" "
            + "minRefreshableVersion=\"3\" useAutoFormatting=\"1\" itemPrintTitles=\"1\" createdVersion=\"6\" indent=\"0\" "
            + "compact=\"0\" compactData=\"0\" outline=\"1\" outlineData=\"1\" gridDropZones=\"0\" multipleFieldFilters=\"0\"")
        if pivot.valuesInRows && multipleValues { xml.raw(" dataOnRows=\"1\"") }
        if let first = pivot.rows.first, !first.showsTotals { xml.raw(" rowGrandTotals=\"0\"") }
        if let first = pivot.columns.first, !first.showsTotals { xml.raw(" colGrandTotals=\"0\"") }
        xml.raw(">")

        let rowFieldCount = rowColumns.count + (pivot.valuesInRows && multipleValues ? 1 : 0)
        let columnFieldCount = columnColumns.count + (!pivot.valuesInRows && multipleValues ? 1 : 0)
        let firstDataColumn = min(max(rowFieldCount, 1), max(location.columnCount - 1, 0))
        let firstHeaderRow = min(1, max(location.rowCount - 1, 0))
        let firstDataRow = min(columnFieldCount > 0 ? 2 : 1, max(location.rowCount - 1, 0))
        xml.raw("<location ref=\"\(location.a1)\" firstHeaderRow=\"\(firstHeaderRow)\" firstDataRow=\"\(firstDataRow)\" "
            + "firstDataCol=\"\(firstDataColumn)\"")
        if !pageColumns.isEmpty { xml.raw(" rowPageCount=\"\(pageColumns.count)\" colPageCount=\"1\"") }
        xml.raw("/>")

        xml.raw("<pivotFields count=\"\(fields.count)\">")
        for (index, field) in fields.enumerated() {
            xml.raw("<pivotField")
            let axis: String? = rowColumns.contains(index) ? "axisRow" : columnColumns.contains(index) ? "axisCol"
                : pageColumns.contains(index) ? "axisPage" : nil
            if let axis { xml.raw(" axis=\"\(axis)\"") }
            if dataColumns.contains(index) { xml.raw(" dataField=\"1\"") }
            xml.raw(" compact=\"0\" outline=\"0\" showAll=\"0\"")
            guard axis != nil else {
                xml.raw("/>")
                continue
            }
            let group = groups[index]
            let ascending = group?.ascending ?? true
            if group != nil { xml.raw(" sortType=\"\(ascending ? "ascending" : "descending")\"") }
            let subtotals = group?.showsTotals ?? true
            if !subtotals { xml.raw(" defaultSubtotal=\"0\"") }
            let hiddenItems = hidden[index] ?? []
            if axis == "axisPage" && !hiddenItems.isEmpty { xml.raw(" multipleItemSelectionAllowed=\"1\"") }
            xml.raw(">")
            let order = sortedItemIndexes(field, ascending: ascending)
            xml.raw("<items count=\"\(order.count + (subtotals ? 1 : 0))\">")
            for itemIndex in order {
                xml.raw(hiddenItems.contains(itemIndex) ? "<item h=\"1\" x=\"\(itemIndex)\"/>" : "<item x=\"\(itemIndex)\"/>")
            }
            if subtotals { xml.raw("<item t=\"default\"/>") }
            xml.raw("</items>")
            if let sortValue = group?.sortByValue, pivot.values.indices.contains(sortValue) {
                xml.raw("<autoSortScope><pivotArea dataOnly=\"0\" outline=\"0\" fieldPosition=\"0\"><references count=\"1\">"
                    + "<reference field=\"4294967294\" count=\"1\" selected=\"0\"><x v=\"\(sortValue)\"/></reference>"
                    + "</references></pivotArea></autoSortScope>")
            }
            xml.raw("</pivotField>")
        }
        xml.raw("</pivotFields>")

        // The values are a field of their own (-2) among the rows or columns when there are several.
        var rowFields = rowColumns
        var columnFields = columnColumns
        if multipleValues {
            if pivot.valuesInRows { rowFields.append(-2) } else { columnFields.append(-2) }
        }
        if !rowFields.isEmpty {
            xml.raw("<rowFields count=\"\(rowFields.count)\">")
            for field in rowFields { xml.raw("<field x=\"\(field)\"/>") }
            xml.raw("</rowFields>")
        }
        if !columnFields.isEmpty {
            xml.raw("<colFields count=\"\(columnFields.count)\">")
            for field in columnFields { xml.raw("<field x=\"\(field)\"/>") }
            xml.raw("</colFields>")
        }
        if !pageColumns.isEmpty {
            xml.raw("<pageFields count=\"\(pageColumns.count)\">")
            for column in pageColumns { xml.raw("<pageField fld=\"\(column)\" hier=\"-1\"/>") }
            xml.raw("</pageFields>")
        }
        if !pivot.values.isEmpty {
            xml.raw("<dataFields count=\"\(pivot.values.count)\">")
            var usedNames = Set(fields.map { $0.name.lowercased() })
            for value in pivot.values {
                var heading = value.name ?? "\(defaultHeadingWord(value.summary)) of \(fields[value.sourceColumn].name)"
                // Excel needs headings unlike each other and the field names; it pads with spaces.
                while usedNames.contains(heading.lowercased()) { heading += " " }
                usedNames.insert(heading.lowercased())
                xml.raw("<dataField")
                xml.attribute("name", heading)
                xml.raw(" fld=\"\(value.sourceColumn)\" subtotal=\"\(subtotal(value.summary))\"")
                if let showAs = showDataAs(value.showAs) { xml.raw(" showDataAs=\"\(showAs)\"") }
                xml.raw(" baseField=\"0\" baseItem=\"0\"")
                if value.showAs != .default { xml.raw(" numFmtId=\"10\"") }
                xml.raw("/>")
            }
            xml.raw("</dataFields>")
        }
        xml.raw("<pivotTableStyleInfo name=\"PivotStyleLight16\" showRowHeaders=\"1\" showColHeaders=\"1\" showRowStripes=\"0\" "
            + "showColStripes=\"0\" showLastColumn=\"1\"/>")
        xml.raw("</pivotTableDefinition>")
        return xml.data
    }

    /// Item indexes in the order the group sorts them: blanks last, numbers and dates before text.
    static func sortedItemIndexes(_ field: Field, ascending: Bool) -> [Int] {
        func rank(_ item: Item) -> Int {
            switch item {
            case .number, .date: 0
            case .text: 1
            case .boolean: 2
            case .error: 3
            case .blank: 4
            }
        }
        func less(_ a: Item, _ b: Item) -> Bool {
            switch (a, b) {
            case (.number(let x), .number(let y)), (.date(let x), .date(let y)), (.number(let x), .date(let y)), (.date(let x), .number(let y)):
                return x < y
            case (.text(let x), .text(let y)):
                let order = x.compare(y, options: [.caseInsensitive, .numeric])
                return order == .orderedSame ? x < y : order == .orderedAscending
            case (.boolean(let x), .boolean(let y)):
                return !x && y
            case (.error(let x), .error(let y)):
                return x < y
            default:
                return false
            }
        }
        return field.items.indices.sorted { left, right in
            let a = field.items[left], b = field.items[right]
            if rank(a) != rank(b) {
                // Blanks stay last either way.
                if rank(a) == 4 || rank(b) == 4 { return rank(a) < rank(b) }
                return ascending ? rank(a) < rank(b) : rank(a) > rank(b)
            }
            if less(a, b) { return ascending }
            if less(b, a) { return !ascending }
            return left < right
        }
    }
}
