import Foundation

/// A case-insensitive text pattern where * matches any run of characters, ? any single character and ~
/// escapes the next character.
struct WildcardPattern {
    private enum Element: Equatable {
        case character(Character)
        case any
        case anyRun
    }

    private let elements: [Element]
    /// The pattern has no wildcards: plain case-insensitive equality.
    private let literal: String?

    init(_ pattern: String) {
        var elements: [Element] = []
        var escaped = false
        var hasWildcard = false
        for character in pattern.lowercased() {
            if escaped {
                elements.append(.character(character))
                escaped = false
                continue
            }
            switch character {
            case "~": escaped = true; hasWildcard = true
            case "*": elements.append(.anyRun); hasWildcard = true
            case "?": elements.append(.any); hasWildcard = true
            default: elements.append(.character(character))
            }
        }
        if escaped { elements.append(.character("~")) }
        self.elements = elements
        literal = hasWildcard ? nil : pattern
    }

    /// Whether `pattern` uses * or ? (or escapes).
    static func hasWildcards(_ pattern: String) -> Bool {
        pattern.contains { $0 == "*" || $0 == "?" || $0 == "~" }
    }

    func matches(_ text: String) -> Bool {
        if let literal { return Coercion.textEquals(literal, text) }
        let characters = Array(text.lowercased())
        var p = 0, t = 0
        var starP = -1, starT = 0
        while t < characters.count {
            if p < elements.count {
                switch elements[p] {
                case .anyRun:
                    starP = p
                    starT = t
                    p += 1
                    continue
                case .any:
                    p += 1
                    t += 1
                    continue
                case .character(let expected) where expected == characters[t]:
                    p += 1
                    t += 1
                    continue
                default:
                    break
                }
            }
            guard starP >= 0 else { return false }
            p = starP + 1
            starT += 1
            t = starT
        }
        while p < elements.count, elements[p] == .anyRun { p += 1 }
        return p == elements.count
    }
}

/// A condition of SUMIF, COUNTIF and friends: ">5", "<>x", "=abc", "a*", 3, TRUE…
struct Criterion {
    enum Comparison { case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual }

    enum Operand {
        case number(Double)
        case text(String, WildcardPattern)
        case boolean(Bool)
        case blank
        case error(CellError.Kind)
    }

    let comparison: Comparison
    let operand: Operand

    init(_ value: CellValue) throws {
        switch value {
        case .number(let number):
            comparison = .equal
            operand = .number(number)
        case .boolean(let boolean):
            comparison = .equal
            operand = .boolean(boolean)
        case .empty:
            comparison = .equal
            operand = .blank
        case .error(let error):
            throw error
        case .text(let text):
            var rest = Substring(text)
            var comparison = Comparison.equal
            for (prefix, kind) in [(">=", Comparison.greaterOrEqual), ("<=", .lessOrEqual), ("<>", .notEqual),
                                   (">", .greater), ("<", .less), ("=", .equal)] where rest.hasPrefix(prefix) {
                comparison = kind
                rest = rest.dropFirst(prefix.count)
                break
            }
            self.comparison = comparison
            let operandText = String(rest)
            if operandText.isEmpty {
                operand = .blank
            } else if let number = Coercion.number(fromText: operandText) {
                operand = .number(number)
            } else if operandText.caseInsensitiveCompare("TRUE") == .orderedSame {
                operand = .boolean(true)
            } else if operandText.caseInsensitiveCompare("FALSE") == .orderedSame {
                operand = .boolean(false)
            } else if let error = CellError(code: operandText) {
                operand = .error(error.kind)
            } else {
                operand = .text(operandText, WildcardPattern(operandText))
            }
        }
    }

    /// Whether empty cells satisfy the criterion.
    var matchesBlank: Bool { matches(.empty) }

    func matches(_ value: CellValue) -> Bool {
        switch comparison {
        case .equal: return equals(value)
        case .notEqual: return !equals(value)
        default: break
        }
        let order: Int
        switch (operand, value) {
        case (.number(let x), .number(let y)): order = Coercion.compareNumbers(y, x)
        case (.text(let x, _), .text(let y)): order = Coercion.compareText(y, x)
        case (.boolean(let x), .boolean(let y)): order = Coercion.compare(.boolean(y), .boolean(x))
        case (.blank, .text(let y)): order = y.isEmpty ? 0 : 1
        default: return false
        }
        switch comparison {
        case .less: return order < 0
        case .lessOrEqual: return order <= 0
        case .greater: return order > 0
        default: return order >= 0
        }
    }

