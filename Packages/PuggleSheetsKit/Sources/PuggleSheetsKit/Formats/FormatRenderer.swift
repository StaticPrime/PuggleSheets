import Foundation

extension ParsedFormat {
    func display(number: Double) -> DisplayText {
        guard isValid, number.isFinite, let (section, absolute) = section(for: number) else {
            return DisplayText(text: GeneralFormat.automatic(number))
        }
        let minus = number < 0 && !absolute
        switch section.kind {
        case .number, .scientific, .fraction:
            return FormatRenderer.number(section, magnitude: number.magnitude, minus: minus)
        case .general:
            return FormatRenderer.general(section, magnitude: number.magnitude, minus: minus)
        case .text:
            return FormatRenderer.text(section, text: GeneralFormat.automatic(absolute ? number.magnitude : number))
        case .date:
            return FormatRenderer.date(section, serial: absolute ? number.magnitude : number)
        }
    }

    func display(text: String) -> DisplayText {
        guard isValid, let section = textSection else { return DisplayText(text: text) }
        if section.isPlainText { return DisplayText(text: text) }
        return FormatRenderer.text(section, text: text)
    }
}

/// Writes a section's parts and splits the result at a repeat fill.
struct PartWriter {
    var builder = TextBuilder()
    private var fillPosition: Int?
    private var fillCharacter: Character = " "

    mutating func fill(_ character: Character) {
        guard fillPosition == nil else { return }
        fillPosition = builder.count
        fillCharacter = character
    }

    func finish(color: RGBColor?) -> DisplayText {
        guard let fillPosition else { return DisplayText(text: builder.makeString(), color: color) }
        let before = builder.makeString(0..<fillPosition)
        let after = builder.makeString(fillPosition..<builder.count)
        return DisplayText(text: before + String(fillCharacter) + after, color: color,
                           fill: DisplayText.Fill(before: before, after: after, character: fillCharacter))
    }
}

