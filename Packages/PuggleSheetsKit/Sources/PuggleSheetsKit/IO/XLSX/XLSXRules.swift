import Foundation

/// Excel's rules: named ranges (`<definedNames>`), data validation (`<dataValidations>`), conditional
/// formatting (`<conditionalFormatting>` with `<dxfs>` in styles.xml) and filters (`<autoFilter>`).
enum XLSXRules {
    static let syntax = RuleFormulaSyntax(export: { XLSXFormula.exporting($0) }, import: { XLSXFormula.importing($0) })

    typealias SheetSize = (String?) -> (rows: Int, columns: Int)

    // MARK: - Ranges

    /// "A1:B2 C3" → the ranges inside Excel's grid.
    static func ranges(_ sqref: String?) -> [CellRange] {
        (sqref ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { part in
            guard let range = CellRange(a1: part), range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns else { return nil }
            return range
        }
    }

    /// Ranges clipped to Excel's grid, as `sqref` writes them.
    static func clipped(_ ranges: [CellRange]) -> [CellRange] {
        let grid = CellRange(rows: 0...(XLSXLimits.rows - 1), columns: 0...(XLSXLimits.columns - 1))
        return ranges.compactMap { $0.intersection(grid) }
    }

    static func sqref(_ ranges: [CellRange]) -> String {
        ranges.map(\.a1).joined(separator: " ")
    }

    /// The condition for an Excel comparison operator (`cellIs`, data validation).
    static func conditionKind(_ excelOperator: String, isDate: Bool) -> CellCondition.Kind? {
        switch excelOperator {
        case "between": isDate ? .dateIsBetween : .isBetween
        case "notBetween": isDate ? .dateIsNotBetween : .isNotBetween
        case "equal": isDate ? .dateIs : .isEqual
        case "notEqual": .isNotEqual
        case "lessThan": isDate ? .dateIsBefore : .lessThan
        case "lessThanOrEqual": isDate ? .dateIsOnOrBefore : .lessThanOrEqual
        case "greaterThan": isDate ? .dateIsAfter : .greaterThan
        case "greaterThanOrEqual": isDate ? .dateIsOnOrAfter : .greaterThanOrEqual
        default: nil
        }
    }

    /// The Excel operator for a comparison condition.
    static func excelOperator(_ kind: CellCondition.Kind) -> String? {
        switch kind {
        case .greaterThan, .dateIsAfter: "greaterThan"
        case .greaterThanOrEqual, .dateIsOnOrAfter: "greaterThanOrEqual"
        case .lessThan, .dateIsBefore: "lessThan"
        case .lessThanOrEqual, .dateIsOnOrBefore: "lessThanOrEqual"
        case .isEqual, .dateIs: "equal"
        case .isNotEqual: "notEqual"
        case .isBetween, .dateIsBetween: "between"
        case .isNotBetween, .dateIsNotBetween: "notBetween"
        default: nil
        }
    }

    /// The comparison's values as Excel expressions; nil when one can't be compared directly (a relative
    /// span such as "past month", or text where a number is needed).
    private static func comparisonExpressions(_ condition: CellCondition, numbersOnly: Bool, size: SheetSize) -> [String]? {
        let isDate = RuleFormulas.isDateKind(condition.kind)
        let count = max(condition.kind.valueCount, 1)
        guard condition.values.count >= count else { return nil }
        var result: [String] = []
        for value in condition.values.prefix(count) {
            if isDate, ["past week", "past month", "past year"].contains(value.trimmingCharacters(in: .whitespaces).lowercased()),
               condition.kind == .dateIs {
                return nil
            }
            if numbersOnly, !value.hasPrefix("="), !(isDate && RuleValues.relativeDateFormula(value) != nil),
               InputParser.parse(value, currentFormat: nil).value.numberValue == nil {
                return nil
            }
            guard let expression = XLSXFormula.exporting("=" + RuleValues.operand(value, isDate: isDate), size: size) else { return nil }
            result.append(expression)
        }
        return result
    }

    // MARK: - Named ranges

    /// Names from `<definedNames>`. Built-in names (`_xlnm.`), placeholders for newer functions, hidden
    /// names and `ignored` ones (lowercased: slicer caches' names) are skipped; sheet-scoped names become
    /// workbook names. `unsupported` when a name isn't a plain reference (constants, formulas, several
    /// areas) or clashes with another.
    static func namedRanges(_ nodes: [XNode], sheetNames: [String], ignoring ignored: Set<String> = []) -> (ranges: [NamedRange], unsupported: Bool) {
        var result: [NamedRange] = []
        var seen = Set<String>()
        var unsupported = false
        for node in nodes {
            let name = node["name"] ?? ""
            if name.hasPrefix("_xlnm.") || name.hasPrefix("_xlfn.") || XLSXValue.isTrue(node["hidden"]) || ignored.contains(name.lowercased()) { continue }
            var reference = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if reference.hasPrefix("=") { reference.removeFirst() }
            if let local = XLSXValue.int(node["localSheetId"]), sheetNames.indices.contains(local), !reference.contains("!"),
               isReference(reference) {
                reference = SheetNames.quoted(sheetNames[local]) + "!" + reference
            }
            guard NamedRange.isValidName(name), isReference(reference), seen.insert(name.lowercased()).inserted else {
                unsupported = true
                continue
            }
            result.append(NamedRange(name: name, reference: reference))
        }
        return (result, unsupported)
    }

    /// True for a single reference, optionally on a sheet: "Sheet1!$A$1:$B$5", "'Q1 2026'!A:A", "$3:$4".
    static func isReference(_ text: String) -> Bool {
        let tokens = XLSXFormulaToken.tokenize(text.trimmingCharacters(in: .whitespaces)).filter { !($0.kind == .symbol && $0.text == " ") }
        var index = 0
        if tokens.count >= 2, tokens[1].isSymbol("!"), tokens[0].kind == .word || tokens[0].kind == .quoted { index = 2 }
        guard index < tokens.count, tokens[index].kind == .word, let first = XLSXReferencePart(tokens[index].text) else { return false }
        if index + 1 == tokens.count { return first.kind == .cell }
        guard index + 3 == tokens.count, tokens[index + 1].isSymbol(":"), tokens[index + 2].kind == .word,
              let second = XLSXReferencePart(tokens[index + 2].text) else { return false }
        return first.kind == second.kind || (first.kind == .cell && second.kind == .cell)
    }

    /// `<definedNames>` for named ranges and each filter's `_xlnm._FilterDatabase`.
    static func writeDefinedNames(_ names: [NamedRange], filters: [(sheet: Int, name: String, range: CellRange)], slicerCaches: [String] = [],
                                  size: SheetSize, into xml: inout XMLWriter) {
        var entries: [(name: String, sheet: Int?, hidden: Bool, value: String)] = []
        var seen = Set<String>()
        for named in names where NamedRange.isValidName(named.name) && seen.insert(named.name.lowercased()).inserted {
            guard let value = XLSXFormula.exporting("=" + named.reference, size: size) else { continue }
            entries.append((named.name, nil, false, value))
        }
        for filter in filters {
            entries.append(("_xlnm._FilterDatabase", filter.sheet, true, SheetNames.quoted(filter.name) + "!" + filter.range.absoluteA1))
        }
        // Excel names each slicer cache, standing for nothing.
        for cache in slicerCaches { entries.append((cache, nil, false, "#N/A")) }
        guard !entries.isEmpty else { return }
        xml.raw("<definedNames>")
        for entry in entries {
            xml.raw("<definedName")
            xml.attribute("name", entry.name)
            if let sheet = entry.sheet { xml.attribute("localSheetId", sheet) }
            if entry.hidden { xml.raw(" hidden=\"1\"") }
            xml.raw(">")
            xml.text(entry.value)
            xml.raw("</definedName>")
        }
        xml.raw("</definedNames>")
    }

    // MARK: - Data validation

    /// Rules from `<dataValidations>` and from Excel 2010's extension list (`x14:dataValidations`, whose
    /// formulas and ranges sit in `xm:f` and `xm:sqref`). `unsupported` when one couldn't be kept.
    static func validations(_ nodes: [XNode]) -> (rules: [DataValidationRule], unsupported: Bool) {
        var rules: [DataValidationRule] = []
        var unsupported = false
        for node in nodes {
            for item in node.children("dataValidation") {
                let formula1 = item.child("formula1").map { $0.child("f")?.text ?? $0.text }
                let formula2 = item.child("formula2").map { $0.child("f")?.text ?? $0.text }
                let sqref = item["sqref"] ?? item.child("sqref")?.text
                if let rule = validation(item, sqref: sqref, formula1: formula1, formula2: formula2) {
                    rules.append(rule)
                } else if let type = item["type"], type != "none" {
                    unsupported = true
                }
            }
        }
        return (rules, unsupported)
    }

    private static func validation(_ node: XNode, sqref: String?, formula1: String?, formula2: String?) -> DataValidationRule? {
        let ranges = ranges(sqref)
        guard let origin = ranges.first?.start else { return nil }
        let first = formula1?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let second = formula2?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let criterion: DataValidationRule.Criterion
        switch node["type"] {
        case "list":
            guard !first.isEmpty else { return nil }
            if let items = RuleValues.unquoted(first) {
                criterion = RuleValues.listCriterion(items.isEmpty ? [] : items.components(separatedBy: ","))
            } else {
                criterion = .listFromRange(String(XLSXFormula.importing(first).dropFirst()))
            }
        case "whole", "decimal", "date", "time":
            let isDate = node["type"] == "date"
            guard let kind = conditionKind(node["operator"] ?? "between", isDate: isDate), !first.isEmpty else { return nil }
            var values = [RuleValues.value(fromExpression: first, isDate: isDate, syntax: syntax)]
            if kind.valueCount == 2 {
                guard !second.isEmpty else { return nil }
                values.append(RuleValues.value(fromExpression: second, isDate: isDate, syntax: syntax))
            }
            criterion = .condition(CellCondition(kind, values))
        case "textLength":
            guard let formula = comparisonFormula(subject: "LEN(\(origin.a1))", excelOperator: node["operator"] ?? "between", first, second)
            else { return nil }
            criterion = .condition(CellCondition(.customFormula, [formula]))
        case "custom":
            guard !first.isEmpty else { return nil }
            criterion = .condition(CellCondition(.customFormula, [XLSXFormula.importing(first)]))
        default:
            return nil
        }
        let rejects = XLSXValue.isTrue(node["showErrorMessage"]) && (node["errorStyle"] ?? "stop") == "stop"
        var help: String?
        if XLSXValue.isTrue(node["showInputMessage"]), let prompt = node["prompt"], !prompt.isEmpty { help = prompt }
        // showDropDown="1" hides the dropdown arrow.
        return DataValidationRule(ranges: ranges, criterion: criterion, rejectsInvalid: rejects, helpText: help,
                                  showsDropdown: !XLSXValue.isTrue(node["showDropDown"]))
    }

    /// One of our formulas comparing `subject` with Excel expressions.
    private static func comparisonFormula(subject: String, excelOperator: String, _ first: String, _ second: String) -> String? {
        func operand(_ expression: String) -> String? {
            expression.isEmpty ? nil : String(XLSXFormula.importing(expression).dropFirst())
        }
        guard let a = operand(first) else { return nil }
        switch excelOperator {
        case "between":
            guard let b = operand(second) else { return nil }
            return "=AND(\(subject)>=\(a),\(subject)<=\(b))"
        case "notBetween":
            guard let b = operand(second) else { return nil }
            return "=OR(\(subject)<\(a),\(subject)>\(b))"
        case "equal": return "=\(subject)=\(a)"
        case "notEqual": return "=\(subject)<>\(a)"
        case "lessThan": return "=\(subject)<\(a)"
        case "lessThanOrEqual": return "=\(subject)<=\(a)"
        case "greaterThan": return "=\(subject)>\(a)"
        case "greaterThanOrEqual": return "=\(subject)>=\(a)"
        default: return nil
        }
    }

    /// `<dataValidations>`, with the rules Excel can hold.
    static func writeValidations(_ rules: [DataValidationRule], size: SheetSize, into xml: inout XMLWriter) {
        var items = XMLWriter(fragmentCapacity: 256)
        var count = 0
        for rule in rules {
            let ranges = clipped(rule.ranges)
            guard let origin = ranges.first?.start, let shape = validationShape(rule.criterion, origin: origin, size: size) else { continue }
            items.raw("<dataValidation type=\"\(shape.type)\"")
            if let op = shape.excelOperator { items.raw(" operator=\"\(op)\"") }
            items.raw(" allowBlank=\"1\"")
            if shape.type == "list", !rule.showsDropdown { items.raw(" showDropDown=\"1\"") }
            if let help = rule.helpText, !help.isEmpty {
                items.raw(" showInputMessage=\"1\"")
                items.attribute("prompt", String(help.prefix(255)))
            }
            items.raw(" showErrorMessage=\"1\"")
            if !rule.rejectsInvalid { items.raw(" errorStyle=\"warning\"") }
            items.raw(" sqref=\"\(sqref(ranges))\">")
            for (index, formula) in shape.formulas.enumerated() {
                items.raw("<formula\(index + 1)>")
                items.text(formula)
                items.raw("</formula\(index + 1)>")
            }
            items.raw("</dataValidation>")
            count += 1
        }
        guard count > 0 else { return }
        xml.raw("<dataValidations count=\"\(count)\">")
        xml.append(items)
        xml.raw("</dataValidations>")
    }

    private static func validationShape(_ criterion: DataValidationRule.Criterion, origin: CellAddress,
                                        size: SheetSize) -> (type: String, excelOperator: String?, formulas: [String])? {
        switch criterion {
        case .list(let items):
            // Excel holds at most 255 characters in an inline list, and can't tell commas inside items apart.
            let joined = items.joined(separator: ",")
            guard !items.isEmpty, joined.utf16.count <= 255 else { return nil }
            return ("list", nil, [RuleValues.quoted(joined)])
        case .listFromRange(let reference):
            guard let formula = XLSXFormula.exporting("=" + reference, size: size) else { return nil }
            return ("list", nil, [formula])
        case .checkbox(let checked, let unchecked):
            return ("list", nil, [RuleValues.quoted("\(checked ?? "TRUE"),\(unchecked ?? "FALSE")")])
        case .condition(let condition):
            if condition.kind == .dateIsValid { return ("date", "greaterThan", ["0"]) }
            if let op = excelOperator(condition.kind), let expressions = comparisonExpressions(condition, numbersOnly: true, size: size) {
                return (RuleFormulas.isDateKind(condition.kind) ? "date" : "decimal", op, expressions)
            }
            guard let formula = XLSXFormula.exporting(RuleFormulas.formula(for: condition, cell: origin.a1), size: size) else { return nil }
            return ("custom", nil, [formula])
        }
    }

    // MARK: - Conditional formatting

    /// Rules from `<conditionalFormatting>` blocks, in priority order. `unsupported` for rule types
    /// PuggleSheets doesn't have (data bars, icon sets, top 10, duplicates, averages…).
    static func conditionalFormats(_ blocks: [XNode], styles: XLSXStyleSheet) -> (rules: [ConditionalFormatRule], unsupported: Bool) {
        var collected: [(priority: Int, order: Int, rule: ConditionalFormatRule)] = []
        var unsupported = false
        for block in blocks {
            let ranges = ranges(block["sqref"])
            for node in block.children("cfRule") {
                guard let origin = ranges.first?.start, let style = conditionalStyle(node, origin: origin, styles: styles) else {
                    unsupported = true
                    continue
                }
                collected.append((XLSXValue.int(node["priority"]) ?? Int.max, collected.count, ConditionalFormatRule(ranges: ranges, style: style)))
            }
        }
        collected.sort { $0.priority != $1.priority ? $0.priority < $1.priority : $0.order < $1.order }
        return (collected.map(\.rule), unsupported)
    }

    private static func conditionalStyle(_ node: XNode, origin: CellAddress, styles: XLSXStyleSheet) -> ConditionalFormatRule.Style? {
        if node["type"] == "colorScale" {
            return colorScale(node.child("colorScale"), palette: styles.palette).map { .colorScale($0) }
        }
        let formulas = node.children("formula").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let condition = condition(of: node, formulas: formulas) else { return nil }
        var format = ConditionalFormat()
        if let id = XLSXValue.int(node["dxfId"]), styles.differentialFormats.indices.contains(id) { format = styles.differentialFormats[id] }
        return .condition(condition, format)
    }

    private static func condition(of node: XNode, formulas: [String]) -> CellCondition? {
        let text = node["text"]
        // Rules whose meaning lives in their formula fall back to it.
        let fallback = formulas.first.map { CellCondition(.customFormula, [XLSXFormula.importing($0)]) }
        switch node["type"] {
        case "cellIs":
            guard let op = node["operator"], let first = formulas.first else { return nil }
            if op == "equal", let literal = RuleValues.unquoted(first) { return CellCondition(.textIsExactly, [literal]) }
            guard let kind = conditionKind(op, isDate: false) else { return nil }
            var values = [RuleValues.value(fromExpression: first, isDate: false, syntax: syntax)]
            if kind.valueCount == 2 {
                guard formulas.count > 1 else { return nil }
                values.append(RuleValues.value(fromExpression: formulas[1], isDate: false, syntax: syntax))
            }
            return CellCondition(kind, values)
        case "containsText": return text.map { CellCondition(.textContains, [$0]) } ?? fallback
        case "notContainsText": return text.map { CellCondition(.textDoesNotContain, [$0]) } ?? fallback
        case "beginsWith": return text.map { CellCondition(.textStartsWith, [$0]) } ?? fallback
        case "endsWith": return text.map { CellCondition(.textEndsWith, [$0]) } ?? fallback
        case "containsBlanks": return CellCondition(.isEmpty)
        case "notContainsBlanks": return CellCondition(.isNotEmpty)
        case "expression": return fallback
        case "timePeriod":
            switch node["timePeriod"] {
            case "today": return CellCondition(.dateIs, ["today"])
            case "yesterday": return CellCondition(.dateIs, ["yesterday"])
            case "tomorrow": return CellCondition(.dateIs, ["tomorrow"])
            case "last7Days": return CellCondition(.dateIs, ["past week"])
            default: return fallback
            }
        case "containsErrors", "notContainsErrors": return fallback
        default: return nil
        }
    }

    private static func colorScale(_ node: XNode?, palette: XLSXColorPalette) -> ColorScale? {
        guard let node else { return nil }
        let thresholds = node.children("cfvo")
        let colors = node.children("color").map { palette.color($0) }
        guard thresholds.count == 2 || thresholds.count == 3, colors.count == thresholds.count else { return nil }
        var points: [ColorScale.Point] = []
        for (threshold, color) in zip(thresholds, colors) {
            guard let color else { return nil }
            let kind: ColorScale.PointKind
            switch threshold["type"] {
            case "min": kind = .minimum
            case "max": kind = .maximum
            case "num": kind = .number
            case "percent": kind = .percent
            case "percentile": kind = .percentile
            default: return nil
            }
            let value = kind == .minimum || kind == .maximum ? nil : (threshold["val"] ?? "0")
            points.append(ColorScale.Point(kind: kind, value: value, color: color))
        }
        return ColorScale(minimum: points[0], midpoint: points.count == 3 ? points[1] : nil, maximum: points[points.count - 1])
    }

    /// `<conditionalFormatting>` blocks, one per rule, in priority order.
    static func writeConditionalFormats(_ rules: [ConditionalFormatRule], styles: inout XLSXStyleWriter, size: SheetSize,
                                        into xml: inout XMLWriter) {
        var priority = 0
        for rule in rules {
            let ranges = clipped(rule.ranges)
            guard let origin = ranges.first?.start else { continue }
            switch rule.style {
            case .colorScale(let scale):
                priority += 1
                xml.raw("<conditionalFormatting sqref=\"\(sqref(ranges))\"><cfRule type=\"colorScale\" priority=\"\(priority)\"><colorScale>")
                let points = [scale.minimum] + (scale.midpoint.map { [$0] } ?? []) + [scale.maximum]
                for point in points {
                    switch point.kind {
                    case .minimum: xml.raw("<cfvo type=\"min\"/>")
                    case .maximum: xml.raw("<cfvo type=\"max\"/>")
                    case .number, .percent, .percentile:
                        let value = point.value ?? "0"
                        if value.hasPrefix("="), let formula = XLSXFormula.exporting(value, size: size) {
                            xml.raw("<cfvo type=\"formula\"")
                            xml.attribute("val", formula)
                        } else {
                            let type = point.kind == .number ? "num" : point.kind == .percent ? "percent" : "percentile"
                            xml.raw("<cfvo type=\"\(type)\"")
                            xml.attribute("val", value)
                        }
                        xml.raw("/>")
                    }
                }
                for point in points { xml.raw("<color rgb=\"FF\(point.color.hex)\"/>") }
                xml.raw("</colorScale></cfRule></conditionalFormatting>")
            case .condition(let condition, let format):
                guard let shape = ruleShape(condition, origin: origin, size: size) else { continue }
                priority += 1
                xml.raw("<conditionalFormatting sqref=\"\(sqref(ranges))\"><cfRule type=\"\(shape.type)\"")
                if !format.isEmpty { xml.raw(" dxfId=\"\(styles.differentialFormatIndex(for: format))\"") }
                xml.raw(" priority=\"\(priority)\"")
                if let op = shape.excelOperator { xml.raw(" operator=\"\(op)\"") }
                if let text = shape.text { xml.attribute("text", text) }
                if let period = shape.timePeriod { xml.raw(" timePeriod=\"\(period)\"") }
                xml.raw(">")
                for formula in shape.formulas {
                    xml.raw("<formula>")
                    xml.text(formula)
                    xml.raw("</formula>")
                }
                xml.raw("</cfRule></conditionalFormatting>")
            }
        }
    }

    private struct RuleShape {
        var type: String
        var excelOperator: String?
        var text: String?
        var timePeriod: String?
        var formulas: [String]
    }

    private static func ruleShape(_ condition: CellCondition, origin: CellAddress, size: SheetSize) -> RuleShape? {
        let cell = origin.a1
        let literal = condition.values.first.flatMap { $0.hasPrefix("=") ? nil : $0 }
        let quoted = literal.map(RuleValues.quoted) ?? ""
        switch condition.kind {
        case .isEmpty:
            return RuleShape(type: "containsBlanks", formulas: ["LEN(TRIM(\(cell)))=0"])
        case .isNotEmpty:
            return RuleShape(type: "notContainsBlanks", formulas: ["LEN(TRIM(\(cell)))>0"])
        case .textContains where literal != nil:
            return RuleShape(type: "containsText", excelOperator: "containsText", text: literal,
                             formulas: ["NOT(ISERROR(SEARCH(\(quoted),\(cell))))"])
        case .textDoesNotContain where literal != nil:
            return RuleShape(type: "notContainsText", excelOperator: "notContains", text: literal,
                             formulas: ["ISERROR(SEARCH(\(quoted),\(cell)))"])
        case .textStartsWith where literal != nil:
            return RuleShape(type: "beginsWith", excelOperator: "beginsWith", text: literal, formulas: ["LEFT(\(cell),LEN(\(quoted)))=\(quoted)"])
        case .textEndsWith where literal != nil:
            return RuleShape(type: "endsWith", excelOperator: "endsWith", text: literal, formulas: ["RIGHT(\(cell),LEN(\(quoted)))=\(quoted)"])
        case .textIsExactly where literal != nil:
            return RuleShape(type: "cellIs", excelOperator: "equal", formulas: [quoted])
        case .dateIs:
            let periods = ["today": ("today", "FLOOR(\(cell),1)=TODAY()"), "yesterday": ("yesterday", "FLOOR(\(cell),1)=TODAY()-1"),
                           "tomorrow": ("tomorrow", "FLOOR(\(cell),1)=TODAY()+1"),
                           "past week": ("last7Days", "AND(TODAY()-FLOOR(\(cell),1)<=6,FLOOR(\(cell),1)<=TODAY())")]
            if let name = condition.values.first?.trimmingCharacters(in: .whitespaces).lowercased(), let period = periods[name] {
                return RuleShape(type: "timePeriod", timePeriod: period.0, formulas: [period.1])
            }
        default:
            break
        }
        if let op = excelOperator(condition.kind), let expressions = comparisonExpressions(condition, numbersOnly: false, size: size) {
            return RuleShape(type: "cellIs", excelOperator: op, formulas: expressions)
        }
        guard let formula = XLSXFormula.exporting(RuleFormulas.formula(for: condition, cell: cell), size: size) else { return nil }
        return RuleShape(type: "expression", formulas: [formula])
    }

    // MARK: - Filters

    /// The sheet's filter from `<autoFilter>`. Value lists name the values shown; PuggleSheets keeps the
    /// values hidden, found from the cells. `unsupported` for criteria it can't express (top 10, dynamic
    /// dates, colors, date groups, odd custom pairs).
    static func filter(_ node: XNode, sheet: Sheet) -> (filter: SheetFilter?, unsupported: Bool) {
        guard let range = node["ref"].flatMap({ CellRange(a1: $0) }), range.end.row < XLSXLimits.rows,
              range.end.column < XLSXLimits.columns else { return (nil, true) }
        var criteria: [Int: FilterCriterion] = [:]
        var unsupported = false
        for column in node.children("filterColumn") {
            guard let offset = XLSXValue.int(column["colId"]), offset >= 0, offset < range.columnCount else {
                unsupported = true
                continue
            }
            let index = range.start.column + offset
            if let filters = column.child("filters"), filters.children("dateGroupItem").isEmpty {
                var shown = Set(filters.children("filter").compactMap { $0["val"]?.lowercased() })
                if XLSXValue.isTrue(filters["blank"]) { shown.insert("") }
                let values = FilterValues.dataRows(of: range).map { FilterValues.shown(in: sheet, column: index, rows: $0) } ?? []
                let hidden = Set(values.filter { !shown.contains($0.lowercased()) })
                if !hidden.isEmpty { criteria[index] = FilterCriterion(hiddenValues: hidden) }
            } else if let custom = column.child("customFilters"), let condition = condition(fromCustomFilters: custom) {
                criteria[index] = FilterCriterion(condition: condition)
            } else {
                unsupported = true
            }
        }
        return (SheetFilter(range: range, criteria: criteria), unsupported)
    }

    private static func condition(fromCustomFilters node: XNode) -> CellCondition? {
        let filters = node.children("customFilter").map { (op: $0["operator"] ?? "equal", value: $0["val"] ?? "") }
        if filters.count == 1 { return condition(fromCustomFilter: filters[0].op, filters[0].value) }
        guard filters.count == 2 else { return nil }
        let isAnd = XLSXValue.isTrue(node["and"])
        let (a, b) = (filters[0], filters[1])
        if isAnd, a.op == "greaterThanOrEqual", b.op == "lessThanOrEqual" { return CellCondition(.isBetween, [a.value, b.value]) }
        if !isAnd, a.op == "lessThan", b.op == "greaterThan" { return CellCondition(.isNotBetween, [a.value, b.value]) }
        return nil
    }

    private static func condition(fromCustomFilter op: String, _ value: String) -> CellCondition? {
        let isNumber = Double(value) != nil
        switch op {
        case "equal", "notEqual":
            let equal = op == "equal"
            if value.trimmingCharacters(in: .whitespaces).isEmpty { return CellCondition(equal ? .isEmpty : .isNotEmpty) }
            let starts = value.hasPrefix("*"), ends = value.hasSuffix("*") && !value.hasSuffix("~*")
            let core = unescapedWildcards(String(value.dropFirst(starts ? 1 : 0).dropLast(ends && value.count > 1 ? 1 : 0)))
            if starts, ends { return CellCondition(equal ? .textContains : .textDoesNotContain, [core]) }
            if equal, ends { return CellCondition(.textStartsWith, [core]) }
            if equal, starts { return CellCondition(.textEndsWith, [core]) }
            if value.contains("*") || value.contains("?") { return nil }
            if equal { return CellCondition(isNumber ? .isEqual : .textIsExactly, [unescapedWildcards(value)]) }
            return CellCondition(.isNotEqual, [unescapedWildcards(value)])
        case "greaterThan": return CellCondition(.greaterThan, [value])
        case "greaterThanOrEqual": return CellCondition(.greaterThanOrEqual, [value])
        case "lessThan": return CellCondition(.lessThan, [value])
        case "lessThanOrEqual": return CellCondition(.lessThanOrEqual, [value])
        default: return nil
        }
    }

    private static func unescapedWildcards(_ text: String) -> String {
        text.replacingOccurrences(of: "~*", with: "*").replacingOccurrences(of: "~?", with: "?").replacingOccurrences(of: "~~", with: "~")
    }

    private static func escapedWildcards(_ text: String) -> String {
        text.replacingOccurrences(of: "~", with: "~~").replacingOccurrences(of: "*", with: "~*").replacingOccurrences(of: "?", with: "~?")
    }

    /// `<autoFilter>` for the sheet's filter: value lists name the values shown, conditions become custom
    /// filters where Excel has them (others are left out; the rows they hide are still written hidden).
    static func writeAutoFilter(_ filter: SheetFilter, sheet: Sheet, into xml: inout XMLWriter) {
        guard let range = clipped([filter.range]).first else { return }
        xml.raw("<autoFilter ref=\"\(range.a1)\"")
        var columns = XMLWriter(fragmentCapacity: 256)
        for (index, criterion) in filter.criteria.sorted(by: { $0.key < $1.key }) where range.columns.contains(index) {
            let offset = index - range.start.column
            if !criterion.hiddenValues.isEmpty {
                let values = FilterValues.dataRows(of: range).map { FilterValues.shown(in: sheet, column: index, rows: $0) } ?? []
                let shown = values.filter { !criterion.hiddenValues.contains($0) }
                columns.raw("<filterColumn colId=\"\(offset)\"><filters")
                if shown.contains("") { columns.raw(" blank=\"1\"") }
                columns.raw(">")
                for value in shown where !value.isEmpty {
                    columns.raw("<filter")
                    columns.attribute("val", value)
                    columns.raw("/>")
                }
                columns.raw("</filters></filterColumn>")
            } else if let condition = criterion.condition, let filters = customFilters(for: condition) {
                columns.raw("<filterColumn colId=\"\(offset)\"><customFilters")
                if filters.and { columns.raw(" and=\"1\"") }
                columns.raw(">")
                for item in filters.items {
                    columns.raw("<customFilter")
                    if item.op != "equal" { columns.raw(" operator=\"\(item.op)\"") }
                    columns.attribute("val", item.value)
                    columns.raw("/>")
                }
                columns.raw("</customFilters></filterColumn>")
            }
        }
        if columns.isEmpty {
            xml.raw("/>")
        } else {
            xml.raw(">")
            xml.append(columns)
            xml.raw("</autoFilter>")
        }
    }

    private static func customFilters(for condition: CellCondition) -> (and: Bool, items: [(op: String, value: String)])? {
        let values = condition.values
        func literal(_ index: Int) -> String? {
            guard index < values.count, !values[index].hasPrefix("=") else { return nil }
            return values[index]
        }
        func number(_ index: Int) -> String? {
            guard let text = literal(index) else { return nil }
            if RuleFormulas.isDateKind(condition.kind), RuleValues.relativeDateFormula(text) != nil { return nil }
            guard let value = InputParser.parse(text, currentFormat: nil).value.numberValue else { return nil }
            return XLSXValue.string(value)
        }
        switch condition.kind {
        case .isEmpty: return (false, [("equal", "")])
        case .isNotEmpty: return (false, [("notEqual", " ")])
        case .textContains: return literal(0).map { (false, [("equal", "*" + escapedWildcards($0) + "*")]) }
        case .textDoesNotContain: return literal(0).map { (false, [("notEqual", "*" + escapedWildcards($0) + "*")]) }
        case .textStartsWith: return literal(0).map { (false, [("equal", escapedWildcards($0) + "*")]) }
        case .textEndsWith: return literal(0).map { (false, [("equal", "*" + escapedWildcards($0))]) }
        case .textIsExactly: return literal(0).map { (false, [("equal", escapedWildcards($0))]) }
        case .isEqual: return (number(0) ?? literal(0).map(escapedWildcards)).map { (false, [("equal", $0)]) }
        case .dateIs: return number(0).map { (false, [("equal", $0)]) }
        case .isNotEqual: return (number(0) ?? literal(0).map(escapedWildcards)).map { (false, [("notEqual", $0)]) }
        case .greaterThan, .dateIsAfter: return number(0).map { (false, [("greaterThan", $0)]) }
        case .greaterThanOrEqual, .dateIsOnOrAfter: return number(0).map { (false, [("greaterThanOrEqual", $0)]) }
        case .lessThan, .dateIsBefore: return number(0).map { (false, [("lessThan", $0)]) }
        case .lessThanOrEqual, .dateIsOnOrBefore: return number(0).map { (false, [("lessThanOrEqual", $0)]) }
        case .isBetween, .dateIsBetween:
            guard let low = number(0), let high = number(1) else { return nil }
            return (true, [("greaterThanOrEqual", low), ("lessThanOrEqual", high)])
        case .isNotBetween, .dateIsNotBetween:
            guard let low = number(0), let high = number(1) else { return nil }
            return (false, [("lessThan", low), ("greaterThan", high)])
        case .textIsValidEmail, .textIsValidURL, .dateIsValid, .customFormula:
            return nil
        }
    }
}
