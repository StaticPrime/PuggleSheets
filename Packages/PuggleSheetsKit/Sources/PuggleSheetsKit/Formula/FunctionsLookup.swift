import Foundation

/// Searching lists the way lookup functions do.
enum Lookup {
    static func sameType(_ a: CellValue, _ b: CellValue) -> Bool {
        switch (a, b) {
        case (.number, .number), (.text, .text), (.boolean, .boolean): true
        default: false
        }
    }

    /// Exact match (case-insensitive text, wildcards when `wildcards` and the key uses them), first or
    /// last position in the list.
    static func exactMatch(_ key: CellValue, in values: [CellValue], wildcards: Bool, reverse: Bool = false,
                           index: (() -> LookupIndex)? = nil) -> Int? {
        if wildcards, case .text(let text) = key, WildcardPattern.hasWildcards(text) {
            let pattern = WildcardPattern(text)
            let positions = reverse ? Array(values.indices.reversed()) : Array(values.indices)
            return positions.first { position in
                if case .text(let candidate) = values[position] { return pattern.matches(candidate) }
                return false
            }
        }
        if !reverse, let index {
            if let position = index().firstPosition(of: key) { return position }
            // Numbers equal within rounding noise hash differently: confirm a miss by comparing.
            guard case .number = key else { return nil }
        }
        let positions = reverse ? Array(values.indices.reversed()) : Array(values.indices)
        return positions.first { sameType(values[$0], key) && Coercion.equals(values[$0], key) }
    }

