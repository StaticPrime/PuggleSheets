import Foundation

/// Numbers in the form the formula bar shows and InputParser reads back.
enum EditText {
    static func number(_ number: Double, kind: NumberFormatKind) -> String {
        guard number.isFinite else { return CellError.Kind.number.rawValue }
        switch kind {
        case .percent:
            return plain(DecimalDigits(number).shifted(by: 2), negative: number < 0) + "%"
        case .date, .time, .dateTime, .duration:
            return dateTime(number, kind: kind) ?? plain(DecimalDigits(number), negative: number < 0)
        default:
            return plain(DecimalDigits(number), negative: number < 0)
        }
    }

    /// Up to 15 significant digits without grouping. Plain notation from 10^-9 up to 10^21, so that
    /// reading the text back implies no scientific format; scientific notation beyond.
    private static func plain(_ digits: DecimalDigits, negative: Bool) -> String {
        guard !digits.isZero else { return "0" }
        var builder = TextBuilder()
        let lead = digits.leadingExponent
        if lead < -9 || lead > 20 {
            GeneralFormat.writeScientific(digits, significantDigits: 15, negative: negative, into: &builder)
        } else {
            if negative { builder.append(0x2D) }
            digits.writePlain(into: &builder)
        }
        return builder.makeString()
    }

    /// "1/2/2026", "3:59:00 PM", "1/2/2026 15:59:00" or "25:30:00", to the millisecond.
    private static func dateTime(_ serial: Double, kind: NumberFormatKind) -> String? {
        guard abs(serial) < FormatRenderer.maximumDateSerial else { return nil }
        let millisecondsPerDay = 86_400_000
        let total = Int((serial * Double(millisecondsPerDay)).rounded())
        var builder = TextBuilder()

        if kind == .duration {
            let magnitude = abs(total)
            if total < 0 { builder.append(0x2D) }
            builder.appendNumber(magnitude / 3_600_000)
            writeMinutesAndSeconds(magnitude % 3_600_000, into: &builder)
            return builder.makeString()
        }

        let days = FormatRenderer.floorDivide(total, millisecondsPerDay)
        let milliseconds = total - days * millisecondsPerDay
        let showsDate = kind != .time || days != 0
        let showsTime = kind != .date || milliseconds != 0
        if showsDate {
            let civil = DateSerial.civilFromDays(days - DateSerial.unixEpochSerial)
            builder.appendNumber(civil.month)
            builder.append(0x2F)
            builder.appendNumber(civil.day)
            builder.append(0x2F)
            builder.appendNumber(civil.year, minimumDigits: 4)
        }
        guard showsTime else { return builder.makeString() }
        let hour = milliseconds / 3_600_000
        if showsDate {
            builder.append(0x20)
            builder.appendNumber(hour)
            writeMinutesAndSeconds(milliseconds % 3_600_000, into: &builder)
        } else {
            builder.appendNumber(hour % 12 == 0 ? 12 : hour % 12)
            writeMinutesAndSeconds(milliseconds % 3_600_000, into: &builder)
            builder.append(hour < 12 ? " AM" : " PM")
        }
        return builder.makeString()
    }

    /// ":mm:ss", plus up to three decimals of a second when there are any.
    private static func writeMinutesAndSeconds(_ milliseconds: Int, into builder: inout TextBuilder) {
        builder.append(0x3A)
        builder.appendNumber(milliseconds / 60000, minimumDigits: 2)
        builder.append(0x3A)
        builder.appendNumber(milliseconds / 1000 % 60, minimumDigits: 2)
        var fraction = milliseconds % 1000
        guard fraction > 0 else { return }
        var digits = 3
        while fraction % 10 == 0 {
            fraction /= 10
            digits -= 1
        }
        builder.append(0x2E)
        builder.appendNumber(fraction, minimumDigits: digits)
    }
}
