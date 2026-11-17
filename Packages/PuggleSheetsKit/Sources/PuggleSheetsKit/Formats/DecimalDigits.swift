import Foundation

/// The magnitude of a number as decimal digits: `significand × 10^exponent`.
///
/// Spreadsheets round what they show from a number's decimal form cut to 15 significant digits, so
/// 1.005 shows as "1.01" with two decimals and 0.1 + 0.2 as "0.3". Working on these digits
/// reproduces that without NumberFormatter and without binary rounding surprises.
struct DecimalDigits: Sendable {
    /// Never ends in a zero digit; 0 for zero.
    private(set) var significand: UInt64
    /// The number of digits in `significand`; 0 for zero.
    private(set) var count: Int
    private(set) var exponent: Int

    static let zero = DecimalDigits(significand: 0, count: 0, exponent: 0)

    /// 10^0 through 10^19.
    static let powersOfTen: [UInt64] = {
        var powers: [UInt64] = [1]
        for _ in 1...19 { powers.append(powers[powers.count - 1] &* 10) }
        return powers
    }()

    private init(significand: UInt64, count: Int, exponent: Int) {
        self.significand = significand
        self.count = count
        self.exponent = exponent
    }

    /// `significand × 10^exponent`, normalized.
    init(significand: UInt64, exponent: Int) {
        guard significand != 0 else {
            self = .zero
            return
        }
        var significand = significand
        var exponent = exponent
        while significand % 10 == 0 {
            significand /= 10
            exponent += 1
        }
        var count = 1
        while count < 20, significand >= DecimalDigits.powersOfTen[count] { count += 1 }
        self.init(significand: significand, count: count, exponent: exponent)
    }

    /// The magnitude of `value` to 15 significant digits; zero for zero and non-finite values.
    init(_ value: Double) {
        let magnitude = value.magnitude
        guard magnitude.isFinite, magnitude != 0 else {
            self = .zero
            return
        }
        if magnitude < 9_007_199_254_740_992, magnitude == magnitude.rounded(.towardZero) {
            self = DecimalDigits(significand: UInt64(magnitude), exponent: 0).rounded(toSignificantDigits: 15)
            return
        }
        // Double.description is the shortest text that reads back as the same Double.
        var significand: UInt64 = 0
        var digitCount = 0
        var exponent = 0
        var afterPoint = false
        var inExponent = false
        var exponentValue = 0
        var exponentSign = 1
        for byte in magnitude.description.utf8 {
            switch byte {
            case 0x30...0x39:
                let digit = UInt64(byte &- 0x30)
                if inExponent {
                    exponentValue = exponentValue * 10 + Int(digit)
                } else if significand == 0, digit == 0 {
                    if afterPoint { exponent -= 1 }
                } else if digitCount < 19 {
                    significand = significand * 10 + digit
                    digitCount += 1
                    if afterPoint { exponent -= 1 }
                } else if !afterPoint {
                    exponent += 1
                }
            case 0x2E: afterPoint = true
            case 0x45, 0x65: inExponent = true
            case 0x2D: exponentSign = -1
            default: break
            }
        }
        self = DecimalDigits(significand: significand, exponent: exponent + exponentSign * exponentValue)
            .rounded(toSignificantDigits: 15)
    }

    var isZero: Bool { significand == 0 }

    /// The power of ten of the first digit: 2 for 123.4, -3 for 0.00123, 0 for zero.
    var leadingExponent: Int { significand == 0 ? 0 : count + exponent - 1 }

    /// The position after the decimal point of the last non-zero digit (0 for tenths), or -1 for
    /// whole numbers.
    var lastFractionIndex: Int { exponent >= 0 ? -1 : -exponent - 1 }

    /// The number times 10^places.
    func shifted(by places: Int) -> DecimalDigits {
        significand == 0 ? self : DecimalDigits(significand: significand, count: count, exponent: exponent + places)
    }

