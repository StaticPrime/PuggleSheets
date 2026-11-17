import Foundation

/// One end of a reference: a cell (A1), a whole column (A) or a whole row (1), each part optionally absolute.
struct ReferencePart: Hashable, Sendable {
    /// Grid limits for parsing; beyond them a word isn't a reference.
    static let maxRows = 10_000_000
    static let maxColumns = 18_278

    var row: Int?
    var column: Int?
    var rowAbsolute = false
    var columnAbsolute = false

    var isCell: Bool { row != nil && column != nil }

    /// "$A$1", "A", "$3"…
    var text: String {
        var text = ""
        if let column {
            if columnAbsolute { text += "$" }
            text += CellAddress.columnName(column)
        }
        if let row {
            if rowAbsolute { text += "$" }
            text += String(row + 1)
        }
        return text
    }

    /// Parses "A1", "$A$1", "a$1", "$A", "AB", "$5" or "5".
    static func parse(_ word: some StringProtocol) -> ReferencePart? {
        let bytes = Array(word.utf8)
        let n = bytes.count
        guard n > 0 else { return nil }
        var i = 0
        let firstDollar = bytes[0] == 0x24
        if firstDollar { i = 1 }
        var column = 0
        let letterStart = i
        while i < n, let value = letterValue(bytes[i]) {
            column = column * 26 + value
            i += 1
        }
        let letterCount = i - letterStart
        var part = ReferencePart()
        if letterCount == 0 {
            guard let row = rowNumber(bytes[i...]) else { return nil }
            part.row = row
            part.rowAbsolute = firstDollar
            return part
        }
        guard letterCount <= 3, column - 1 < maxColumns else { return nil }
        part.column = column - 1
        part.columnAbsolute = firstDollar
        if i == n { return part }
        if bytes[i] == 0x24 {
            part.rowAbsolute = true
            i += 1
        }
        guard let row = rowNumber(bytes[i...]) else { return nil }
        part.row = row
        return part
    }

    private static func letterValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x41...0x5A: Int(byte) - 0x40
        case 0x61...0x7A: Int(byte) - 0x60
        default: nil
        }
    }

    private static func rowNumber(_ digits: ArraySlice<UInt8>) -> Int? {
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        var number = 0
        for byte in digits {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            number = number * 10 + Int(byte - 0x30)
        }
        guard number >= 1, number <= maxRows else { return nil }
        return number - 1
    }

    /// Parts that make a reference together: two cells, two columns, two rows, or a cell with a column
    /// ("A2:A", open-ended rows) or a row ("A2:2", open-ended columns).
    static func canCombine(_ a: ReferencePart, _ b: ReferencePart) -> Bool {
        if a.isCell || b.isCell { return true }
        return (a.row == nil) == (b.row == nil)
    }
}

/// A reference as written in a formula, with its position.
struct ReferenceSyntax: Hashable, Sendable {
    /// The sheet named in the reference (unquoted), if any.
    var sheet: String?
    var first: ReferencePart
    var second: ReferencePart?
    /// UTF-16 span of the whole reference, sheet prefix included.
    var span: Range<Int>
    /// UTF-16 offset where the first part starts (after "Sheet1!").
    var partsStart: Int
    /// Index of the token after the reference.
    var tokenEnd: Int

    /// The covered rows: nil for every row; an upper bound of nil means "to the last row".
    var rowBounds: (lower: Int, upper: Int?)? {
        Self.bounds(first.row, second?.row, hasSecond: second != nil)
    }

    var columnBounds: (lower: Int, upper: Int?)? {
        Self.bounds(first.column, second?.column, hasSecond: second != nil)
    }

    private static func bounds(_ a: Int?, _ b: Int?, hasSecond: Bool) -> (lower: Int, upper: Int?)? {
        guard hasSecond else { return a.map { ($0, $0) } }
        switch (a, b) {
        case (let x?, let y?): return (min(x, y), max(x, y))
        case (let x?, nil), (nil, let x?): return (x, nil)
        case (nil, nil): return nil
        }
    }

    /// The block covered in a sheet of the given size, or nil when it doesn't fit in the grid.
    func range(rowCount: Int, columnCount: Int) -> CellRange? {
        guard let rows = Self.resolve(rowBounds, count: rowCount),
              let columns = Self.resolve(columnBounds, count: columnCount) else { return nil }
        return CellRange(rows: rows, columns: columns)
    }

