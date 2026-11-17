import Foundation

/// An expression of QUERY's query language (its second argument).
indirect enum QueryNode: Equatable {
    /// A column by its identifier ("A", "Col2"); `index` is set once resolved against the data.
    case column(String, index: Int?)
    case literal(CellValue)
    /// + - * /
    case arithmetic(Character, QueryNode, QueryNode)
    case negate(QueryNode)
    /// = != < > <= >=
    case compare(String, QueryNode, QueryNode)
    case and(QueryNode, QueryNode)
    case or(QueryNode, QueryNode)
    case not(QueryNode)
    /// `is null` (negated: `is not null`).
    case isNull(QueryNode, negated: Bool)
    /// contains, starts with, ends with, matches, like
    case textTest(String, QueryNode, QueryNode)
    /// A scalar function, lowercased: year(), upper()…
    case function(String, [QueryNode])
    /// sum, avg, count, max, min
    case aggregate(String, QueryNode)

    var containsAggregate: Bool {
        switch self {
        case .aggregate: true
        case .column, .literal: false
        case .arithmetic(_, let a, let b), .compare(_, let a, let b), .and(let a, let b), .or(let a, let b), .textTest(_, let a, let b):
            a.containsAggregate || b.containsAggregate
        case .negate(let a), .not(let a), .isNull(let a, _): a.containsAggregate
        case .function(_, let arguments): arguments.contains { $0.containsAggregate }
        }
    }

    /// Every column the expression uses, outside aggregates.
    func columnsOutsideAggregates(_ body: (String) -> Void) {
        switch self {
        case .column(let id, _): body(id)
        case .aggregate, .literal: break
        case .arithmetic(_, let a, let b), .compare(_, let a, let b), .and(let a, let b), .or(let a, let b), .textTest(_, let a, let b):
            a.columnsOutsideAggregates(body)
            b.columnsOutsideAggregates(body)
        case .negate(let a), .not(let a), .isNull(let a, _): a.columnsOutsideAggregates(body)
        case .function(_, let arguments): arguments.forEach { $0.columnsOutsideAggregates(body) }
        }
    }

    /// The expression as text, with column identifiers: the key for matching ORDER BY, LABEL and FORMAT
    /// items to selected columns.
    var text: String {
        switch self {
        case .column(let id, _): return id
        case .literal(let value):
            switch value {
            case .text(let text): return "'\(text)'"
            case .number(let number): return NumberText.general(number)
            case .boolean(let boolean): return boolean ? "true" : "false"
            default: return "null"
            }
        case .arithmetic(let op, let a, let b): return "\(a.text)\(op)\(b.text)"
        case .negate(let a): return "-\(a.text)"
        case .compare(let op, let a, let b): return "\(a.text)\(op)\(b.text)"
        case .and(let a, let b): return "\(a.text) and \(b.text)"
        case .or(let a, let b): return "\(a.text) or \(b.text)"
        case .not(let a): return "not \(a.text)"
        case .isNull(let a, let negated): return "\(a.text) is \(negated ? "not " : "")null"
        case .textTest(let op, let a, let b): return "\(a.text) \(op) \(b.text)"
        case .function(let name, let arguments): return "\(name)(\(arguments.map(\.text).joined(separator: ", ")))"
        case .aggregate(let name, let argument): return "\(name)(\(argument.text))"
        }
    }

    /// The same expression with column identifiers resolved to indexes; nil (with the identifier) for unknown columns.
    func resolved(_ lookup: (String) -> Int?) -> Result<QueryNode, QueryError> {
        func map(_ node: QueryNode) throws -> QueryNode {
            switch node {
            case .column(let id, _):
                guard let index = lookup(id) else { throw QueryError("NO_COLUMN: \(id)") }
                return .column(id, index: index)
            case .literal: return node
            case .arithmetic(let op, let a, let b): return .arithmetic(op, try map(a), try map(b))
            case .negate(let a): return .negate(try map(a))
            case .compare(let op, let a, let b): return .compare(op, try map(a), try map(b))
            case .and(let a, let b): return .and(try map(a), try map(b))
            case .or(let a, let b): return .or(try map(a), try map(b))
            case .not(let a): return .not(try map(a))
            case .isNull(let a, let negated): return .isNull(try map(a), negated: negated)
            case .textTest(let op, let a, let b): return .textTest(op, try map(a), try map(b))
            case .function(let name, let arguments): return .function(name, try arguments.map(map))
            case .aggregate(let name, let argument): return .aggregate(name, try map(argument))
            }
        }
        do {
            return .success(try map(self))
        } catch let error as QueryError {
            return .failure(error)
        } catch {
            return .failure(QueryError("INTERNAL"))
        }
    }
}

