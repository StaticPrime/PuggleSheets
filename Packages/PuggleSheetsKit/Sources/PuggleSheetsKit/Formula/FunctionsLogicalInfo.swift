import Foundation

extension FunctionTable {
    mutating func addLogicalAndInfoFunctions() {
        add("AND", 1, .max) { a in .boolean(try Self.logicalValues(a).allSatisfy { $0 }) }
        add("OR", 1, .max) { a in .boolean(try Self.logicalValues(a).contains(true)) }
        add("XOR", 1, .max) { a in .boolean(try Self.logicalValues(a).filter { $0 }.count % 2 == 1) }
        add("TRUE", 0, 0) { _ in .boolean(true) }
        add("FALSE", 0, 0) { _ in .boolean(false) }
        add("NOT", 1, 1, lift: Params.all) { a in .boolean(!(try a.boolean(0))) }

        addLazy("IF", 2, 3) { a in
            let condition = a.operand(0)
            switch condition {
            case .array(let conditions):
                let whenTrue = a.evaluator.matrix(a.evaluate(1))
                let whenFalse = a.count > 2 ? a.evaluator.matrix(a.evaluate(2)) : ValueMatrix(.boolean(false))
                return Self.select(conditions, function: "IF") { flag, row, column in
                    (flag ? whenTrue : whenFalse).broadcastValue(row: row, column: column)
                }
            default:
                let value = a.evaluator.scalar(condition)
                if case .error = value { return .value(value) }
                do {
                    if try Coercion.boolean(value, function: "IF", parameter: 1) { return a.passing(1) }
                } catch {
                    return .error(error as? CellError ?? CellError(.value))
                }
                return a.count > 2 ? a.passing(2) : .boolean(false)
            }
        }
        for (name, onlyNotAvailable) in [("IFERROR", false), ("IFNA", true)] {
            addLazy(name, onlyNotAvailable ? 2 : 1, 2) { a in
                func isCaught(_ value: CellValue) -> Bool {
                    guard case .error(let error) = value else { return false }
                    return !onlyNotAvailable || error.kind == .notAvailable
                }
                let value = a.passingOperand(0)
                switch value {
                case .array(let matrix):
                    a.passed.decoration = nil
                    guard matrix.values.contains(where: isCaught) else { return value }
                    let fallback = a.count > 1 ? a.evaluator.matrix(a.evaluate(1)) : ValueMatrix(.empty)
                    var result = matrix
                    for row in 0..<matrix.rows {
                        for column in 0..<matrix.columns where isCaught(matrix[row, column]) {
                            result[row, column] = fallback.broadcastValue(row: row, column: column)
                        }
                    }
                    return .array(result)
                default:
                    guard isCaught(a.evaluator.scalar(value)) else { return value }
                    a.passed.decoration = nil
                    return a.count > 1 ? a.passing(1) : .value(.empty)
                }
            }
        }
        addLazy("IFS", 2, .max) { a in
            guard a.count % 2 == 0 else {
                return .error(FormulaErrors.argumentCount("IFS", min: a.count + 1, max: a.count + 1, got: a.count))
            }
            var index = 0
            while index < a.count {
                let condition = a.operand(index)
                if case .array = condition {
                    // Element by element: evaluate the remaining pairs as arrays.
                    var pairs: [(ValueMatrix, ValueMatrix)] = []
                    for pair in stride(from: index, to: a.count, by: 2) {
                        pairs.append((a.evaluator.matrix(pair == index ? condition : a.evaluate(pair)),
                                      a.evaluator.matrix(a.evaluate(pair + 1))))
                    }
                    let rows = pairs.map(\.0.rows).max()!, columns = pairs.map(\.0.columns).max()!
                    var result = ValueMatrix(rows: rows, columns: columns, repeating: .error(CellError(.notAvailable, "No match.")))
                    for row in 0..<rows {
                        for column in 0..<columns {
                            for (conditions, values) in pairs {
                                let flag = conditions.broadcastValue(row: row, column: column)
                                if case .error = flag { result[row, column] = flag; break }
                                if (try? Coercion.boolean(flag, function: "IFS", parameter: 1)) == true {
                                    result[row, column] = values.broadcastValue(row: row, column: column)
                                    break
                                }
                            }
                        }
                    }
                    return .array(result)
                }
                let value = a.evaluator.scalar(condition)
                if case .error = value { return .value(value) }
                do {
                    if try Coercion.boolean(value, function: "IFS", parameter: index + 1) { return a.passing(index + 1) }
                } catch {
                    return .error(error as? CellError ?? CellError(.value))
                }
                index += 2
            }
            return .error(.notAvailable, "No match.")
        }
        addLazy("SWITCH", 3, .max) { a in
            let expression = a.evaluator.scalar(a.evaluate(0))
            if case .error = expression { return .value(expression) }
            var index = 1
            while index + 1 < a.count {
                let candidate = a.evaluator.scalar(a.evaluate(index))
                if case .error = candidate { return .value(candidate) }
                if Coercion.equals(expression, candidate) { return a.passing(index + 1) }
                index += 2
            }
            if index < a.count { return a.passing(index) }
            return .error(.notAvailable, "No match.")
        }

        // HYPERLINK(url, [link_label]): shows the label (the URL when it's omitted or an empty cell); the
        // formula engine records the link of cells whose result comes from it.
        add("HYPERLINK", 1, 2, lift: Params.all) { a in
            let url = try a.text(0)
            var label = a.has(1) ? try a.scalar(1) : CellValue.text(url)
            if case .empty = label { label = .text(url) }
            a.evaluator.pendingDecoration = Self.hyperlinkTarget(url).map(CellDecoration.link)
            return .value(label)
        }

        add("ERROR.TYPE", 1, 1, lift: Params.all) { a in
            guard case .error(let error) = a.raw(0) else {
                throw CellError(.notAvailable, "Function ERROR.TYPE parameter 1 value is not an error.")
            }
            let codes: [CellError.Kind: Double] = [.null: 1, .divideByZero: 2, .value: 3, .reference: 4, .name: 5,
                                                   .number: 6, .notAvailable: 7, .parse: 8]
            return .number(codes[error.kind] ?? 8)
        }
        add("ISBLANK", 1, 1, lift: Params.all) { a in
            // A cell holding a formula isn't blank, even when the formula shows nothing.
            if let reference = a.reference(0),
               a.evaluator.workbook.sheets[reference.sheet].cells[reference.range.start]?.formula != nil {
                return .boolean(false)
            }
            return .boolean(a.raw(0) == .empty)
        }
        add("ISERR", 1, 1, lift: Params.all) { a in
            guard case .error(let error) = a.raw(0) else { return .boolean(false) }
            return .boolean(error.kind != .notAvailable)
        }
        add("ISERROR", 1, 1, lift: Params.all) { a in .boolean(a.raw(0).errorValue != nil) }
        add("ISNA", 1, 1, lift: Params.all) { a in .boolean(a.raw(0).errorValue?.kind == .notAvailable) }
        for (name, remainder) in [("ISEVEN", 0.0), ("ISODD", 1.0)] {
            add(name, 1, 1, lift: Params.all) { a in
                let number = try a.number(0).rounded(.towardZero)
                return .boolean(abs(number.truncatingRemainder(dividingBy: 2)) == remainder)
            }
        }
        add("ISLOGICAL", 1, 1, lift: Params.all) { a in .boolean(a.raw(0).booleanValue != nil) }
        add("ISNONTEXT", 1, 1, lift: Params.all) { a in .boolean(a.raw(0).textValue == nil) }
        add("ISNUMBER", 1, 1, lift: Params.all) { a in .boolean(a.raw(0).numberValue != nil) }
        add("ISTEXT", 1, 1, lift: Params.all) { a in .boolean(a.raw(0).textValue != nil) }
        add("ISREF", 1, 1, positional: Params.at(0)) { a in .boolean(a.reference(0) != nil) }
        add("N", 1, 1, lift: Params.all) { a in
            switch try a.scalar(0) {
            case .number(let number): .number(number)
            case .boolean(let boolean): .number(boolean ? 1 : 0)
            default: .number(0)
            }
        }
        add("NA", 0, 0) { _ in .error(FormulaErrors.notAvailable) }
        add("TYPE", 1, 1) { a in
            switch a.values[0] {
            case .array(let matrix) where !matrix.isSingle: return .number(64)
            case .reference(let reference) where !reference.range.isSingleCell: return .number(64)
            default:
                switch a.raw(0) {
                case .empty, .number: return .number(1)
                case .text: return .number(2)
                case .boolean: return .number(4)
                case .error: return .number(16)
                }
            }
        }
    }

