import Foundation

/// Decimal-correct rounding: 2.675 rounds to 2.68 as it does in Sheets, not to 2.67 as binary doubles would.
enum Rounding {
    enum Mode { case halfAwayFromZero, towardZero, awayFromZero }

    private static let posix = Locale(identifier: "en_US_POSIX")

    static func round(_ value: Double, digits: Int, mode: Mode) -> Double {
        guard value.isFinite, value != 0 else { return value }
        let digits = max(-400, min(digits, 400))
        let magnitude = abs(value)
        if let decimal = Decimal(string: String(format: "%.15g", magnitude), locale: posix), digits <= 120 {
            var input = decimal
            var output = Decimal()
            let decimalMode: NSDecimalNumber.RoundingMode = switch mode {
            case .halfAwayFromZero: .plain
            case .towardZero: .down
            case .awayFromZero: .up
            }
            NSDecimalRound(&output, &input, digits, decimalMode)
            // Through text: NSDecimalNumber.doubleValue can be one unit off in the last place.
            let result = Double(output.description) ?? NSDecimalNumber(decimal: output).doubleValue
            return value < 0 ? -result : result
        }
        let scale = Foundation.pow(10, Double(digits))
        let scaled = magnitude * scale
        guard scaled.isFinite else { return value }
        let rounded: Double = switch mode {
        case .halfAwayFromZero: scaled.rounded(.toNearestOrAwayFromZero)
        case .towardZero: scaled.rounded(.towardZero)
        case .awayFromZero: scaled.rounded(.awayFromZero)
        }
        return (value < 0 ? -rounded : rounded) / scale
    }

    /// Removes binary noise past 15 significant digits (0.30000000000000004 → 0.3).
    static func clean(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return value }
        return Double(String(format: "%.15g", value)) ?? value
    }

    /// value / factor, snapped to the nearest integer when it is within floating-point noise of one.
    static func quotient(_ value: Double, _ factor: Double) -> Double {
        let quotient = value / factor
        let nearest = quotient.rounded()
        return abs(quotient - nearest) <= 1e-9 * max(1, abs(quotient)) ? nearest : quotient
    }
}