    /// Binary search among the values of the key's type, assumed sorted (ascending, or descending when
    /// `descending`): the last position whose value is ≤ key (≥ key when descending).
    static func approximateMatch(_ key: CellValue, in values: [CellValue], descending: Bool = false) -> Int? {
        let candidates = values.indices.filter { sameType(values[$0], key) }
        var low = 0, high = candidates.count - 1
        var result: Int?
        while low <= high {
            let middle = (low + high) / 2
            let order = Coercion.compare(values[candidates[middle]], key)
            if descending ? order >= 0 : order <= 0 {
                result = candidates[middle]
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return result
    }

    /// The first position (in sorted order) whose value is ≥ key (≤ key when descending).
    static func firstAtLeast(_ key: CellValue, in values: [CellValue], descending: Bool) -> Int? {
        let candidates = values.indices.filter { sameType(values[$0], key) }
        var low = 0, high = candidates.count - 1
        var result: Int?
        while low <= high {
            let middle = (low + high) / 2
            let order = Coercion.compare(values[candidates[middle]], key)
            if descending ? order <= 0 : order >= 0 {
                result = candidates[middle]
                high = middle - 1
            } else {
                low = middle + 1
            }
        }
        return result
    }

    /// XLOOKUP/XMATCH: match mode 0 exact, 1 exact or next larger, -1 exact or next smaller, 2 wildcard;
    /// search mode 1 first to last, -1 last to first, 2 binary ascending, -2 binary descending.
    static func xmatch(_ key: CellValue, in values: [CellValue], matchMode: Int, searchMode: Int) -> Int? {
        if abs(searchMode) == 2 {
            let descending = searchMode < 0
            switch matchMode {
            case 1:
                return descending ? approximateMatch(key, in: values, descending: true)
                    : firstAtLeast(key, in: values, descending: false)
            case -1:
                return descending ? firstAtLeast(key, in: values, descending: true)
                    : approximateMatch(key, in: values)
            default:
                guard let position = approximateMatch(key, in: values, descending: descending),
                      Coercion.equals(values[position], key) else {
                    return matchMode == 2 ? exactMatch(key, in: values, wildcards: true) : nil
                }
                return position
            }
        }
        let reverse = searchMode < 0
        if matchMode == 0 || matchMode == 2 {
            return exactMatch(key, in: values, wildcards: matchMode == 2, reverse: reverse)
        }
        var best: Int?
        for position in (reverse ? Array(values.indices.reversed()) : Array(values.indices)) {
            let value = values[position]
            guard sameType(value, key) else { continue }
            let order = Coercion.compare(value, key)
            if order == 0 { return position }
            guard matchMode == 1 ? order > 0 : order < 0 else { continue }
            if let current = best {
                let better = Coercion.compare(value, values[current])
                if matchMode == 1 ? better < 0 : better > 0 { best = position }
            } else {
                best = position
            }
        }
        return best
    }
}

extension Evaluator {
    /// The reference INDIRECT names: "B3", "Sheet2!A1:C4", "'My sheet'!A:A", or R1C1 notation.
    func indirectReference(_ text: String, a1: Bool) -> FormulaValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var sheet: String?
        var body = Substring(trimmed)
        if let syntax = a1 ? Self.referenceSyntax(trimmed) : nil { return resolve(syntax, defaultSheet: sheetIndex) }
        if a1, workbook.namedRange(trimmed) != nil { return resolveName(trimmed) }
        if let bang = trimmed.lastIndex(of: "!") {
            var name = String(trimmed[..<bang])
            if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            sheet = name
            body = trimmed[trimmed.index(after: bang)...]
        }
        if a1 {
            guard sheet != nil, var syntax = Self.referenceSyntax(String(body)), syntax.sheet == nil else { return nil }
            syntax.sheet = sheet
            return resolve(syntax, defaultSheet: sheetIndex)
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        var corners: [CellAddress] = []
        for part in parts {
            guard let corner = r1c1Address(part) else { return nil }
            corners.append(corner)
        }
        var sheetIndex = self.sheetIndex
        if let sheet {
            guard let index = lookupSheet(sheet) else { return .error(FormulaErrors.unresolvedSheet(sheet)) }
            sheetIndex = index
        }
        let range = CellRange(corners[0], corners[corners.count - 1])
        guard range.start.row >= 0, range.start.column >= 0, range.end.row < workbook.sheets[sheetIndex].rowCount,
              range.end.column < workbook.sheets[sheetIndex].columnCount else { return .error(FormulaErrors.outOfGrid) }
        return .reference(SheetReference(sheet: sheetIndex, range: range))
    }

    static func referenceSyntax(_ text: String) -> ReferenceSyntax? {
        let units = Array(text.utf16)
        let (tokens, complete) = FormulaLexer.tokenize(units, from: 0)
        guard complete, !tokens.isEmpty, let syntax = FormulaParser.matchReference(tokens, at: 0, units: units),
              syntax.tokenEnd == tokens.count else { return nil }
        return syntax
    }

    /// "R2C3", "R[-1]C[2]", "RC".
    private func r1c1Address(_ text: Substring) -> CellAddress? {
        var characters = Array(text.uppercased())
        func coordinate(_ letter: Character, current: Int) -> Int? {
            guard characters.first == letter else { return nil }
            characters.removeFirst()
            if characters.first == "[" {
                guard let close = characters.firstIndex(of: "]"), let offset = Int(String(characters[1..<close])),
                      abs(offset) <= ReferencePart.maxRows else { return nil }
                characters.removeFirst(close + 1)
                return current + offset
            }
            let digits = characters.prefix { $0.isASCII && $0.isNumber }
            characters.removeFirst(digits.count)
            guard !digits.isEmpty else { return current }
            guard digits.count <= 9, let number = Int(String(digits)), number >= 1 else { return nil }
            return number - 1
        }
        guard let row = coordinate("R", current: address.row), let column = coordinate("C", current: address.column),
              characters.isEmpty else { return nil }
        return CellAddress(row: row, column: column)
    }
}

extension FunctionTable {
    mutating func addLookupFunctions() {
        add("ADDRESS", 2, 5, lift: Params.all) { a in
            let row = try a.integer(0), column = try a.integer(1)
            guard row >= 1 else { throw FormulaErrors.value("Function ADDRESS parameter 1 value is \(row). It should be greater than or equal to 1.") }
            guard column >= 1 else { throw FormulaErrors.value("Function ADDRESS parameter 2 value is \(column). It should be greater than or equal to 1.") }
            let mode = try a.integer(2, default: 1)
            guard (1...4).contains(mode) else {
                throw FormulaErrors.value("Function ADDRESS parameter 3 value is \(mode). Valid values are between 1 and 4 inclusive.")
            }
            let rowAbsolute = mode <= 2, columnAbsolute = mode == 1 || mode == 3
            var text: String
            if try a.boolean(3, default: true) {
                text = (columnAbsolute ? "$" : "") + CellAddress.columnName(column - 1) + (rowAbsolute ? "$" : "") + String(row)
            } else {
                text = (rowAbsolute ? "R\(row)" : "R[\(row)]") + (columnAbsolute ? "C\(column)" : "C[\(column)]")
            }
            if a.has(4) {
                let sheet = try a.text(4)
                if !sheet.isEmpty { text = FormulaRewriter.quotedSheetName(sheet) + "!" + text }
            }
            return .text(text)
        }
        addLazy("CHOOSE", 2, .max) { a in
            let selector = a.operand(0)
            if case .array(let indexes) = selector {
                let choices = (1..<a.count).map { a.evaluator.matrix(a.evaluate($0)) }
                return .array(indexes.enumeratedMap { value, row, column in
                    guard let number = try? Coercion.number(value, function: "CHOOSE", parameter: 1) else {
                        return value.errorValue.map(CellValue.error) ?? .error(CellError(.value))
                    }
                    let index = Int(number.rounded(.towardZero).clamped(to: -1...1e9))
                    guard index >= 1, index <= choices.count else { return .error(CellError(.value)) }
                    return choices[index - 1].broadcastValue(row: row, column: column)
                })
            }
            do {
                let number = try Coercion.number(a.evaluator.scalar(selector), function: "CHOOSE", parameter: 1)
                let index = Int(number.rounded(.towardZero).clamped(to: -1...1e9))
                guard index >= 1, index < a.count else {
                    return .error(.value, "Function CHOOSE parameter 1 value is \(index). Valid values are between 1 and \(a.count - 1) inclusive.")
                }
                return a.passing(index)
            } catch {
                return .error(error as? CellError ?? CellError(.value))
            }
        }
        for (name, isRow) in [("ROW", true), ("COLUMN", false)] {
            add(name, 0, 1, positional: Params.at(0)) { a in
                guard a.has(0) else {
                    return .number(Double((isRow ? a.evaluator.address.row : a.evaluator.address.column) + 1))
                }
                guard let reference = a.reference(0) else {
                    if let error = a.values[0].errorValue { throw error }
                    throw FormulaErrors.value("Function \(name) parameter 1 expects a cell reference.")
                }
                let span = isRow ? reference.range.rows : reference.range.columns
                let numbers = span.map { CellValue.number(Double($0 + 1)) }
                guard numbers.count > 1 else { return .value(numbers[0]) }
                return .array(isRow ? ValueMatrix(column: numbers) : ValueMatrix(row: numbers))
            }
        }
        for (name, isRows) in [("ROWS", true), ("COLUMNS", false)] {
            add(name, 1, 1, positional: Params.at(0)) { a in
                if let reference = a.reference(0) {
                    return .number(Double(isRows ? reference.range.rowCount : reference.range.columnCount))
                }
                let matrix = try a.matrix(0)
                return .number(Double(isRows ? matrix.rows : matrix.columns))
            }
        }
        for (name, vertical) in [("VLOOKUP", true), ("HLOOKUP", false)] {
            add(name, 3, 4, lift: Params.at(0, 2, 3)) { a in
                let key = try a.scalar(0)
                let data = try a.data(1)
                let index = try a.integer(2)
                guard index >= 1 else {
                    throw FormulaErrors.value("Function \(name) parameter 3 value is \(index). It should be greater than or equal to 1.")
                }
                guard index <= (vertical ? data.columns : data.rows) else {
                    throw CellError(.reference, "\(name) evaluates to an out of bounds range.")
                }
                let keys = vertical ? data.column(0) : data.row(0)
                let position = try a.boolean(3, default: true)
                    ? Lookup.approximateMatch(key, in: keys)
                    : Lookup.exactMatch(key, in: keys, wildcards: true) { data.lookupIndex(0, vertical: vertical) }
                guard let position else { throw FormulaErrors.notFound(key, function: name) }
                return .value(vertical ? data.value(row: position, column: index - 1) : data.value(row: index - 1, column: position))
            }
        }
        add("INDEX", 1, 3) { a in
            let row = try a.integer(1, default: 0), column = try a.integer(2, default: 0)
            guard row >= 0, column >= 0 else {
                throw FormulaErrors.value("Function INDEX parameter \(row < 0 ? 2 : 3) value is negative. It should be positive or zero.")
            }
            func checkBounds(rows: Int, columns: Int) throws {
                if row > rows {
                    throw CellError(.reference, "Function INDEX parameter 2 value is \(row). Valid values are between 0 and \(rows) inclusive.")
                }
                if column > columns {
                    throw CellError(.reference, "Function INDEX parameter 3 value is \(column). Valid values are between 0 and \(columns) inclusive.")
                }
            }
            if let reference = a.reference(0) {
                let range = reference.range
                try checkBounds(rows: range.rowCount, columns: range.columnCount)
                let rows = row == 0 ? range.rows : (range.start.row + row - 1)...(range.start.row + row - 1)
                let columns = column == 0 ? range.columns : (range.start.column + column - 1)...(range.start.column + column - 1)
                return .reference(SheetReference(sheet: reference.sheet, range: CellRange(rows: rows, columns: columns)))
            }
            let matrix = try a.matrix(0)
            try checkBounds(rows: matrix.rows, columns: matrix.columns)
            let rows = row == 0 ? Array(0..<matrix.rows) : [row - 1]
            let columns = column == 0 ? Array(0..<matrix.columns) : [column - 1]
            let values = rows.flatMap { r in columns.map { c in matrix[r, c] } }
            return values.count == 1 ? .value(values[0]) : .array(ValueMatrix(rows: rows.count, columns: columns.count, values: values))
        }
        add("INDIRECT", 1, 2, lift: Params.at(0), volatile: true) { a in
            let text = try a.text(0)
            guard let reference = a.evaluator.indirectReference(text, a1: try a.boolean(1, default: true)) else {
                throw CellError(.reference, "Function INDIRECT parameter 1 value is '\(text)'. It is not a valid cell/range reference.")
            }
            return reference
        }
        add("LOOKUP", 2, 3, lift: Params.at(0)) { a in
            let key = try a.scalar(0)
            let data = try a.data(1)
            let keys: [CellValue], results: [CellValue]
            if a.has(2) {
                let resultData = try a.data(2)
                guard data.rows == 1 || data.columns == 1, resultData.rows == 1 || resultData.columns == 1 else {
                    throw CellError(.notAvailable, "LOOKUP range must be a single row or a single column.")
                }
                keys = data.columns == 1 ? data.column(0) : data.row(0)
                results = resultData.columns == 1 ? resultData.column(0) : resultData.row(0)
            } else if data.columns > data.rows {
                keys = data.row(0)
                results = data.row(data.rows - 1)
            } else {
                keys = data.column(0)
                results = data.column(data.columns - 1)
            }
            guard let position = Lookup.approximateMatch(key, in: keys), position < results.count else {
                throw FormulaErrors.notFound(key, function: "LOOKUP")
            }
            return .value(results[position])
        }
        add("MATCH", 2, 3, lift: Params.at(0, 2)) { a in
            let key = try a.scalar(0)
            let data = try a.data(1)
            guard data.rows == 1 || data.columns == 1 else {
                throw CellError(.notAvailable, "MATCH range must be a single row or a single column.")
            }
            let vertical = data.columns == 1
            let values = vertical ? data.column(0) : data.row(0)
            let type = try a.number(2, default: 1)
            let position = type == 0
                ? Lookup.exactMatch(key, in: values, wildcards: true) { data.lookupIndex(0, vertical: vertical) }
                : Lookup.approximateMatch(key, in: values, descending: type < 0)
            guard let position else { throw FormulaErrors.notFound(key, function: "MATCH") }
            return .number(Double(position + 1))
        }
        add("OFFSET", 3, 5, positional: Params.at(0), volatile: true) { a in
            guard let reference = a.reference(0) else {
                if let error = a.values[0].errorValue { throw error }
                throw FormulaErrors.value("Function OFFSET parameter 1 expects a cell reference.")
            }
            let rows = try a.integer(1), columns = try a.integer(2)
            let height = try a.integer(3, default: reference.range.rowCount)
            let width = try a.integer(4, default: reference.range.columnCount)
            guard height >= 1, width >= 1 else {
                throw CellError(.reference, "Function OFFSET parameter \(height < 1 ? 4 : 5) value is 0. It should be greater than or equal to 1.")
            }
            let top = reference.range.start.row + rows, left = reference.range.start.column + columns
            let sheet = a.evaluator.workbook.sheets[reference.sheet]
            guard top >= 0, left >= 0, top + height <= sheet.rowCount, left + width <= sheet.columnCount else {
                throw CellError(.reference, "OFFSET evaluates to an out of bounds range.")
            }
            return .reference(SheetReference(sheet: reference.sheet,
                                             range: CellRange(rows: top...(top + height - 1), columns: left...(left + width - 1))))
        }
        add("XLOOKUP", 3, 6, lift: Params.at(0)) { a in
            let key = try a.scalar(0)
            let lookup = try a.data(1)
            guard lookup.rows == 1 || lookup.columns == 1 else {
                throw FormulaErrors.value("XLOOKUP lookup_range must be a single row or a single column.")
            }
            let vertical = lookup.columns == 1
            let results = try a.data(2)
            guard vertical ? results.rows == lookup.rows : results.columns == lookup.columns else {
                throw FormulaErrors.value("Array arguments to XLOOKUP are of different size.")
            }
            let (matchMode, searchMode) = try Self.lookupModes(a, matchIndex: 4, searchIndex: 5)
            guard let position = Lookup.xmatch(key, in: vertical ? lookup.column(0) : lookup.row(0),
                                               matchMode: matchMode, searchMode: searchMode) else {
                if a.has(3), a.raw(3) != .empty { return a.values[3] }
                throw FormulaErrors.notFound(key, function: "XLOOKUP")
            }
            let values = vertical ? results.row(position) : results.column(position)
            guard values.count > 1 else { return .value(values[0]) }
            return .array(vertical ? ValueMatrix(row: values) : ValueMatrix(column: values))
        }
        add("XMATCH", 2, 4, lift: Params.at(0)) { a in
            let key = try a.scalar(0)
            let lookup = try a.data(1)
            guard lookup.rows == 1 || lookup.columns == 1 else {
                throw FormulaErrors.value("XMATCH lookup_range must be a single row or a single column.")
            }
            let (matchMode, searchMode) = try Self.lookupModes(a, matchIndex: 2, searchIndex: 3)
            guard let position = Lookup.xmatch(key, in: lookup.columns == 1 ? lookup.column(0) : lookup.row(0),
                                               matchMode: matchMode, searchMode: searchMode) else {
                throw FormulaErrors.notFound(key, function: "XMATCH")
            }
            return .number(Double(position + 1))
        }
    }

    static func lookupModes(_ a: Arguments, matchIndex: Int, searchIndex: Int) throws -> (Int, Int) {
        let matchMode = try a.integer(matchIndex, default: 0)
        let searchMode = try a.integer(searchIndex, default: 1)
        guard [-1, 0, 1, 2].contains(matchMode) else {
            throw FormulaErrors.value("Function \(a.name) parameter \(matchIndex + 1) value is \(matchMode). Valid values are -1, 0, 1 and 2.")
        }
        guard [-2, -1, 1, 2].contains(searchMode) else {
            throw FormulaErrors.value("Function \(a.name) parameter \(searchIndex + 1) value is \(searchMode). Valid values are -2, -1, 1 and 2.")
        }
        return (matchMode, searchMode)
    }
}

extension ValueMatrix {
    func enumeratedMap(_ transform: (CellValue, Int, Int) -> CellValue) -> ValueMatrix {
        var result = self
        for row in 0..<rows {
            for column in 0..<columns { result[row, column] = transform(self[row, column], row, column) }
        }
        return result
    }
}
