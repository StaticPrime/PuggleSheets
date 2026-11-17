import Foundation

extension FunctionTable {
    mutating func addStatisticalFunctions() {
        for (name, mode) in [("AVERAGE", RangeNumbers.numbersOnly), ("AVERAGEA", .allValues)] {
            add(name, 1, .max) { a in
                var sum = 0.0, count = 0
                try a.forEachNumber(0..<a.count, mode: mode) { sum += $0; count += 1 }
                guard count > 0 else { throw FormulaErrors.divideByZero(name) }
                return .number(sum / Double(count))
            }
        }
        add("AVERAGEIF", 2, 3) { a in
            let range = try a.data(0)
            let values = a.has(2) ? try a.valueRange(2, shapedLike: range) : range
            let numbers = try Self.numbers(at: a.matchingPositions([(range, try Criterion(a.raw(1)))], within: values), in: values)
            guard !numbers.isEmpty else { throw FormulaErrors.divideByZero("AVERAGEIF") }
            return .number(numbers.reduce(0, +) / Double(numbers.count))
        }
        add("AVERAGEIFS", 3, .max) { a in
            let numbers = try Self.ifsNumbers(a)
            guard !numbers.isEmpty else { throw FormulaErrors.divideByZero("AVERAGEIFS") }
            return .number(numbers.reduce(0, +) / Double(numbers.count))
        }
        add("COUNT", 1, .max) { a in
            var count = 0
            try a.forEachValue(0..<a.count) { value, _, _ in
                if case .number = value { count += 1 }
            }
            return .number(Double(count))
        }
        add("COUNTA", 1, .max) { a in
            var count = 0
            try a.forEachValue(0..<a.count) { _, _, _ in count += 1 }
            return .number(Double(count))
        }
        add("COUNTBLANK", 1, 1) { a in
            let data = try a.data(0)
            let filled = data.entries.filter { $0.value != .text("") }.count
            return .number(Double(data.count - filled))
        }
        add("COUNTIF", 2, 2) { a in
            let data = try a.data(0)
            let criterion = try Criterion(a.raw(1))
            var count = data.entries.filter { criterion.matches($0.value) }.count
            if criterion.matchesBlank { count += data.count - data.entries.count }
            return .number(Double(count))
        }
        add("COUNTIFS", 2, .max) { a in
            .number(Double(try a.matchingPositions(a.criteriaPairs(from: 0)).count))
        }
        add("COUNTUNIQUE", 1, .max) { a in
            var seen = Set<CellValue>()
            try a.forEachValue(0..<a.count) { value, _, _ in
                if case .error(let error) = value { throw error }
                seen.insert(value)
            }
            return .number(Double(seen.count))
        }
        for (name, largest) in [("LARGE", true), ("SMALL", false)] {
            add(name, 2, 2) { a in
                let numbers = try a.numbers(0..<1).sorted(by: largest ? (>) : (<))
                let n = try a.number(1).rounded(.up)
                guard n >= 1, n <= Double(numbers.count) else {
                    throw FormulaErrors.number("Function \(name) parameter 2 value \(NumberText.general(n)) is out of range.")
                }
                return .number(numbers[Int(n) - 1])
            }
        }
        for (name, mode, largest) in [("MAX", RangeNumbers.numbersOnly, true), ("MAXA", .allValues, true),
                                      ("MIN", .numbersOnly, false), ("MINA", .allValues, false)] {
            add(name, 1, .max) { a in
                var result: Double?
                try a.forEachNumber(0..<a.count, mode: mode) { number in
                    if let current = result {
                        result = largest ? Swift.max(current, number) : Swift.min(current, number)
                    } else {
                        result = number
                    }
                }
                return .number(result ?? 0)
            }
        }
        for (name, largest) in [("MAXIFS", true), ("MINIFS", false)] {
            add(name, 3, .max) { a in
                let numbers = try Self.ifsNumbers(a)
                return .number((largest ? numbers.max() : numbers.min()) ?? 0)
            }
        }
        add("MEDIAN", 1, .max) { a in
            let numbers = try a.numbers().sorted()
            guard !numbers.isEmpty else { throw FormulaErrors.number("MEDIAN has no valid input data.") }
            let middle = numbers.count / 2
            return .number(numbers.count % 2 == 1 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2)
        }
        add("MODE", 1, .max) { a in
            let numbers = try a.numbers()
            var counts: [Double: Int] = [:]
            for number in numbers { counts[number, default: 0] += 1 }
            let best = counts.values.max() ?? 0
            guard best > 1, let mode = numbers.first(where: { counts[$0] == best }) else {
                throw CellError(.notAvailable, "MODE cannot produce a result because no values occur more than once.")
            }
            return .number(mode)
        }
        alias("MODE.SNGL", "MODE")
        add("PERCENTILE", 2, 2) { a in
            let k = try a.number(1)
            guard (0...1).contains(k) else {
                throw FormulaErrors.number("Function PERCENTILE parameter 2 value is \(NumberText.general(k)). Valid values are between 0 and 1 inclusive.")
            }
            return .number(try Self.percentile(a.numbers(0..<1), k, name: "PERCENTILE"))
        }
        alias("PERCENTILE.INC", "PERCENTILE")
        add("QUARTILE", 2, 2) { a in
            let quartile = try a.number(1).rounded(.towardZero)
            guard (0...4).contains(quartile) else {
                throw FormulaErrors.number("Function QUARTILE parameter 2 value is \(NumberText.general(quartile)). Valid values are between 0 and 4 inclusive.")
            }
            return .number(try Self.percentile(a.numbers(0..<1), quartile / 4, name: "QUARTILE"))
        }
        alias("QUARTILE.INC", "QUARTILE")
        for (name, average) in [("RANK", false), ("RANK.EQ", false), ("RANK.AVG", true)] {
            add(name, 2, 3) { a in
                let value = try a.number(0)
                let numbers = try a.numbers(1..<2)
                let ascending = try a.boolean(2, default: false)
                let ties = numbers.filter { $0 == value }.count
                guard ties > 0 else { throw CellError(.notAvailable, "\(name)'s value \(NumberText.general(value)) is not in the data.") }
                let before = numbers.filter { ascending ? $0 < value : $0 > value }.count
                return .number(Double(before + 1) + (average ? Double(ties - 1) / 2 : 0))
            }
        }
        for (name, sample, root) in [("STDEV", true, true), ("STDEV.S", true, true), ("STDEVP", false, true),
                                     ("STDEV.P", false, true), ("VAR", true, false), ("VAR.S", true, false),
                                     ("VARP", false, false), ("VAR.P", false, false)] {
            add(name, 1, .max) { a in
                let numbers = try a.numbers()
                guard numbers.count >= (sample ? 2 : 1) else { throw FormulaErrors.divideByZero(name) }
                let variance = Self.sumOfSquares(numbers) / Double(sample ? numbers.count - 1 : numbers.count)
                return .number(root ? variance.squareRoot() : variance)
            }
        }
        add("CORREL", 2, 2) { a in
            let (ys, xs) = try Self.pairs(a)
            let sxx = Self.sumOfSquares(xs), syy = Self.sumOfSquares(ys)
            guard xs.count > 1, sxx > 0, syy > 0 else { throw FormulaErrors.divideByZero("CORREL") }
            return .number(Self.sumOfProducts(xs, ys) / (sxx * syy).squareRoot())
        }
        add("SLOPE", 2, 2) { a in
            let (ys, xs) = try Self.pairs(a)
            let sxx = Self.sumOfSquares(xs)
            guard xs.count > 1, sxx > 0 else { throw FormulaErrors.divideByZero("SLOPE") }
            return .number(Self.sumOfProducts(xs, ys) / sxx)
        }
        add("INTERCEPT", 2, 2) { a in
            let (ys, xs) = try Self.pairs(a)
            let sxx = Self.sumOfSquares(xs)
            guard xs.count > 1, sxx > 0 else { throw FormulaErrors.divideByZero("INTERCEPT") }
            let slope = Self.sumOfProducts(xs, ys) / sxx
            return .number(Self.mean(ys) - slope * Self.mean(xs))
        }
    }