enum FormatRenderer {
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                             "October", "November", "December"]
    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdayAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    // MARK: Text

    static func text(_ section: FormatSection, text: String) -> DisplayText {
        var writer = PartWriter()
        for part in section.parts {
            switch part {
            case .text: writer.builder.append(text)
            case .literal(let bytes): writer.builder.append(bytes)
            case .fill(let character): writer.fill(character)
            default: break
            }
        }
        return writer.finish(color: section.color)
    }

    static func general(_ section: FormatSection, magnitude: Double, minus: Bool) -> DisplayText {
        var writer = PartWriter()
        if minus { writer.builder.append(0x2D) }
        for part in section.parts {
            switch part {
            case .general: GeneralFormat.writeAutomatic(magnitude, into: &writer.builder)
            case .literal(let bytes): writer.builder.append(bytes)
            case .fill(let character): writer.fill(character)
            default: break
            }
        }
        return writer.finish(color: section.color)
    }

    // MARK: Numbers

    /// The digits a number section shows.
    private struct Digits {
        var integer: [UInt8] = []
        var fraction = DecimalDigits.zero
        var lastFractionIndex = -1
        var exponent: [UInt8] = []
        var exponentNegative = false
        var numerator: [UInt8] = []
        var denominator: [UInt8] = []
        /// A fraction of a whole number shows as blanks.
        var blankFraction = false
    }

    static func number(_ section: FormatSection, magnitude: Double, minus: Bool) -> DisplayText {
        let digits: Digits
        switch section.kind {
        case .scientific:
            digits = scientificDigits(section, magnitude: magnitude)
        case .fraction:
            guard let fraction = fractionDigits(section, magnitude: magnitude) else {
                return DisplayText(text: GeneralFormat.automatic(minus ? -magnitude : magnitude), color: section.color)
            }
            digits = fraction
        default:
            let rounded = DecimalDigits(magnitude).shifted(by: section.decimalShift).rounded(toDecimals: section.fractionCount)
            digits = Digits(integer: rounded.integerDigits(), fraction: rounded, lastFractionIndex: rounded.lastFractionIndex)
        }

        var writer = PartWriter()
        if minus { writer.builder.append(0x2D) }
        for part in section.parts {
            switch part {
            case .literal(let bytes):
                writer.builder.append(bytes)
            case .fill(let character):
                writer.fill(character)
            case .integerDigit(let placeholder, let position):
                writePositional(placeholder, position: position, placeholderCount: section.integerCount,
                                digits: digits.integer, grouping: section.grouping, into: &writer.builder)
            case .decimalPoint:
                writer.builder.append(0x2E)
            case .fractionDigit(let placeholder, let index):
                if index <= digits.lastFractionIndex {
                    writer.builder.append(digits.fraction.digit(atPower: -(index + 1)) &+ 0x30)
                } else {
                    writeEmpty(placeholder, into: &writer.builder)
                }
            case .exponentMarker(let uppercase, let alwaysSign):
                writer.builder.append(uppercase ? 0x45 : 0x65)
                if digits.exponentNegative {
                    writer.builder.append(0x2D)
                } else if alwaysSign {
                    writer.builder.append(0x2B)
                }
            case .exponentDigit(let placeholder, let position):
                writePositional(placeholder, position: position, placeholderCount: section.exponentCount,
                                digits: digits.exponent, grouping: false, into: &writer.builder)
            case .numeratorDigit(let placeholder, let position):
                if digits.blankFraction {
                    writer.builder.append(0x20)
                } else {
                    writePositional(placeholder, position: position, placeholderCount: section.numeratorCount,
                                    digits: digits.numerator, grouping: false, into: &writer.builder)
                }
            case .fractionSlash:
                writer.builder.append(digits.blankFraction ? 0x20 : 0x2F)
            case .denominatorDigit(let placeholder, let index):
                if digits.blankFraction {
                    writer.builder.append(0x20)
                } else if index < digits.denominator.count {
                    writer.builder.append(digits.denominator[index])
                } else if placeholder != .hash {
                    writer.builder.append(0x20)
                }
            case .fixedDenominator(let bytes):
                if digits.blankFraction {
                    writer.builder.append(repeating: 0x20, count: bytes.count)
                } else {
                    writer.builder.append(bytes)
                }
            default:
                break
            }
        }
        return writer.finish(color: section.color)
    }

    /// What a placeholder shows where the number has no digit.
    private static func writeEmpty(_ placeholder: DigitPlaceholder, into builder: inout TextBuilder) {
        switch placeholder {
        case .zero: builder.append(0x30)
        case .question: builder.append(0x20)
        case .hash: break
        }
    }

    /// Integer-like placeholders fill from the right; the leftmost one takes any extra digits.
    private static func writePositional(_ placeholder: DigitPlaceholder, position: Int, placeholderCount: Int,
                                        digits: [UInt8], grouping: Bool, into builder: inout TextBuilder) {
        let digitCount = digits.count
        if position == placeholderCount - 1, digitCount > placeholderCount {
            for index in 0..<(digitCount - placeholderCount) {
                builder.append(digits[index])
                let digitPosition = digitCount - 1 - index
                if grouping, digitPosition % 3 == 0 { builder.append(0x2C) }
            }
        }
        let index = digitCount - 1 - position
        let separatorFollows = grouping && position > 0 && position % 3 == 0
        if index >= 0 {
            builder.append(digits[index])
            if separatorFollows { builder.append(0x2C) }
            return
        }
        switch placeholder {
        case .zero:
            builder.append(0x30)
            if separatorFollows { builder.append(0x2C) }
        case .question:
            builder.append(0x20)
            if separatorFollows { builder.append(0x20) }
        case .hash:
            break
        }
    }

    private static func scientificDigits(_ section: FormatSection, magnitude: Double) -> Digits {
        let value = DecimalDigits(magnitude).shifted(by: section.decimalShift)
        var exponent = 0
        var mantissa = DecimalDigits.zero
        if !value.isZero {
            let integerCount = max(1, section.integerCount)
            var lead = value.leadingExponent
            for _ in 0..<3 {
                exponent = section.engineering ? floorDivide(lead, integerCount) * integerCount : lead - (integerCount - 1)
                mantissa = value.shifted(by: -exponent).rounded(toDecimals: section.fractionCount)
                // Rounding up can add a digit (9.99 → 10.0): move to the next exponent.
                guard !mantissa.isZero, mantissa.leadingExponent >= integerCount else { break }
                lead += 1
            }
        }
        return Digits(integer: mantissa.integerDigits(), fraction: mantissa, lastFractionIndex: mantissa.lastFractionIndex,
                      exponent: asciiDigits(of: abs(exponent)), exponentNegative: exponent < 0)
    }

    private static func fractionDigits(_ section: FormatSection, magnitude: Double) -> Digits? {
        let value = magnitude * pow(10, Double(section.decimalShift))
        guard value < 1e15 else { return nil }
        var whole = 0.0
        var remainder = value
        if section.hasWholePart {
            whole = value.rounded(.down)
            remainder = value - whole
        }
        let maxDenominator = section.fixedDenominator > 0
            ? section.fixedDenominator
            : Int(DecimalDigits.powersOfTen[min(max(section.denominatorCount, 1), 9)]) - 1
        // Numerators of improper fractions grow with the value; keep them well inside Int.
        guard remainder * Double(maxDenominator + 1) < 1e15 else { return nil }
        var numerator: Int
        var denominator: Int
        if section.fixedDenominator > 0 {
            denominator = section.fixedDenominator
            numerator = Int((remainder * Double(denominator)).rounded())
        } else {
            (numerator, denominator) = bestRational(remainder, maxDenominator: maxDenominator)
        }
        var digits = Digits()
        if section.hasWholePart {
            if numerator >= denominator {
                whole += 1
                numerator -= denominator
            }
            digits.blankFraction = numerator == 0
            digits.integer = DecimalDigits(whole).integerDigits()
            if digits.integer.isEmpty, numerator == 0 { digits.integer = [0x30] }
        }
        digits.numerator = asciiDigits(of: numerator)
        digits.denominator = asciiDigits(of: denominator)
        return digits
    }

    /// The fraction closest to `value` with a denominator up to `maxDenominator` (continued fractions).
    static func bestRational(_ value: Double, maxDenominator: Int) -> (numerator: Int, denominator: Int) {
        guard value > 0 else { return (0, 1) }
        var p0 = 0, q0 = 1, p1 = 1, q1 = 0
        var remainder = value
        for _ in 0..<64 {
            let wholePart = remainder.rounded(.down)
            guard wholePart < 1e12 else { break }
            let term = Int(wholePart)
            let q2 = q0 + term * q1
            if q2 > maxDenominator { break }
            (p0, q0, p1, q1) = (p1, q1, p0 + term * p1, q2)
            let fractional = remainder - wholePart
            if fractional < 1e-12 { break }
            remainder = 1 / fractional
        }
        guard q1 > 0 else { return (Int(value.rounded()), 1) }
        let steps = (maxDenominator - q0) / q1
        let candidate = (numerator: p0 + steps * p1, denominator: q0 + steps * q1)
        let convergentError = abs(Double(p1) / Double(q1) - value)
        let candidateError = abs(Double(candidate.numerator) / Double(candidate.denominator) - value)
        return convergentError <= candidateError ? (p1, q1) : candidate
    }

    static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    // MARK: Dates and times

    /// The largest serial shown as a date (about the year 275,000); larger values show as Automatic.
    static let maximumDateSerial = 1e8

    static func date(_ section: FormatSection, serial: Double) -> DisplayText {
        var value = serial
        var writer = PartWriter()
        if section.hasElapsed, value < 0 {
            writer.builder.append(0x2D)
            value = -value
        }
        guard abs(value) < maximumDateSerial else {
            return DisplayText(text: GeneralFormat.automatic(serial), color: section.color)
        }
        let fractionDigits = min(section.secondDigits, 3)
        let unitsPerSecond = Int(DecimalDigits.powersOfTen[fractionDigits])
        let unitsPerDay = 86_400 * unitsPerSecond
        let totalUnits = Int((value * Double(unitsPerDay)).rounded())
        let days = floorDivide(totalUnits, unitsPerDay)
        let unitsOfDay = totalUnits - days * unitsPerDay
        let secondsOfDay = unitsOfDay / unitsPerSecond
        let hour = secondsOfDay / 3600
        let minute = secondsOfDay / 60 % 60
        let second = secondsOfDay % 60
        let civil = section.hasDateParts ? DateSerial.civilFromDays(days - DateSerial.unixEpochSerial) : (year: 0, month: 1, day: 1)

        for part in section.parts {
            switch part {
            case .literal(let bytes):
                writer.builder.append(bytes)
            case .fill(let character):
                writer.fill(character)
            case .year(let fourDigits):
                if fourDigits {
                    writer.builder.appendNumber(civil.year, minimumDigits: 4)
                } else {
                    writer.builder.appendNumber((civil.year % 100 + 100) % 100, minimumDigits: 2)
                }
            case .month(let style):
                switch style {
                case .number: writer.builder.appendNumber(civil.month)
                case .paddedNumber: writer.builder.appendNumber(civil.month, minimumDigits: 2)
                case .short: writer.builder.append(monthAbbreviations[civil.month - 1])
                case .full: writer.builder.append(monthNames[civil.month - 1])
                case .initial: writer.builder.append(monthNames[civil.month - 1].utf8.first ?? 0x20)
                }
            case .day(let twoDigits):
                writer.builder.appendNumber(civil.day, minimumDigits: twoDigits ? 2 : 1)
            case .weekday(let full):
                let weekday = DateSerial.weekday(of: Double(days)) - 1
                writer.builder.append(full ? weekdayNames[weekday] : weekdayAbbreviations[weekday])
            case .hour(let twoDigits):
                let shown = section.twelveHour ? (hour % 12 == 0 ? 12 : hour % 12) : hour
                writer.builder.appendNumber(shown, minimumDigits: twoDigits ? 2 : 1)
            case .minute(let twoDigits):
                writer.builder.appendNumber(minute, minimumDigits: twoDigits ? 2 : 1)
            case .second(let twoDigits):
                writer.builder.appendNumber(second, minimumDigits: twoDigits ? 2 : 1)
            case .secondFraction(let digits):
                let shown = min(digits, fractionDigits)
                let units = unitsOfDay % unitsPerSecond
                let scaled = units / Int(DecimalDigits.powersOfTen[fractionDigits - shown])
                writer.builder.appendNumber(scaled, minimumDigits: shown)
                writer.builder.append(repeating: 0x30, count: digits - shown)
            case .elapsedHours(let minimumDigits):
                writer.builder.appendNumber(floorDivide(totalUnits, 3600 * unitsPerSecond), minimumDigits: minimumDigits)
            case .elapsedMinutes(let minimumDigits):
                writer.builder.appendNumber(floorDivide(totalUnits, 60 * unitsPerSecond), minimumDigits: minimumDigits)
            case .elapsedSeconds(let minimumDigits):
                writer.builder.appendNumber(floorDivide(totalUnits, unitsPerSecond), minimumDigits: minimumDigits)
            case .amPm(let style):
                let morning = hour < 12
                switch style {
                case .full: writer.builder.append(morning ? "AM" : "PM")
                case .upperLetter: writer.builder.append(morning ? 0x41 : 0x50)
                case .lowerLetter: writer.builder.append(morning ? 0x61 : 0x70)
                }
            default:
                break
            }
        }
        return writer.finish(color: section.color)
    }
}
