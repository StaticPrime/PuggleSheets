import Foundation

/// A block of values in row-major order: array literals, materialized ranges and array results.
/// Always at least 1 × 1.
struct ValueMatrix: Hashable, Sendable {
    private(set) var rows: Int
    private(set) var columns: Int
    var values: [CellValue]

    init(rows: Int, columns: Int, values: [CellValue]) {
        precondition(rows > 0 && columns > 0 && values.count == rows * columns, "Invalid matrix shape")
        self.rows = rows
        self.columns = columns
        self.values = values
    }

    init(rows: Int, columns: Int, repeating value: CellValue = .empty) {
        self.init(rows: rows, columns: columns, values: Array(repeating: value, count: rows * columns))
    }

    init(_ value: CellValue) {
        self.init(rows: 1, columns: 1, values: [value])
    }

    init(column: [CellValue]) {
        self.init(rows: column.count, columns: 1, values: column)
    }

    init(row: [CellValue]) {
        self.init(rows: 1, columns: row.count, values: row)
    }

    /// Rows of equal length.
    init(rowList: [[CellValue]]) {
        self.init(rows: rowList.count, columns: rowList[0].count, values: rowList.flatMap { $0 })
    }

    subscript(row: Int, column: Int) -> CellValue {
        get { values[row * columns + column] }
        set { values[row * columns + column] = newValue }
    }

    var count: Int { values.count }
    var isSingle: Bool { values.count == 1 }

    func row(_ index: Int) -> [CellValue] { Array(values[(index * columns)..<((index + 1) * columns)]) }

    func column(_ index: Int) -> [CellValue] {
        (0..<rows).map { values[$0 * columns + index] }
    }

    var transposed: ValueMatrix {
        var result = ValueMatrix(rows: columns, columns: rows)
        for row in 0..<rows {
            for column in 0..<columns { result[column, row] = self[row, column] }
        }
        return result
    }

    /// The element at (row, column) when this matrix is stretched to a bigger shape: a dimension of size 1
    /// repeats, positions beyond a longer dimension are #N/A.
    func broadcastValue(row: Int, column: Int) -> CellValue {
        let r = rows == 1 ? 0 : row
        let c = columns == 1 ? 0 : column
        guard r < rows, c < columns else { return .error(FormulaErrors.arrayMismatch) }
        return values[r * columns + c]
    }

    /// The shape two matrices broadcast to.
    static func broadcastShape(_ shapes: [(rows: Int, columns: Int)]) -> (rows: Int, columns: Int) {
        (shapes.map(\.rows).max() ?? 1, shapes.map(\.columns).max() ?? 1)
    }

    func map(_ transform: (CellValue) -> CellValue) -> ValueMatrix {
        ValueMatrix(rows: rows, columns: columns, values: values.map(transform))
    }
}

/// A resolved reference: a block of a sheet, by sheet index. Always inside the sheet's grid.
struct SheetReference: Hashable, Sendable {
    var sheet: Int
    var range: CellRange
}

/// What an expression evaluates to.
enum FormulaValue {
    case value(CellValue)
    case array(ValueMatrix)
    case reference(SheetReference)
    /// A LAMBDA waiting to be called.
    case lambda(Lambda)

    /// A number result; NaN and infinities become #NUM!.
    static func number(_ number: Double) -> FormulaValue {
        guard number.isFinite else { return .value(.error(FormulaErrors.notFinite)) }
        return .value(.number(number == 0 ? 0 : number))
    }

    static func text(_ text: String) -> FormulaValue { .value(.text(text)) }
    static func boolean(_ boolean: Bool) -> FormulaValue { .value(.boolean(boolean)) }
    static func error(_ kind: CellError.Kind, _ message: String? = nil) -> FormulaValue {
        .value(.error(CellError(kind, message)))
    }
    static func error(_ error: CellError) -> FormulaValue { .value(.error(error)) }

    var errorValue: CellError? {
        if case .value(.error(let error)) = self { return error }
        return nil
    }
}

/// A LAMBDA's parameters and body, with the LET and LAMBDA names in effect where it was made.
final class Lambda {
    /// Uppercased.
    let parameters: [String]
    let body: Expr
    let scope: Scope?

