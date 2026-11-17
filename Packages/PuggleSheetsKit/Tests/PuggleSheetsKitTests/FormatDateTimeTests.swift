import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormatDateTimeTests {
    /// Friday, January 2, 2026, 15:04:05.678.
    let moment = DateSerial.serial(year: 2026, month: 1, day: 2, hour: 15, minute: 4, second: 5.678)
    /// Monday, November 9, 2026, 09:07:08.
    let morning = DateSerial.serial(year: 2026, month: 11, day: 9, hour: 9, minute: 7, second: 8)

    @Test func dayTokens() {
        #expect(shown(moment, "d") == "2")
        #expect(shown(moment, "dd") == "02")
        #expect(shown(moment, "ddd") == "Fri")
        #expect(shown(moment, "dddd") == "Friday")
        #expect(shown(moment, "ddddd") == "Friday")
        #expect(shown(morning, "d") == "9")
        #expect(shown(morning, "dddd") == "Monday")
    }

    @Test func monthTokens() {
        #expect(shown(moment, "m") == "1")
        #expect(shown(moment, "mm") == "01")
        #expect(shown(moment, "mmm") == "Jan")
        #expect(shown(moment, "mmmm") == "January")
        #expect(shown(moment, "mmmmm") == "J")
        #expect(shown(moment, "mmmmmm") == "January")
        #expect(shown(morning, "m") == "11")
        #expect(shown(morning, "mmm") == "Nov")
        #expect(shown(morning, "mmmm") == "November")
        #expect(shown(morning, "mmmmm") == "N")
    }

    @Test func yearTokens() {
        #expect(shown(moment, "yy") == "26")
        #expect(shown(moment, "y") == "26")
        #expect(shown(moment, "yyy") == "2026")
        #expect(shown(moment, "yyyy") == "2026")
        #expect(shown(DateSerial.serial(year: 1905, month: 3, day: 4), "yy") == "05")
    }

    @Test func hourMinuteSecondTokens() {
        #expect(shown(moment, "h") == "15")
        #expect(shown(morning, "h") == "9")
        #expect(shown(morning, "hh") == "09")
        #expect(shown(moment, "h:mm") == "15:04")
        #expect(shown(moment, "h:m") == "15:4")
        #expect(shown(moment, "h:mm:ss") == "15:04:06")
        #expect(shown(morning, "hh:mm:ss") == "09:07:08")
        #expect(shown(moment, "mm:ss") == "04:06")
        #expect(shown(moment, "m:s") == "4:6")
        #expect(shown(moment, "s") == "6")
        #expect(shown(morning, "ss") == "08")
    }

    @Test func fractionalSeconds() {
        #expect(shown(moment, "h:mm:ss.000") == "15:04:05.678")
        #expect(shown(moment, "h:mm:ss.00") == "15:04:05.68")
        #expect(shown(moment, "ss.0") == "05.7")
        #expect(shown(moment, "[h]:mm:ss.0") == "1104591:04:05.7")
        #expect(shown(DateSerial.time(hour: 0, minute: 0, second: 59.96), "mm:ss.0") == "01:00.0")
    }

    @Test func amPm() {
        #expect(shown(moment, "h AM/PM") == "3 PM")
        #expect(shown(moment, "h:mm AM/PM") == "3:04 PM")
        #expect(shown(moment, "hh:mm am/pm") == "03:04 PM")
        #expect(shown(moment, "h:mm A/P") == "3:04 P")
        #expect(shown(moment, "h:mm a/p") == "3:04 p")
        #expect(shown(morning, "h:mm AM/PM") == "9:07 AM")
        #expect(shown(morning, "h:mm a/p") == "9:07 a")
        #expect(shown(0, "h:mm AM/PM") == "12:00 AM")
        #expect(shown(0.5, "h:mm AM/PM") == "12:00 PM")
        #expect(shown(0, "h:mm") == "0:00")
        #expect(shown(moment, "h:mm:ss AM/PM") == "3:04:06 PM")
    }

    @Test func minuteOrMonth() {
        // m after hours or before seconds is minutes; otherwise it is the month.
        #expect(shown(moment, "m/d/yyyy h:mm") == "1/2/2026 15:04")
        #expect(shown(moment, "yyyy-mm-dd hh:mm:ss") == "2026-01-02 15:04:06")
        #expect(shown(moment, "dd/mm") == "02/01")
        #expect(shown(moment, "mm") == "01")
        #expect(shown(moment, "[h]:mm") == "1104591:04")
        #expect(shown(moment, "h \"h\" m \"min\"") == "15 h 4 min")
        #expect(shown(moment, "m \"min\" s \"s\"") == "4 min 6 s")
        #expect(shown(moment, "mmm h:mm") == "Jan 15:04")
    }

    @Test func sheetsStylePatterns() {
        #expect(shown(moment, "M/d/yyyy") == "1/2/2026")
        #expect(shown(moment, "MM/dd/yyyy") == "01/02/2026")
        #expect(shown(moment, "MMM d, yyyy") == "Jan 2, 2026")
        #expect(shown(moment, "dddd, mmmm d, yyyy") == "Friday, January 2, 2026")
        #expect(shown(moment, "M/d/yyyy H:mm:ss") == "1/2/2026 15:04:06")
        #expect(shown(moment, "yyyy\"年\"m\"月\"d\"日\"") == "2026年1月2日")
        #expect(shown(moment, "d-mmm-yy") == "2-Jan-26")
        #expect(shown(moment, "[$-409]mmmm d, yyyy") == "January 2, 2026")
    }

    @Test func elapsedTime() {
        #expect(shown(1.5, "[h]:mm:ss") == "36:00:00")
        #expect(shown(1.0 + 1.0 / 1440, "[h]:mm:ss") == "24:01:00")
        #expect(shown(0.5, "[mm]:ss") == "720:00")
        #expect(shown(0.5, "[ss]") == "43200")
        #expect(shown(2.25, "[h]") == "54")
        #expect(shown(0.25, "[hh]:mm") == "06:00")
        #expect(shown(-0.5, "[h]:mm") == "-12:00")
        #expect(shown(-1.0625, "[h]:mm:ss") == "-25:30:00")
        #expect(shown(1.0000001, "[h]:mm:ss") == "24:00:00")
    }

    @Test func roundingCarriesIntoTheNextUnit() {
        #expect(shown(0.99999999, "h:mm:ss") == "0:00:00")
        #expect(shown(DateSerial.serial(year: 2026, month: 1, day: 2) - 0.000001, "M/d/yyyy h:mm:ss") == "1/2/2026 0:00:00")
        #expect(shown(DateSerial.time(hour: 10, minute: 59, second: 59.6), "h:mm:ss") == "11:00:00")
        #expect(shown(DateSerial.time(hour: 10, minute: 59, second: 59.6), "h:mm:ss.0") == "10:59:59.6")
    }

    @Test func datesBeforeTheEpochAndOutOfRange() {
        #expect(shown(-1, "M/d/yyyy") == "12/29/1899")
        #expect(shown(0, "M/d/yyyy") == "12/30/1899")
        #expect(shown(1, "dddd") == "Sunday")
        #expect(shown(1e10, "M/d/yyyy") == "10000000000")
    }

    @Test func literalsInDates() {
        #expect(shown(moment, "\"Date: \"M/d") == "Date: 1/2")
        #expect(shown(moment, "d\\d") == "2d")
        #expect(shown(moment, "yyyy.mm.dd") == "2026.01.02")
        #expect(CellDisplay.text(for: .number(moment), pattern: "[Blue]M/d").color?.hex == "0000FF")
        let filled = CellDisplay.text(for: .number(moment), pattern: "M/d* ")
        #expect(filled.fill == DisplayText.Fill(before: "1/2", after: ""))
    }
}