/// A problem with the query: the text after "Unable to parse query string for Function QUERY parameter 2: ".
struct QueryError: Error {
    var detail: String
    init(_ detail: String) { self.detail = detail }
}

/// A parsed query: its clauses, in the order a query writes them.
struct QueryStatement {
    /// nil: `select *` (or no select clause).
    var select: [QueryNode]?
    var filter: QueryNode?
    var groupBy: [QueryNode] = []
    var pivot: [QueryNode] = []
    var orderBy: [(node: QueryNode, ascending: Bool)] = []
    var limit: Int?
    var offset = 0
    var labels: [(node: QueryNode, label: String)] = []
    var formats: [(node: QueryNode, pattern: String)] = []
}

/// Reads query text: select, where, group by, pivot, order by, limit, offset, label, format and options
/// clauses, in that order; keywords ignore case.
struct QueryParser {
    private enum Token: Equatable {
        case word(String)
        /// A `back-quoted` identifier.
        case quoted(String)
        case number(Double)
        case string(String)
        case symbol(String)
    }

    private var tokens: [(token: Token, column: Int)] = []
    private var position = 0
    private let length: Int

    private static let keywords: Set<String> = [
        "SELECT", "WHERE", "GROUP", "BY", "PIVOT", "ORDER", "ASC", "DESC", "LIMIT", "OFFSET", "LABEL", "FORMAT", "OPTIONS",
        "AND", "OR", "NOT", "IS", "NULL", "CONTAINS", "STARTS", "ENDS", "WITH", "MATCHES", "LIKE", "TRUE", "FALSE",
        "DATE", "DATETIME", "TIMEOFDAY", "TIMESTAMP",
    ]
    static let aggregates: Set<String> = ["SUM", "AVG", "COUNT", "MAX", "MIN"]
    static let functions: Set<String> = ["YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "MILLISECOND", "QUARTER", "DAYOFWEEK",
                                         "NOW", "TODATE", "DATEDIFF", "UPPER", "LOWER"]

    static func parse(_ text: String) -> Result<QueryStatement, QueryError> {
        var parser = QueryParser(length: text.count)
        do {
            parser.tokens = try Self.tokenize(text)
            return .success(try parser.statement())
        } catch let error as QueryError {
            return .failure(error)
        } catch {
            return .failure(QueryError("PARSE_ERROR"))
        }
    }

    private init(length: Int) {
        self.length = length
    }

    // MARK: Tokens