    private static func resolve(_ bounds: (lower: Int, upper: Int?)?, count: Int) -> ClosedRange<Int>? {
        let lower = bounds?.lower ?? 0
        let upper = bounds.map { $0.upper ?? count - 1 } ?? count - 1
        guard lower >= 0, lower <= upper, upper < count else { return nil }
        return lower...upper
    }

    /// The parts as text ("A1:B2").
    var partsText: String {
        guard let second else { return first.text }
        return first.text + ":" + second.text
    }

    /// The block covered when every part names a cell; nil for whole and open-ended rows or columns.
    var cellRange: CellRange? {
        guard let firstRow = first.row, let firstColumn = first.column else { return nil }
        guard let second else { return CellRange(CellAddress(row: firstRow, column: firstColumn)) }
        guard let secondRow = second.row, let secondColumn = second.column else { return nil }
        return CellRange(CellAddress(row: firstRow, column: firstColumn), CellAddress(row: secondRow, column: secondColumn))
    }
}

/// A structured reference to a table: Table1[#ALL], Table1[Sales], Table1[[#HEADERS],[Sales]],
/// Table1[[Q1]:[Q4]]. Names match without regard to case.
struct TableReferenceSyntax: Hashable, Sendable {
    enum Area: Hashable, Sendable {
        /// Header row and data rows.
        case all
        case data
        case headers
    }

    var table: String
    var area: Area
    /// The first and last column named (nil: every column).
    var firstColumn: String?
    var lastColumn: String?

    /// Reads the text between a table reference's outer brackets: "#ALL", "Sales", "[Sales]",
    /// "[#HEADERS],[Sales]", "[Q1]:[Q4]", "[#ALL],[Q1]:[Q4]". Nil when it isn't one of these.
    init?(table: String, spec: String) {
        self.table = table
        area = .data
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        var items: [String] = []
        if !trimmed.contains("[") {
            items = [trimmed]
        } else {
            // Bracketed items separated by commas; a column range is two bracketed names around ":".
            var index = trimmed.startIndex
            var current = ""
            var depth = 0
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if character == "[" {
                    depth += 1
                    if depth > 1 { return nil }
                } else if character == "]" {
                    depth -= 1
                    if depth < 0 { return nil }
                } else if character == ",", depth == 0 {
                    items.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    index = trimmed.index(after: index)
                    continue
                } else if depth == 0, !character.isWhitespace, character != ":" {
                    return nil
                }
                current.append(character)
                index = trimmed.index(after: index)
            }
            guard depth == 0 else { return nil }
            items.append(current.trimmingCharacters(in: .whitespaces))
        }
        var areaSet = false
        for item in items {
            // "[A]:[B]" or "[A]" or a bare item.
            let names: [String]
            if item.hasPrefix("[") {
                let parts = item.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count <= 2, parts.allSatisfy({ $0.hasPrefix("[") && $0.hasSuffix("]") && $0.count >= 2 }) else { return nil }
                names = parts.map { String($0.dropFirst().dropLast()) }
            } else {
                names = [item]
            }
            if names.count == 1, names[0].hasPrefix("#") {
                guard !areaSet else { return nil }
                areaSet = true
                switch names[0].uppercased() {
                case "#ALL": area = .all
                case "#DATA": area = .data
                case "#HEADERS": area = .headers
                default: return nil
                }
                continue
            }
            guard firstColumn == nil, !names.contains(where: { $0.isEmpty || $0.hasPrefix("#") }) else { return nil }
            firstColumn = names[0]
            lastColumn = names.count == 2 ? names[1] : names[0]
        }
    }

    /// The reference as formula text.
    var text: String {
        let areaText: String? = switch area {
        case .all: "#ALL"
        case .headers: "#HEADERS"
        case .data: nil
        }
        guard let firstColumn, let lastColumn else { return "\(table)[\(areaText ?? "#DATA")]" }
        let columns = firstColumn.caseInsensitiveCompare(lastColumn) == .orderedSame ? "[\(firstColumn)]" : "[\(firstColumn)]:[\(lastColumn)]"
        guard let areaText else { return "\(table)[\(columns)]" }
        return "\(table)[[\(areaText)],\(columns)]"
    }
}

