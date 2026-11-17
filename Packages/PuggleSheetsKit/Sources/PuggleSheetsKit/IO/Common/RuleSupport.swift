import Foundation

/// How a file writes the formulas inside rules (conditional formats, validations, filters).
struct RuleFormulaSyntax: Sendable {
    /// One of our formulas, with its "=", as the file's expression; nil when it can't be written.
    var export: @Sendable (String) -> String?
    /// The file's expression as one of our formulas, with its "=".
    var `import`: @Sendable (String) -> String
}

/// Condition values ("as typed": "10", "1/2/2026", "today", "=B2", "abc") as formula operands and
/// file expressions, and back.
enum RuleValues {
    /// A dropdown list read from a file. Neither Excel nor OpenDocument has checkboxes, so they're
    /// written as a TRUE,FALSE list; that list reads back as checkboxes.
    static func listCriterion(_ items: [String]) -> DataValidationRule.Criterion {
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        return trimmed == ["TRUE", "FALSE"] ? .checkbox(checked: nil, unchecked: nil) : .list(items)
    }

    /// The relative dates date conditions accept, with the formulas they stand for.
    static let relativeDates: [(name: String, formula: String)] = [
        ("today", "=TODAY()"), ("tomorrow", "=TODAY()+1"), ("yesterday", "=TODAY()-1"),
        ("past week", "=TODAY()-7"), ("past month", "=EDATE(TODAY(),-1)"), ("past year", "=EDATE(TODAY(),-12)"),
    ]

    static func relativeDateFormula(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespaces)
        return relativeDates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.formula
    }

    /// A value as an operand in one of our formulas (without "="): formulas as written, numbers (and
    /// dates, percentages… as InputParser reads them) as numbers, relative dates as TODAY() arithmetic,
    /// booleans, and any other text as a string literal.
    static func operand(_ value: String, isDate: Bool) -> String {
        if value.hasPrefix("="), value.count > 1 { return String(value.dropFirst()) }
        if isDate, let formula = relativeDateFormula(value) { return String(formula.dropFirst()) }
        switch InputParser.parse(value, currentFormat: nil).value {
        case .number(let number): return XLSXValue.string(number)
        case .boolean(let boolean): return boolean ? "TRUE" : "FALSE"
        default: return quoted(value)
        }
    }

    /// A value as a file expression.
    static func expression(_ value: String, isDate: Bool, syntax: RuleFormulaSyntax) -> String? {
        syntax.export("=" + operand(value, isDate: isDate))
    }

    /// A file expression as a value: string literals unquoted, numbers as numbers (dates as "1/2/2026"
    /// in date conditions), relative dates by name, booleans, anything else as a formula.
    static func value(fromExpression expression: String, isDate: Bool, syntax: RuleFormulaSyntax) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = unquoted(trimmed) { return text }
        if let number = Double(trimmed), number.isFinite {
            return isDate ? EditText.number(number, kind: .date) : XLSXValue.string(number)
        }
        let formula = syntax.import(trimmed)
        let compact = formula.replacingOccurrences(of: " ", with: "").uppercased()
        if isDate, let relative = relativeDates.first(where: { $0.formula == compact }) { return relative.name }
        switch compact {
        case "=TRUE", "=TRUE()": return "TRUE"
        case "=FALSE", "=FALSE()": return "FALSE"
        default: return formula
        }
    }

    /// "abc" → "\"abc\"", doubling quotes inside.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The text of a single string literal, or nil when `text` is anything else (`"a"&"b"` included).
    static func unquoted(_ text: String) -> String? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        let inner = Array(text.dropFirst().dropLast())
        var result = ""
        var index = 0
        while index < inner.count {
            if inner[index] == "\"" {
                guard index + 1 < inner.count, inner[index + 1] == "\"" else { return nil }
                result.append("\"")
                index += 2
            } else {
                result.append(inner[index])
                index += 1
            }
        }
        return result
    }
}

