import Foundation

/// Dates as spreadsheets store them: the number of days since December 30, 1899, with the time of day
/// as the fraction. 1 January 1900 is 2, noon is 0.5. Calendar math is proleptic Gregorian.
public enum DateSerial {
    public struct Parts: Hashable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int
        public var hour: Int
        public var minute: Int
        public var second: Int
        public var millisecond: Int
    }

    /// Days from 1970-01-01 to the given civil date (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// Serial 0 is 1899-12-30, which is 25,569 days before 1970-01-01.
    static let unixEpochSerial = 25_569

    /// The serial for a date. Months and days outside their usual ranges roll over, as DATE() does:
    /// month 13 is January of the next year and day 0 is the last day of the previous month.
    public static func serial(year: Int, month: Int, day: Int) -> Double {
        let months = year * 12 + (month - 1)
        let normalizedYear = Int((Double(months) / 12).rounded(.down))
        let normalizedMonth = months - normalizedYear * 12 + 1
        return Double(daysFromCivil(normalizedYear, normalizedMonth, 1) + day - 1 + unixEpochSerial)
    }

    public static func serial(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Double) -> Double {
        serial(year: year, month: month, day: day) + time(hour: hour, minute: minute, second: second)
    }

    /// A time of day as a fraction of a day; values roll over like TIME().
    public static func time(hour: Int, minute: Int, second: Double) -> Double {
        (Double(hour) * 3600 + Double(minute) * 60 + second) / 86_400
    }

    /// The calendar parts of a serial, rounded to the nearest millisecond.
    public static func parts(of serial: Double) -> Parts {
        let totalMilliseconds = (serial * 86_400_000).rounded()
        let days = (totalMilliseconds / 86_400_000).rounded(.down)
        var milliseconds = Int(totalMilliseconds - days * 86_400_000)
        let date = civilFromDays(Int(days) - unixEpochSerial)
        let hour = milliseconds / 3_600_000
        milliseconds %= 3_600_000
        let minute = milliseconds / 60000
        milliseconds %= 60000
        return Parts(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute,
                     second: milliseconds / 1000, millisecond: milliseconds % 1000)
    }

    /// 1 for Sunday through 7 for Saturday.
    public static func weekday(of serial: Double) -> Int {
        // Serial 0 (1899-12-30) was a Saturday, serial 1 a Sunday.
        let index = ((Int(serial.rounded(.down)) % 7) + 7) % 7
        return index == 0 ? 7 : index
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// The serial for a moment, as seen on a clock in `timeZone`.
    public static func serial(from date: Date, timeZone: TimeZone = .current) -> Double {
        let local = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        return local / 86_400 + Double(unixEpochSerial)
    }

    /// The moment a serial names on a clock in `timeZone`.
    public static func date(fromSerial serial: Double, timeZone: TimeZone = .current) -> Date {
        let local = (serial - Double(unixEpochSerial)) * 86_400
        let guess = Date(timeIntervalSince1970: local)
        return Date(timeIntervalSince1970: local - Double(timeZone.secondsFromGMT(for: guess)))
    }
}
