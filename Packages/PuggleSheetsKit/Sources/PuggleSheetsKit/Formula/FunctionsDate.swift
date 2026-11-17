import Foundation

enum DateMath {
    /// The serial of 9999-12-31, the last date Sheets supports.
    static let maxSerial = DateSerial.serial(year: 9999, month: 12, day: 31)
    /// The serial of 0001-01-01.
    static let minSerial = DateSerial.serial(year: 1, month: 1, day: 1)

    /// Monday 1 … Sunday 7.
    static func isoWeekday(_ serial: Double) -> Int { (DateSerial.weekday(of: serial) + 5) % 7 + 1 }

    static func isWeekend(_ serial: Double) -> Bool { isoWeekday(serial) >= 6 }

    static func isoWeekNumber(_ serial: Double) -> Int {
        let day = serial.rounded(.down)
        let thursday = day - Double(isoWeekday(day)) + 4
        let year = DateSerial.parts(of: thursday).year
        return Int((thursday - DateSerial.serial(year: year, month: 1, day: 1)) / 7) + 1
    }

    /// The date `months` months after `serial`, keeping the day when the month has it.
    static func addMonths(_ serial: Double, _ months: Int, endOfMonth: Bool) -> Double {
        let parts = DateSerial.parts(of: serial.rounded(.down))
        let total = parts.year * 12 + (parts.month - 1) + months
        let year = Int((Double(total) / 12).rounded(.down))
        let month = total - year * 12 + 1
        let last = DateSerial.daysInMonth(year: year, month: month)
        return DateSerial.serial(year: year, month: month, day: endOfMonth ? last : min(parts.day, last))
    }

    static func yearFraction(_ start: Double, _ end: Double, basis: Int) -> Double {
        let (from, to) = start <= end ? (start.rounded(.down), end.rounded(.down)) : (end.rounded(.down), start.rounded(.down))
        let a = DateSerial.parts(of: from), b = DateSerial.parts(of: to)
        switch basis {
        case 1:
            let denominator: Double
            if a.year == b.year {
                denominator = DateSerial.isLeapYear(a.year) ? 366 : 365
            } else if b.year - a.year == 1, a.month > b.month || (a.month == b.month && a.day >= b.day) {
                let leapDays = [a.year, b.year].filter(DateSerial.isLeapYear).map { DateSerial.serial(year: $0, month: 2, day: 29) }
                denominator = leapDays.contains { $0 >= from && $0 <= to } ? 366 : 365
            } else {
                let days = DateSerial.serial(year: b.year + 1, month: 1, day: 1) - DateSerial.serial(year: a.year, month: 1, day: 1)
                denominator = days / Double(b.year - a.year + 1)
            }
            return (to - from) / denominator
        case 2: return (to - from) / 360
        case 3: return (to - from) / 365
        case 4:
            return Double((b.year - a.year) * 360 + (b.month - a.month) * 30 + (min(b.day, 30) - min(a.day, 30))) / 360
        default:
            var d1 = a.day, d2 = b.day
            let startIsLastOfFebruary = a.month == 2 && d1 == DateSerial.daysInMonth(year: a.year, month: 2)
            let endIsLastOfFebruary = b.month == 2 && d2 == DateSerial.daysInMonth(year: b.year, month: 2)
            if startIsLastOfFebruary, endIsLastOfFebruary { d2 = 30 }
            if startIsLastOfFebruary { d1 = 30 }
            if d2 == 31, d1 >= 30 { d2 = 30 }
            if d1 == 31 { d1 = 30 }
            return Double((b.year - a.year) * 360 + (b.month - a.month) * 30 + (d2 - d1)) / 360
        }
    }
}

extension Arguments {
    /// A date argument as a serial (text dates are parsed), within the supported years 1 to 9999.
    func date(_ index: Int) throws -> Double {
        let serial = try number(index)
        guard serial >= DateMath.minSerial, serial < DateMath.maxSerial + 1 else {
            throw FormulaErrors.number("Function \(name) parameter \(index + 1) value \(NumberText.general(serial)) is out of range.")
        }
        return serial
    }

