import Foundation

/// OpenDocument's rules: content validations, LibreOffice's conditional formats (`calcext:`), filters
/// (database ranges) and named ranges.
enum ODSRules {
    typealias SheetSize = (String?) -> (rows: Int, columns: Int)

    static let syntax = RuleFormulaSyntax(
        export: { formula in
            let text = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
            return ODSFormula.exportExpression(text, size: { _ in (Sheet.defaultRowCount, Sheet.defaultColumnCount) })
        },
        import: { "=" + ODSFormula.importExpression($0) })

    /// The formula language prefix of an OpenDocument expression ("of:", "oooc:").
    private static func withoutNamespace(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"), trimmed[..<colon].allSatisfy({ $0.isASCII && $0.isLetter }) else { return trimmed }
        let prefix = trimmed[..<colon].lowercased()
        guard prefix == "of" || prefix == "oooc" || prefix == "msoxl" else { return trimmed }
        return String(trimmed[trimmed.index(after: colon)...])
    }

    /// Splits at `separators` outside parentheses, brackets and quotes.
    static func splitArguments(_ text: Substring, separators: Set<Character>) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth -= 1
                current.append(character)
            default:
                if depth == 0, separators.contains(character) {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// The arguments of `name(…)` when `text` is exactly such a call.
    private static func arguments(of name: String, in text: String) -> [String]? {
        guard text.hasPrefix(name + "("), text.hasSuffix(")") else { return nil }
        let inner = text.dropFirst(name.count + 1).dropLast()
        var parts = splitArguments(inner, separators: [";"])
        if parts.count == 1 { parts = splitArguments(inner, separators: [","]) }
        return parts
    }

    /// The comparison a leading operator stands for ("<=5" → (.lessThanOrEqual, "5")).
    private static func comparison(_ text: String, isDate: Bool) -> (CellCondition.Kind, String)? {
        let operators: [(String, CellCondition.Kind, CellCondition.Kind)] = [
            ("!=", .isNotEqual, .isNotEqual), ("<>", .isNotEqual, .isNotEqual), ("<=", .lessThanOrEqual, .dateIsOnOrBefore),
            (">=", .greaterThanOrEqual, .dateIsOnOrAfter), ("<", .lessThan, .dateIsBefore), (">", .greaterThan, .dateIsAfter),
            ("=", .isEqual, .dateIs),
        ]
        for (symbol, kind, dateKind) in operators where text.hasPrefix(symbol) {
            return (isDate ? dateKind : kind, String(text.dropFirst(symbol.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func value(_ expression: String, isDate: Bool = false) -> String {
        RuleValues.value(fromExpression: expression, isDate: isDate, syntax: syntax)
    }

    private static func expression(_ value: String, isDate: Bool, size: SheetSize) -> String {
        if value.hasPrefix("="), value.count > 1 { return ODSFormula.exportExpression(String(value.dropFirst()), size: size) }
        return ODSFormula.exportExpression(RuleValues.operand(value, isDate: isDate), size: size)
    }

    /// Merges cell blocks into as few ranges as possible: runs down columns, then across.
    static func mergedRanges(_ blocks: [CellRange]) -> [CellRange] {
        var vertical: [CellRange] = []
        for block in blocks.sorted(by: { ($0.start.column, $0.end.column, $0.start.row) < ($1.start.column, $1.end.column, $1.start.row) }) {
            if let last = vertical.last, last.columns == block.columns, last.end.row + 1 >= block.start.row {
                vertical[vertical.count - 1] = last.union(block)
            } else {
                vertical.append(block)
            }
        }
        var result: [CellRange] = []
        for block in vertical.sorted(by: { ($0.start.row, $0.end.row, $0.start.column) < ($1.start.row, $1.end.row, $1.start.column) }) {
            if let last = result.last, last.rows == block.rows, last.end.column + 1 >= block.start.column {
                result[result.count - 1] = last.union(block)
            } else {
                result.append(block)
            }
        }
        return result
    }

    // MARK: - Content validation

    /// The rules of `table:content-validations` placed on the cells that name them, in the file's order.
    static func validations(_ node: XNode?, blocks: [String: [CellRange]]) -> (rules: [DataValidationRule], unsupported: Bool) {
        guard let node else { return ([], false) }
        var rules: [DataValidationRule] = []
        var unsupported = false
        for definition in node.children("content-validation") {
            guard let name = definition["name"], let cellBlocks = blocks[name], !cellBlocks.isEmpty else { continue }
            let ranges = mergedRanges(cellBlocks)
            guard let origin = ranges.first?.start, let criterion = criterion(definition["condition"] ?? "", origin: origin) else {
                unsupported = true
                continue
            }
            let error = definition.child("error-message")
            let rejects = XLSXValue.isTrue(error?["display"]) && (error?["message-type"] ?? "stop") == "stop"
            var help: String?
            if let message = definition.child("help-message"), XLSXValue.isTrue(message["display"]) {
                let text = message.children("p").map(\.text).joined(separator: "\n")
                if !text.isEmpty { help = text }
            }
            rules.append(DataValidationRule(ranges: ranges, criterion: criterion, rejectsInvalid: rejects, helpText: help,
                                            showsDropdown: definition["display-list"] != "none"))
        }
        return (rules, unsupported)
    }

    private static func criterion(_ condition: String, origin: CellAddress) -> DataValidationRule.Criterion? {
        let text = withoutNamespace(condition)
        if let items = arguments(of: "cell-content-is-in-list", in: text) {
            if items.count == 1, items[0].hasPrefix("["), items[0].hasSuffix("]") {
                return .listFromRange(ODSFormula.importExpression(items[0]))
            }
            var values: [String] = []
            for item in items {
                if let literal = RuleValues.unquoted(item) {
                    values.append(literal)
                } else if let number = Double(item), number.isFinite {
                    values.append(XLSXValue.string(number))
                } else {
                    return nil
                }
            }
            return RuleValues.listCriterion(values)
        }
        if let formula = arguments(of: "is-true-formula", in: text), formula.count == 1 {
            return .condition(CellCondition(.customFormula, ["=" + ODSFormula.importExpression(formula[0])]))
        }
        let length = "LEN(\(origin.a1))"
        if text.hasPrefix("cell-content-text-length()"), let (kind, operand) = comparison(String(text.dropFirst("cell-content-text-length()".count)), isDate: false),
           let symbol = symbol(kind) {
            return .condition(CellCondition(.customFormula, ["=\(length)\(symbol)\(ODSFormula.importExpression(operand))"]))
        }
        for (name, negated) in [("cell-content-text-length-is-between", false), ("cell-content-text-length-is-not-between", true)] {
            if let bounds = arguments(of: name, in: text), bounds.count == 2 {
                let low = ODSFormula.importExpression(bounds[0]), high = ODSFormula.importExpression(bounds[1])
                return .condition(CellCondition(.customFormula, [negated ? "=OR(\(length)<\(low),\(length)>\(high))"
                                                                           : "=AND(\(length)>=\(low),\(length)<=\(high))"]))
            }
        }
        // "cell-content-is-decimal-number() and cell-content()>5"
        guard let and = text.range(of: " and ") else { return nil }
        let type = text[..<and.lowerBound].trimmingCharacters(in: .whitespaces)
        let test = text[and.upperBound...].trimmingCharacters(in: .whitespaces)
        let isDate: Bool
        switch type {
        case "cell-content-is-whole-number()", "cell-content-is-decimal-number()", "cell-content-is-time()": isDate = false
        case "cell-content-is-date()": isDate = true
        default: return nil
        }
        if let bounds = arguments(of: "cell-content-is-between", in: test), bounds.count == 2 {
            return .condition(CellCondition(isDate ? .dateIsBetween : .isBetween, [value(bounds[0], isDate: isDate), value(bounds[1], isDate: isDate)]))
        }
        if let bounds = arguments(of: "cell-content-is-not-between", in: test), bounds.count == 2 {
            return .condition(CellCondition(isDate ? .dateIsNotBetween : .isNotBetween,
                                            [value(bounds[0], isDate: isDate), value(bounds[1], isDate: isDate)]))
        }
        if let formula = arguments(of: "is-true-formula", in: test), formula.count == 1 {
            return .condition(CellCondition(.customFormula, ["=" + ODSFormula.importExpression(formula[0])]))
        }
        guard test.hasPrefix("cell-content()"), let (kind, operand) = comparison(String(test.dropFirst("cell-content()".count)), isDate: isDate)
        else { return nil }
        return .condition(CellCondition(kind, [value(operand, isDate: isDate)]))
    }

    private static func symbol(_ kind: CellCondition.Kind) -> String? {
        switch kind {
        case .lessThan, .dateIsBefore: "<"
        case .lessThanOrEqual, .dateIsOnOrBefore: "<="
        case .greaterThan, .dateIsAfter: ">"
        case .greaterThanOrEqual, .dateIsOnOrAfter: ">="
        case .isEqual, .dateIs: "="
        case .isNotEqual: "!="
        default: nil
        }
    }

    /// `table:content-validation` elements for one sheet's rules, named `val<first>…`. Returns the names
    /// in rule order (nil for rules that couldn't be written).
    static func writeValidations(_ rules: [DataValidationRule], sheet: String, firstNumber: Int, size: SheetSize,
                                 into xml: inout XMLWriter) -> [String?] {
        var names: [String?] = []
        for (offset, rule) in rules.enumerated() {
            guard let origin = rule.ranges.first?.start, origin.row >= 0, origin.column >= 0,
                  let condition = validationCondition(rule.criterion, origin: origin, size: size) else {
                names.append(nil)
                continue
            }
            let name = "val\(firstNumber + offset)"
            names.append(name)
            xml.raw("<table:content-validation")
            xml.attribute("table:name", name)
            xml.attribute("table:condition", condition)
            xml.raw(" table:allow-empty-cell=\"true\"")
            xml.attribute("table:base-cell-address", ODSFormula.address(sheet: sheet, range: CellRange(origin)))
            switch rule.criterion {
            case .list, .listFromRange, .checkbox: xml.raw(rule.showsDropdown ? " table:display-list=\"unsorted\"" : " table:display-list=\"none\"")
            case .condition: break
            }
            xml.raw(">")
            if let help = rule.helpText, !help.isEmpty {
                xml.raw("<table:help-message table:display=\"true\">")
                for line in help.components(separatedBy: "\n") {
                    xml.raw("<text:p>")
                    xml.text(line)
                    xml.raw("</text:p>")
                }
                xml.raw("</table:help-message>")
            }
            xml.raw("<table:error-message table:message-type=\"\(rule.rejectsInvalid ? "stop" : "warning")\" table:display=\"true\"/>")
            xml.raw("</table:content-validation>")
        }
        return names
    }

    private static func validationCondition(_ criterion: DataValidationRule.Criterion, origin: CellAddress, size: SheetSize) -> String? {
        func item(_ text: String) -> String {
            if let number = Double(text), number.isFinite, text == XLSXValue.string(number) { return text }
            return RuleValues.quoted(text)
        }
        switch criterion {
        case .list(let items):
            guard !items.isEmpty else { return nil }
            return "of:cell-content-is-in-list(" + items.map(item).joined(separator: ";") + ")"
        case .listFromRange(let reference):
            let expression = ODSFormula.exportExpression(reference, size: size)
            guard expression.hasPrefix("["), expression.hasSuffix("]") else { return nil }
            return "of:cell-content-is-in-list(\(expression))"
        case .checkbox(let checked, let unchecked):
            return "of:cell-content-is-in-list(" + [checked ?? "TRUE", unchecked ?? "FALSE"].map(RuleValues.quoted).joined(separator: ";") + ")"
        case .condition(let condition):
            let isDate = RuleFormulas.isDateKind(condition.kind)
            let type = isDate ? "cell-content-is-date()" : "cell-content-is-decimal-number()"
            let numeric = condition.values.prefix(max(condition.kind.valueCount, 1)).allSatisfy { value in
                value.hasPrefix("=") || (isDate && RuleValues.relativeDateFormula(value) != nil
                    && !["past week", "past month", "past year"].contains(value.trimmingCharacters(in: .whitespaces).lowercased()))
                    || InputParser.parse(value, currentFormat: nil).value.numberValue != nil
            }
            if condition.kind == .dateIsValid { return "of:cell-content-is-date() and cell-content()>=0" }
            if numeric, condition.values.count >= condition.kind.valueCount {
                let values = condition.values.map { expression($0, isDate: isDate, size: size) }
                switch condition.kind {
                case .isBetween, .dateIsBetween: return "of:\(type) and cell-content-is-between(\(values[0]),\(values[1]))"
                case .isNotBetween, .dateIsNotBetween: return "of:\(type) and cell-content-is-not-between(\(values[0]),\(values[1]))"
                default:
                    if let symbol = symbol(condition.kind) { return "of:\(type) and cell-content()\(symbol)\(values[0])" }
                }
            }
            let formula = RuleFormulas.formula(for: condition, cell: origin.a1)
            return "of:is-true-formula(\(ODSFormula.exportExpression(String(formula.dropFirst()), size: size)))"
        }
    }

    // MARK: - Conditional formatting

    /// Rules from LibreOffice's `calcext:conditional-formats` for the sheet `sheetName`, in order.
    static func conditionalFormats(_ node: XNode?, sheetName: String, styles: ODSStyleSheet) -> (rules: [ConditionalFormatRule], unsupported: Bool) {
        guard let node else { return ([], false) }
        var rules: [ConditionalFormatRule] = []
        var unsupported = false
        for format in node.children("conditional-format") {
            let ranges = ODSFormula.parseAddressList(format["target-range-address"] ?? "")
                .filter { $0.sheet == nil || $0.sheet?.caseInsensitiveCompare(sheetName) == .orderedSame }.map(\.range)
            guard let origin = ranges.first?.start else {
                unsupported = true
                continue
            }
            for entry in format.children {
                switch entry.name {
                case "condition":
                    guard let condition = condition(entry["value"] ?? "", origin: origin) else {
                        unsupported = true
                        continue
                    }
                    let look = entry["apply-style-name"].map { styles.conditionalFormat($0) } ?? ConditionalFormat()
                    rules.append(ConditionalFormatRule(ranges: ranges, style: .condition(condition, look)))
                case "date-is":
                    // LibreOffice's names; other periods (this week, last month…) have no equivalent.
                    let names = ["today": "today", "yesterday": "yesterday", "tomorrow": "tomorrow", "last-7-days": "past week"]
                    guard let name = entry["date"].flatMap({ names[$0] }) else {
                        unsupported = true
                        continue
                    }
                    let look = entry["style"].map { styles.conditionalFormat($0) } ?? ConditionalFormat()
                    rules.append(ConditionalFormatRule(ranges: ranges, style: .condition(CellCondition(.dateIs, [name]), look)))
                case "color-scale":
                    guard let scale = colorScale(entry) else {
                        unsupported = true
                        continue
                    }
                    rules.append(ConditionalFormatRule(ranges: ranges, style: .colorScale(scale)))
                default:
                    unsupported = true
                }
            }
        }
        return (rules, unsupported)
    }

    private static func condition(_ text: String, origin: CellAddress) -> CellCondition? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let bounds = arguments(of: "between", in: value), bounds.count == 2 {
            return CellCondition(.isBetween, [self.value(bounds[0]), self.value(bounds[1])])
        }
        if let bounds = arguments(of: "not-between", in: value), bounds.count == 2 {
            return CellCondition(.isNotBetween, [self.value(bounds[0]), self.value(bounds[1])])
        }
        for (name, kind) in [("begins-with", CellCondition.Kind.textStartsWith), ("ends-with", .textEndsWith),
                             ("contains-text", .textContains), ("not-contains-text", .textDoesNotContain)] {
            if let argument = arguments(of: name, in: value), argument.count == 1 {
                return CellCondition(kind, [self.value(argument[0])])
            }
        }
        if let formula = arguments(of: "formula-is", in: value), formula.count == 1 {
            return CellCondition(.customFormula, ["=" + ODSFormula.importExpression(formula[0])])
        }
        if value == "is-error" { return CellCondition(.customFormula, ["=ISERROR(\(origin.a1))"]) }
        if value == "is-no-error" { return CellCondition(.customFormula, ["=NOT(ISERROR(\(origin.a1)))"]) }
        guard let (kind, operand) = comparison(value, isDate: false), !operand.isEmpty else { return nil }
        if kind == .isEqual, let literal = RuleValues.unquoted(operand) { return CellCondition(.textIsExactly, [literal]) }
        return CellCondition(kind, [self.value(operand)])
    }

    private static func colorScale(_ node: XNode) -> ColorScale? {
        let entries = node.children("color-scale-entry")
        guard entries.count == 2 || entries.count == 3 else { return nil }
        var points: [ColorScale.Point] = []
        for entry in entries {
            guard let color = entry["color"].flatMap(ODSStyleSheet.color) else { return nil }
            let kind: ColorScale.PointKind
            switch entry["type"] {
            case "minimum", "auto-minimum": kind = .minimum
            case "maximum", "auto-maximum": kind = .maximum
            case "number": kind = .number
            case "percent": kind = .percent
            case "percentile": kind = .percentile
            default: return nil
            }
            points.append(ColorScale.Point(kind: kind, value: kind == .minimum || kind == .maximum ? nil : (entry["value"] ?? "0"), color: color))
        }
        return ColorScale(minimum: points[0], midpoint: points.count == 3 ? points[1] : nil, maximum: points[points.count - 1])
    }

    /// `calcext:conditional-formats` for one sheet's rules, with their looks as named styles.
    static func writeConditionalFormats(_ rules: [ConditionalFormatRule], sheet: String, styles: inout ODSStyleWriter, size: SheetSize,
                                        into xml: inout XMLWriter) {
        var body = XMLWriter(fragmentCapacity: 256)
        for rule in rules {
            let ranges = rule.ranges.filter { $0.start.row >= 0 && $0.start.column >= 0 }
            guard let origin = ranges.first?.start else { continue }
            let target = ranges.map { ODSFormula.address(sheet: sheet, range: $0) }.joined(separator: " ")
            switch rule.style {
            case .colorScale(let scale):
                body.raw("<calcext:conditional-format")
                body.attribute("calcext:target-range-address", target)
                body.raw("><calcext:color-scale>")
                for point in [scale.minimum] + (scale.midpoint.map { [$0] } ?? []) + [scale.maximum] {
                    let type = switch point.kind {
                    case .minimum: "minimum"
                    case .maximum: "maximum"
                    case .number: "number"
                    case .percent: "percent"
                    case .percentile: "percentile"
                    }
                    body.raw("<calcext:color-scale-entry")
                    body.attribute("calcext:value", point.value ?? "0")
                    body.raw(" calcext:type=\"\(type)\" calcext:color=\"#\(point.color.hex.lowercased())\"/>")
                }
                body.raw("</calcext:color-scale></calcext:conditional-format>")
            case .condition(let condition, let look):
                let style = styles.conditionalStyle(look)
                body.raw("<calcext:conditional-format")
                body.attribute("calcext:target-range-address", target)
                body.raw(">")
                let relative = ["today": "today", "yesterday": "yesterday", "tomorrow": "tomorrow", "past week": "last-7-days"]
                if condition.kind == .dateIs, let name = condition.values.first?.trimmingCharacters(in: .whitespaces).lowercased(),
                   let date = relative[name] {
                    body.raw("<calcext:date-is calcext:date=\"\(date)\"")
                    body.attribute("calcext:style", style)
                    body.raw("/>")
                } else {
                    body.raw("<calcext:condition")
                    body.attribute("calcext:apply-style-name", style)
                    body.attribute("calcext:value", conditionValue(condition, origin: origin, size: size))
                    body.attribute("calcext:base-cell-address", ODSFormula.address(sheet: sheet, range: CellRange(origin)))
                    body.raw("/>")
                }
                body.raw("</calcext:conditional-format>")
            }
        }
        guard !body.isEmpty else { return }
        xml.raw("<calcext:conditional-formats>")
        xml.append(body)
        xml.raw("</calcext:conditional-formats>")
    }

    private static func conditionValue(_ condition: CellCondition, origin: CellAddress, size: SheetSize) -> String {
        let literal = condition.values.first.flatMap { $0.hasPrefix("=") ? nil : $0 }
        switch condition.kind {
        case .textContains where literal != nil: return "contains-text(\(RuleValues.quoted(literal!)))"
        case .textDoesNotContain where literal != nil: return "not-contains-text(\(RuleValues.quoted(literal!)))"
        case .textStartsWith where literal != nil: return "begins-with(\(RuleValues.quoted(literal!)))"
        case .textEndsWith where literal != nil: return "ends-with(\(RuleValues.quoted(literal!)))"
        case .textIsExactly where literal != nil: return "=" + RuleValues.quoted(literal!)
        default: break
        }
        let isDate = RuleFormulas.isDateKind(condition.kind)
        let spans = ["past week", "past month", "past year"]
        let direct = condition.values.count >= condition.kind.valueCount && condition.kind.valueCount > 0
            && !(condition.kind == .dateIs && spans.contains(condition.values[0].trimmingCharacters(in: .whitespaces).lowercased()))
        if direct {
            let values = condition.values.map { expression($0, isDate: isDate, size: size) }
            switch condition.kind {
            case .isBetween, .dateIsBetween: return "between(\(values[0]),\(values[1]))"
            case .isNotBetween, .dateIsNotBetween: return "not-between(\(values[0]),\(values[1]))"
            default:
                if let symbol = symbol(condition.kind) { return symbol + values[0] }
            }
        }
        let formula = RuleFormulas.formula(for: condition, cell: origin.a1)
        return "formula-is(\(ODSFormula.exportExpression(String(formula.dropFirst()), size: size)))"
    }

    // MARK: - Filters

    /// The criteria of a `table:filter`. Values chosen in a list name the values shown; PuggleSheets keeps
    /// the ones hidden, found from the sheet's cells.
    static func filterCriteria(_ node: XNode?, range: CellRange, sheet: Sheet) -> (criteria: [Int: FilterCriterion], unsupported: Bool) {
        guard let node else { return ([:], false) }
        var unsupported = false
        var conditions: [XNode] = []
        if let and = node.child("filter-and") {
            conditions = and.children("filter-condition")
            unsupported = !and.children("filter-or").isEmpty || !and.children("filter-and").isEmpty
        } else if let or = node.child("filter-or") {
            let items = or.children("filter-condition")
            // Either side of a range on one column is "not between"; other alternatives can't be kept.
            if items.count == 2, items[0]["field-number"] == items[1]["field-number"], items[0]["operator"] == "<",
               items[1]["operator"] == ">", let field = XLSXValue.int(items[0]["field-number"]) {
                let column = range.start.column + field
                return ([column: FilterCriterion(condition: CellCondition(.isNotBetween, [items[0]["value"] ?? "", items[1]["value"] ?? ""]))], false)
            }
            return ([:], true)
        } else {
            conditions = node.children("filter-condition")
        }
        var criteria: [Int: FilterCriterion] = [:]
        var byField: [Int: [XNode]] = [:]
        for condition in conditions {
            guard let field = XLSXValue.int(condition["field-number"]), field >= 0, field < range.columnCount else {
                unsupported = true
                continue
            }
            byField[field, default: []].append(condition)
        }
        for (field, items) in byField {
            let column = range.start.column + field
            if items.count == 2, items[0]["operator"] == ">=", items[1]["operator"] == "<=" {
                criteria[column] = FilterCriterion(condition: CellCondition(.isBetween, [items[0]["value"] ?? "", items[1]["value"] ?? ""]))
                continue
            }
            guard items.count == 1 else {
                unsupported = true
                continue
            }
            let item = items[0]
            let setItems = item.children("filter-set-item")
            if !setItems.isEmpty {
                let shown = Set(setItems.compactMap { $0["value"]?.lowercased() })
                let values = FilterValues.dataRows(of: range).map { FilterValues.shown(in: sheet, column: column, rows: $0) } ?? []
                let hidden = Set(values.filter { !shown.contains($0.lowercased()) })
                if !hidden.isEmpty { criteria[column] = FilterCriterion(hiddenValues: hidden) }
                continue
            }
            let value = item["value"] ?? ""
            let isNumber = item["data-type"] == "number"
            let kind: CellCondition.Kind?
            // LibreOffice's operator names, and the OpenDocument standard's where they differ.
            switch item["operator"] {
            case "=": kind = isNumber ? .isEqual : (value.isEmpty ? .isEmpty : .textIsExactly)
            case "!=": kind = isNumber ? .isNotEqual : (value.isEmpty ? .isNotEmpty : .isNotEqual)
            case "<": kind = .lessThan
            case ">": kind = .greaterThan
            case "<=": kind = .lessThanOrEqual
            case ">=": kind = .greaterThanOrEqual
            case "contains": kind = .textContains
            case "does-not-contain", "!contains": kind = .textDoesNotContain
            case "begins-with", "begins": kind = .textStartsWith
            case "ends-with", "ends": kind = .textEndsWith
            case "empty": kind = .isEmpty
            case "!empty": kind = .isNotEmpty
            default: kind = nil
            }
            guard let kind else {
                unsupported = true
                continue
            }
            criteria[column] = FilterCriterion(condition: CellCondition(kind, kind.valueCount == 0 ? [] : [value]))
        }
        return (criteria, unsupported)
    }

    /// The sheet filter's `table:database-range`, named as LibreOffice names a sheet's own range.
    static func writeFilter(of sheet: Sheet, index: Int, name: String, into body: inout XMLWriter) {
        guard let filter = sheet.filter, filter.range.start.row >= 0, filter.range.start.column >= 0 else { return }
        writeDatabaseRange(name: ODSTables.sheetRangePrefix + String(index), sheetName: name, range: filter.range, criteria: filter.criteria,
                           sheet: sheet, into: &body)
    }

    /// A `table:database-range` over `range` with filter buttons and a filter for `criteria` (by sheet
    /// column). Returns the filter's fingerprint (see `filterFingerprint`).
    @discardableResult
    static func writeDatabaseRange(name: String, sheetName: String, range: CellRange, criteria: [Int: FilterCriterion], sheet: Sheet,
                                   containsHeader: Bool = false, into body: inout XMLWriter) -> String {
        body.raw("<table:database-range")
        body.attribute("table:name", name)
        body.attribute("table:target-range-address", ODSFormula.address(sheet: sheetName, range: range))
        if containsHeader { body.raw(" table:contains-header=\"true\"") }
        body.raw(" table:display-filter-buttons=\"true\">")
        let filter = filterItems(range: range, criteria: criteria, sheet: sheet)
        if !filter.items.isEmpty {
            let group = filter.either ? "table:filter-or" : (filter.items.count > 1 ? "table:filter-and" : nil)
            body.raw("<table:filter>")
            if let group { body.raw("<\(group)>") }
            for item in filter.items {
                body.raw("<table:filter-condition table:field-number=\"\(item.field)\"")
                body.attribute("table:value", item.value)
                body.attribute("table:operator", item.op)
                if let dataType = item.dataType { body.raw(" table:data-type=\"\(dataType)\"") }
                guard let values = item.setItems else {
                    body.raw("/>")
                    continue
                }
                body.raw(">")
                for value in values {
                    body.raw("<table:filter-set-item")
                    body.attribute("table:value", value)
                    body.raw("/>")
                }
                body.raw("</table:filter-condition>")
            }
            if let group { body.raw("</\(group)>") }
            body.raw("</table:filter>")
        }
        body.raw("</table:database-range>")
        return filterFingerprint(filter)
    }

    /// A `table:filter-condition`: a comparison on a field (a column of the range), or the values shown
    /// (`setItems`, written as LibreOffice does: "=" the first of them, then each).
    struct FilterItem {
        var field: Int
        var op: String
        var value: String
        var dataType: String?
        var setItems: [String]?
    }

    /// The filter conditions for `criteria`, and whether either of them is enough (otherwise all must hold).
    static func filterItems(range: CellRange, criteria: [Int: FilterCriterion], sheet: Sheet) -> (items: [FilterItem], either: Bool) {
        let criteria = criteria.sorted(by: { $0.key < $1.key }).filter { range.columns.contains($0.key) }
        // "Not between" needs either-or, which LibreOffice can only hold as a filter's sole criterion.
        if criteria.count == 1, criteria[0].value.hiddenValues.isEmpty, let condition = criteria[0].value.condition,
           let bounds = notBetweenBounds(condition) {
            let field = criteria[0].key - range.start.column
            return ([FilterItem(field: field, op: "<", value: bounds.low, dataType: "number"),
                     FilterItem(field: field, op: ">", value: bounds.high, dataType: "number")], true)
        }
        var items: [FilterItem] = []
        for (column, criterion) in criteria {
            let field = column - range.start.column
            if !criterion.hiddenValues.isEmpty {
                let values = FilterValues.dataRows(of: range).map { FilterValues.shown(in: sheet, column: column, rows: $0) } ?? []
                let shown = values.filter { !criterion.hiddenValues.contains($0) }
                guard let first = shown.first else { continue }
                items.append(FilterItem(field: field, op: "=", value: first, setItems: shown))
            } else if let condition = criterion.condition {
                for part in filterConditions(condition) {
                    items.append(FilterItem(field: field, op: part.op, value: part.value, dataType: part.isNumber ? "number" : "text"))
                }
            }
        }
        return (items, false)
    }

    /// What a written filter holds, to tell later whether a file's filter is still the one written.
    static func filterFingerprint(_ filter: (items: [FilterItem], either: Bool)) -> String {
        guard !filter.items.isEmpty else { return "" }
        let group = filter.either ? "or" : (filter.items.count > 1 ? "and" : "one")
        return group + filter.items.map {
            fingerprint([String($0.field), $0.op, $0.value, $0.dataType ?? ""], items: $0.setItems ?? [])
        }.joined()
    }

    /// The fingerprint of a file's `table:filter`, as `filterFingerprint(_:)` gives it for the filter written.
    static func filterFingerprint(_ node: XNode?) -> String {
        guard let node else { return "" }
        var group = "one"
        var conditions = node.children("filter-condition")
        for (name, kind) in [("filter-and", "and"), ("filter-or", "or")] {
            guard let inner = node.child(name) else { continue }
            conditions = inner.children("filter-condition")
            // Nested groups are never written.
            group = inner.children.contains { $0.name != "filter-condition" } || !node.children("filter-condition").isEmpty ? "nested" : kind
            break
        }
        guard !conditions.isEmpty else { return "" }
        if group == "one", conditions.count > 1 { group = "many" }
        return group + conditions.map {
            fingerprint([$0["field-number"] ?? "", $0["operator"] ?? "", $0["value"] ?? "", $0["data-type"] ?? ""],
                        items: $0.children("filter-set-item").map { $0["value"] ?? "" })
        }.joined()
    }

    /// Parts with their lengths, so no text inside them can be mistaken for a separator.
    private static func fingerprint(_ parts: [String], items: [String]) -> String {
        (parts + [String(items.count)] + items).map { "\($0.utf8.count):\($0)" }.joined() + ";"
    }

    /// A filter condition as OpenDocument filter conditions on one field (all must hold).
    static func filterConditions(_ condition: CellCondition) -> [(op: String, value: String, isNumber: Bool)] {
        let values = condition.values
        func literal(_ index: Int) -> String? {
            guard index < values.count, !values[index].hasPrefix("=") else { return nil }
            return values[index]
        }
        func number(_ index: Int) -> String? {
            guard let text = literal(index) else { return nil }
            if RuleFormulas.isDateKind(condition.kind), RuleValues.relativeDateFormula(text) != nil { return nil }
            return InputParser.parse(text, currentFormat: nil).value.numberValue.map(XLSXValue.string)
        }
        func single(_ op: String, _ value: String?, number: Bool) -> [(op: String, value: String, isNumber: Bool)] {
            value.map { [(op, $0, number)] } ?? []
        }
        switch condition.kind {
        // LibreOffice's names. It reads "!empty" back as a comparison, so "not empty" is "not equal to nothing".
        case .isEmpty: return [("empty", "", false)]
        case .isNotEmpty: return [("!=", "", false)]
        case .textContains: return single("contains", literal(0), number: false)
        case .textDoesNotContain: return single("does-not-contain", literal(0), number: false)
        case .textStartsWith: return single("begins-with", literal(0), number: false)
        case .textEndsWith: return single("ends-with", literal(0), number: false)
        case .textIsExactly: return single("=", literal(0), number: false)
        case .isEqual: return number(0).map { [("=", $0, true)] } ?? single("=", literal(0), number: false)
        case .isNotEqual: return number(0).map { [("!=", $0, true)] } ?? single("!=", literal(0), number: false)
        case .dateIs: return single("=", number(0), number: true)
        case .greaterThan, .dateIsAfter: return single(">", number(0), number: true)
        case .greaterThanOrEqual, .dateIsOnOrAfter: return single(">=", number(0), number: true)
        case .lessThan, .dateIsBefore: return single("<", number(0), number: true)
        case .lessThanOrEqual, .dateIsOnOrBefore: return single("<=", number(0), number: true)
        case .isBetween, .dateIsBetween:
            guard let low = number(0), let high = number(1) else { return [] }
            return [(">=", low, true), ("<=", high, true)]
        case .isNotBetween, .dateIsNotBetween, .textIsValidEmail, .textIsValidURL, .dateIsValid, .customFormula:
            return []
        }
    }

    /// The numeric bounds of a "not between" condition.
    static func notBetweenBounds(_ condition: CellCondition) -> (low: String, high: String)? {
        guard condition.kind == .isNotBetween || condition.kind == .dateIsNotBetween, condition.values.count >= 2 else { return nil }
        let bounds = condition.values.prefix(2).compactMap { text -> String? in
            guard !text.hasPrefix("="), RuleValues.relativeDateFormula(text) == nil else { return nil }
            return InputParser.parse(text, currentFormat: nil).value.numberValue.map(XLSXValue.string)
        }
        return bounds.count == 2 ? (bounds[0], bounds[1]) : nil
    }

    // MARK: - Named ranges

    /// Named ranges from `table:named-expressions` (workbook and sheet ones). Expressions that aren't a
    /// single reference, and names PuggleSheets can't use, are `unsupported`.
    static func namedRanges(_ nodes: [(node: XNode, sheet: String?)]) -> (ranges: [NamedRange], unsupported: Bool) {
        var result: [NamedRange] = []
        var seen = Set<String>()
        var unsupported = false
        for (node, localSheet) in nodes {
            for item in node.children {
                guard item.name == "named-range" || item.name == "named-expression", let name = item["name"] else { continue }
                var reference: String?
                if item.name == "named-range", let address = item["cell-range-address"].flatMap({ ODSFormula.parseAddress(Substring($0)) }) {
                    var resolved = address
                    if resolved.sheet == nil {
                        resolved.sheet = item["base-cell-address"].flatMap { ODSFormula.parseAddress(Substring($0))?.sheet } ?? localSheet
                    }
                    reference = resolved.text
                } else if item.name == "named-expression", let expression = item["expression"].flatMap(ODSFormula.importing) {
                    let text = String(expression.dropFirst())
                    if XLSXRules.isReference(text) { reference = text }
                }
                guard let reference, NamedRange.isValidName(name), seen.insert(name.lowercased()).inserted else {
                    unsupported = true
                    continue
                }
                result.append(NamedRange(name: name, reference: reference))
            }
        }
        return (result, unsupported)
    }

    /// `table:named-expressions` for the workbook's named ranges (those without a sheet belong to the first).
    static func writeNamedRanges(_ names: [NamedRange], firstSheet: String, into xml: inout XMLWriter) {
        var body = XMLWriter(fragmentCapacity: 128)
        var seen = Set<String>()
        for named in names where NamedRange.isValidName(named.name) && seen.insert(named.name.lowercased()).inserted {
            guard let address = ODSFormula.address(fromReference: named.reference, defaultSheet: firstSheet) else { continue }
            body.raw("<table:named-range")
            body.attribute("table:name", named.name)
            body.attribute("table:base-cell-address", "$" + ODSFormula.quotedSheet(firstSheet) + ".$A$1")
            body.attribute("table:cell-range-address", address)
            body.raw("/>")
        }
        guard !body.isEmpty else { return }
        xml.raw("<table:named-expressions>")
        xml.append(body)
        xml.raw("</table:named-expressions>")
    }
}
