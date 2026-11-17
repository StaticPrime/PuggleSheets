import Foundation

/// A spreadsheet function: its argument counts and implementation.
final class FunctionDef: Sendable {
    typealias EagerBody = @Sendable (Arguments) throws -> FormulaValue
    typealias LazyBody = @Sendable (LazyArguments) -> FormulaValue

    enum Body: Sendable {
        /// Receives evaluated arguments; thrown `CellError`s become the result.
        case eager(EagerBody)
        /// Evaluates its arguments itself (IF evaluates only the chosen branch).
        case lazy(LazyBody)
    }

    let name: String
    let minArguments: Int
    let maxArguments: Int
    /// Arguments (bit per position, the last bit standing for all later ones) that take single values:
    /// arrays passed there make the function run once per element.
    let liftMask: UInt64
    /// Arguments whose references are used for their position only (ROW(A1)), not their values.
    let positionalMask: UInt64
    let isVolatile: Bool
    let body: Body

    init(name: String, minArguments: Int, maxArguments: Int, liftMask: UInt64, positionalMask: UInt64,
         isVolatile: Bool, body: Body) {
        self.name = name
        self.minArguments = minArguments
        self.maxArguments = maxArguments
        self.liftMask = liftMask
        self.positionalMask = positionalMask
        self.isVolatile = isVolatile
        self.body = body
    }

    func lifts(_ index: Int) -> Bool { liftMask & (1 << UInt64(min(index, 63))) != 0 }
    func isPositional(_ index: Int) -> Bool { positionalMask & (1 << UInt64(min(index, 63))) != 0 }
}

/// Bit masks naming argument positions.
enum Params {
    static let all = UInt64.max
    static let none: UInt64 = 0

    static func at(_ indices: Int...) -> UInt64 {
        indices.reduce(0) { $0 | (1 << UInt64($1)) }
    }

    /// Positions `start` and later.
    static func from(_ start: Int) -> UInt64 { UInt64.max << UInt64(start) }
}

/// Builds the function table.
struct FunctionTable {
    private(set) var functions: [String: FunctionDef] = [:]

    mutating func add(_ name: String, _ minArguments: Int, _ maxArguments: Int, lift: UInt64 = Params.none,
                      positional: UInt64 = Params.none, volatile: Bool = false,
                      _ body: @escaping FunctionDef.EagerBody) {
        functions[name] = FunctionDef(name: name, minArguments: minArguments, maxArguments: maxArguments, liftMask: lift,
                                      positionalMask: positional, isVolatile: volatile, body: .eager(body))
    }

    mutating func addLazy(_ name: String, _ minArguments: Int, _ maxArguments: Int,
                          _ body: @escaping FunctionDef.LazyBody) {
        functions[name] = FunctionDef(name: name, minArguments: minArguments, maxArguments: maxArguments, liftMask: 0,
                                      positionalMask: 0, isVolatile: false, body: .lazy(body))
    }

    /// One number in, one number out, lifted over arrays.
    mutating func addMath(_ name: String, _ transform: @escaping @Sendable (Double) throws -> Double) {
        add(name, 1, 1, lift: Params.all) { .number(try transform($0.number(0))) }
    }

    /// Registers `name` under another name too (STDEV.S for STDEV).
    mutating func alias(_ name: String, _ original: String) {
        guard let function = functions[original] else { return }
        functions[name] = FunctionDef(name: name, minArguments: function.minArguments, maxArguments: function.maxArguments,
                                      liftMask: function.liftMask, positionalMask: function.positionalMask,
                                      isVolatile: function.isVolatile, body: function.body)
    }
}

enum FunctionLibrary {
    static let functions: [String: FunctionDef] = {
        var table = FunctionTable()
        table.addMathFunctions()
        table.addStatisticalFunctions()
        table.addLogicalAndInfoFunctions()
        table.addTextFunctions()
        table.addLookupFunctions()
        table.addDateFunctions()
        table.addFinancialAndArrayFunctions()
        table.addLambdaFunctions()
        table.addQueryFunctions()
        table.addSheetsFunctions()
        return table.functions
    }()

    static let names: [String] = functions.keys.sorted()

    static func function(named name: String) -> FunctionDef? {
        var key = name.uppercased()
        for prefix in ["_XLFN.", "_XLWS."] where key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        return functions[key]
    }
}

/// How aggregate functions read values inside ranges and arrays.
enum RangeNumbers {
    /// Only numbers (SUM, AVERAGE): text and booleans are skipped.
    case numbersOnly
    /// Text counts as 0 and booleans as 1/0 (AVERAGEA, MAXA).
    case allValues
}

/// Evaluated arguments of an eager function, with Sheets-style conversions.
struct Arguments {
    let function: FunctionDef
    let values: [FormulaValue]
    let evaluator: Evaluator

    var count: Int { values.count }
    var name: String { function.name }
    func has(_ index: Int) -> Bool { index < values.count }

    /// The argument as one value (top-left of ranges); errors are returned, not thrown.
    func raw(_ index: Int) -> CellValue { evaluator.scalar(values[index]) }

    /// The argument as one value; errors are thrown.
    func scalar(_ index: Int) throws -> CellValue {
        let value = raw(index)
        if case .error(let error) = value { throw error }
        return value
    }