    static func numbers(at positions: [Int], in values: RangeData) throws -> [Double] {
        var numbers: [Double] = []
        for position in positions {
            switch values.value(at: position) {
            case .number(let number): numbers.append(number)
            case .error(let error): throw error
            default: break
            }
        }
        return numbers
    }

    /// The numbers of the first argument's range where the criteria pairs that follow match (…IFS functions).
    static func ifsNumbers(_ a: Arguments) throws -> [Double] {
        let values = try a.data(0)
        let pairs = try a.criteriaPairs(from: 1)
        guard pairs[0].range.rows == values.rows, pairs[0].range.columns == values.columns else {
            throw FormulaErrors.value("Array arguments to \(a.name) are of different size.")
        }
        return try numbers(at: a.matchingPositions(pairs, within: values), in: values)
    }

    static func mean(_ numbers: [Double]) -> Double { numbers.reduce(0, +) / Double(numbers.count) }

    /// Σ(x - mean)².
    static func sumOfSquares(_ numbers: [Double]) -> Double {
        let average = mean(numbers)
        return numbers.reduce(0) { $0 + ($1 - average) * ($1 - average) }
    }

    /// Σ(x - mean x)(y - mean y).
    static func sumOfProducts(_ xs: [Double], _ ys: [Double]) -> Double {
        let meanX = mean(xs), meanY = mean(ys)
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
    }

    /// Paired numbers of arguments 1 (y) and 2 (x), skipping pairs where either isn't a number.
    static func pairs(_ a: Arguments) throws -> (ys: [Double], xs: [Double]) {
        let y = try a.matrix(0), x = try a.matrix(1)
        guard y.count == x.count else {
            throw CellError(.notAvailable, "\(a.name) has mismatched range sizes.")
        }
        var ys: [Double] = [], xs: [Double] = []
        for index in 0..<y.count {
            if case .error(let error) = y.values[index] { throw error }
            if case .error(let error) = x.values[index] { throw error }
            if case .number(let yValue) = y.values[index], case .number(let xValue) = x.values[index] {
                ys.append(yValue)
                xs.append(xValue)
            }
        }
        return (ys, xs)
    }

    static func percentile(_ numbers: [Double], _ k: Double, name: String) throws -> Double {
        guard !numbers.isEmpty else { throw FormulaErrors.number("\(name) has no valid input data.") }
        let sorted = numbers.sorted()
        let rank = k * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let fraction = rank - Double(lower)
        guard lower + 1 < sorted.count else { return sorted[lower] }
        return sorted[lower] + fraction * (sorted[lower + 1] - sorted[lower])
    }
}