/// A parsed expression.
indirect enum Expr: Sendable {
    case literal(CellValue)
    /// An omitted function argument, as in IF(A1,,1).
    case missing
    case reference(ReferenceSyntax)
    /// An identifier that isn't a reference (named ranges aren't supported).
    case name(String)
    case array([[Expr]])
    case negate(Expr)
    case plus(Expr)
    case percent(Expr)
    case binary(FormulaOperator, Expr, Expr)
    /// The ":" operator between expressions that aren't plain references (A1:INDEX(…)).
    case range(Expr, Expr)
    case call(FunctionDef, [Expr])
    /// A call to a name that isn't a function: a LET or LAMBDA name holding a LAMBDA, or an unknown function.
    case unknownFunction(String, [Expr])
    /// Calling what an expression produces: LAMBDA(x, x*2)(3).
    case invoke(Expr, [Expr])
    case tableReference(TableReferenceSyntax)
}

/// A static reference whose values a formula reads.
struct Dependency: Sendable {
    var reference: ReferenceSyntax
    /// Set for SUMIF and AVERAGEIF sum ranges, which are read in the shape of the criteria range from
    /// their top-left cell.
    var shapedLike: ReferenceSyntax?
}

/// A formula parsed once and shared by every cell holding the same text.
final class ParsedFormula: Sendable {
    let expression: Expr
    /// Static references whose values the formula reads.
    let dependencies: [Dependency]
    /// Named ranges (or LET and LAMBDA names, or table names) the formula reads, as written.
    let names: [String]
    /// Tables the formula refers to with structured references.
    let tables: [String]
    /// Recomputed on every recalculation: NOW, RAND, INDIRECT, OFFSET…
    let isVolatile: Bool

    private struct Collector {
        var dependencies: [Dependency] = []
        var names: [String] = []
        var tables: [String] = []
        var isVolatile = false
    }

    init(_ text: String) {
        expression = FormulaParser.parse(text)
        var collector = Collector()
        Self.collect(expression, &collector)
        dependencies = collector.dependencies
        names = collector.names
        tables = collector.tables
        isVolatile = collector.isVolatile
    }

    private static func collect(_ expression: Expr, _ collector: inout Collector) {
        switch expression {
        case .reference(let reference):
            collector.dependencies.append(Dependency(reference: reference))
        case .name(let name):
            if !collector.names.contains(name) { collector.names.append(name) }
        case .array(let rows):
            for row in rows {
                for element in row { collect(element, &collector) }
            }
        case .negate(let operand), .plus(let operand), .percent(let operand):
            collect(operand, &collector)
        case .binary(_, let lhs, let rhs):
            collect(lhs, &collector)
            collect(rhs, &collector)
        case .range(let lhs, let rhs):
            collector.isVolatile = true
            collect(lhs, &collector)
            collect(rhs, &collector)
        case .call(let function, let arguments):
            if function.isVolatile { collector.isVolatile = true }
            let resizesSumRange = function.name == "SUMIF" || function.name == "AVERAGEIF"
            for (index, argument) in arguments.enumerated() {
                switch argument {
                case .reference, .name:
                    if function.isPositional(index) { continue }
                default:
                    break
                }
                if index == 2, resizesSumRange {
                    if case .reference(let sumRange) = argument, case .reference(let criteriaRange) = arguments[0] {
                        collector.dependencies.append(Dependency(reference: sumRange, shapedLike: criteriaRange))
                        continue
                    }
                    // A resized sum range named indirectly can't be pinned down statically.
                    collector.isVolatile = true
                }
                collect(argument, &collector)
            }
        case .unknownFunction(_, let arguments):
            for argument in arguments { collect(argument, &collector) }
        case .invoke(let callee, let arguments):
            collect(callee, &collector)
            for argument in arguments { collect(argument, &collector) }
        case .tableReference(let reference):
            if !collector.tables.contains(where: { $0.caseInsensitiveCompare(reference.table) == .orderedSame }) {
                collector.tables.append(reference.table)
            }
        case .literal, .missing:
            break
        }
    }
}

/// Recursive-descent parser for formula syntax.
struct FormulaParser {
    private struct Failure: Error {}
    /// Nesting limit (Excel allows 64 levels of functions); deeper formulas are parse errors.
    private static let maxDepth = 100

    private let tokens: [FormulaToken]
    private let units: [UInt16]
    private var position = 0
    private var depth = 0

    private init(tokens: [FormulaToken], units: [UInt16]) {
        self.tokens = tokens
        self.units = units
    }

