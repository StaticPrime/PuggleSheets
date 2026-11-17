import Foundation

enum FormulaOperator: Sendable, Equatable {
    case add, subtract, multiply, divide, power, concatenate
    case equal, notEqual, less, greater, lessOrEqual, greaterOrEqual
    case percent

    var isComparison: Bool {
        switch self {
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual: true
        default: false
        }
    }

    /// The function name used in messages about this operator.
    var functionName: String {
        switch self {
        case .add: "ADD"
        case .subtract: "MINUS"
        case .multiply: "MULTIPLY"
        case .divide: "DIVIDE"
        case .power: "POW"
        case .concatenate: "CONCAT"
        case .equal: "EQ"
        case .notEqual: "NE"
        case .less: "LT"
        case .greater: "GT"
        case .lessOrEqual: "LTE"
        case .greaterOrEqual: "GTE"
        case .percent: "UNARY_PERCENT"
        }
    }
}

/// A structured reference as written: the table's name and the text between the outer brackets.
final class TableToken: Sendable, Equatable {
    let table: String
    let spec: String

    init(table: String, spec: String) {
        self.table = table
        self.spec = spec
    }

    static func == (lhs: TableToken, rhs: TableToken) -> Bool { lhs.table == rhs.table && lhs.spec == rhs.spec }
}

struct FormulaToken: Sendable {
    enum Kind: Sendable, Equatable {
        case number(Double)
        case string(String)
        /// Letters, digits, "_", ".", "$": function names, references, sheet names, TRUE/FALSE.
        case word(String)
        /// A 'quoted' sheet name, unquoted.
        case quotedName(String)
        /// A table name followed by brackets: "Table1[Sales]". (Boxed, so tokens stay small: the parser
        /// keeps several on the stack per nesting level.)
        case tableReference(TableToken)
        case error(CellError.Kind)
        case op(FormulaOperator)
        case leftParen, rightParen, leftBrace, rightBrace, comma, semicolon, colon, bang
    }

    var kind: Kind
    /// UTF-16 offsets in the formula text.
    var start: Int
    var end: Int
    /// A number written with digits only (usable as a row reference such as 1:5).
    var isInteger = false

    var word: String? {
        if case .word(let word) = kind { return word }
        return nil
    }
}

