import Foundation

/// Pivot tables as LibreOffice's DataPilot tables (`table:data-pilot-tables`).
///
/// LibreOffice names a DataPilot field after its source column's heading ("Column C" for an empty
/// one; a repeated heading gets "2", "3", …). Its "count" counts every non-empty value (COUNTA) and
/// "countnums" counts numbers (COUNT). Its grand total for rows is the column of totals on the right,
/// shown in PuggleSheets by the first column group's totals; its grand total for columns is the row
/// of totals at the bottom, shown by the first row group's.
enum ODSPivotTables {
    // MARK: - Field names

    /// LibreOffice's names for the columns of a source range: the headings in its first row.
    static func fieldNames(sheet: Sheet, range: CellRange) -> [String] {
        var names: [String] = []
        var used = Set<String>()
        for column in range.columns {
            let address = CellAddress(row: range.start.row, column: column)
            var label: String
            switch sheet.value(at: address) {
            case .empty: label = ""
            case .text(let text): label = text
            case .number(let number): label = XLSXValue.string(number)
            case .boolean(let value): label = value ? "TRUE" : "FALSE"
            case .error(let error): label = error.code
            }
            if label.isEmpty { label = "Column " + CellAddress.columnName(column) }
            var candidate = label
            var suffix = 1
            while used.contains(candidate.lowercased()) {
                suffix += 1
                candidate = label + String(suffix)
            }
            used.insert(candidate.lowercased())
            names.append(candidate)
        }
        return names
    }

    private static func function(_ summary: PivotValue.Summary) -> String {
        switch summary {
        case .sum: "sum"
        case .countA: "count"
        case .count: "countnums"
        // LibreOffice can't count unique values; settings.xml keeps COUNTUNIQUE for PuggleSheets.
        case .countUnique: "count"
        case .average: "average"
        case .max: "max"
        case .min: "min"
        case .median: "median"
        case .product: "product"
        case .stdev: "stdev"
        case .stdevp: "stdevp"
        case .variance: "var"
        case .variancep: "varp"
        }
    }

    private static func summary(_ function: String?) -> PivotValue.Summary? {
        switch function {
        case "sum", "auto", nil: .sum
        case "count": .countA
        case "countnums": .count
        case "average": .average
        case "max": .max
        case "min": .min
        case "median": .median
        case "product": .product
        case "stdev": .stdev
        case "stdevp": .stdevp
        case "var": .variance
        case "varp": .variancep
        default: nil
        }
    }

    // MARK: - Writing

    /// `table:data-pilot-tables` for every sheet's pivot tables, and the settings PuggleSheets keeps
    /// for each.
    static func write(_ workbook: Workbook, names: [String], into xml: inout XMLWriter) -> [ODSPivotExtras] {
        var body = XMLWriter(fragmentCapacity: 1024)
        var extras: [ODSPivotExtras] = []
        for (sheetIndex, sheet) in workbook.sheets.enumerated() {
            for pivot in sheet.pivotTables {
                guard pivot.anchor.row >= 0, pivot.anchor.column >= 0, pivot.anchor.row < ODSWriter.maximumRows,
                      pivot.anchor.column < ODSWriter.maximumColumns,
                      let source = workbook.resolve(pivot.source, onSheet: sheetIndex) else { continue }
                let name = "Pivot table \(extras.count + 1)"
                var target = sheet.spillRanges[pivot.anchor] ?? CellRange(pivot.anchor)
                if target.start != pivot.anchor { target = CellRange(pivot.anchor) }
                target = CellRange(target.start, CellAddress(row: min(target.end.row, ODSWriter.maximumRows - 1),
                                                             column: min(target.end.column, ODSWriter.maximumColumns - 1)))
                let fingerprint = write(pivot, name: name, target: target, sheetName: names[sheetIndex], source: source, workbook: workbook,
                                        names: names, into: &body)
                extras.append(ODSPivotExtras(name: name, pivot: pivot, fingerprint: fingerprint))
            }
        }
        guard !body.isEmpty else { return [] }
        xml.raw("<table:data-pilot-tables>")
        xml.append(body)
        xml.raw("</table:data-pilot-tables>")
        return extras
    }

