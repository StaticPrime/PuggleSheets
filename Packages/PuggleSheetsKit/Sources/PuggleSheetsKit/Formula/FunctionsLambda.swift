import Foundation

/// LET, LAMBDA and the functions that call LAMBDAs (MAP, REDUCE, SCAN, BYROW, BYCOL, MAKEARRAY).
extension FunctionTable {
    mutating func addLambdaFunctions() {
        // LET(name1, value1, [name2, value2, …], expression): each value can use the names before it.
        addLazy("LET", 3, .max) { a in
            guard a.count % 2 == 1 else {
                return .error(.notAvailable, "Wrong number of arguments to LET. Expected an odd number of arguments, but got \(a.count) arguments.")
            }
            let evaluator = a.evaluator
            let saved = evaluator.scope
            defer { evaluator.scope = saved }
            for index in stride(from: 0, to: a.count - 1, by: 2) {
                guard let name = Self.bindableName(a.expressions[index]) else {
                    return .error(.value, "Argument \(index + 1) of function LET must be a valid name.")
                }
                let value = a.evaluate(index + 1)
                evaluator.scope = Scope([name.uppercased(): .value(value)], parent: evaluator.scope)
            }
            return a.passing(a.count - 1)
        }
        // LAMBDA([name, …], expression): a function value; its body sees the LET and LAMBDA names around it.
        addLazy("LAMBDA", 1, .max) { a in
            var parameters: [String] = []
            for index in 0..<(a.count - 1) {
                guard let name = Self.bindableName(a.expressions[index]) else {
                    return .error(.value, "Argument \(index + 1) of function LAMBDA must be a valid name.")
                }
                let key = name.uppercased()
                guard !parameters.contains(key) else {
                    return .error(.value, "Function LAMBDA has more than one parameter named '\(name)'.")
                }
                parameters.append(key)
            }
            return .lambda(Lambda(parameters: parameters, body: a.expressions[a.count - 1], scope: a.evaluator.scope))
        }
        addLazy("ISOMITTED", 1, 1) { a in
            if case .missing = a.expressions[0] { return .boolean(true) }
            if case .name(let name) = a.expressions[0], case .omitted? = a.evaluator.scope?.lookup(name) { return .boolean(true) }
            return .boolean(false)
        }

        add("MAP", 2, .max) { a in
            let lambda = try Self.lambda(a, a.count - 1)
            let arrays = try (0..<(a.count - 1)).map { try a.matrix($0) }
            guard lambda.parameters.count == arrays.count else {
                throw FormulaErrors.lambdaArguments(expected: lambda.parameters.count, got: arrays.count)
            }
            let rows = arrays[0].rows, columns = arrays[0].columns
            guard arrays.allSatisfy({ $0.rows == rows && $0.columns == columns }) else {
                throw CellError(.value, "Array arguments to MAP are of incompatible size.")
            }
            var results: [CellValue] = []
            results.reserveCapacity(rows * columns)
            for index in 0..<(rows * columns) {
                results.append(Self.single(a.evaluator.call(lambda, arrays.map { .value($0.values[index]) }), a.evaluator))
            }
            return Self.array(results, rows: rows, columns: columns)
        }
        add("REDUCE", 3, 3) { a in
            let lambda = try Self.lambda(a, 2, parameters: 2)
            let values = try a.matrix(1).values
            var accumulator = a.values[0]
            for value in values { accumulator = a.evaluator.call(lambda, [accumulator, .value(value)]) }
            return accumulator
        }
        add("SCAN", 3, 3) { a in
            let lambda = try Self.lambda(a, 2, parameters: 2)
            let matrix = try a.matrix(1)
            var accumulator = a.values[0]
            var results: [CellValue] = []
            results.reserveCapacity(matrix.values.count)
            for value in matrix.values {
                accumulator = a.evaluator.call(lambda, [accumulator, .value(value)])
                results.append(Self.single(accumulator, a.evaluator))
            }
            return Self.array(results, rows: matrix.rows, columns: matrix.columns)
        }
        for (name, byRow) in [("BYROW", true), ("BYCOL", false)] {
            add(name, 2, 2) { a in
                let lambda = try Self.lambda(a, 1, parameters: 1)
                let matrix = try a.matrix(0)
                let count = byRow ? matrix.rows : matrix.columns
                var results: [CellValue] = []
                results.reserveCapacity(count)
                for index in 0..<count {
                    let slice = byRow ? ValueMatrix(rows: 1, columns: matrix.columns, values: matrix.row(index))
                        : ValueMatrix(rows: matrix.rows, columns: 1, values: matrix.column(index))
                    let argument: FormulaValue = slice.isSingle ? .value(slice.values[0]) : .array(slice)
                    results.append(Self.single(a.evaluator.call(lambda, [argument]), a.evaluator))
                }
                return byRow ? Self.array(results, rows: count, columns: 1) : Self.array(results, rows: 1, columns: count)
            }
        }
        add("MAKEARRAY", 3, 3) { a in
            let lambda = try Self.lambda(a, 2, parameters: 2)
            let rows = try a.integer(0), columns = try a.integer(1)
            for (index, count) in [(1, rows), (2, columns)] where count < 1 {
                throw CellError(.value, "Function MAKEARRAY parameter \(index) value is \(count). It should be greater than or equal to 1.")
            }
            guard rows * columns <= 10_000_000 else { throw CellError(.value, "Function MAKEARRAY makes an array that is too large.") }
            var results: [CellValue] = []
            results.reserveCapacity(rows * columns)
            for row in 1...rows {
                for column in 1...columns {
                    results.append(Self.single(a.evaluator.call(lambda, [.value(.number(Double(row))), .value(.number(Double(column)))]),
                                               a.evaluator))
                }
            }
            return Self.array(results, rows: rows, columns: columns)
        }
    }

    /// A LET or LAMBDA name: an identifier that isn't a cell reference or TRUE/FALSE.
    static func bindableName(_ expression: Expr) -> String? {
        if case .name(let name) = expression { return name }
        return nil
    }

    /// Argument `index` as a LAMBDA (with `parameters` parameters, when given).
    static func lambda(_ a: Arguments, _ index: Int, parameters: Int? = nil) throws -> Lambda {
        guard case .lambda(let lambda) = a.values[index] else {
            if let error = a.values[index].errorValue { throw error }
            throw CellError(.value, "Argument \(index + 1) of function \(a.name) must be a LAMBDA.")
        }
        if let parameters, lambda.parameters.count != parameters {
            throw FormulaErrors.lambdaArguments(expected: lambda.parameters.count, got: parameters)
        }
        return lambda
    }

    /// A LAMBDA's result as one value of an array being built (arrays there are errors).
    static func single(_ value: FormulaValue, _ evaluator: Evaluator) -> CellValue {
        let nested = CellError(.value, "Single value expected. Nested arrays are not supported.")
        switch value {
        case .value(let value): return Evaluator.finite(value)
        case .array(let matrix): return matrix.isSingle ? Evaluator.finite(matrix.values[0]) : .error(nested)
        case .reference(let reference):
            return reference.range.isSingleCell ? evaluator.cellValue(sheet: reference.sheet, address: reference.range.start) : .error(nested)
        case .lambda(let lambda): return .error(lambda.uncalledError)
        }
    }

    static func array(_ values: [CellValue], rows: Int, columns: Int) -> FormulaValue {
        values.count == 1 ? .value(values[0]) : .array(ValueMatrix(rows: rows, columns: columns, values: values))
    }
}