/// Splits formula text into tokens, keeping UTF-16 positions.
enum FormulaLexer {
    /// The tokens of `units` from `start`, and whether the whole text could be read. On a lexing
    /// failure the tokens read so far are returned.
    static func tokenize(_ units: [UInt16], from start: Int) -> (tokens: [FormulaToken], complete: Bool) {
        var tokens: [FormulaToken] = []
        tokens.reserveCapacity(8)
        var i = start
        let n = units.count

        func add(_ kind: FormulaToken.Kind, _ begin: Int, _ end: Int) {
            tokens.append(FormulaToken(kind: kind, start: begin, end: end))
        }

        while i < n {
            let c = units[i]
            let begin = i
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D, 0xA0:
                i += 1
            case 0x22, 0x27: // " or '
                var text: [UInt16] = []
                i += 1
                var closed = false
                while i < n {
                    if units[i] == c {
                        if i + 1 < n, units[i + 1] == c {
                            text.append(c)
                            i += 2
                            continue
                        }
                        i += 1
                        closed = true
                        break
                    }
                    text.append(units[i])
                    i += 1
                }
                guard closed else { return (tokens, false) }
                let string = String(decoding: text, as: UTF16.self)
                add(c == 0x22 ? .string(string) : .quotedName(string), begin, i)
            case 0x23: // #
                guard let (kind, length) = errorCode(units, at: i) else { return (tokens, false) }
                i += length
                add(.error(kind), begin, i)
            case 0x30...0x39, 0x2E:
                if c == 0x2E, !(i + 1 < n && isDigit(units[i + 1])) { return (tokens, false) }
                var isInteger = true
                while i < n, isDigit(units[i]) { i += 1 }
                if i < n, units[i] == 0x2E {
                    isInteger = false
                    i += 1
                    while i < n, isDigit(units[i]) { i += 1 }
                }
                if i < n, units[i] == 0x45 || units[i] == 0x65 { // e E
                    var j = i + 1
                    if j < n, units[j] == 0x2B || units[j] == 0x2D { j += 1 }
                    if j < n, isDigit(units[j]) {
                        isInteger = false
                        i = j
                        while i < n, isDigit(units[i]) { i += 1 }
                    }
                }
                let text = String(decoding: units[begin..<i], as: UTF16.self)
                guard let number = Double(text) else { return (tokens, false) }
                tokens.append(FormulaToken(kind: .number(number), start: begin, end: i, isInteger: isInteger))
            case 0x28: i += 1; add(.leftParen, begin, i)
            case 0x29: i += 1; add(.rightParen, begin, i)
            case 0x7B: i += 1; add(.leftBrace, begin, i)
            case 0x7D: i += 1; add(.rightBrace, begin, i)
            case 0x2C: i += 1; add(.comma, begin, i)
            case 0x3B: i += 1; add(.semicolon, begin, i)
            case 0x3A: i += 1; add(.colon, begin, i)
            case 0x21: i += 1; add(.bang, begin, i)
            case 0x2B: i += 1; add(.op(.add), begin, i)
            case 0x2D: i += 1; add(.op(.subtract), begin, i)
            case 0x2A: i += 1; add(.op(.multiply), begin, i)
            case 0x2F: i += 1; add(.op(.divide), begin, i)
            case 0x5E: i += 1; add(.op(.power), begin, i)
            case 0x26: i += 1; add(.op(.concatenate), begin, i)
            case 0x25: i += 1; add(.op(.percent), begin, i)
            case 0x3D: i += 1; add(.op(.equal), begin, i)
            case 0x3C: // <
                if i + 1 < n, units[i + 1] == 0x3D {
                    i += 2; add(.op(.lessOrEqual), begin, i)
                } else if i + 1 < n, units[i + 1] == 0x3E {
                    i += 2; add(.op(.notEqual), begin, i)
                } else {
                    i += 1; add(.op(.less), begin, i)
                }
            case 0x3E: // >
                if i + 1 < n, units[i + 1] == 0x3D {
                    i += 2; add(.op(.greaterOrEqual), begin, i)
                } else {
                    i += 1; add(.op(.greater), begin, i)
                }
            default:
                guard isWordStart(c) else { return (tokens, false) }
                while i < n, isWordPart(units[i]) { i += 1 }
                let word = String(decoding: units[begin..<i], as: UTF16.self)
                guard i < n, units[i] == 0x5B else {
                    add(.word(word), begin, i)
                    continue
                }
                // Table1[Column], Table1[[#HEADERS],[Column]]: everything up to the matching bracket.
                let specStart = i + 1
                var depth = 0
                while i < n {
                    if units[i] == 0x5B { depth += 1 } else if units[i] == 0x5D { depth -= 1 }
                    i += 1
                    if depth == 0 { break }
                }
                guard depth == 0 else { return (tokens, false) }
                add(.tableReference(TableToken(table: word, spec: String(decoding: units[specStart..<(i - 1)], as: UTF16.self))), begin, i)
            }
        }
        return (tokens, true)
    }

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    @inline(__always) static func isASCIILetter(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    static func isWordStart(_ c: UInt16) -> Bool {
        isASCIILetter(c) || c == 0x5F || c == 0x24 || c == 0x5C || (c >= 0x80 && c != 0xA0 && !isSpecialUnicode(c))
    }

    static func isWordPart(_ c: UInt16) -> Bool {
        isWordStart(c) || isDigit(c) || c == 0x2E
    }

    /// Non-ASCII punctuation that never belongs to a name (typographic quotes and spaces).
    private static func isSpecialUnicode(_ c: UInt16) -> Bool {
        (c >= 0x2000 && c <= 0x206F) || c == 0x3000 || c == 0xFEFF
    }

    private static let errorCodes: [(String, CellError.Kind)] = CellError.Kind.allCases
        .map { ($0.rawValue, $0) }
        .sorted { $0.0.count > $1.0.count }

    private static func errorCode(_ units: [UInt16], at index: Int) -> (CellError.Kind, Int)? {
        for (code, kind) in errorCodes {
            let codeUnits = Array(code.utf16)
            guard index + codeUnits.count <= units.count else { continue }
            var matches = true
            for (offset, expected) in codeUnits.enumerated() {
                var actual = units[index + offset]
                if actual >= 0x61 && actual <= 0x7A { actual -= 0x20 }
                if actual != expected { matches = false; break }
            }
            if matches { return (kind, codeUnits.count) }
        }
        return nil
    }
}
