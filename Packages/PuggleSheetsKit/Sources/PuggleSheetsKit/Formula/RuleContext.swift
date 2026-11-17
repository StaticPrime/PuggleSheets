import Foundation

/// Evaluates rule conditions over many cells of one sheet, sharing one evaluator (and its range cache),
/// the rules' parsed formulas and today's date.
final class RuleContext {
    let workbook: Workbook
    let sheetIndex: Int
    let today: Double
    private let evaluator: Evaluator
    private var formulas: [String: ParsedFormula] = [:]

    convenience init(workbook: Workbook, sheetIndex: Int, now: Date) {
        self.init(evaluator: Evaluator(workbook: workbook, sheetIndex: sheetIndex, address: CellAddress(row: 0, column: 0), now: now),
                  sheetIndex: sheetIndex, now: now)
    }

    /// Shares `evaluator` (during a recalculation, one that reads fresh formula results). Rule formulas
    /// move its current cell; a recalculation restores it after each formula.
    init(evaluator: Evaluator, sheetIndex: Int, now: Date) {
        workbook = evaluator.workbook
        self.sheetIndex = sheetIndex
        today = DateSerial.serial(from: now, timeZone: .current).rounded(.down)
        self.evaluator = evaluator
    }

    /// What a cell shows: its value or one spilled into it.
    func value(at address: CellAddress) -> CellValue {
        workbook.sheets[sheetIndex].value(at: address)
    }

    /// The text a cell shows with its number format ("" when empty).
    func shownText(at address: CellAddress) -> String {
        CellDisplay.text(for: workbook.sheets[sheetIndex].value(at: address),
                         pattern: workbook.sheets[sheetIndex].cells[address]?.format.numberFormat).text
    }

    static func isBlank(_ value: CellValue) -> Bool {
        switch value {
        case .empty: true
        case .text(let text): text.isEmpty
        default: false
        }
    }

    /// A rule formula evaluated in `address` as if copied there from `origin`.
    private func evaluate(_ formula: String, at address: CellAddress, origin: CellAddress) -> CellValue {
        let parsed: ParsedFormula
        if let cached = formulas[formula] {
            parsed = cached
        } else {
            parsed = ParsedFormula(formula)
            formulas[formula] = parsed
        }
        evaluator.sheetIndex = sheetIndex
        evaluator.address = address
        evaluator.shift = (address.row - origin.row, address.column - origin.column)
        defer { evaluator.shift = (0, 0) }
        return evaluator.evaluateFormula(parsed)
    }

    // MARK: Conditions

    /// Whether `condition` holds at `address`, for the cell's own value or `explicit` (input being checked).
    func test(_ condition: CellCondition, at address: CellAddress, origin: CellAddress, value explicit: CellValue? = nil) -> Bool {
        evaluator.override = explicit.map { (sheetIndex, address, $0) }
        defer { evaluator.override = nil }
        let value = explicit ?? self.value(at: address)
        /// Condition value `index`: a formula's result, or the text as typed.
        func operand(_ index: Int) -> CellValue? {
            guard index < condition.values.count else { return nil }
            let text = condition.values[index]
            return text.hasPrefix("=") ? evaluate(text, at: address, origin: origin) : .text(text)
        }
        switch condition.kind {
        case .isEmpty:
            return Self.isBlank(value)
        case .isNotEmpty:
            return !Self.isBlank(value)
        case .textContains, .textDoesNotContain, .textStartsWith, .textEndsWith, .textIsExactly:
            guard let operand = operand(0), let needle = try? Coercion.text(operand),
                  let haystack = Self.text(of: value) else { return false }
            switch condition.kind {
            case .textContains: return needle.isEmpty || haystack.range(of: needle, options: .caseInsensitive) != nil
            case .textDoesNotContain: return !needle.isEmpty && haystack.range(of: needle, options: .caseInsensitive) == nil
            case .textStartsWith: return needle.isEmpty || haystack.range(of: needle, options: [.caseInsensitive, .anchored]) != nil
            case .textEndsWith:
                return needle.isEmpty || haystack.range(of: needle, options: [.caseInsensitive, .anchored, .backwards]) != nil
            default: return Coercion.textEquals(haystack, needle)
            }
        case .textIsValidEmail:
            guard case .text(let text) = value else { return false }
            return Self.isEmail(text)
        case .textIsValidURL:
            guard case .text(let text) = value else { return false }
            return Self.isURL(text)
        case .dateIs, .dateIsBefore, .dateIsAfter, .dateIsOnOrBefore, .dateIsOnOrAfter, .dateIsBetween, .dateIsNotBetween,
             .dateIsValid:
            return testDate(condition.kind, value, operand)
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .isEqual, .isNotEqual, .isBetween, .isNotBetween:
            return testNumber(condition.kind, value, operand)
        case .customFormula:
            guard let text = condition.values.first, !text.isEmpty else { return false }
            switch evaluate(text.hasPrefix("=") ? text : "=" + text, at: address, origin: origin) {
            case .boolean(let boolean): return boolean
            case .number(let number): return number != 0
            default: return false
            }
        }
    }