    /// The whole-day serials of a holidays argument.
    func holidays(_ index: Int) throws -> Set<Double> {
        guard has(index) else { return [] }
        var result = Set<Double>()
        try forEachValue(index..<(index + 1)) { value, _, _ in
            switch value {
            case .number(let number): result.insert(number.rounded(.down))
            case .error(let error): throw error
            case .text(let text):
                guard let number = Coercion.number(fromText: text) else {
                    throw FormulaErrors.notNumber(text, function: name, parameter: index + 1)
                }
                result.insert(number.rounded(.down))
            default: break
            }
        }
        return result
    }
}

extension FunctionTable {
    mutating func addDateFunctions() {
        add("DATE", 3, 3, lift: Params.all) { a in
            var year = try a.integer(0)
            let month = try a.integer(1), day = try a.integer(2)
            guard year >= 0, year < 10000 else {
                throw FormulaErrors.number("Function DATE parameter 1 value is \(year). It should be greater than or equal to 0 and less than 10000.")
            }
            if year < 1900 { year += 1900 }
            guard abs(month) < 1_000_000, abs(day) < 100_000_000 else { throw FormulaErrors.number("DATE evaluates to an out of range value.") }
            let serial = DateSerial.serial(year: year, month: month, day: day)
            guard serial <= DateMath.maxSerial else { throw FormulaErrors.number("DATE evaluates to an out of range value.") }
            return .number(serial)
        }
        add("DATEDIF", 3, 3, lift: Params.all) { a in
            let start = try a.date(0).rounded(.down), end = try a.date(1).rounded(.down)
            let unit = try a.text(2).uppercased()
            guard start <= end else {
                throw FormulaErrors.number("Function DATEDIF parameter 1 (start date) should be on or before Function DATEDIF parameter 2 (end date).")
            }
            let s = DateSerial.parts(of: start), e = DateSerial.parts(of: end)
            let months = (e.year - s.year) * 12 + (e.month - s.month) - (e.day < s.day ? 1 : 0)
            switch unit {
            case "D": return .number(end - start)
            case "M": return .number(Double(months))
            case "Y": return .number(Double(months / 12))
            case "YM": return .number(Double(months % 12))
            case "MD":
                if e.day >= s.day { return .number(Double(e.day - s.day)) }
                return .number(end - DateSerial.serial(year: e.year, month: e.month - 1, day: s.day))
            case "YD":
                let sameYear = (e.month, e.day) >= (s.month, s.day) ? e.year : e.year - 1
                return .number(end - DateSerial.serial(year: sameYear, month: s.month, day: s.day))
            default:
                throw FormulaErrors.number("Function DATEDIF parameter 3 value is \(unit). It should be one of: Y, M, D, MD, YM, YD.")
            }
        }
        for (name, timeOnly) in [("DATEVALUE", false), ("TIMEVALUE", true)] {
            add(name, 1, 1, lift: Params.all) { a in
                let value = try a.scalar(0)
                guard case .text(let text) = value, let serial = InputParser.number(from: text), serial.isFinite else {
                    throw FormulaErrors.value("\(name) parameter '\(Coercion.displayText(value))' cannot be parsed to date/time.")
                }
                return .number(timeOnly ? serial - serial.rounded(.down) : serial.rounded(.down))
            }
        }
        let parts: [(String, @Sendable (DateSerial.Parts) -> Int)] = [
            ("YEAR", { $0.year }), ("MONTH", { $0.month }), ("DAY", { $0.day }),
            ("HOUR", { $0.hour }), ("MINUTE", { $0.minute }), ("SECOND", { $0.second }),
        ]
        for (name, part) in parts {
            add(name, 1, 1, lift: Params.all) { a in
                .number(Double(part(DateSerial.parts(of: try a.date(0)))))
            }
        }
        add("DAYS", 2, 2, lift: Params.all) { a in
            .number(try a.number(0).rounded(.down) - a.number(1).rounded(.down))
        }
        for (name, endOfMonth) in [("EDATE", false), ("EOMONTH", true)] {
            add(name, 2, 2, lift: Params.all) { a in
                let start = try a.date(0)
                guard start >= 0 else { throw FormulaErrors.number("Function \(name) parameter 1 value is negative. It should be positive or zero.") }
                let months = try a.integer(1)
                guard abs(months) < 120_000 else { throw FormulaErrors.number("\(name) evaluates to an out of range value.") }
                return .number(DateMath.addMonths(start, months, endOfMonth: endOfMonth))
            }
        }
        add("ISOWEEKNUM", 1, 1, lift: Params.all) { a in .number(Double(DateMath.isoWeekNumber(try a.date(0)))) }
        add("NETWORKDAYS", 2, 3, lift: Params.at(0, 1)) { a in
            let start = try a.date(0).rounded(.down), end = try a.date(1).rounded(.down)
            let holidays = try a.holidays(2)
            let (low, high) = (min(start, end), max(start, end))
            let total = Int(high - low) + 1
            var count = total / 7 * 5
            var day = low + Double(total / 7 * 7)
            while day <= high {
                if !DateMath.isWeekend(day) { count += 1 }
                day += 1
            }
            count -= holidays.filter { $0 >= low && $0 <= high && !DateMath.isWeekend($0) }.count
            return .number(Double(start <= end ? count : -count))
        }
        add("NOW", 0, 0, volatile: true) { a in .number(DateSerial.serial(from: a.evaluator.now, timeZone: .current)) }
        add("TODAY", 0, 0, volatile: true) { a in
            .number(DateSerial.serial(from: a.evaluator.now, timeZone: .current).rounded(.down))
        }
        add("TIME", 3, 3, lift: Params.all) { a in
            let total = try a.integer(0) * 3600 + a.integer(1) * 60 + a.integer(2)
            guard total >= 0 else {
                throw FormulaErrors.number("TIME evaluates to an out of range value \(total). It should be greater than or equal to 0.")
            }
            return .number(Double(total % 86_400) / 86_400)
        }
        add("WEEKDAY", 1, 2, lift: Params.all) { a in
            let weekday = DateSerial.weekday(of: try a.date(0).rounded(.down))
            let type = try a.integer(1, default: 1)
            switch type {
            case 1: return .number(Double(weekday))
            case 2: return .number(Double((weekday + 5) % 7 + 1))
            case 3: return .number(Double((weekday + 5) % 7))
            case 11...17:
                let first = type == 17 ? 1 : type - 9
                return .number(Double((weekday - first + 7) % 7 + 1))
            default:
                throw FormulaErrors.number("Function WEEKDAY parameter 2 value is \(type). Valid values are 1, 2, 3 and 11 to 17.")
            }
        }
        add("WEEKNUM", 1, 2, lift: Params.all) { a in
            let serial = try a.date(0).rounded(.down)
            let type = try a.integer(1, default: 1)
            let first: Int
            switch type {
            case 1, 17: first = 1
            case 2: first = 2
            case 11...16: first = type - 9
            case 21: return .number(Double(DateMath.isoWeekNumber(serial)))
            default:
                throw FormulaErrors.number("Function WEEKNUM parameter 2 value is \(type). Valid values are 1, 2, 11 to 17 and 21.")
            }
            let january1 = DateSerial.serial(year: DateSerial.parts(of: serial).year, month: 1, day: 1)
            let offset = (DateSerial.weekday(of: january1) - first + 7) % 7
            return .number(Double((Int(serial - january1) + offset) / 7 + 1))
        }
        add("WORKDAY", 2, 3, lift: Params.at(0, 1)) { a in
            var day = try a.date(0).rounded(.down)
            var remaining = try a.integer(1)
            guard abs(remaining) <= 10_000_000 else { throw FormulaErrors.number("WORKDAY evaluates to an out of range value.") }
            let holidays = try a.holidays(2)
            let step: Double = remaining >= 0 ? 1 : -1
            while remaining != 0 {
                day += step
                if !DateMath.isWeekend(day), !holidays.contains(day) { remaining -= Int(step) }
            }
            return .number(day)
        }
        add("YEARFRAC", 2, 3, lift: Params.all) { a in
            let start = try a.date(0), end = try a.date(1)
            let basis = try a.integer(2, default: 0)
            guard (0...4).contains(basis) else {
                throw FormulaErrors.number("Function YEARFRAC parameter 3 value is \(basis). Valid values are between 0 and 4 inclusive.")
            }
            guard start >= 0, end >= 0 else { throw FormulaErrors.number("Function YEARFRAC parameter 1 value is negative.") }
            return .number(DateMath.yearFraction(start, end, basis: basis))
        }
    }
}