extension FunctionTable {
    mutating func addMathFunctions() {
        addMath("ABS") { abs($0) }
        addMath("ACOS") { x in
            guard (-1...1).contains(x) else { throw Self.domain("ACOS", x, "Valid values are between -1 and 1 inclusive.") }
            return acos(x)
        }
        addMath("ACOSH") { x in
            guard x >= 1 else { throw Self.domain("ACOSH", x, "It should be greater than or equal to 1.") }
            return acosh(x)
        }
        addMath("ASIN") { x in
            guard (-1...1).contains(x) else { throw Self.domain("ASIN", x, "Valid values are between -1 and 1 inclusive.") }
            return asin(x)
        }
        addMath("ASINH") { asinh($0) }
        addMath("ATAN") { atan($0) }
        add("ATAN2", 2, 2, lift: Params.all) { a in
            let x = try a.number(0), y = try a.number(1)
            guard x != 0 || y != 0 else { throw FormulaErrors.divideByZero("ATAN2") }
            return .number(atan2(y, x))
        }
        addMath("ATANH") { x in
            guard x > -1, x < 1 else { throw Self.domain("ATANH", x, "Valid values are between -1 and 1 exclusive.") }
            return atanh(x)
        }
        add("CEILING", 1, 2, lift: Params.all) { a in
            let value = try a.number(0), factor = try a.number(1, default: 1)
            guard factor != 0 else { return .number(0) }
            if value > 0, factor < 0 {
                throw FormulaErrors.number("Function CEILING parameter 2 value is negative. It must be positive when parameter 1 is positive.")
            }
            let quotient = Rounding.quotient(value, factor)
            let steps = value < 0 && factor < 0 ? quotient.rounded(.awayFromZero) : quotient.rounded(.up)
            return .number(Rounding.clean(steps * factor))
        }
        add("CEILING.MATH", 1, 3, lift: Params.all) { a in
            let value = try a.number(0), factor = abs(try a.number(1, default: 1)), mode = try a.number(2, default: 0)
            guard factor != 0 else { return .number(0) }
            let quotient = Rounding.quotient(value, factor)
            let steps = value < 0 && mode != 0 ? quotient.rounded(.awayFromZero) : quotient.rounded(.up)
            return .number(Rounding.clean(steps * factor))
        }
        add("COMBIN", 2, 2, lift: Params.all) { a in
            let n = (try a.number(0)).rounded(.towardZero), k = (try a.number(1)).rounded(.towardZero)
            guard n >= 0, k >= 0, k <= n else {
                throw FormulaErrors.number("Function COMBIN parameter 2 value is \(NumberText.general(k)). It should be less than or equal to \(NumberText.general(n)).")
            }
            return .number(Self.combinations(n, k))
        }
        addMath("COS") { cos($0) }
        addMath("COSH") { cosh($0) }
        addMath("DEGREES") { $0 * 180 / .pi }
        addMath("EVEN") { x in
            let up = abs(x).rounded(.up)
            let even = up.truncatingRemainder(dividingBy: 2) == 0 ? up : up + 1
            return x < 0 ? -even : even
        }
        addMath("EXP") { exp($0) }
        addMath("FACT") { x in
            let n = x.rounded(.towardZero)
            guard n >= 0 else { throw Self.domain("FACT", x, "It should be greater than or equal to 0.") }
            guard n <= 170 else { throw FormulaErrors.notFinite }
            return n < 2 ? 1 : (2...Int(n)).reduce(1.0) { $0 * Double($1) }
        }
        add("FLOOR", 1, 2, lift: Params.all) { a in
            let value = try a.number(0), factor = try a.number(1, default: 1)
            guard factor != 0 else { throw FormulaErrors.divideByZero("FLOOR") }
            if value > 0, factor < 0 {
                throw FormulaErrors.number("Function FLOOR parameter 2 value is negative. It must be positive when parameter 1 is positive.")
            }
            let quotient = Rounding.quotient(value, factor)
            let steps = value < 0 && factor < 0 ? quotient.rounded(.towardZero) : quotient.rounded(.down)
            return .number(Rounding.clean(steps * factor))
        }
        add("FLOOR.MATH", 1, 3, lift: Params.all) { a in
            let value = try a.number(0), factor = abs(try a.number(1, default: 1)), mode = try a.number(2, default: 0)
            guard factor != 0 else { return .number(0) }
            let quotient = Rounding.quotient(value, factor)
            let steps = value < 0 && mode != 0 ? quotient.rounded(.towardZero) : quotient.rounded(.down)
            return .number(Rounding.clean(steps * factor))
        }
        add("GCD", 1, .max) { a in
            var result = 0.0
            for value in try a.numbers() {
                let n = value.rounded(.towardZero)
                guard n >= 0 else { throw FormulaErrors.number("Function GCD parameter 1 value is negative. It should be positive or zero.") }
                result = Self.gcd(result, n)
            }
            return .number(result)
        }
        addMath("INT") { $0.rounded(.down) }
        add("LCM", 1, .max) { a in
            var result = 1.0
            for value in try a.numbers() {
                let n = value.rounded(.towardZero)
                guard n >= 0 else { throw FormulaErrors.number("Function LCM parameter 1 value is negative. It should be positive or zero.") }
                if n == 0 { return .number(0) }
                result = result / Self.gcd(result, n) * n
            }
            return .number(result)
        }
        addMath("LN") { x in
            guard x > 0 else { throw Self.domain("LN", x, "It should be greater than 0.") }
            return log(x)
        }
        add("LOG", 1, 2, lift: Params.all) { a in
            let x = try a.number(0), base = try a.number(1, default: 10)
            guard x > 0 else { throw Self.domain("LOG", x, "It should be greater than 0.") }
            guard base > 0 else { throw FormulaErrors.number("Function LOG parameter 2 value is \(NumberText.general(base)). It should be greater than 0.") }
            guard base != 1 else { throw FormulaErrors.divideByZero("LOG") }
            return .number(log(x) / log(base))
        }
        addMath("LOG10") { x in
            guard x > 0 else { throw Self.domain("LOG10", x, "It should be greater than 0.") }
            return log10(x)
        }
        add("MOD", 2, 2, lift: Params.all) { a in
            let x = try a.number(0), y = try a.number(1)
            guard y != 0 else { throw CellError(.divideByZero, "Function MOD parameter 2 cannot be zero.") }
            let result = x - y * (x / y).rounded(.down)
            return .number(Rounding.clean(result))
        }
        add("MROUND", 2, 2, lift: Params.all) { a in
            let value = try a.number(0), factor = try a.number(1)
            guard factor != 0, value != 0 else { return .number(0) }
            guard (value > 0) == (factor > 0) else {
                throw FormulaErrors.number("Parameters of MROUND must have same signs (both positive or both negative).")
            }
            let steps = Rounding.round(Rounding.quotient(value, factor), digits: 0, mode: .halfAwayFromZero)
            return .number(Rounding.clean(steps * factor))
        }
        addMath("ODD") { x in
            let up = abs(x).rounded(.up)
            let odd = up.truncatingRemainder(dividingBy: 2) == 1 ? up : up + 1
            return x < 0 ? -odd : odd
        }
        add("PI", 0, 0) { _ in .number(.pi) }
        add("POWER", 2, 2, lift: Params.all) { a in
            .value(Evaluator.apply(.power, .number(try a.number(0)), .number(try a.number(1))))
        }
        add("PRODUCT", 1, .max) { a in
            var product = 1.0, any = false
            try a.forEachNumber(0..<a.count) { product *= $0; any = true }
            return .number(any ? product : 0)
        }
        add("QUOTIENT", 2, 2, lift: Params.all) { a in
            let x = try a.number(0), y = try a.number(1)
            guard y != 0 else { throw CellError(.divideByZero, "Function QUOTIENT parameter 2 cannot be zero.") }
            return .number((x / y).rounded(.towardZero))
        }
        addMath("RADIANS") { $0 * .pi / 180 }
        add("RAND", 0, 0, volatile: true) { _ in .number(Double.random(in: 0..<1)) }
        add("RANDBETWEEN", 2, 2, lift: Params.all, volatile: true) { a in
            let low = (try a.number(0)).rounded(.up), high = (try a.number(1)).rounded(.down)
            guard low <= high else {
                throw FormulaErrors.number("Function RANDBETWEEN parameter 2 value is \(NumberText.general(high)). It should be greater than or equal to \(NumberText.general(low)).")
            }
            return .number((low + (Double.random(in: 0..<1) * (high - low + 1)).rounded(.down)).clamped(to: low...high))
        }
        for (name, mode) in [("ROUND", Rounding.Mode.halfAwayFromZero), ("ROUNDDOWN", .towardZero), ("ROUNDUP", .awayFromZero),
                             ("TRUNC", .towardZero)] {
            add(name, 1, 2, lift: Params.all) { a in
                .number(Rounding.round(try a.number(0), digits: try a.integer(1, default: 0), mode: mode))
            }
        }
        addMath("SIGN") { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        addMath("SIN") { sin($0) }
        addMath("SINH") { sinh($0) }
        addMath("SQRT") { x in
            guard x >= 0 else { throw Self.domain("SQRT", x, "It should be greater than or equal to 0.") }
            return x.squareRoot()
        }
        add("SUM", 1, .max) { a in
            var sum = 0.0
            try a.forEachNumber(0..<a.count) { sum += $0 }
            return .number(sum)
        }
        add("SUMIF", 2, 3) { a in
            let range = try a.data(0)
            let values = a.has(2) ? try a.valueRange(2, shapedLike: range) : range
            var sum = 0.0
            for position in try a.matchingPositions([(range, try Criterion(a.raw(1)))], within: values) {
                switch values.value(at: position) {
                case .number(let number): sum += number
                case .error(let error): throw error
                default: break
                }
            }
            return .number(sum)
        }
        add("SUMIFS", 3, .max) { a in
            let values = try a.data(0)
            let pairs = try a.criteriaPairs(from: 1)
            guard pairs[0].range.rows == values.rows, pairs[0].range.columns == values.columns else {
                throw FormulaErrors.value("Array arguments to SUMIFS are of different size.")
            }
            var sum = 0.0
            for position in try a.matchingPositions(pairs, within: values) {
                switch values.value(at: position) {
                case .number(let number): sum += number
                case .error(let error): throw error
                default: break
                }
            }
            return .number(sum)
        }
        add("SUMPRODUCT", 1, .max) { a in
            let matrices = try (0..<a.count).map { try a.matrix($0) }
            let rows = matrices[0].rows, columns = matrices[0].columns
            for matrix in matrices where matrix.rows != rows || matrix.columns != columns {
                throw FormulaErrors.value("SUMPRODUCT has mismatched range sizes. Expected row count: \(rows). column count: \(columns). Actual row count: \(matrix.rows), column count: \(matrix.columns).")
            }
            var total = 0.0
            for index in 0..<(rows * columns) {
                var product = 1.0
                for matrix in matrices {
                    switch matrix.values[index] {
                    case .number(let number): product *= number
                    case .error(let error): throw error
                    default: product = 0
                    }
                }
                total += product
            }
            return .number(total)
        }
        add("SUMSQ", 1, .max) { a in
            var sum = 0.0
            try a.forEachNumber(0..<a.count) { sum += $0 * $0 }
            return .number(sum)
        }
        addMath("TAN") { tan($0) }
        addMath("TANH") { tanh($0) }
    }

    static func domain(_ name: String, _ x: Double, _ requirement: String) -> CellError {
        FormulaErrors.number("Function \(name) parameter 1 value is \(NumberText.general(x)). \(requirement)")
    }

    static func gcd(_ a: Double, _ b: Double) -> Double {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x.truncatingRemainder(dividingBy: y)) }
        return x
    }

    static func combinations(_ n: Double, _ k: Double) -> Double {
        let k = min(k, n - k)
        guard k > 0 else { return 1 }
        // Large inputs overflow anyway; lgamma keeps them fast.
        if k > 1000 { return exp(lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1)).rounded() }
        var result = 1.0
        var i = 1.0
        while i <= k {
            result = result * (n - k + i) / i
            i += 1
        }
        return result.rounded()
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
