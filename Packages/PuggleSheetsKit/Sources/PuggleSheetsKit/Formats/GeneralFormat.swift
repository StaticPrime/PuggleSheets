import Foundation

/// Number text without a pattern: the Automatic format and the text formulas make from numbers.
enum GeneralFormat {
    /// Automatic: whole numbers below 10^15 in full, others with at most 10 significant digits,
    /// scientific notation with 6 significant digits for magnitudes of at least 10^15 or below 10^-9.
    static func automatic(_ number: Double) -> String {
        guard number.isFinite else { return CellError.Kind.number.rawValue }
        var builder = TextBuilder()
        writeAutomatic(number, into: &builder)
        return builder.makeString()
    }

    static func writeAutomatic(_ number: Double, into builder: inout TextBuilder) {
        let digits = DecimalDigits(number)
        guard !digits.isZero else {
            builder.append(0x30)
            return
        }
        let negative = number < 0
        let lead = digits.leadingExponent
        if lead >= 15 || lead < -9 {
            writeScientific(digits, significantDigits: 6, negative: negative, into: &builder)
            return
        }
        // Never round away integer digits; otherwise keep 10 significant digits.
        let rounded = lead >= 9 ? digits.rounded(toDecimals: 0) : digits.rounded(toSignificantDigits: 10)
        if rounded.leadingExponent >= 15 {
            writeScientific(rounded, significantDigits: 6, negative: negative, into: &builder)
            return
        }
        if negative { builder.append(0x2D) }
        rounded.writePlain(into: &builder)
    }

    /// The text formulas make from a number: up to 15 significant digits, scientific notation from
    /// 10^15 up and below 10^-6.
    static func formulaText(_ number: Double) -> String {
        guard number.isFinite else { return CellError.Kind.number.rawValue }
        let digits = DecimalDigits(number)
        guard !digits.isZero else { return "0" }
        var builder = TextBuilder()
        writeFormulaText(digits, negative: number < 0, into: &builder)
        return builder.makeString()
    }

    static func writeFormulaText(_ digits: DecimalDigits, negative: Bool, into builder: inout TextBuilder) {
        guard !digits.isZero else {
            builder.append(0x30)
            return
        }
        let lead = digits.leadingExponent
        if lead >= 15 || lead < -6 {
            writeScientific(digits, significantDigits: 15, negative: negative, into: &builder)
        } else {
            if negative { builder.append(0x2D) }
            digits.rounded(toSignificantDigits: 15).writePlain(into: &builder)
        }
    }

    /// "1.23457E+15", "-1E-10": a mantissa with trailing zeros removed and a two-digit exponent at least.
    static func writeScientific(_ digits: DecimalDigits, significantDigits: Int, negative: Bool,
                                into builder: inout TextBuilder) {
        let rounded = digits.rounded(toSignificantDigits: significantDigits)
        let lead = rounded.leadingExponent
        if negative { builder.append(0x2D) }
        builder.append(rounded.digit(atPower: lead) &+ 0x30)
        if rounded.count > 1 {
            builder.append(0x2E)
            for power in stride(from: lead - 1, through: rounded.exponent, by: -1) {
                builder.append(rounded.digit(atPower: power) &+ 0x30)
            }
        }
        builder.append(0x45)
        builder.append(lead < 0 ? 0x2D : 0x2B)
        builder.appendNumber(abs(lead), minimumDigits: 2)
    }

    /// Automatic text cut to `maxLength` characters: fewer decimals first (rounded), then scientific
    /// notation with fewer significant digits. When even one significant digit doesn't fit, the
    /// shortest scientific form is returned anyway.
    static func automatic(_ number: Double, maxLength: Int) -> String {
        let full = automatic(number)
        guard full.utf8.count > maxLength else { return full }
        guard maxLength > 0 else { return "" }
        guard number.isFinite, number != 0 else { return full }
        let negative = number < 0
        let signLength = negative ? 1 : 0
        let digits = DecimalDigits(number)
        let lead = digits.leadingExponent
        if lead < 15, lead >= -9 {
            let integerLength = max(1, lead + 1)
            let decimals = maxLength - signLength - integerLength - 1
            if decimals >= 1, let text = plain(digits.rounded(toDecimals: decimals), negative: negative),
               text.utf8.count <= maxLength {
                return text
            }
            if integerLength + signLength <= maxLength,
               let text = plain(digits.rounded(toDecimals: 0), negative: negative), text.utf8.count <= maxLength {
                return text
            }
        }
        var shortest = ""
        for significant in stride(from: 6, through: 1, by: -1) {
            var builder = TextBuilder()
            writeScientific(digits, significantDigits: significant, negative: negative, into: &builder)
            shortest = builder.makeString()
            if shortest.utf8.count <= maxLength { return shortest }
        }
        return shortest
    }

    /// Plain decimal text, or nil when the rounding left nothing but zero.
    private static func plain(_ digits: DecimalDigits, negative: Bool) -> String? {
        guard !digits.isZero else { return nil }
        var builder = TextBuilder()
        if negative { builder.append(0x2D) }
        digits.writePlain(into: &builder)
        return builder.makeString()
    }
}