    private func equals(_ value: CellValue) -> Bool {
        switch (operand, value) {
        case (.blank, .empty): return true
        case (.blank, .text(let text)): return text.isEmpty
        case (.number(let x), .number(let y)): return Coercion.compareNumbers(x, y) == 0
        case (.number(let x), .text(let text)):
            guard !text.isEmpty, let number = Coercion.number(fromText: text) else { return false }
            return Coercion.compareNumbers(x, number) == 0
        case (.text(_, let pattern), .text(let text)): return pattern.matches(text)
        case (.boolean(let x), .boolean(let y)): return x == y
        case (.error(let kind), .error(let error)): return kind == error.kind
        default: return false
        }
    }
}

extension Arguments {
    /// Row-major indices of the positions where every (range, criterion) pair matches. The ranges must
    /// have the same shape as the first one. When every criterion accepts blanks and `values` is given,
    /// only positions where `values` isn't empty are returned.
    func matchingPositions(_ pairs: [(range: RangeData, criterion: Criterion)], within values: RangeData? = nil) throws -> [Int] {
        guard let first = pairs.first else { return [] }
        for pair in pairs where pair.range.rows != first.range.rows || pair.range.columns != first.range.columns {
            throw FormulaErrors.value("Array arguments to \(name) are of different size.")
        }
        // Walk the non-empty cells of a range whose criterion rejects blanks; otherwise every position.
        let driver = pairs.firstIndex { !$0.criterion.matchesBlank }
        var positions: [Int] = []
        if let driver {
            for entry in pairs[driver].range.entries where pairs[driver].criterion.matches(entry.value) {
                var matches = true
                for (index, pair) in pairs.enumerated() where index != driver {
                    if !pair.criterion.matches(pair.range.value(at: entry.index)) { matches = false; break }
                }
                if matches { positions.append(entry.index) }
            }
        } else if let values {
            for entry in values.entries where pairs.allSatisfy({ $0.criterion.matches($0.range.value(at: entry.index)) }) {
                positions.append(entry.index)
            }
        } else {
            for position in 0..<first.range.count {
                if pairs.allSatisfy({ $0.criterion.matches($0.range.value(at: position)) }) { positions.append(position) }
            }
        }
        return positions
    }

    /// The block of values that goes with a criteria range: a range is resized to the criteria range's shape
    /// from its top-left cell, as Sheets does.
    func valueRange(_ index: Int, shapedLike criteria: RangeData) throws -> RangeData {
        if case .reference(let reference) = values[index] {
            let sheet = evaluator.workbook.sheets[reference.sheet]
            let start = reference.range.start
            let end = CellAddress(row: min(start.row + criteria.rows - 1, sheet.rowCount - 1),
                                  column: min(start.column + criteria.columns - 1, sheet.columnCount - 1))
            let resized = evaluator.rangeData(SheetReference(sheet: reference.sheet, range: CellRange(start, end)))
            if resized.rows == criteria.rows, resized.columns == criteria.columns { return resized }
            var values = [CellValue](repeating: .empty, count: criteria.count)
            for entry in resized.entries {
                let row = entry.index / resized.columns, column = entry.index % resized.columns
                values[row * criteria.columns + column] = entry.value
            }
            return RangeData(matrix: ValueMatrix(rows: criteria.rows, columns: criteria.columns, values: values))
        }
        let data = try self.data(index)
        guard data.rows == criteria.rows, data.columns == criteria.columns else {
            throw FormulaErrors.value("Array arguments to \(name) are of different size.")
        }
        return data
    }

    /// The (range, criterion) pairs of arguments start, start + 1, …
    func criteriaPairs(from start: Int) throws -> [(range: RangeData, criterion: Criterion)] {
        guard (count - start) % 2 == 0 else {
            throw FormulaErrors.argumentCount(name, min: start + 2, max: Int.max, got: count)
        }
        var pairs: [(range: RangeData, criterion: Criterion)] = []
        var index = start
        while index < count {
            pairs.append((try data(index), try Criterion(raw(index + 1))))
            index += 2
        }
        return pairs
    }
}