    /// The expression of formula text ("=…"); a literal #ERROR! when it can't be parsed.
    static func parse(_ formula: String) -> Expr {
        let units = Array(formula.utf16)
        let start = units.first == 0x3D ? 1 : 0
        let (tokens, complete) = FormulaLexer.tokenize(units, from: start)
        guard complete, !tokens.isEmpty else { return .literal(.error(FormulaErrors.parse)) }
        var parser = FormulaParser(tokens: tokens, units: units)
        do {
            let expression = try parser.parseExpression()
            guard parser.position == tokens.count else { throw Failure() }
            return expression
        } catch {
            return .literal(.error(FormulaErrors.parse))
        }
    }

    /// Every reference in a token stream, in order (works on incomplete formulas too).
    static func references(in tokens: [FormulaToken], units: [UInt16]) -> [ReferenceSyntax] {
        var result: [ReferenceSyntax] = []
        var index = 0
        while index < tokens.count {
            if let reference = matchReference(tokens, at: index, units: units) {
                result.append(reference)
                index = reference.tokenEnd
            } else {
                index += 1
            }
        }
        return result
    }

    /// The reference starting at token `index`, if any.
    static func matchReference(_ tokens: [FormulaToken], at index: Int, units: [UInt16]) -> ReferenceSyntax? {
        var j = index
        var sheet: String?
        if j + 1 < tokens.count, tokens[j + 1].kind == .bang {
            switch tokens[j].kind {
            case .word(let word): sheet = word
            case .quotedName(let name): sheet = name
            default: return nil
            }
            j += 2
        }
        guard j < tokens.count, let first = part(tokens[j], units: units) else { return nil }
        let next = j + 1 < tokens.count ? tokens[j + 1].kind : nil
        if tokens[j].word != nil, next == .leftParen || next == .bang { return nil }
        var second: ReferencePart?
        var last = j
        if next == .colon, j + 2 < tokens.count, let candidate = part(tokens[j + 2], units: units) {
            let after = j + 3 < tokens.count ? tokens[j + 3].kind : nil
            if after != .leftParen, after != .bang, ReferencePart.canCombine(first, candidate) {
                second = candidate
                last = j + 2
            }
        }
        if second == nil, !first.isCell { return nil }
        return ReferenceSyntax(sheet: sheet, first: first, second: second, span: tokens[index].start..<tokens[last].end,
                               partsStart: tokens[j].start, tokenEnd: last + 1)
    }

    private static func part(_ token: FormulaToken, units: [UInt16]) -> ReferencePart? {
        switch token.kind {
        case .word(let word): return ReferencePart.parse(word)
        case .number where token.isInteger:
            return ReferencePart.parse(String(decoding: units[token.start..<token.end], as: UTF16.self))
        default: return nil
        }
    }

    // MARK: Grammar

    private var current: FormulaToken.Kind? { position < tokens.count ? tokens[position].kind : nil }

    private func peek(_ offset: Int) -> FormulaToken.Kind? {
        position + offset < tokens.count ? tokens[position + offset].kind : nil
    }

    private mutating func expect(_ kind: FormulaToken.Kind) throws {
        guard current == kind else { throw Failure() }
        position += 1
    }

    /// Binding strength of binary operators, lowest first: comparison, &, + -, * /, ^.
    private static func precedence(_ op: FormulaOperator) -> Int? {
        switch op {
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual: 1
        case .concatenate: 2
        case .add, .subtract: 3
        case .multiply, .divide: 4
        case .power: 5
        case .percent: nil
        }
    }

    /// Precedence climbing: every binary operator is left-associative (2^3^2 is 64).
    private mutating func parseExpression(_ minimumPrecedence: Int = 1) throws -> Expr {
        if minimumPrecedence == 1 {
            depth += 1
            guard depth <= Self.maxDepth else { throw Failure() }
        }
        defer { if minimumPrecedence == 1 { depth -= 1 } }
        var lhs = try parseOperand()
        while case .op(let op)? = current, let precedence = Self.precedence(op), precedence >= minimumPrecedence {
            position += 1
            lhs = .binary(op, lhs, try parseExpression(precedence + 1))
        }
        return lhs
    }