    private static func tokenize(_ text: String) throws -> [(token: Token, column: Int)] {
        let characters = Array(text)
        var result: [(token: Token, column: Int)] = []
        var i = 0
        while i < characters.count {
            let c = characters[i]
            let start = i
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                i += 1
                var value = ""
                while i < characters.count, characters[i] != c {
                    value.append(characters[i])
                    i += 1
                }
                guard i < characters.count else { throw QueryError("PARSE_ERROR: Encountered unterminated string at line 1, column \(start + 1).") }
                i += 1
                result.append((c == "`" ? .quoted(value) : .string(value), start + 1))
                continue
            }
            if c.isNumber || (c == "." && i + 1 < characters.count && characters[i + 1].isNumber) {
                while i < characters.count, characters[i].isNumber || characters[i] == "." { i += 1 }
                if i < characters.count, characters[i] == "e" || characters[i] == "E" {
                    var j = i + 1
                    if j < characters.count, characters[j] == "+" || characters[j] == "-" { j += 1 }
                    if j < characters.count, characters[j].isNumber {
                        i = j
                        while i < characters.count, characters[i].isNumber { i += 1 }
                    }
                }
                guard let number = Double(String(characters[start..<i])) else {
                    throw QueryError("PARSE_ERROR: Encountered \"\(String(characters[start..<i]))\" at line 1, column \(start + 1).")
                }
                result.append((.number(number), start + 1))
                continue
            }
            if c.isLetter || c == "_" {
                while i < characters.count, characters[i].isLetter || characters[i].isNumber || characters[i] == "_" { i += 1 }
                result.append((.word(String(characters[start..<i])), start + 1))
                continue
            }
            let two = i + 1 < characters.count ? String([c, characters[i + 1]]) : ""
            if ["!=", "<>", "<=", ">="].contains(two) {
                result.append((.symbol(two == "<>" ? "!=" : two), start + 1))
                i += 2
                continue
            }
            guard "*,()+-/=<>".contains(c) else {
                throw QueryError("PARSE_ERROR: Encountered \"\(c)\" at line 1, column \(start + 1).")
            }
            result.append((.symbol(String(c)), start + 1))
            i += 1
        }
        return result
    }

    // MARK: Grammar helpers

    private var current: Token? { position < tokens.count ? tokens[position].token : nil }

    private func isKeyword(_ keyword: String, at offset: Int = 0) -> Bool {
        guard position + offset < tokens.count, case .word(let word) = tokens[position + offset].token else { return false }
        return word.uppercased() == keyword
    }

    private func unexpected() -> QueryError {
        guard position < tokens.count else { return QueryError("PARSE_ERROR: Encountered \"<EOF>\" at line 1, column \(length + 1).") }
        let found: String
        switch tokens[position].token {
        case .word(let word): found = word
        case .quoted(let name): found = "`\(name)`"
        case .number(let number): found = NumberText.general(number)
        case .string(let text): found = "'\(text)'"
        case .symbol(let symbol): found = symbol
        }
        return QueryError("PARSE_ERROR: Encountered \"\(found)\" at line 1, column \(tokens[position].column).")
    }

    private mutating func accept(_ keyword: String) -> Bool {
        guard isKeyword(keyword) else { return false }
        position += 1
        return true
    }

    private mutating func expect(_ keyword: String) throws {
        guard accept(keyword) else { throw unexpected() }
    }

    private mutating func acceptSymbol(_ symbol: String) -> Bool {
        guard current == .symbol(symbol) else { return false }
        position += 1
        return true
    }

    // MARK: Clauses

    private mutating func statement() throws -> QueryStatement {
        var query = QueryStatement()
        if accept("SELECT") {
            if acceptSymbol("*") {
                query.select = nil
            } else {
                query.select = try list()
            }
        }
        if accept("WHERE") { query.filter = try expression() }
        if accept("GROUP") {
            try expect("BY")
            query.groupBy = try list()
        }
        if accept("PIVOT") { query.pivot = try list() }
        if accept("ORDER") {
            try expect("BY")
            repeat {
                let node = try expression()
                var ascending = true
                if accept("DESC") { ascending = false } else { _ = accept("ASC") }
                query.orderBy.append((node, ascending))
            } while acceptSymbol(",")
        }
        if accept("LIMIT") { query.limit = try count() }
        if accept("OFFSET") { query.offset = try count() }
        if accept("LABEL") {
            repeat {
                let node = try expression()
                guard case .string(let label)? = current else { throw unexpected() }
                position += 1
                query.labels.append((node, label))
            } while acceptSymbol(",")
        }
        if accept("FORMAT") {
            repeat {
                let node = try expression()
                guard case .string(let pattern)? = current else { throw unexpected() }
                position += 1
                query.formats.append((node, pattern))
            } while acceptSymbol(",")
        }
        if accept("OPTIONS") {
            // no_values, no_format: nothing to do for a spreadsheet.
            while case .word? = current { position += 1 }
        }
        guard position == tokens.count else { throw unexpected() }
        return query
    }

    private mutating func list() throws -> [QueryNode] {
        var nodes = [try expression()]
        while acceptSymbol(",") { nodes.append(try expression()) }
        return nodes
    }

    private mutating func count() throws -> Int {
        guard case .number(let number)? = current, number >= 0, number == number.rounded() else { throw unexpected() }
        position += 1
        return Int(min(number, Double(Int32.max)))
    }

    // MARK: Expressions

    private mutating func expression() throws -> QueryNode {
        var node = try conjunction()
        while accept("OR") { node = .or(node, try conjunction()) }
        return node
    }

    private mutating func conjunction() throws -> QueryNode {
        var node = try negation()
        while accept("AND") { node = .and(node, try negation()) }
        return node
    }

    private mutating func negation() throws -> QueryNode {
        if accept("NOT") { return .not(try negation()) }
        return try comparison()
    }

    private mutating func comparison() throws -> QueryNode {
        let lhs = try additive()
        if case .symbol(let symbol)? = current, ["=", "!=", "<", ">", "<=", ">="].contains(symbol) {
            position += 1
            return .compare(symbol, lhs, try additive())
        }
        if accept("IS") {
            let negated = accept("NOT")
            try expect("NULL")
            return .isNull(lhs, negated: negated)
        }
        if accept("CONTAINS") { return .textTest("contains", lhs, try additive()) }
        if accept("MATCHES") { return .textTest("matches", lhs, try additive()) }
        if accept("LIKE") { return .textTest("like", lhs, try additive()) }
        if accept("STARTS") {
            try expect("WITH")
            return .textTest("starts with", lhs, try additive())
        }
        if accept("ENDS") {
            try expect("WITH")
            return .textTest("ends with", lhs, try additive())
        }
        return lhs
    }

    private mutating func additive() throws -> QueryNode {
        var node = try multiplicative()
        while case .symbol(let symbol)? = current, symbol == "+" || symbol == "-" {
            position += 1
            node = .arithmetic(Character(symbol), node, try multiplicative())
        }
        return node
    }

    private mutating func multiplicative() throws -> QueryNode {
        var node = try unary()
        while case .symbol(let symbol)? = current, symbol == "*" || symbol == "/" {
            position += 1
            node = .arithmetic(Character(symbol), node, try unary())
        }
        return node
    }

    private mutating func unary() throws -> QueryNode {
        if acceptSymbol("-") { return .negate(try unary()) }
        return try primary()
    }

    private mutating func primary() throws -> QueryNode {
        guard let token = current else { throw unexpected() }
        switch token {
        case .number(let number):
            position += 1
            return .literal(.number(number))
        case .string(let text):
            position += 1
            return .literal(.text(text))
        case .quoted(let name):
            position += 1
            return .column(name, index: nil)
        case .symbol("("):
            position += 1
            let node = try expression()
            guard acceptSymbol(")") else { throw unexpected() }
            return node
        case .word(let word):
            let upper = word.uppercased()
            if upper == "TRUE" || upper == "FALSE" {
                position += 1
                return .literal(.boolean(upper == "TRUE"))
            }
            if ["DATE", "DATETIME", "TIMEOFDAY", "TIMESTAMP"].contains(upper), position + 1 < tokens.count,
               case .string(let text) = tokens[position + 1].token {
                guard let serial = Self.dateLiteral(upper, text) else {
                    throw QueryError("PARSE_ERROR: Invalid \(word.lowercased()) literal [\(text)]. Expected a value like \(Self.example(upper)).")
                }
                position += 2
                return .literal(.number(serial))
            }
            if tokens.indices.contains(position + 1), tokens[position + 1].token == .symbol("(") {
                position += 2
                var arguments: [QueryNode] = []
                if !acceptSymbol(")") {
                    if Self.aggregates.contains(upper), upper == "COUNT", acceptSymbol("*") {
                        throw QueryError("PARSE_ERROR: Encountered \"*\" at line 1, column \(tokens[position - 1].column).")
                    }
                    arguments = try list()
                    guard acceptSymbol(")") else { throw unexpected() }
                }
                if Self.aggregates.contains(upper) {
                    guard arguments.count == 1 else { throw QueryError("PARSE_ERROR: Function \(word.lowercased()) takes one argument.") }
                    return .aggregate(word.lowercased(), arguments[0])
                }
                guard Self.functions.contains(upper) else { throw QueryError("PARSE_ERROR: Unknown function \(word.lowercased()).") }
                return .function(word.lowercased(), arguments)
            }
            guard !Self.keywords.contains(upper) else { throw unexpected() }
            position += 1
            return .column(word, index: nil)
        default:
            throw unexpected()
        }
    }

    /// date 'yyyy-mm-dd', datetime 'yyyy-mm-dd HH:mm:ss[.sss]', timeofday 'HH:mm:ss[.sss]' as serial numbers.
    private static func dateLiteral(_ kind: String, _ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        func date(_ part: Substring) -> Double? {
            let fields = part.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3, let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
                  (1...12).contains(month), (1...DateSerial.daysInMonth(year: year, month: month)).contains(day) else { return nil }
            return DateSerial.serial(year: year, month: month, day: day)
        }
        func time(_ part: Substring) -> Double? {
            let fields = part.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2 || fields.count == 3, let hour = Int(fields[0]), let minute = Int(fields[1]),
                  (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
            let second = fields.count == 3 ? Double(fields[2]) : 0
            guard let second, second >= 0, second < 60 else { return nil }
            return DateSerial.time(hour: hour, minute: minute, second: second)
        }
        switch kind {
        case "DATE": return date(Substring(trimmed))
        case "TIMEOFDAY": return time(Substring(trimmed))
        default:
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let day = date(parts[0]), let clock = time(parts[1]) else { return nil }
            return day + clock
        }
    }

    private static func example(_ kind: String) -> String {
        switch kind {
        case "DATE": "'2024-01-31'"
        case "TIMEOFDAY": "'13:45:00'"
        default: "'2024-01-31 13:45:00'"
        }
    }
}