/// Conditions as formulas, for files that can't express a condition directly.
enum RuleFormulas {
    /// One of our formulas (with "=") that is TRUE when `condition` holds for the cell `cell` (a relative
    /// reference such as "B2", the top-left cell of the rule's range).
    static func formula(for condition: CellCondition, cell: String) -> String {
        let values = condition.values
        func value(_ index: Int, date: Bool = false) -> String {
            RuleValues.operand(index < values.count ? values[index] : "", isDate: date)
        }
        let day = "INT(\(cell))"
        switch condition.kind {
        case .isEmpty: return "=LEN(\(cell))=0"
        case .isNotEmpty: return "=LEN(\(cell))>0"
        case .textContains: return "=ISNUMBER(SEARCH(\(value(0)),\(cell)))"
        case .textDoesNotContain: return "=ISERROR(SEARCH(\(value(0)),\(cell)))"
        case .textStartsWith: return "=LEFT(\(cell),LEN(\(value(0))))=\(value(0))"
        case .textEndsWith: return "=RIGHT(\(cell),LEN(\(value(0))))=\(value(0))"
        case .textIsExactly: return "=EXACT(\(cell),\(value(0)))"
        case .textIsValidEmail: return "=ISNUMBER(MATCH(\"*@*.?*\",\(cell),0))"
        case .textIsValidURL: return "=OR(LEFT(\(cell),7)=\"http://\",LEFT(\(cell),8)=\"https://\")"
        case .dateIs:
            let name = values.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if ["past week", "past month", "past year"].contains(name) {
                return "=AND(\(day)>=\(value(0, date: true)),\(day)<=TODAY())"
            }
            return "=\(day)=\(value(0, date: true))"
        case .dateIsBefore: return "=\(day)<\(value(0, date: true))"
        case .dateIsAfter: return "=\(day)>\(value(0, date: true))"
        case .dateIsOnOrBefore: return "=\(day)<=\(value(0, date: true))"
        case .dateIsOnOrAfter: return "=\(day)>=\(value(0, date: true))"
        case .dateIsBetween: return "=AND(\(day)>=\(value(0, date: true)),\(day)<=\(value(1, date: true)))"
        case .dateIsNotBetween: return "=OR(\(day)<\(value(0, date: true)),\(day)>\(value(1, date: true)))"
        case .dateIsValid: return "=ISNUMBER(\(cell))"
        case .greaterThan: return "=\(cell)>\(value(0))"
        case .greaterThanOrEqual: return "=\(cell)>=\(value(0))"
        case .lessThan: return "=\(cell)<\(value(0))"
        case .lessThanOrEqual: return "=\(cell)<=\(value(0))"
        case .isEqual: return "=\(cell)=\(value(0))"
        case .isNotEqual: return "=\(cell)<>\(value(0))"
        case .isBetween: return "=AND(\(cell)>=\(value(0)),\(cell)<=\(value(1)))"
        case .isNotBetween: return "=OR(\(cell)<\(value(0)),\(cell)>\(value(1)))"
        case .customFormula:
            guard let formula = values.first, !formula.isEmpty else { return "=TRUE" }
            return formula.hasPrefix("=") ? formula : "=" + formula
        }
    }

    /// Whether a condition compares dates.
    static func isDateKind(_ kind: CellCondition.Kind) -> Bool {
        switch kind {
        case .dateIs, .dateIsBefore, .dateIsAfter, .dateIsOnOrBefore, .dateIsOnOrAfter, .dateIsBetween, .dateIsNotBetween,
             .dateIsValid: true
        default: false
        }
    }
}

/// The values a filter column shows, for "filter by values" (files list the values shown; PuggleSheets
/// keeps the values hidden).
enum FilterValues {
    /// The distinct texts the cells of `column` show in `rows`, in order of first appearance; "" stands
    /// for empty cells.
    static func shown(in sheet: Sheet, column: Int, rows: ClosedRange<Int>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for row in rows {
            let address = CellAddress(row: row, column: column)
            let text = CellDisplay.text(for: sheet.value(at: address), pattern: sheet.cells[address]?.format.numberFormat).text
            if seen.insert(text).inserted { result.append(text) }
        }
        return result
    }

    /// The data rows of a filter: its range without the header row.
    static func dataRows(of range: CellRange) -> ClosedRange<Int>? {
        range.rowCount > 1 ? (range.start.row + 1)...range.end.row : nil
    }
}