    /// A value as text conditions see it; nil for errors.
    private static func text(of value: CellValue) -> String? {
        if case .error = value { return nil }
        return try? Coercion.text(value)
    }

    /// A value as number conditions see it: empty is 0, booleans 1/0, text read as typed input.
    private static func number(of value: CellValue) -> Double? {
        switch value {
        case .number(let number): number
        case .empty: 0
        case .boolean(let boolean): boolean ? 1 : 0
        case .text(let text): Coercion.number(fromText: text)
        case .error: nil
        }
    }

    /// A condition value typed as text, read as a number, TRUE/FALSE or text.
    private static func typed(_ value: CellValue) -> CellValue {
        guard case .text(let text) = value else { return value }
        if let number = Coercion.number(fromText: text), !text.isEmpty { return .number(number) }
        if text.caseInsensitiveCompare("TRUE") == .orderedSame { return .boolean(true) }
        if text.caseInsensitiveCompare("FALSE") == .orderedSame { return .boolean(false) }
        return value
    }

    private func testNumber(_ kind: CellCondition.Kind, _ value: CellValue, _ operand: (Int) -> CellValue?) -> Bool {
        if case .error = value { return false }
        guard let first = operand(0).map(Self.typed) else { return false }
        if kind == .isBetween || kind == .isNotBetween {
            guard let second = operand(1).map(Self.typed), case .number(let a) = first, case .number(let b) = second,
                  let number = Self.number(of: value) else { return false }
            let inside = Coercion.compareNumbers(number, min(a, b)) >= 0 && Coercion.compareNumbers(number, max(a, b)) <= 0
            return kind == .isBetween ? inside : !inside
        }
        let order: Int
        if case .number(let target) = first {
            guard let number = Self.number(of: value) else { return kind == .isNotEqual }
            order = Coercion.compareNumbers(number, target)
        } else {
            if case .error = first { return false }
            order = Coercion.compare(value, first)
        }
        switch kind {
        case .greaterThan: return order > 0
        case .greaterThanOrEqual: return order >= 0
        case .lessThan: return order < 0
        case .lessThanOrEqual: return order <= 0
        case .isEqual: return order == 0
        default: return order != 0
        }
    }

    // MARK: Dates

    /// What a date condition value stands for: one day, or a period up to today.
    private enum DateTarget {
        case day(Double)
        case period(Double, Double)
    }