    func number(_ index: Int) throws -> Double {
        try Coercion.number(raw(index), function: name, parameter: index + 1)
    }

    func number(_ index: Int, default defaultValue: Double) throws -> Double {
        has(index) ? try number(index) : defaultValue
    }

    /// A number truncated toward zero.
    func integer(_ index: Int) throws -> Int {
        let number = try number(index)
        guard abs(number) < 1e15 else { throw FormulaErrors.number("Function \(name) parameter \(index + 1) value is too large.") }
        return Int(number.rounded(.towardZero))
    }

    func integer(_ index: Int, default defaultValue: Int) throws -> Int {
        has(index) ? try integer(index) : defaultValue
    }

    func text(_ index: Int) throws -> String { try Coercion.text(raw(index)) }

    func text(_ index: Int, default defaultValue: String) throws -> String {
        has(index) ? try text(index) : defaultValue
    }

    func boolean(_ index: Int) throws -> Bool {
        try Coercion.boolean(raw(index), function: name, parameter: index + 1)
    }

    func boolean(_ index: Int, default defaultValue: Bool) throws -> Bool {
        has(index) ? try boolean(index) : defaultValue
    }

    /// The argument as a block of values; a single error value is thrown.
    func matrix(_ index: Int) throws -> ValueMatrix {
        if let error = values[index].errorValue { throw error }
        return evaluator.matrix(values[index])
    }

    /// The argument as a block, sparse when it is a range.
    func data(_ index: Int) throws -> RangeData {
        if let error = values[index].errorValue { throw error }
        return evaluator.data(values[index])
    }

    func reference(_ index: Int) -> SheetReference? {
        if case .reference(let reference) = values[index] { return reference }
        return nil
    }

    /// Calls `body` with every non-empty value of the arguments in `indices`, row-major inside ranges;
    /// `direct` tells whether the value was passed directly rather than inside a range or array.
    func forEachValue(_ indices: Range<Int>, _ body: (_ value: CellValue, _ direct: Bool, _ index: Int) throws -> Void) throws {
        for index in indices {
            switch values[index] {
            case .value(let value):
                if case .empty = value { continue }
                try body(value, true, index)
            case .array(let matrix):
                for value in matrix.values {
                    if case .empty = value { continue }
                    try body(value, false, index)
                }
            case .lambda(let lambda):
                throw lambda.uncalledError
            case .reference(let reference):
                if reference.range.isSingleCell {
                    let value = evaluator.cellValue(sheet: reference.sheet, address: reference.range.start)
                    if case .empty = value { continue }
                    try body(value, false, index)
                } else {
                    for entry in evaluator.rangeData(reference).entries { try body(entry.value, false, index) }
                }
            }
        }
    }

    /// Calls `body` with the numbers of arguments `indices` the way SUM reads them: direct values are
    /// converted (text that isn't a number is an error), values inside ranges are filtered by `mode`.
    /// The first error found is thrown.
    func forEachNumber(_ indices: Range<Int>, mode: RangeNumbers = .numbersOnly, _ body: (Double) throws -> Void) throws {
        try forEachValue(indices) { value, direct, index in
            switch value {
            case .number(let number): try body(number)
            case .error(let error): throw error
            case .boolean(let boolean):
                if direct || mode == .allValues { try body(boolean ? 1 : 0) }
            case .text:
                if direct {
                    try body(Coercion.number(value, function: name, parameter: index + 1))
                } else if mode == .allValues {
                    try body(0)
                }
            case .empty:
                break
            }
        }
    }

    func numbers(_ indices: Range<Int>, mode: RangeNumbers = .numbersOnly) throws -> [Double] {
        var result: [Double] = []
        try forEachNumber(indices, mode: mode) { result.append($0) }
        return result
    }

    func numbers(from start: Int = 0, mode: RangeNumbers = .numbersOnly) throws -> [Double] {
        try numbers(start..<count, mode: mode)
    }
}

/// Unevaluated arguments of a lazy function.
struct LazyArguments {
    let function: FunctionDef
    let expressions: [Expr]
    let evaluator: Evaluator
    /// Where `passing` notes the link of the argument the function returns.
    let passed: LinkPassing

    var count: Int { expressions.count }
    func evaluate(_ index: Int) -> FormulaValue { evaluator.evaluate(expressions[index]) }

    /// The argument reduced to a value or an array.
    func operand(_ index: Int) -> FormulaValue { evaluator.operand(evaluate(index)) }

    /// Evaluates an argument the function returns as its result, unchanged: a HYPERLINK there keeps its link.
    func passing(_ index: Int) -> FormulaValue {
        let value = evaluate(index)
        passed.decoration = evaluator.currentDecoration
        return value
    }

    /// `operand(index)`, returned as the function's result unchanged.
    func passingOperand(_ index: Int) -> FormulaValue {
        let value = evaluate(index)
        passed.decoration = evaluator.currentDecoration
        return evaluator.operand(value)
    }
}

/// The link or sparkline a lazy function's result carries: set when it returns one of its arguments unchanged.
final class LinkPassing {
    var decoration: CellDecoration?
}
