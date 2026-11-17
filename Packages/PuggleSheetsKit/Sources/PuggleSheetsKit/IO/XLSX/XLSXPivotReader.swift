import Foundation

/// Reads Excel pivot tables into pivot table specs. Their stored results are removed from the sheet
/// afterwards, so PuggleSheets computes them again.
enum XLSXPivotReader {
    struct Context {
        let sheetIndex: Int
        let sheets: [Sheet]
        /// Lowercased sheet names as the file writes them → index into `sheets`.
        let sheetIndexes: [String: Int]
        let namedRanges: [NamedRange]
        /// The workbook's caches: cacheId → cache definition part.
        let caches: [Int: String]
    }

    struct Result {
        var pivot: PivotTable?
        /// The cells holding the stored results (the table and its report filters), to clear.
        var cleared: [CellRange] = []
        var unsupported = false
    }

    /// The cached items of one field, as the file stores them.
    private enum Item {
        case blank
        case text(String)
        case number(Double)
        case date(String)
        case boolean(Bool)
        case error(String)
    }

    static func read(_ path: String, zip: ZipReader, context: Context) -> Result {
        var result = Result()
        guard let data = try? zip.read(path), let table = try? XMLTree.parse(data), table.name == "pivotTableDefinition",
              let locationNode = table.child("location"), let location = CellRange(a1: (locationNode["ref"] ?? "").replacingOccurrences(of: "$", with: "")),
              location.end.row < XLSXLimits.rows, location.end.column < XLSXLimits.columns else {
            result.unsupported = true
            return result
        }
        result.cleared.append(location)

        // The cache, through the table's own relationship or the workbook's list.
        let relationships = (try? XLSXPackage.relationships(of: path, in: zip)) ?? []
        let cachePath = relationships.first(where: { $0.hasType("pivotCacheDefinition") && !$0.isExternal })?.target
            ?? XLSXValue.int(table["cacheId"]).flatMap { context.caches[$0] }
        guard let cachePath, let cacheData = try? zip.read(cachePath), let cache = try? XMLTree.parse(cacheData),
              cache.name == "pivotCacheDefinition" else {
            result.unsupported = true
            return result
        }
        guard let source = self.source(cache, context: context) else {
            result.unsupported = true
            return result
        }
        let cacheFields = cache.child("cacheFields")?.children("cacheField") ?? []
        let fieldNames = cacheFields.map { $0["name"] ?? "" }
        let sharedItems = cacheFields.map { field in (field.child("sharedItems")?.children ?? []).map(item) }
        // Calculated fields and grouped fields have no counterpart; neither do OLAP caches.
        if cache.child("cacheHierarchies") != nil || cacheFields.contains(where: { $0["formula"] != nil || $0.child("fieldGroup") != nil }) {
            result.unsupported = true
            return result
        }
        if table.child("filters") != nil || table.child("calculatedItems") != nil { result.unsupported = true }

        let pivotFields = table.child("pivotFields")?.children("pivotField") ?? []
        func items(of field: Int) -> [(index: Int, hidden: Bool)] {
            guard pivotFields.indices.contains(field) else { return [] }
            return (pivotFields[field].child("items")?.children("item") ?? []).compactMap { item in
                guard item["t"] == nil || item["t"] == "data", let index = XLSXValue.int(item["x"]) else { return nil }
                return (index, XLSXValue.isTrue(item["h"]))
            }
        }
        func sortValue(of field: Int) -> Int? {
            guard pivotFields.indices.contains(field),
                  let reference = pivotFields[field].child("autoSortScope")?.firstDescendant("reference"),
                  reference["field"] == "4294967294" || reference["field"] == "-2" else { return nil }
            return XLSXValue.int(reference.child("x")?["v"])
        }
        func group(_ field: Int) -> PivotGroup {
            let node = pivotFields.indices.contains(field) ? pivotFields[field] : nil
            return PivotGroup(sourceColumn: field, ascending: node?["sortType"] != "descending",
                              showsTotals: XLSXValue.isOn(node?["defaultSubtotal"]), sortByValue: sortValue(of: field))
        }

        let fieldCount = max(fieldNames.count, source.range.columnCount)
        func isField(_ index: Int) -> Bool { index >= 0 && index < fieldCount }
        let rowFields = (table.child("rowFields")?.children("field") ?? []).compactMap { XLSXValue.int($0["x"]) }
        let columnFields = (table.child("colFields")?.children("field") ?? []).compactMap { XLSXValue.int($0["x"]) }
        var rows = rowFields.filter(isField).map(group)
        var columns = columnFields.filter(isField).map(group)
        // The outermost group's totals are the grand totals; the others' are subtotals.
        if !rows.isEmpty { rows[0].showsTotals = XLSXValue.isOn(table["rowGrandTotals"]) }
        if !columns.isEmpty { columns[0].showsTotals = XLSXValue.isOn(table["colGrandTotals"]) }

        var values: [PivotValue] = []
        for node in table.child("dataFields")?.children("dataField") ?? [] {
            guard let field = XLSXValue.int(node["fld"]), isField(field) else {
                result.unsupported = true
                continue
            }
            guard let summary = summary(node["subtotal"] ?? "sum") else {
                result.unsupported = true
                continue
            }
            let showAs = self.showAs(node["showDataAs"])
            if showAs == nil { result.unsupported = true }
            let fieldName = field < fieldNames.count ? fieldNames[field] : ""
            var name = node["name"]
            if let heading = name, isDefaultHeading(heading, summary: summary, subtotal: node["subtotal"] ?? "sum", field: fieldName) { name = nil }
            values.append(PivotValue(sourceColumn: field, summary: summary, showAs: showAs ?? .default, name: name))
        }

        // Hidden items become filters: on report filters, and on rows and columns.
        var filters: [PivotFilter] = []
        let sourceSheet = context.sheets[source.sheet]
        func shownText(field: Int, item: Int) -> String? {
            guard field < sharedItems.count, sharedItems[field].indices.contains(item) else { return nil }
            return text(of: sharedItems[field][item], column: source.range.start.column + field, range: source.range, sheet: sourceSheet)
        }
        func hiddenTexts(field: Int, keeping selected: Int? = nil) -> Set<String> {
            var hidden = Set<String>()
            let listed = items(of: field)
            if let selected {
                for item in listed where item.index != selected { if let text = shownText(field: field, item: item.index) { hidden.insert(text) } }
                // Items the table doesn't list (none, in a file Excel wrote) are hidden too.
                if listed.isEmpty, field < sharedItems.count {
                    for index in sharedItems[field].indices where index != selected {
                        if let text = shownText(field: field, item: index) { hidden.insert(text) }
                    }
                }
            } else {
                for item in listed where item.hidden { if let text = shownText(field: field, item: item.index) { hidden.insert(text) } }
            }
            return hidden
        }
        var pageColumns = Set<Int>()
        let pageFields = table.child("pageFields")?.children("pageField") ?? []
        // Excel shows report filters above the table, one per row with a blank row before the table:
        // the field's name, then its selection. Those cells go with the table.
        let pageTop = location.start.row - 1 - pageFields.count
        for (position, node) in pageFields.enumerated() {
            guard let field = XLSXValue.int(node["fld"]), isField(field) else { continue }
            let caption = CellAddress(row: pageTop + position, column: location.start.column)
            if caption.row >= 0, field < fieldNames.count,
               context.sheets[context.sheetIndex].value(at: caption) == .text(fieldNames[field]) {
                result.cleared.append(CellRange(rows: caption.row...caption.row,
                                                columns: caption.column...min(caption.column + 1, XLSXLimits.columns - 1)))
            }
            pageColumns.insert(field)
            let multiple = pivotFields.indices.contains(field) && XLSXValue.isTrue(pivotFields[field]["multipleItemSelectionAllowed"])
            let selected = multiple ? nil : XLSXValue.int(node["item"])
            filters.append(PivotFilter(sourceColumn: field, criterion: FilterCriterion(hiddenValues: hiddenTexts(field: field, keeping: selected))))
        }
        for field in rowFields + columnFields where isField(field) && !pageColumns.contains(field) {
            let hidden = hiddenTexts(field: field)
            if !hidden.isEmpty { filters.append(PivotFilter(sourceColumn: field, criterion: FilterCriterion(hiddenValues: hidden))) }
        }

        let sourceText: String = {
            if let name = source.name { return name }
            return SheetNames.quoted(context.sheets[source.sheet].name) + "!" + source.range.a1
        }()
        result.pivot = PivotTable(anchor: location.start, source: sourceText, rows: rows, columns: columns, values: values, filters: filters,
                                  valuesInRows: XLSXValue.isTrue(table["dataOnRows"]) && values.count > 1)
        return result
    }