    /// The fingerprint a DataPilot table is recognized by: its name, place, source and fields.
    static func fingerprint(name: String, target: String, source: String, fields: [String]) -> String {
        ([name, target, source] + fields).joined(separator: "|")
    }

    private static func write(_ pivot: PivotTable, name: String, target: CellRange, sheetName: String, source: (sheet: Int, range: CellRange),
                              workbook: Workbook, names: [String], into xml: inout XMLWriter) -> String {
        let sourceSheet = workbook.sheets[source.sheet]
        let fieldNames = Self.fieldNames(sheet: sourceSheet, range: source.range)
        func fieldName(_ column: Int) -> String? { fieldNames.indices.contains(column) ? fieldNames[column] : nil }
        let dataRows = FilterValues.dataRows(of: source.range)
        func shownValues(_ column: Int) -> [String] {
            guard let dataRows else { return [] }
            return FilterValues.shown(in: sourceSheet, column: source.range.start.column + column, rows: dataRows)
        }

        let targetAddress = ODSFormula.address(sheet: sheetName, range: target)
        let sourceAddress = ODSFormula.address(sheet: names[source.sheet], range: source.range)
        xml.raw("<table:data-pilot-table")
        xml.attribute("table:name", name)
        xml.attribute("table:target-range-address", targetAddress)
        let rowGrand = pivot.columns.first?.showsTotals ?? true
        let columnGrand = pivot.rows.first?.showsTotals ?? true
        switch (rowGrand, columnGrand) {
        case (true, true): break
        case (true, false): xml.raw(" table:grand-total=\"row\"")
        case (false, true): xml.raw(" table:grand-total=\"column\"")
        case (false, false): xml.raw(" table:grand-total=\"none\"")
        }
        xml.raw(" table:show-filter-button=\"false\">")

        // The source, with the conditions of filters as its filter.
        xml.raw("<table:source-cell-range")
        let named = workbook.namedRange(pivot.source.trimmingCharacters(in: .whitespaces))
        if let named { xml.attribute("table:name", named.name) }
        xml.attribute("table:cell-range-address", sourceAddress)
        xml.raw(">")
        var conditions: [(field: Int, op: String, value: String, isNumber: Bool)] = []
        for filter in pivot.filters where fieldName(filter.sourceColumn) != nil {
            guard let condition = filter.criterion.condition else { continue }
            for part in ODSRules.filterConditions(condition) { conditions.append((filter.sourceColumn, part.op, part.value, part.isNumber)) }
        }
        if !conditions.isEmpty {
            xml.raw(conditions.count > 1 ? "<table:filter><table:filter-and>" : "<table:filter>")
            for condition in conditions {
                xml.raw("<table:filter-condition table:field-number=\"\(condition.field)\"")
                xml.attribute("table:value", condition.value)
                xml.attribute("table:operator", condition.op)
                xml.raw(" table:data-type=\"\(condition.isNumber ? "number" : "text")\"/>")
            }
            xml.raw(conditions.count > 1 ? "</table:filter-and></table:filter>" : "</table:filter>")
        }
        xml.raw("</table:source-cell-range>")

        // Values hidden by filters, by source column.
        var hidden: [Int: Set<String>] = [:]
        for filter in pivot.filters where !filter.criterion.hiddenValues.isEmpty && fieldName(filter.sourceColumn) != nil {
            hidden[filter.sourceColumn, default: []].formUnion(filter.criterion.hiddenValues)
        }
        var fieldList: [String] = []
        func members(_ column: Int, into xml: inout XMLWriter) {
            guard let values = hidden[column] else { return }
            let shown = shownValues(column)
            guard !shown.isEmpty else { return }
            xml.raw("<table:data-pilot-members>")
            for value in shown {
                xml.raw("<table:data-pilot-member")
                xml.attribute("table:name", value)
                xml.raw(" table:display=\"\(values.contains(value) ? "false" : "true")\" table:show-details=\"true\"/>")
            }
            xml.raw("</table:data-pilot-members>")
        }
        var membersWritten = Set<Int>()
        func group(_ group: PivotGroup, orientation: String, into xml: inout XMLWriter) {
            guard let field = fieldName(group.sourceColumn) else { return }
            fieldList.append("\(orientation):\(field)")
            xml.raw("<table:data-pilot-field")
            xml.attribute("table:source-field-name", field)
            xml.raw(" table:orientation=\"\(orientation)\" table:used-hierarchy=\"0\" table:function=\"auto\">")
            xml.raw("<table:data-pilot-level table:show-empty=\"false\">")
            xml.raw("<table:data-pilot-subtotals><table:data-pilot-subtotal table:function=\"\(group.showsTotals ? "auto" : "none")\"/></table:data-pilot-subtotals>")
            if membersWritten.insert(group.sourceColumn).inserted { members(group.sourceColumn, into: &xml) }
            xml.raw("<table:data-pilot-sort-info")
            if let index = group.sortByValue, pivot.values.indices.contains(index), let dataField = fieldName(pivot.values[index].sourceColumn) {
                xml.attribute("table:data-field", dataField)
                xml.raw(" table:sort-mode=\"data\"")
            } else {
                xml.raw(" table:sort-mode=\"name\"")
            }
            xml.raw(" table:order=\"\(group.ascending ? "ascending" : "descending")\"/>")
            xml.raw("<table:data-pilot-layout-info table:add-empty-lines=\"false\" table:layout-mode=\"tabular-layout\"/>")
            xml.raw("</table:data-pilot-level></table:data-pilot-field>")
        }
        for item in pivot.rows { group(item, orientation: "row", into: &xml) }
        for item in pivot.columns { group(item, orientation: "column", into: &xml) }
        let values = pivot.values.filter { fieldName($0.sourceColumn) != nil }
        if !values.isEmpty {
            // The "Data" field places the values in columns, or in rows.
            let orientation = pivot.valuesInRows ? "row" : "column"
            fieldList.append("\(orientation):")
            xml.raw("<table:data-pilot-field table:source-field-name=\"\" table:is-data-layout-field=\"true\" table:orientation=\"\(orientation)\""
                + " table:used-hierarchy=\"-1\" table:function=\"auto\"/>")
        }
        for value in values {
            guard let field = fieldName(value.sourceColumn) else { continue }
            fieldList.append("data:\(field):\(function(value.summary))")
            xml.raw("<table:data-pilot-field")
            xml.attribute("table:source-field-name", field)
            if let display = value.name, !display.isEmpty { xml.attribute("tableooo:display-name", display) }
            xml.raw(" table:orientation=\"data\" table:used-hierarchy=\"0\" table:function=\"\(function(value.summary))\">")
            let reference: String? = switch value.showAs {
            case .default: nil
            case .percentOfRow: "row-percentage"
            case .percentOfColumn: "column-percentage"
            case .percentOfGrandTotal: "total-percentage"
            }
            if let reference {
                xml.raw("<table:data-pilot-field-reference")
                xml.attribute("table:field-name", field)
                xml.raw(" table:member-type=\"named\" table:member-name=\"\" table:type=\"\(reference)\"/>")
            }
            xml.raw("</table:data-pilot-field>")
        }
        // Filters on columns that aren't groups are page fields, showing the values not hidden.
        for column in hidden.keys.sorted() where !membersWritten.contains(column) {
            guard let field = fieldName(column) else { continue }
            fieldList.append("page:\(field)")
            let shown = shownValues(column).filter { !(hidden[column]?.contains($0) ?? false) }
            xml.raw("<table:data-pilot-field")
            xml.attribute("table:source-field-name", field)
            xml.raw(" table:orientation=\"page\"")
            xml.attribute("table:selected-page", shown.first ?? "")
            xml.raw(" loext:ignore-selected-page=\"true\" table:used-hierarchy=\"0\" table:function=\"auto\">")
            xml.raw("<table:data-pilot-level table:show-empty=\"false\">")
            members(column, into: &xml)
            xml.raw("</table:data-pilot-level></table:data-pilot-field>")
        }
        xml.raw("</table:data-pilot-table>")
        return fingerprint(name: name, target: targetAddress, source: sourceAddress, fields: fieldList)
    }