    private func dateTarget(_ value: CellValue?) -> DateTarget? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            return .day(number.rounded(.down))
        case .text(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "today": return .day(today)
            case "tomorrow": return .day(today + 1)
            case "yesterday": return .day(today - 1)
            case "past week": return .period(today - 7, today)
            case "past month": return .period(DateMath.addMonths(today, -1, endOfMonth: false), today)
            case "past year": return .period(DateMath.addMonths(today, -12, endOfMonth: false), today)
            default:
                guard let number = InputParser.number(from: text) else { return nil }
                return .day(number.rounded(.down))
            }
        default:
            return nil
        }
    }

    /// The day a date value compares as in before/after conditions (a period counts from its start).
    private func comparisonDay(_ value: CellValue?) -> Double? {
        switch dateTarget(value) {
        case .day(let day)?: day
        case .period(let start, _)?: start
        case nil: nil
        }
    }

    private static func date(of value: CellValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .text(let text):
            let parsed = InputParser.parse(text, currentFormat: nil)
            guard case .number(let number) = parsed.value, parsed.formula == nil else { return nil }
            switch NumberFormatPresets.kind(of: parsed.impliedFormat) {
            case .date, .dateTime: return number
            default: return nil
            }
        default: return nil
        }
    }

    private func testDate(_ kind: CellCondition.Kind, _ value: CellValue, _ operand: (Int) -> CellValue?) -> Bool {
        guard let date = Self.date(of: value) else { return false }
        let day = date.rounded(.down)
        switch kind {
        case .dateIsValid:
            return date >= DateMath.minSerial && date < DateMath.maxSerial + 1
        case .dateIs:
            switch dateTarget(operand(0)) {
            case .day(let target)?: return day == target
            case .period(let start, let end)?: return day >= start && day <= end
            case nil: return false
            }
        case .dateIsBetween, .dateIsNotBetween:
            guard let a = comparisonDay(operand(0)), let b = comparisonDay(operand(1)) else { return false }
            let inside = day >= min(a, b) && day <= max(a, b)
            return kind == .dateIsBetween ? inside : !inside
        default:
            guard let target = comparisonDay(operand(0)) else { return false }
            switch kind {
            case .dateIsBefore: return day < target
            case .dateIsAfter: return day > target
            case .dateIsOnOrBefore: return day <= target
            default: return day >= target
            }
        }
    }

    // MARK: Email and URL

    /// "name@example.com": one @, a local part of letters, digits and the usual symbols, and a domain of
    /// letter-digit-hyphen labels ending in a top-level domain of two or more letters.
    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[0].hasPrefix("."), !parts[0].hasSuffix("."),
              !parts[0].contains("..") else { return false }
        let localSymbols = Set("!#$%&'*+/=?^_`{|}~.-")
        guard parts[0].allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || localSymbols.contains($0) }) else { return false }
        return isDomain(parts[1])
    }

    private static func isDomain(_ text: Substring) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, last.count >= 2,
              last.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// "example.com", "www.example.com/path?q=1", "https://example.com:8080", "http://localhost": an optional
    /// http(s)/ftp scheme, a host name, IPv4 address or localhost, an optional port, then an optional path.
    static func isURL(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        var rest = Substring(text)
        for scheme in ["https://", "http://", "ftps://", "ftp://"] where rest.lowercased().hasPrefix(scheme) {
            rest = rest.dropFirst(scheme.count)
            break
        }
        let hostEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var host = rest[..<hostEnd]
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.count <= 5, port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(port), number <= 65_535 else { return false }
            host = host[..<colon]
        }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if host.lowercased() == "localhost" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0) ?? 999) <= 255 }) {
            return true
        }
        return isDomain(host)
    }

    // MARK: Color scales

    struct Gradient {
        var stops: [(value: Double, color: RGBColor)]

        func color(for number: Double) -> RGBColor {
            guard let first = stops.first, let last = stops.last else { return .white }
            if number <= first.value { return first.color }
            if number >= last.value { return last.color }
            for (lower, upper) in zip(stops, stops.dropFirst()) where number <= upper.value {
                let span = upper.value - lower.value
                let t = span > 0 ? (number - lower.value) / span : 0
                return Self.mix(lower.color, upper.color, t)
            }
            return last.color
        }

        static func mix(_ a: RGBColor, _ b: RGBColor, _ t: Double) -> RGBColor {
            func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
                UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded().clamped(to: 0...255))
            }
            return RGBColor(red: channel(a.red, b.red), green: channel(a.green, b.green), blue: channel(a.blue, b.blue))
        }
    }

    /// A color scale's stops, computed from the numbers in the rule's ranges; nil when they hold none.
    func gradient(for scale: ColorScale, over ranges: [CellRange]) -> Gradient? {
        let sheet = workbook.sheets[sheetIndex]
        var numbers: [Double] = []
        for range in ranges {
            guard let clipped = range.intersection(sheet.gridRange) else { continue }
            for entry in evaluator.rangeData(SheetReference(sheet: sheetIndex, range: clipped)).entries {
                if case .number(let number) = entry.value { numbers.append(number) }
            }
        }
        guard let low = numbers.min(), let high = numbers.max() else { return nil }
        func position(_ point: ColorScale.Point) -> Double? {
            switch point.kind {
            case .minimum: return low
            case .maximum: return high
            case .number: return pointNumber(point.value)
            case .percent: return pointNumber(point.value).map { low + (high - low) * $0 / 100 }
            case .percentile: return pointNumber(point.value).map { Self.percentile(&numbers, ($0 / 100).clamped(to: 0...1)) }
            }
        }
        guard let minimum = position(scale.minimum), let maximum = position(scale.maximum) else { return nil }
        var stops = [(minimum, scale.minimum.color)]
        if let midpoint = scale.midpoint, let middle = position(midpoint) { stops.append((middle, midpoint.color)) }
        stops.append((maximum, scale.maximum.color))
        return Gradient(stops: stops)
    }

    /// A color scale point's number: typed, or a formula's result.
    private func pointNumber(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("=") { return evaluate(text, at: CellAddress(row: 0, column: 0), origin: CellAddress(row: 0, column: 0)).numberValue }
        return Coercion.number(fromText: text)
    }

    /// PERCENTILE's interpolated value, by selection rather than sorting (it reorders `values`).
    static func percentile(_ values: inout [Double], _ fraction: Double) -> Double {
        let rank = fraction * Double(values.count - 1)
        let lower = Int(rank.rounded(.down))
        let low = select(&values, lower)
        guard lower + 1 < values.count, rank > Double(lower) else { return low }
        let high = values[(lower + 1)...].min()!
        return low + (rank - Double(lower)) * (high - low)
    }

    /// The `k`th smallest value (Hoare's selection): afterwards, values before `k` are no larger and those after no smaller.
    private static func select(_ values: inout [Double], _ k: Int) -> Double {
        var low = 0, high = values.count - 1
        while low < high {
            let pivot = values[(low + high) / 2]
            var i = low, j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { high = j } else if k >= i { low = i } else { break }
        }
        return values[k]
    }

    // MARK: Validation lists

    struct ListItem {
        var text: String
        var number: Double?

        /// An item typed into the rule: "5" also stands for the number 5, "1/2/2026" for its date.
        init(typed text: String) {
            self.text = text
            number = InputParser.number(from: text)
        }

        init(text: String, number: Double?) {
            self.text = text
            self.number = number
        }
    }

    /// The shown values of a range written as a reference ("Sheet1!$A$1:$A$10") or named range, in reading order.
    func items(in reference: String) -> [ListItem] {
        var text = reference.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        let resolved: FormulaValue
        if let syntax = Evaluator.referenceSyntax(text) {
            resolved = evaluator.resolve(syntax, defaultSheet: sheetIndex)
        } else {
            resolved = evaluator.resolveName(text)
        }
        guard case .reference(let block) = resolved else { return [] }
        let sheet = workbook.sheets[block.sheet]
        var items: [ListItem] = []
        for entry in evaluator.rangeData(block).entries {
            let address = CellAddress(row: block.range.start.row + entry.index / block.range.columnCount,
                                      column: block.range.start.column + entry.index % block.range.columnCount)
            let shown = CellDisplay.text(for: entry.value, pattern: sheet.cells[address]?.format.numberFormat).text
            items.append(ListItem(text: shown, number: entry.value.numberValue))
        }
        return items
    }

    /// Whether a value matches an item: the same number, or the same shown text ignoring case.
    func list(_ items: [ListItem], accepts value: CellValue, at address: CellAddress) -> Bool {
        if case .number(let number) = value,
           items.contains(where: { $0.number.map { Coercion.compareNumbers($0, number) == 0 } ?? false }) {
            return true
        }
        let shown: String
        if case .text(let text) = value {
            shown = text
        } else {
            shown = CellDisplay.text(for: value, pattern: workbook.sheets[sheetIndex].cells[address]?.format.numberFormat).text
        }
        return items.contains { Coercion.textEquals($0.text, shown) }
    }

    static func checkbox(accepts value: CellValue, checked: String, unchecked: String) -> Bool {
        func matches(_ option: String) -> Bool {
            switch value {
            case .boolean(let boolean): return Coercion.textEquals(option.trimmingCharacters(in: .whitespaces), boolean ? "TRUE" : "FALSE")
            case .number(let number):
                guard let optionNumber = InputParser.number(from: option) else { return false }
                return Coercion.compareNumbers(optionNumber, number) == 0
            case .text(let text): return Coercion.textEquals(text.trimmingCharacters(in: .whitespaces), option.trimmingCharacters(in: .whitespaces))
            default: return false
            }
        }
        return matches(checked) || matches(unchecked)
    }

    // MARK: Filters

    /// The data rows (not the header) of `filter` that some column's criterion hides.
    func hiddenRows(by filter: SheetFilter) -> Set<Int> {
        guard filter.range.rowCount > 1 else { return [] }
        let dataRows = (filter.range.start.row + 1)...filter.range.end.row
        var hidden = Set<Int>()
        for column in filter.criteria.keys.sorted() where filter.range.columns.contains(column) {
            guard let criterion = filter.criteria[column], !criterion.isEmpty else { continue }
            let origin = CellAddress(row: dataRows.lowerBound, column: column)
            for row in dataRows where !hidden.contains(row) {
                let address = CellAddress(row: row, column: column)
                if !criterion.hiddenValues.isEmpty, criterion.hiddenValues.contains(shownText(at: address)) {
                    hidden.insert(row)
                } else if let condition = criterion.condition, !test(condition, at: address, origin: origin) {
                    hidden.insert(row)
                }
            }
        }
        return hidden
    }

    // MARK: Messages

    /// "Input must be a number greater than 5."
    static func message(for condition: CellCondition) -> String {
        func value(_ index: Int) -> String { index < condition.values.count ? condition.values[index] : "" }
        func day(_ index: Int) -> String {
            switch value(index).trimmingCharacters(in: .whitespaces).lowercased() {
            case "today": "today"
            case "tomorrow": "tomorrow"
            case "yesterday": "yesterday"
            case "past week": "one week ago"
            case "past month": "one month ago"
            case "past year": "one year ago"
            default: value(index)
            }
        }
        switch condition.kind {
        case .isEmpty: return "Input must be empty."
        case .isNotEmpty: return "Input must not be empty."
        case .textContains: return "Input must be text containing \"\(value(0))\"."
        case .textDoesNotContain: return "Input must be text not containing \"\(value(0))\"."
        case .textStartsWith: return "Input must be text starting with \"\(value(0))\"."
        case .textEndsWith: return "Input must be text ending with \"\(value(0))\"."
        case .textIsExactly: return "Input must be exactly \"\(value(0))\"."
        case .textIsValidEmail: return "Input must be a valid email address."
        case .textIsValidURL: return "Input must be a valid URL."
        case .dateIs:
            switch value(0).trimmingCharacters(in: .whitespaces).lowercased() {
            case "past week": return "Input must be a date in the past week."
            case "past month": return "Input must be a date in the past month."
            case "past year": return "Input must be a date in the past year."
            default: return "Input must be the date \(day(0))."
            }
        case .dateIsBefore: return "Input must be a date before \(day(0))."
        case .dateIsAfter: return "Input must be a date after \(day(0))."
        case .dateIsOnOrBefore: return "Input must be a date on or before \(day(0))."
        case .dateIsOnOrAfter: return "Input must be a date on or after \(day(0))."
        case .dateIsBetween: return "Input must be a date between \(day(0)) and \(day(1))."
        case .dateIsNotBetween: return "Input must be a date not between \(day(0)) and \(day(1))."
        case .dateIsValid: return "Input must be a valid date."
        case .greaterThan: return "Input must be a number greater than \(value(0))."
        case .greaterThanOrEqual: return "Input must be a number greater than or equal to \(value(0))."
        case .lessThan: return "Input must be a number less than \(value(0))."
        case .lessThanOrEqual: return "Input must be a number less than or equal to \(value(0))."
        case .isEqual: return "Input must be equal to \(value(0))."
        case .isNotEqual: return "Input must not be equal to \(value(0))."
        case .isBetween: return "Input must be a number between \(value(0)) and \(value(1))."
        case .isNotBetween: return "Input must be a number not between \(value(0)) and \(value(1))."
        case .customFormula: return "Input must satisfy the specified formula."
        }
    }
}