    /// The cache's worksheet range (or the named range naming it).
    private static func source(_ cache: XNode, context: Context) -> (sheet: Int, range: CellRange, name: String?)? {
        guard let cacheSource = cache.child("cacheSource"), (cacheSource["type"] ?? "worksheet") == "worksheet",
              let worksheet = cacheSource.child("worksheetSource"), worksheet["id"] == nil else { return nil }
        if let reference = worksheet["ref"] {
            let sheet: Int
            if let name = worksheet["sheet"] {
                guard let index = context.sheetIndexes[name.lowercased()] else { return nil }
                sheet = index
            } else {
                sheet = context.sheetIndex
            }
            guard let range = CellRange(a1: reference.replacingOccurrences(of: "$", with: "")) else { return nil }
            return (sheet, range, nil)
        }
        // A defined name; Excel tables (also given by name) aren't kept.
        guard let name = worksheet["name"], let named = context.namedRanges.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        let workbook = Workbook(sheets: context.sheets, namedRanges: context.namedRanges)
        guard let resolved = workbook.resolve(named.reference, onSheet: context.sheetIndex) else { return nil }
        return (resolved.sheet, resolved.range, named.name)
    }

    private static func item(_ node: XNode) -> Item {
        switch node.name {
        case "s": .text(node["v"] ?? "")
        case "n": XLSXValue.double(node["v"]).map(Item.number) ?? .blank
        case "d": .date(node["v"] ?? "")
        case "b": .boolean(XLSXValue.isTrue(node["v"]))
        case "e": .error(node["v"] ?? "#N/A")
        default: .blank
        }
    }