    // MARK: - Reading

    /// Pivot tables from `table:data-pilot-tables`. The cells of each one's target range are removed, so
    /// PuggleSheets' engine places its results there.
    static func read(_ node: XNode?, workbook: inout Workbook, fileNames: [String], extras: [String: ODSPivotExtras],
                     warnings: inout Set<ImportWarning>) {
        guard let node else { return }
        func sheetIndex(_ name: String?) -> Int? {
            guard let name else { return nil }
            return fileNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame } ?? workbook.sheetIndex(named: name)
        }
        for table in node.children("data-pilot-table") {
            guard let targetText = table["target-range-address"], let target = ODSFormula.parseAddressList(targetText).first,
                  let sheet = sheetIndex(target.sheet), workbook.sheets.indices.contains(sheet) else {
                warnings.insert(.pivotTables)
                continue
            }
            guard let result = readTable(table, sheet: sheet, target: target.range, workbook: workbook, fileNames: fileNames, sheetIndex: sheetIndex) else {
                warnings.insert(.pivotTables)
                continue
            }
            var pivot = result.pivot
            let name = table["name"] ?? ""
            if let kept = extras[name], kept.fingerprint == result.fingerprint {
                pivot = kept.pivot
                pivot.anchor = target.range.start
            } else if result.unsupported {
                warnings.insert(.pivotTables)
            }
            workbook.sheets[sheet].removeCells(in: target.range)
            workbook.sheets[sheet].pivotTables.append(pivot)
        }
    }

    private struct Member {
        var name: String
        var shown: Bool
    }

    private static func readTable(_ table: XNode, sheet: Int, target: CellRange, workbook: Workbook, fileNames: [String],
                              sheetIndex: (String?) -> Int?) -> (pivot: PivotTable, fingerprint: String, unsupported: Bool)? {
        guard let sourceNode = table.child("source-cell-range") else { return nil }
        // The source: a named range, or a range.
        var sourceText: String?
        var sourceRange: (sheet: Int, range: CellRange)?
        if let name = sourceNode["name"], let named = workbook.namedRange(name), let resolved = workbook.resolve(named.name, onSheet: sheet) {
            sourceText = named.name
            sourceRange = resolved
        } else if let text = sourceNode["cell-range-address"], let address = ODSFormula.parseAddress(Substring(text)), let range = address.range,
                  let index = sheetIndex(address.sheet) ?? (address.sheet == nil ? sheet : nil), workbook.sheets.indices.contains(index) {
            sourceRange = (index, range)
            sourceText = index == sheet ? range.a1 : SheetNames.quoted(workbook.sheets[index].name) + "!" + range.a1
        }
        guard let sourceText, let source = sourceRange else { return nil }
        var unsupported = false
        let sourceSheet = workbook.sheets[source.sheet]
        let fieldNames = Self.fieldNames(sheet: sourceSheet, range: source.range)
        func column(_ name: String?) -> Int? {
            guard var name else { return nil }
            // LibreOffice marks a field used twice with "*".
            while name.hasSuffix("*"), !fieldNames.contains(name) { name.removeLast() }
            return fieldNames.firstIndex(of: name) ?? fieldNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let dataRows = FilterValues.dataRows(of: source.range)
        func shownValues(_ column: Int) -> [String] {
            guard let dataRows else { return [] }
            return FilterValues.shown(in: sourceSheet, column: source.range.start.column + column, rows: dataRows)
        }

        var rows: [PivotGroup] = [], columns: [PivotGroup] = [], values: [PivotValue] = []
        var rowSubtotals: [Bool] = [], columnSubtotals: [Bool] = []
        var hidden: [Int: Set<String>] = [:]
        var pageColumns: [Int] = []
        var valuesInRows = false
        var sortFields: [(orientation: String, index: Int, field: String)] = []
        var fieldList: [String] = []

        for field in table.children("data-pilot-field") {
            let orientation = field["orientation"] ?? "hidden"
            if XLSXValue.isTrue(field["is-data-layout-field"]) {
                valuesInRows = orientation == "row"
                if orientation == "row" || orientation == "column" { fieldList.append("\(orientation):") }
                continue
            }
            if field["formula"] != nil || field.child("data-pilot-groups") != nil {
                unsupported = true
                continue
            }
            guard orientation != "hidden" else { continue }
            guard let index = column(field["source-field-name"]) else {
                unsupported = true
                continue
            }
            let level = field.child("data-pilot-level")
            if XLSXValue.isTrue(level?["loext-repeat-item-labels"] ?? level?["repeat-item-labels"]) { unsupported = true }
            if XLSXValue.isTrue(level?.child("data-pilot-display-info")?["enabled"]) { unsupported = true }
            if let layout = level?.child("data-pilot-layout-info") {
                if XLSXValue.isTrue(layout["add-empty-lines"]) || (layout["layout-mode"] ?? "tabular-layout") != "tabular-layout"
                    || (layout["loext-layout-mode"] ?? "tabular-layout") != "tabular-layout" { unsupported = true }
            }
            var members: [Member] = []
            for member in level?.child("data-pilot-members")?.children("data-pilot-member") ?? [] {
                guard let name = member["name"] else { continue }
                members.append(Member(name: name, shown: member["display"] != "false"))
            }
            let hiddenMembers = Set(members.filter { !$0.shown }.map(\.name))
            switch orientation {
            case "row", "column":
                let sort = level?.child("data-pilot-sort-info")
                var group = PivotGroup(sourceColumn: index, ascending: sort?["order"] != "descending")
                switch sort?["sort-mode"] {
                case "data":
                    if let dataField = sort?["data-field"] {
                        sortFields.append((orientation, orientation == "row" ? rows.count : columns.count, dataField))
                    }
                case "manual", "none":
                    unsupported = true
                default:
                    break
                }
                // No subtotals element means automatic subtotals.
                let functions = level?.child("data-pilot-subtotals")?.children("data-pilot-subtotal").compactMap { $0["function"] }
                let subtotals = functions.map { !$0.isEmpty && !$0.allSatisfy { $0 == "none" } } ?? true
                if let functions, functions.contains(where: { $0 != "auto" && $0 != "none" }) { unsupported = true }
                group.showsTotals = subtotals
                if orientation == "row" {
                    rows.append(group)
                    rowSubtotals.append(subtotals)
                } else {
                    columns.append(group)
                    columnSubtotals.append(subtotals)
                }
                if !hiddenMembers.isEmpty { hidden[index, default: []].formUnion(hiddenMembers) }
                fieldList.append("\(orientation):\(fieldNames[index])")
            case "data":
                guard let summary = summary(field["function"]) else {
                    unsupported = true
                    continue
                }
                var value = PivotValue(sourceColumn: index, summary: summary)
                if let reference = field.child("data-pilot-field-reference") {
                    switch reference["type"] {
                    case "row-percentage": value.showAs = .percentOfRow
                    case "column-percentage": value.showAs = .percentOfColumn
                    case "total-percentage": value.showAs = .percentOfGrandTotal
                    case "none", nil: break
                    default: unsupported = true
                    }
                }
                if let display = field["display-name"], !display.isEmpty { value.name = display }
                values.append(value)
                fieldList.append("data:\(fieldNames[index]):\(field["function"] ?? "auto")")
            case "page":
                if !hiddenMembers.isEmpty {
                    hidden[index, default: []].formUnion(hiddenMembers)
                } else if field["loext-ignore-selected-page"] == nil, let selected = field["selected-page"], !selected.isEmpty {
                    // One value shown: the rest are hidden.
                    let others = shownValues(index).filter { $0 != selected }
                    if !others.isEmpty { hidden[index, default: []].formUnion(others) }
                }
                pageColumns.append(index)
                fieldList.append("page:\(fieldNames[index])")
            default:
                unsupported = true
            }
        }

        // Grand totals: the attribute, or LibreOffice's newer elements.
        var rowGrand = true, columnGrand = true
        switch table["grand-total"] {
        case "row": columnGrand = false
        case "column": rowGrand = false
        case "none":
            rowGrand = false
            columnGrand = false
        default: break
        }
        for total in table.children("data-pilot-grand-total") {
            let display = total["display"] != "false"
            switch total["orientation"] {
            case "row": rowGrand = display
            case "column": columnGrand = display
            case "both":
                rowGrand = display
                columnGrand = display
            default: break
            }
        }
        if !rows.isEmpty {
            if rows.count > 1, rowSubtotals[0] != columnGrand { unsupported = true }
            rows[0].showsTotals = columnGrand
        }
        if !columns.isEmpty {
            if columns.count > 1, columnSubtotals[0] != rowGrand { unsupported = true }
            columns[0].showsTotals = rowGrand
        }
        for item in sortFields {
            var name = item.field
            while name.hasSuffix("*"), !fieldNames.contains(name) { name.removeLast() }
            guard let position = values.firstIndex(where: { fieldNames[$0.sourceColumn] == name }) else {
                unsupported = true
                continue
            }
            if item.orientation == "row" { rows[item.index].sortByValue = position } else { columns[item.index].sortByValue = position }
        }

        // Filters: hidden values, and the source's filter.
        var filters: [PivotFilter] = []
        var filterColumns = pageColumns
        for column in hidden.keys.sorted() where !filterColumns.contains(column) { filterColumns.append(column) }
        var conditions: [Int: FilterCriterion] = [:]
        if let filter = sourceNode.child("filter") {
            let result = ODSRules.filterCriteria(filter, range: source.range, sheet: sourceSheet)
            if result.unsupported { unsupported = true }
            for (sheetColumn, criterion) in result.criteria { conditions[sheetColumn - source.range.start.column] = criterion }
        }
        for column in conditions.keys.sorted() where !filterColumns.contains(column) { filterColumns.append(column) }
        for column in filterColumns {
            var criterion = conditions[column] ?? FilterCriterion()
            criterion.hiddenValues.formUnion(hidden[column] ?? [])
            filters.append(PivotFilter(sourceColumn: column, criterion: criterion))
        }

        let pivot = PivotTable(anchor: target.start, source: sourceText, rows: rows, columns: columns, values: values, filters: filters,
                               valuesInRows: valuesInRows)
        let targetText = ODSFormula.address(sheet: fileNames.indices.contains(sheet) ? fileNames[sheet] : workbook.sheets[sheet].name, range: target)
        let sourceAddress = ODSFormula.address(sheet: fileNames.indices.contains(source.sheet) ? fileNames[source.sheet] : sourceSheet.name,
                                               range: source.range)
        let fingerprint = fingerprint(name: table["name"] ?? "", target: targetText, source: sourceAddress, fields: fieldList)
        return (pivot, fingerprint, unsupported)
    }
}
