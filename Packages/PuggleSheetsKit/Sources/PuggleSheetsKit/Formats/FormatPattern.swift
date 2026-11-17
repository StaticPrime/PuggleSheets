import Foundation

/// A digit placeholder: where the number has no digit, "0" shows a zero, "#" nothing and "?" a space.
enum DigitPlaceholder: Sendable {
    case zero, hash, question
}

enum AmPmStyle: Sendable {
    /// "AM/PM" in any case shows "AM" or "PM".
    case full
    /// "A/P" shows "A" or "P".
    case upperLetter
    /// "a/p" shows "a" or "p".
    case lowerLetter
}

enum MonthStyle: Sendable {
    /// m: 1, mm: 01, mmm: Jan, mmmm: January, mmmmm: J.
    case number, paddedNumber, short, full, initial
}

/// "[>100]", "[<=0]".
struct FormatCondition: Sendable {
    enum Comparison: Sendable {
        case less, lessOrEqual, greater, greaterOrEqual, equal, notEqual
    }

    var comparison: Comparison
    var operand: Double

    func matches(_ value: Double) -> Bool {
        switch comparison {
        case .less: value < operand
        case .lessOrEqual: value <= operand
        case .greater: value > operand
        case .greaterOrEqual: value >= operand
        case .equal: value == operand
        case .notEqual: value != operand
        }
    }
}

/// One piece of a compiled section, in display order.
enum FormatPart: Sendable {
    case literal([UInt8])
    /// "*x": repeat x to fill the cell.
    case fill(Character)

    // Numbers. Positions count from the right (0 = units); indexes from the left.
    case integerDigit(DigitPlaceholder, position: Int)
    case decimalPoint
    case fractionDigit(DigitPlaceholder, index: Int)
    case exponentMarker(uppercase: Bool, alwaysSign: Bool)
    case exponentDigit(DigitPlaceholder, position: Int)
    case numeratorDigit(DigitPlaceholder, position: Int)
    case fractionSlash
    case denominatorDigit(DigitPlaceholder, index: Int)
    case fixedDenominator([UInt8])
    /// "General" inside a pattern: the Automatic text.
    case general

    /// "@": the text itself.
    case text

    // Dates and times.
    case year(fourDigits: Bool)
    case month(MonthStyle)
    case day(twoDigits: Bool)
    case weekday(full: Bool)
    case hour(twoDigits: Bool)
    case minute(twoDigits: Bool)
    case second(twoDigits: Bool)
    case secondFraction(digits: Int)
    case elapsedHours(minimumDigits: Int)
    case elapsedMinutes(minimumDigits: Int)
    case elapsedSeconds(minimumDigits: Int)
    case amPm(AmPmStyle)
}

/// One ";"-separated section of a pattern, compiled for display.
struct FormatSection: Sendable {
    enum Kind: Sendable {
        case number, scientific, fraction, general, text, date
    }

    var kind: Kind
    var parts: [FormatPart] = []
    var color: RGBColor?
    var condition: FormatCondition?
    var hasFill = false
    var hasCurrency = false

    // Numbers
    var integerCount = 0
    var fractionCount = 0
    var exponentCount = 0
    var grouping = false
    /// Powers of ten applied before display: +2 per "%", -3 per scaling comma.
    var decimalShift = 0
    var hasPercent = false
    var hasDigits = false
    /// Scientific notation with exponents in multiples of `integerCount` ("##0.0E+0").
    var engineering = false

    // Fractions
    var hasWholePart = false
    var numeratorCount = 0
    var denominatorCount = 0
    /// The denominator written in the pattern ("?/8"), or 0 when it's chosen to fit the placeholders.
    var fixedDenominator = 0

    // Dates and times
    var twelveHour = false
    var secondDigits = 0
    var hasDateParts = false
    var hasTimeParts = false
    var hasElapsed = false

    /// Exactly "@": the text as is.
    var isPlainText = false

    init(kind: Kind) {
        self.kind = kind
    }
}

/// A parsed pattern. Invalid patterns display like Automatic.
final class ParsedFormat: Sendable {
    let isValid: Bool
    let sections: [FormatSection]
    /// The sections for numbers: positive, negative, zero (fewer when the pattern has fewer).
    let numberSections: [FormatSection]
    /// The section for text values, if the pattern has one.
    let textSection: FormatSection?

    static let invalid = ParsedFormat()

    private init() {
        isValid = false
        sections = []
        numberSections = []
        textSection = nil
    }

    init(sections: [FormatSection]) {
        isValid = true
        self.sections = sections
        if sections.count == 4 {
            numberSections = Array(sections[0..<3])
            textSection = sections[3]
        } else if let last = sections.last, last.kind == .text {
            numberSections = Array(sections.dropLast())
            textSection = last
        } else {
            numberSections = sections
            textSection = nil
        }
    }

    /// The section that shows `value`, and whether it shows the value without its sign (the negative
    /// section, and a first section with a condition, as in Excel). Nil means Automatic.
    func section(for value: Double) -> (section: FormatSection, absolute: Bool)? {
        let sections = numberSections
        guard let first = sections.first else { return nil }
        if let condition = first.condition {
            if condition.matches(value) { return (first, true) }
        } else if sections.count == 1 || (sections.count == 2 && value >= 0) || (sections.count >= 2 && value > 0) {
            return (first, false)
        }
        guard sections.count >= 2 else { return nil }
        let second = sections[1]
        if let condition = second.condition {
            if condition.matches(value) { return (second, true) }
        } else if value < 0 || (sections.count == 2 && first.condition != nil) {
            return (second, true)
        }
        guard sections.count >= 3 else { return nil }
        return (sections[2], false)
    }
}