    /// The truth values of AND/OR/XOR arguments: text inside ranges is skipped, text passed directly must
    /// read TRUE or FALSE.
    static func logicalValues(_ a: Arguments) throws -> [Bool] {
        var result: [Bool] = []
        try a.forEachValue(0..<a.count) { value, direct, index in
            switch value {
            case .boolean(let boolean): result.append(boolean)
            case .number(let number): result.append(number != 0)
            case .error(let error): throw error
            case .text:
                if direct { result.append(try Coercion.boolean(value, function: a.name, parameter: index + 1)) }
            case .empty: break
            }
        }
        guard !result.isEmpty else {
            throw FormulaErrors.value("\(a.name) has no valid input data.")
        }
        return result
    }

    /// Picks an element per condition element (IF over arrays).
    static func select(_ conditions: ValueMatrix, function: String,
                       _ pick: (Bool, Int, Int) -> CellValue) -> FormulaValue {
        var result = conditions
        for row in 0..<conditions.rows {
            for column in 0..<conditions.columns {
                let condition = conditions[row, column]
                if case .error = condition { continue }
                do {
                    let flag = try Coercion.boolean(condition, function: function, parameter: 1)
                    result[row, column] = pick(flag, row, column)
                } catch {
                    result[row, column] = .error(error as? CellError ?? CellError(.value))
                }
            }
        }
        return .array(result)
    }
}

extension FunctionTable {
    /// Where a HYPERLINK goes: http, https, mailto, aim, ftp, gopher, telnet and
    /// news links (other schemes link nowhere), "http://" added when there is no scheme, and "#gid=…" or
    /// "#namedrange=…" places in the spreadsheet. Nil for an empty URL.
    static func hyperlinkTarget(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { return trimmed }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[..<colon]
            let isScheme = scheme.first?.isLetter == true
                && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
                && (!scheme.contains(".") || trimmed[colon...].hasPrefix("://"))
            if isScheme {
                let allowed: Set<String> = ["http", "https", "mailto", "aim", "ftp", "gopher", "telnet", "news"]
                return allowed.contains(scheme.lowercased()) ? trimmed : nil
            }
        }
        return "http://" + trimmed
    }
}
