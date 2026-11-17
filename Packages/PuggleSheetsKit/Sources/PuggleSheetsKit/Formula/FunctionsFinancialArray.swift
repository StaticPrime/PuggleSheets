import Foundation

enum Finance {
    /// (1 + rate)^periods, accurate for small rates.
    static func growth(_ rate: Double, _ periods: Double) -> Double {
        exp(periods * log1p(rate))
    }

    /// ((1 + rate)^periods - 1) / rate, with its limit at rate 0, accurate for small rates.
    static func annuityFactor(_ rate: Double, _ periods: Double) -> Double {
        rate == 0 ? periods : expm1(periods * log1p(rate)) / rate
    }

    /// The future-value balance equation: zero at the right rate.
    static func balance(rate: Double, periods: Double, payment: Double, present: Double, future: Double, type: Double) -> Double {
        present * growth(rate, periods) + payment * (1 + rate * type) * annuityFactor(rate, periods) + future
    }

    /// Newton's method with a numeric derivative. `scale` is the size of the amounts involved, for the
    /// final tolerance check.
    static func solve(guess: Double, scale: Double, _ function: (Double) -> Double) -> Double? {
        var x = guess
        for _ in 0..<200 {
            let y = function(x)
            guard y.isFinite else { return nil }
            let step = 1e-7 * max(1, abs(x))
            let slope = (function(x + step) - y) / step
            guard slope != 0, slope.isFinite else { break }
            let next = x - y / slope
            guard next.isFinite, next > -1 else { return nil }
            if abs(next - x) < 1e-13 * max(1, abs(x)) {
                x = next
                break
            }
            x = next
        }
        return abs(function(x)) <= 1e-9 * max(1, scale) ? x : nil
    }
}