    init(parameters: [String], body: Expr, scope: Scope?) {
        self.parameters = parameters
        self.body = body
        self.scope = scope
    }

    /// What a LAMBDA left uncalled shows: it is called with no arguments.
    var uncalledError: CellError { FormulaErrors.lambdaArguments(expected: parameters.count, got: 0) }
}

/// Names bound by LET and LAMBDA, innermost frame first.
final class Scope {
    enum Binding {
        case value(FormulaValue)
        /// A LAMBDA argument left empty in the call (ISOMITTED is TRUE for it).
        case omitted
    }

    /// Uppercased names.
    let bindings: [String: Binding]
    let parent: Scope?

    init(_ bindings: [String: Binding], parent: Scope?) {
        self.bindings = bindings
        self.parent = parent
    }

    func lookup(_ name: String) -> Binding? {
        let key = name.uppercased()
        var frame: Scope? = self
        while let current = frame {
            if let binding = current.bindings[key] { return binding }
            frame = current.parent
        }
        return nil
    }
}

/// What a formula cell shows besides its value: a HYPERLINK's link or a SPARKLINE's chart.
enum CellDecoration: Equatable {
    case link(String)
    case sparkline(SparklineSpec)
}

/// Errors and the messages shown for them.
enum FormulaErrors {
    static let circularMessage = "Circular dependency detected. To resolve with iterative calculation, see File > Settings."
    static let circular = CellError(.reference, circularMessage)
    static let parse = CellError(.parse, "Formula parse error.")
    static let notFinite = CellError(.number, "The result is too large or is not a number.")
    static let arrayMismatch = CellError(.notAvailable, "Array arguments are of different size.")
    static let outOfGrid = CellError(.reference, "Reference does not exist.")
    static let divideByZero = CellError(.divideByZero, "Function DIVIDE parameter 2 cannot be zero.")
    static let notAvailable = CellError(.notAvailable, "Value not available.")

    static func unknownFunction(_ name: String) -> CellError {
        CellError(.name, "Unknown function: '\(name)'.")
    }

    static func lambdaArguments(expected: Int, got: Int) -> CellError {
        CellError(.notAvailable, "Wrong number of arguments to LAMBDA. Expected \(expected) arguments, but got \(got) arguments.")
    }

    static let lambdaDepth = CellError(.number, "Too many nested LAMBDA calls.")

    static func unknownName(_ name: String) -> CellError {
        CellError(.name, "Unknown range name: '\(name)'.")
    }

    static func unresolvedSheet(_ name: String) -> CellError {
        CellError(.reference, "Unresolved sheet name '\(name)'.")
    }

    static func argumentCount(_ name: String, min: Int, max: Int, got: Int) -> CellError {
        let expected: String
        if min == max {
            expected = "Expected \(min) arguments"
        } else if max == Int.max {
            expected = "Expected at least \(min) arguments"
        } else {
            expected = "Expected between \(min) and \(max) arguments"
        }
        return CellError(.notAvailable, "Wrong number of arguments to \(name). \(expected), but got \(got) arguments.")
    }

    static func notNumber(_ text: String, function: String, parameter: Int) -> CellError {
        CellError(.value, "Function \(function) parameter \(parameter) expects number values. But '\(text)' is a text and cannot be coerced to a number.")
    }

    static func notBoolean(_ text: String, function: String, parameter: Int) -> CellError {
        CellError(.value, "Function \(function) parameter \(parameter) expects boolean values. But '\(text)' is a text and cannot be coerced to a boolean.")
    }

    static func value(_ message: String) -> CellError { CellError(.value, message) }
    static func number(_ message: String) -> CellError { CellError(.number, message) }

    static func notFound(_ key: CellValue, function: String) -> CellError {
        CellError(.notAvailable, "Did not find value '\(Coercion.displayText(key))' in \(function) evaluation.")
    }

    static func divideByZero(_ function: String) -> CellError {
        CellError(.divideByZero, "Evaluation of function \(function) caused a divide by zero error.")
    }
}

/// Conversion and comparison rules.
enum Coercion {
    static let locale = Locale(identifier: "en_US")