    /// An item as the source shows it: the shown text of a cell holding that value.
    private static func text(of item: Item, column: Int, range: CellRange, sheet: Sheet) -> String {
        let target: CellValue
        switch item {
        case .blank: return ""
        case .text(let text): return text
        case .boolean(let flag): target = .boolean(flag)
        case .error(let code): return code
        case .number(let number): target = .number(number)
        case .date(let text):
            guard let date = XLSXWorksheetParser.serial(isoDate: text) else { return text }
            target = .number(date.serial)
        }
        if range.rowCount > 1 {
            for row in (range.start.row + 1)...range.end.row {
                let address = CellAddress(row: row, column: column)
                if sheet.value(at: address) == target {
                    return CellDisplay.text(for: target, pattern: sheet.cells[address]?.format.numberFormat).text
                }
            }
        }
        return CellDisplay.text(for: target, pattern: nil).text
    }

    private static func summary(_ subtotal: String) -> PivotValue.Summary? {
        switch subtotal {
        case "sum": .sum
        case "count": .countA
        case "countNums": .count
        case "average": .average
        case "max": .max
        case "min": .min
        case "product": .product
        case "stdDev": .stdev
        case "stdDevp": .stdevp
        case "var": .variance
        case "varp": .variancep
        default: nil
        }
    }

    /// Nil for "show as" choices PuggleSheets has none for (differences, running totals, index…).
    private static func showAs(_ value: String?) -> PivotValue.ShowAs? {
        switch value {
        case nil, "normal": .default
        case "percentOfRow": .percentOfRow
        case "percentOfCol": .percentOfColumn
        case "percentOfTotal": .percentOfGrandTotal
        default: nil
        }
    }

    /// A default heading, "SUM of Sales" or "Sum of Sales", with the spaces Excel pads names with.
    private static func isDefaultHeading(_ heading: String, summary: PivotValue.Summary, subtotal: String, field: String) -> Bool {
        let trimmed = heading.trimmingCharacters(in: .whitespaces).lowercased()
        let excelWord: String = switch subtotal {
        case "countNums": "count"
        case "stdDev": "stddev"
        case "stdDevp": "stddevp"
        default: subtotal.lowercased()
        }
        let field = field.lowercased()
        return trimmed == "\(summary.rawValue.lowercased()) of \(field)" || trimmed == "\(excelWord) of \(field)"
    }
}
