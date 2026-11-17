import Foundation
import Testing
@testable import PuggleSheetsKit

/// Formula results that depend on the number-format module (CellDisplay, NumberText, InputParser).
/// Expected values are for the en-US locale.
struct FormulaFormattingTests {
    @Test func textFunction() {
        #expect(eval("=TEXT(1234.5, \"#,##0.00\")") == .text("1,234.50"))
        #expect(eval("=TEXT(0.25, \"0%\")") == .text("25%"))
        #expect(eval("=TEXT(3.14159, \"0.00\")") == .text("3.14"))
        #expect(eval("=TEXT(46342, \"yyyy-mm-dd\")") == .text("2026-11-16"))
        #expect(eval("=TEXT(46342, \"dddd, mmmm d\")") == .text("Monday, November 16"))
        #expect(eval("=TEXT(46342.75, \"M/d/yyyy h:mm\")") == .text("11/16/2026 18:00"))
        #expect(eval("=TEXT(0.5, \"h:mm AM/PM\")") == .text("12:00 PM"))
        #expect(eval("=TEXT(-5, \"0;(0)\")") == .text("(5)"))
        #expect(eval("=TEXT(\"12\", \"0.0\")") == .text("12.0"))
    }

    @Test func numbersBecomeText() {
        #expect(eval("=1/3&\"\"") == .text("0.333333333333333"))
        #expect(eval("=(0.1+0.2)&\"\"") == .text("0.3"))
        #expect(eval("=1E+20&\"\"") == .text("1E+20"))
        #expect(eval("=123456789012345678&\"\"") == .text("1.23456789012346E+17"))
        #expect(eval("=0.000001&\"\"") == .text("0.000001"))
        #expect(eval("=CONCATENATE(2/3)") == .text("0.666666666666667"))
        #expect(eval("=LEN(1/3)") == .number(17))
        #expect(eval("=JOIN(\",\", {0.5, 1E+21})") == .text("0.5,1E+21"))
    }

    @Test func textBecomesNumbers() {
        #expect(eval("=\"1,234\"+1") == .number(1235))
        #expect(eval("=\"12%\"*2") == .number(0.24))
        #expect(eval("=\"$5\"*2") == .number(10))
        #expect(eval("=\"1/2/2026\"+0") == .number(46024))
        #expect(eval("=VALUE(\"1,234.5\")") == .number(1234.5))
        #expect(eval("=VALUE(\"50%\")") == .number(0.5))
        #expect(eval("=SUM(\"1,000\", 1)") == .number(1001))
    }

    @Test func dateAndTimeText() {
        #expect(eval("=DATEVALUE(\"1/2/2026\")") == .number(46024))
        #expect(eval("=DATEVALUE(\"2026-11-16\")") == .number(46342))
        #expect(eval("=DATEVALUE(\"1/2/2026 6:00 PM\")") == .number(46024))
        #expect(close(eval("=TIMEVALUE(\"6:00 PM\")"), 0.75))
        #expect(close(eval("=TIMEVALUE(\"1/2/2026 6:00 PM\")"), 0.75))
        #expect(eval("=YEAR(\"11/16/2026\")") == .number(2026))
        #expect(eval("=DAYS(\"3/1/2026\", \"2/1/2026\")") == .number(28))
        #expect(eval("=EDATE(\"1/31/2026\", 1)") == .number(DateSerial.serial(year: 2026, month: 2, day: 28)))
    }

    @Test func dateCriteria() {
        let cells: [String: CellInput] = ["A1": 46022, "A2": 46023, "A3": 46024, "B1": 500, "B2": 1500]
        #expect(eval("=COUNTIF(A1:A3, \"<=1/1/2026\")", cells) == .number(2))
        #expect(eval("=COUNTIF(A1:A3, \">12/31/2025\")", cells) == .number(2))
        #expect(eval("=SUMIF(B1:B2, \">1,000\")", cells) == .number(1500))
        #expect(eval("=COUNTIF(B1:B2, \"<50%\")", cells) == .number(0))
    }

    @Test func splitParsesTypedValues() {
        #expect(eval("=INDEX(SPLIT(\"1/2/2026,50%\", \",\"), 1, 1)") == .number(46024))
        #expect(eval("=INDEX(SPLIT(\"1/2/2026,50%\", \",\"), 1, 2)") == .number(0.5))
    }

    @Test func messagesShowNumbersAsSheetsDoes() {
        #expect(message(eval("=VLOOKUP(0.1+0.2, {1,2}, 1, FALSE)")) == "Did not find value '0.3' in VLOOKUP evaluation.")
    }
}