    /// Rounded half away from zero to `places` digits after the decimal point.
    func rounded(toDecimals places: Int) -> DecimalDigits {
        droppingDigits(-(exponent + places))
    }

    /// Rounded half away from zero to at most `digits` significant digits.
    func rounded(toSignificantDigits digits: Int) -> DecimalDigits {
        droppingDigits(count - max(1, digits))
    }

    private func droppingDigits(_ dropped: Int) -> DecimalDigits {
        guard dropped > 0, significand != 0 else { return self }
        guard dropped <= count else { return .zero }
        let divisor = DecimalDigits.powersOfTen[dropped]
        let kept = significand / divisor + (significand % divisor >= divisor / 2 ? 1 : 0)
        return DecimalDigits(significand: kept, exponent: exponent + dropped)
    }

    /// The digit (0–9) at decimal position `power`: 0 is the units, -1 the tenths, 2 the hundreds.
    func digit(atPower power: Int) -> UInt8 {
        guard power >= exponent, power < exponent + count else { return 0 }
        return UInt8((significand / DecimalDigits.powersOfTen[power - exponent]) % 10)
    }

    /// ASCII digits of the integer part, most significant first; empty when the integer part is 0.
    func integerDigits() -> [UInt8] {
        let length = count + exponent
        guard significand != 0, length > 0 else { return [] }
        var digits = [UInt8](repeating: 0x30, count: length)
        var remaining = exponent >= 0 ? significand : significand / DecimalDigits.powersOfTen[-exponent]
        var index = exponent >= 0 ? count - 1 : length - 1
        while index >= 0 {
            digits[index] = UInt8(remaining % 10) &+ 0x30
            remaining /= 10
            index -= 1
        }
        return digits
    }

    /// Writes every digit in plain decimal notation: "1234.5", "0.001", "1000".
    func writePlain(into builder: inout TextBuilder) {
        guard significand != 0 else {
            builder.append(0x30)
            return
        }
        for power in stride(from: max(leadingExponent, 0), through: 0, by: -1) {
            builder.append(digit(atPower: power) &+ 0x30)
        }
        guard exponent < 0 else { return }
        builder.append(0x2E)
        for power in stride(from: -1, through: exponent, by: -1) {
            builder.append(digit(atPower: power) &+ 0x30)
        }
    }
}

/// Collects UTF-8 bytes for display text; cheaper than appending to a String piece by piece.
struct TextBuilder {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 24) {
        bytes.reserveCapacity(capacity)
    }

    var count: Int { bytes.count }

    mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    mutating func append(_ newBytes: [UInt8]) {
        bytes.append(contentsOf: newBytes)
    }

    mutating func append(_ string: String) {
        bytes.append(contentsOf: string.utf8)
    }

    mutating func append(repeating byte: UInt8, count: Int) {
        guard count > 0 else { return }
        bytes.append(contentsOf: repeatElement(byte, count: count))
    }

    /// Appends `value` in decimal, padded with leading zeros to `minimumDigits`.
    mutating func appendNumber(_ value: Int, minimumDigits: Int = 1) {
        if value < 0 { bytes.append(0x2D) }
        var magnitude = value.magnitude
        var length = 1
        var probe = magnitude
        while probe >= 10 {
            probe /= 10
            length += 1
        }
        append(repeating: 0x30, count: minimumDigits - length)
        let start = bytes.count
        bytes.append(contentsOf: repeatElement(0x30, count: length))
        var index = start + length - 1
        repeat {
            bytes[index] = UInt8(magnitude % 10) &+ 0x30
            magnitude /= 10
            index -= 1
        } while magnitude > 0
    }

    func makeString() -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    func makeString(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }
}

/// ASCII digits of a non-negative integer.
func asciiDigits(of value: Int) -> [UInt8] {
    var builder = TextBuilder(capacity: 8)
    builder.appendNumber(value)
    return builder.bytes
}