extension FunctionTable {
    mutating func addFinancialAndArrayFunctions() {
        add("FV", 3, 5, lift: Params.all) { a in
            let rate = try a.number(0), periods = try a.number(1), payment = try a.number(2)
            let present = try a.number(3, default: 0), type: Double = try a.number(4, default: 0) != 0 ? 1 : 0
            let growth = Finance.growth(rate, periods)
            return .number(-(present * growth + payment * (1 + rate * type) * Finance.annuityFactor(rate, periods)))
        }
        add("PV", 3, 5, lift: Params.all) { a in
            let rate = try a.number(0), periods = try a.number(1), payment = try a.number(2)
            let future = try a.number(3, default: 0), type: Double = try a.number(4, default: 0) != 0 ? 1 : 0
            let growth = Finance.growth(rate, periods)
            return .number(-(future + payment * (1 + rate * type) * Finance.annuityFactor(rate, periods)) / growth)
        }
        add("PMT", 3, 5, lift: Params.all) { a in
            let rate = try a.number(0), periods = try a.number(1), present = try a.number(2)
            let future = try a.number(3, default: 0), type: Double = try a.number(4, default: 0) != 0 ? 1 : 0
            guard periods != 0 else { throw FormulaErrors.number("Function PMT parameter 2 value is 0. It should not be 0.") }
            let growth = Finance.growth(rate, periods)
            return .number(-(present * growth + future) / ((1 + rate * type) * Finance.annuityFactor(rate, periods)))
        }
        add("NPER", 3, 5, lift: Params.all) { a in
            let rate = try a.number(0), payment = try a.number(1), present = try a.number(2)
            let future = try a.number(3, default: 0), type: Double = try a.number(4, default: 0) != 0 ? 1 : 0
            if rate == 0 {
                guard payment != 0 else { throw FormulaErrors.divideByZero("NPER") }
                return .number(-(present + future) / payment)
            }
            let numerator = payment * (1 + rate * type) - future * rate
            let denominator = payment * (1 + rate * type) + present * rate
            guard denominator != 0, numerator / denominator > 0 else {
                throw FormulaErrors.number("NPER evaluates to an out of range value.")
            }
            return .number(log(numerator / denominator) / log(1 + rate))
        }
        add("RATE", 3, 6, lift: Params.all) { a in
            let periods = try a.number(0), payment = try a.number(1), present = try a.number(2)
            let future = try a.number(3, default: 0), type: Double = try a.number(4, default: 0) != 0 ? 1 : 0
            let guess = try a.number(5, default: 0.1)
            let scale = max(abs(present), abs(future), abs(payment) * abs(periods))
            guard let rate = Finance.solve(guess: guess, scale: scale, {
                Finance.balance(rate: $0, periods: periods, payment: payment, present: present, future: future, type: type)
            }) else {
                throw FormulaErrors.number("RATE attempted to compute an invalid value.")
            }
            return .number(rate)
        }
        add("NPV", 2, .max) { a in
            let rate = try a.number(0)
            guard rate != -1 else { throw FormulaErrors.divideByZero("NPV") }
            var total = 0.0
            var period = 1.0
            try a.forEachNumber(1..<a.count) { value in
                total += value / Foundation.pow(1 + rate, period)
                period += 1
            }
            return .number(total)
        }
        add("IRR", 1, 2) { a in
            let values = try a.numbers(0..<1)
            guard values.contains(where: { $0 > 0 }), values.contains(where: { $0 < 0 }) else {
                throw FormulaErrors.number("IRR attempted to compute an invalid value.")
            }
            let guess = try a.number(1, default: 0.1)
            let scale = values.reduce(0) { $0 + abs($1) }
            guard let rate = Finance.solve(guess: guess, scale: scale, { rate in
                values.enumerated().reduce(0) { $0 + $1.element / Foundation.pow(1 + rate, Double($1.offset)) }
            }) else {
                throw FormulaErrors.number("IRR attempted to compute an invalid value.")
            }
            return .number(rate)
        }

        add("ARRAYFORMULA", 1, 1) { a in a.values[0] }
        add("FILTER", 2, .max) { a in
            let data = try a.matrix(0)
            var keep = [Bool]()
            var byRows = true
            for index in 1..<a.count {
                let condition = try a.matrix(index)
                if index == 1 {
                    byRows = condition.columns == 1 && condition.rows == data.rows
                    keep = Array(repeating: true, count: byRows ? data.rows : data.columns)
                }
                guard byRows ? (condition.columns == 1 && condition.rows == data.rows)
                    : (condition.rows == 1 && condition.columns == data.columns) else {
                    throw FormulaErrors.value("FILTER has mismatched range sizes. Expected row count: \(data.rows). column count: 1. Actual row count: \(condition.rows), column count: \(condition.columns).")
                }
                for (position, value) in condition.values.enumerated() {
                    if case .error(let error) = value { throw error }
                    if !((try? Coercion.boolean(value, function: "FILTER", parameter: index + 1)) ?? false) { keep[position] = false }
                }
            }
            let kept = keep.indices.filter { keep[$0] }
            guard !kept.isEmpty else { throw CellError(.notAvailable, "No matches are found in FILTER evaluation.") }
            let result = byRows
                ? ValueMatrix(rows: kept.count, columns: data.columns, values: kept.flatMap { data.row($0) })
                : ValueMatrix(rows: data.rows, columns: kept.count,
                              values: (0..<data.rows).flatMap { row in kept.map { data[row, $0] } })
            return result.isSingle ? .value(result.values[0]) : .array(result)
        }
        add("SORT", 1, .max) { a in
            let data = try a.matrix(0)
            var keys: [(values: [CellValue], ascending: Bool)] = []
            if a.count == 1 {
                keys = [(data.column(0), true)]
            }
            var index = 1
            while index < a.count {
                let ascending = index + 1 < a.count ? try a.boolean(index + 1) : true
                let spec = a.evaluator.operand(a.values[index])
                if case .array(let column) = spec {
                    guard column.columns == 1, column.rows == data.rows else {
                        throw FormulaErrors.value("Function SORT parameter \(index + 1) has mismatched row size.")
                    }
                    keys.append((column.values, ascending))
                } else {
                    let column = try a.integer(index)
                    guard column >= 1, column <= data.columns else {
                        throw FormulaErrors.value("Function SORT parameter \(index + 1) value is \(column). Valid values are between 1 and \(data.columns) inclusive.")
                    }
                    keys.append((data.column(column - 1), ascending))
                }
                index += 2
            }
            let order = (0..<data.rows).sorted { first, second in
                for key in keys {
                    let x = key.values[first], y = key.values[second]
                    if x == .empty || y == .empty {
                        if (x == .empty) != (y == .empty) { return y == .empty }
                        continue
                    }
                    let order = Coercion.compare(x, y)
                    if order != 0 { return key.ascending ? order < 0 : order > 0 }
                }
                return first < second
            }
            return .array(ValueMatrix(rows: data.rows, columns: data.columns, values: order.flatMap { data.row($0) }))
        }
        add("UNIQUE", 1, 3) { a in
            let data = try a.matrix(0)
            let byColumn = try a.boolean(1, default: false), exactlyOnce = try a.boolean(2, default: false)
            let lines = byColumn ? (0..<data.columns).map { data.column($0) } : (0..<data.rows).map { data.row($0) }
            var counts: [[CellValue]: Int] = [:]
            for line in lines { counts[line, default: 0] += 1 }
            var seen = Set<[CellValue]>()
            var unique: [[CellValue]] = []
            for line in lines where seen.insert(line).inserted && (!exactlyOnce || counts[line] == 1) {
                unique.append(line)
            }
            guard !unique.isEmpty else { throw CellError(.notAvailable, "No unique values found.") }
            let result = byColumn ? ValueMatrix(rowList: unique).transposed : ValueMatrix(rowList: unique)
            return result.isSingle ? .value(result.values[0]) : .array(result)
        }
        add("SEQUENCE", 1, 4) { a in
            let rows = try a.integer(0), columns = try a.integer(1, default: 1)
            guard rows >= 1, columns >= 1 else {
                throw FormulaErrors.value("Function SEQUENCE parameter \(rows < 1 ? 1 : 2) value is \(min(rows, columns)). It should be greater than or equal to 1.")
            }
            guard rows <= 5_000_000, columns <= 5_000_000, rows * columns <= 5_000_000 else {
                throw FormulaErrors.value("SEQUENCE result is too large.")
            }
            let start = try a.number(2, default: 1), step = try a.number(3, default: 1)
            let values = (0..<(rows * columns)).map { CellValue.number(start + Double($0) * step) }
            return values.count == 1 ? .value(values[0]) : .array(ValueMatrix(rows: rows, columns: columns, values: values))
        }
        add("TRANSPOSE", 1, 1) { a in
            let result = try a.matrix(0).transposed
            return result.isSingle ? .value(result.values[0]) : .array(result)
        }
    }
}