    /// A value used as a number: empty is 0, booleans 1/0, text parsed as typed input.
    static func number(_ value: CellValue, function: String, parameter: Int) throws -> Double {
        switch value {
        case .number(let number): return number
        case .empty: return 0
        case .boolean(let boolean): return boolean ? 1 : 0
        case .text(let text):
            if let number = number(fromText: text) { return number }
            throw FormulaErrors.notNumber(text, function: function, parameter: parameter)
        case .error(let error): throw error
        }
    }

    /// The number a text stands for ("" is 0), or nil.
    static func number(fromText text: String) -> Double? {
        if text.isEmpty { return 0 }
        guard let number = InputParser.number(from: text), number.isFinite else { return nil }
        return number
    }

    /// A value used as text: numbers as formulas print them, booleans TRUE/FALSE, empty "".
    static func text(_ value: CellValue) throws -> String {
        switch value {
        case .text(let text): return text
        case .number(let number): return NumberText.general(number)
        case .boolean(let boolean): return boolean ? "TRUE" : "FALSE"
        case .empty: return ""
        case .error(let error): throw error
        }
    }

    /// The text shown for a value in messages.
    static func displayText(_ value: CellValue) -> String {
        switch value {
        case .error(let error): return error.code
        default: return (try? text(value)) ?? ""
        }
    }

    /// A value used as a condition: numbers are true unless zero, "TRUE"/"FALSE" text is accepted.
    static func boolean(_ value: CellValue, function: String, parameter: Int) throws -> Bool {
        switch value {
        case .boolean(let boolean): return boolean
        case .number(let number): return number != 0
        case .empty: return false
        case .text(let text):
            if text.caseInsensitiveCompare("TRUE") == .orderedSame { return true }
            if text.caseInsensitiveCompare("FALSE") == .orderedSame { return false }
            throw FormulaErrors.notBoolean(text, function: function, parameter: parameter)
        case .error(let error): throw error
        }
    }

    /// Sort order: numbers < text < booleans; text ignores case; an empty value stands for the
    /// other side's zero value (0, "" or FALSE). Errors sort last. Returns -1, 0 or 1.
    static func compare(_ a: CellValue, _ b: CellValue) -> Int {
        switch (a, b) {
        case (.empty, .empty): return 0
        case (.empty, _): return compare(zeroValue(like: b), b)
        case (_, .empty): return compare(a, zeroValue(like: a))
        case (.number(let x), .number(let y)): return compareNumbers(x, y)
        case (.text(let x), .text(let y)): return compareText(x, y)
        case (.boolean(let x), .boolean(let y)): return x == y ? 0 : (x ? 1 : -1)
        default:
            let left = rank(a), right = rank(b)
            return left == right ? 0 : (left < right ? -1 : 1)
        }
    }

    static func rank(_ value: CellValue) -> Int {
        switch value {
        case .empty: 0
        case .number: 1
        case .text: 2
        case .boolean: 3
        case .error: 4
        }
    }

    private static func zeroValue(like value: CellValue) -> CellValue {
        switch value {
        case .text: .text("")
        case .boolean: .boolean(false)
        default: .number(0)
        }
    }

    /// Numbers that agree to about 15 significant digits are equal, so 0.1+0.2 equals 0.3 as in Sheets.
    static func compareNumbers(_ x: Double, _ y: Double) -> Int {
        if x == y { return 0 }
        if abs(x - y) <= max(abs(x), abs(y)) * 1e-15 { return 0 }
        return x < y ? -1 : 1
    }

    /// Case-insensitive, locale-aware text order.
    static func compareText(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        switch a.compare(b, options: [.caseInsensitive], range: nil, locale: locale) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    /// Case-insensitive text equality.
    static func textEquals(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if isASCII(a), isASCII(b) {
            guard a.utf8.count == b.utf8.count else { return false }
            return zip(a.utf8, b.utf8).allSatisfy { lowercaseASCII($0) == lowercaseASCII($1) }
        }
        return a.lowercased() == b.lowercased()
    }

    @inline(__always) private static func lowercaseASCII(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    static func isASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 }
    }

    /// Equality as the = operator sees it.
    static func equals(_ a: CellValue, _ b: CellValue) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): return textEquals(x, y)
        default: return compare(a, b) == 0
        }
    }
}