    /// Unary + and - (binding tighter than ^, so -2^2 is 4), then a primary with ":" ranges and postfix %.
    private mutating func parseOperand() throws -> Expr {
        switch current {
        case .op(.subtract)?, .op(.add)?:
            let negate = current == .op(.subtract)
            position += 1
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else { throw Failure() }
            let operand = try parseOperand()
            return negate ? .negate(operand) : .plus(operand)
        default:
            break
        }
        var operand = try parsePrimary()
        // LAMBDA(x, x*2)(3): calling what a call (or a parenthesized expression) produces.
        while current == .leftParen, Self.canBeCalled(operand) {
            operand = try parseInvocation(of: operand)
        }
        while current == .colon {
            position += 1
            let rhs = try parsePrimary()
            guard Self.canBeReference(operand), Self.canBeReference(rhs) else { throw Failure() }
            operand = .range(operand, rhs)
        }
        while current == .op(.percent) {
            position += 1
            operand = .percent(operand)
        }
        return operand
    }

    /// Operands of ":" must produce references: references, function calls or nested ranges.
    private static func canBeReference(_ expression: Expr) -> Bool {
        switch expression {
        case .reference, .name, .call, .range, .unknownFunction, .invoke, .tableReference: true
        default: false
        }
    }

    private static func canBeCalled(_ expression: Expr) -> Bool {
        switch expression {
        case .call, .unknownFunction, .invoke: true
        default: false
        }
    }

    private mutating func parsePrimary() throws -> Expr {
        guard let token = current else { throw Failure() }
        switch token {
        case .number(let number):
            if let reference = Self.matchReference(tokens, at: position, units: units) {
                position = reference.tokenEnd
                return .reference(reference)
            }
            position += 1
            return .literal(.number(number))
        case .string(let text):
            position += 1
            return .literal(.text(text))
        case .error(let kind):
            position += 1
            return .literal(.error(CellError(kind)))
        case .leftParen:
            position += 1
            let inner = try parseExpression()
            try expect(.rightParen)
            if current == .leftParen { return try parseInvocation(of: inner) }
            return inner
        case .tableReference:
            return try parseTableReference()
        case .leftBrace:
            return try parseArray()
        case .word(let word):
            if peek(1) == .leftParen { return try parseCall(word) }
            if let reference = Self.matchReference(tokens, at: position, units: units) {
                position = reference.tokenEnd
                return .reference(reference)
            }
            guard peek(1) != .bang else { throw Failure() }
            position += 1
            if word.caseInsensitiveCompare("TRUE") == .orderedSame { return .literal(.boolean(true)) }
            if word.caseInsensitiveCompare("FALSE") == .orderedSame { return .literal(.boolean(false)) }
            return .name(word)
        case .quotedName:
            guard let reference = Self.matchReference(tokens, at: position, units: units) else { throw Failure() }
            position = reference.tokenEnd
            return .reference(reference)
        default:
            throw Failure()
        }
    }

    // Formulas nest through parsePrimary and parseOperand; rarer forms live in their own functions so those
    // frames stay small.

    @inline(never)
    private mutating func parseInvocation(of callee: Expr) throws -> Expr {
        .invoke(callee, try parseArguments())
    }

    @inline(never)
    private mutating func parseTableReference() throws -> Expr {
        guard case .tableReference(let token)? = current, let reference = TableReferenceSyntax(table: token.table, spec: token.spec) else {
            throw Failure()
        }
        position += 1
        return .tableReference(reference)
    }

    private mutating func parseCall(_ name: String) throws -> Expr {
        position += 1
        let arguments = try parseArguments()
        guard let function = FunctionLibrary.function(named: name) else { return .unknownFunction(name, arguments) }
        return .call(function, arguments)
    }

    /// "(a, , b)" from the opening parenthesis: arguments, empty ones as `.missing`.
    private mutating func parseArguments() throws -> [Expr] {
        try expect(.leftParen)
        var arguments: [Expr] = []
        if current == .rightParen {
            position += 1
            return arguments
        }
        while true {
            if current == .comma || current == .rightParen {
                arguments.append(.missing)
            } else {
                arguments.append(try parseExpression())
            }
            if current == .comma {
                position += 1
                continue
            }
            try expect(.rightParen)
            return arguments
        }
    }

    private mutating func parseArray() throws -> Expr {
        position += 1
        var rows: [[Expr]] = [[]]
        while true {
            rows[rows.count - 1].append(try parseExpression())
            switch current {
            case .comma?:
                position += 1
            case .semicolon?:
                position += 1
                rows.append([])
            case .rightBrace?:
                position += 1
                return .array(rows)
            default:
                throw Failure()
            }
        }
    }
}
