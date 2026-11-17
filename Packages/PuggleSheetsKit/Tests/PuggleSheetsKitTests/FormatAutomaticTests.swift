import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormatAutomaticTests {
    @Test func automaticNumbers() {
        #expect(shown(1_234_567, nil) == "1234567")
        #expect(shown(123_456_789_012_345, nil) == "123456789012345")
        #expect(shown(999_999_999_999_999, nil) == "999999999999999")
        #expect(shown(-42, nil) == "-42")
        #expect(shown(1.0 / 3, nil) == "0.3333333333")
        #expect(shown(2.0 / 3, nil) == "0.6666666667")
        #expect(shown(100.0 / 3, nil) == "33.33333333")
        #expect(shown(1234.5678, nil) == "1234.5678")
        #expect(shown(-1.5, nil) == "-1.5")
        #expect(shown(0.1 + 0.2, nil) == "0.3")
        #expect(shown(1.0 / 3000, nil) == "0.0003333333333")
        #expect(shown(12_345_678_901.5, nil) == "12345678902")
        #expect(shown(1e-9, nil) == "0.000000001")
        #expect(shown(0.99999999999, nil) == "1")
    }

    @Test func automaticScientific() {
        #expect(shown(1e15, nil) == "1E+15")
        #expect(shown(1_234_567_890_123_456, nil) == "1.23457E+15")
        #expect(shown(-1.5e20, nil) == "-1.5E+20")
        #expect(shown(1e100, nil) == "1E+100")
        #expect(shown(1e-10, nil) == "1E-10")
        #expect(shown(1.234567e-12, nil) == "1.23457E-12")
        #expect(shown(1.5e-300, nil) == "1.5E-300")
    }

    @Test func automaticNeverShowsMinusZero() {
        #expect(shown(-0.0, nil) == "0")
        #expect(shown(0, nil) == "0")
        #expect(shown(-1e-20, nil) == "-1E-20")
    }

    @Test func automaticOtherValues() {
        #expect(CellDisplay.text(for: .boolean(true), pattern: nil).text == "TRUE")
        #expect(CellDisplay.text(for: .boolean(false), pattern: nil).text == "FALSE")
        #expect(CellDisplay.text(for: .error(CellError(.notAvailable)), pattern: nil).text == "#N/A")
        #expect(CellDisplay.text(for: .text("  as is  "), pattern: nil).text == "  as is  ")
        #expect(CellDisplay.text(for: .empty, pattern: nil).text == "")
    }

    @Test func narrowColumnsDropDecimalsThenUseScientific() {
        func narrow(_ number: Double, _ length: Int) -> String { CellDisplay.automaticNumberText(number, maxLength: length) }
        #expect(narrow(1.0 / 3, 20) == "0.3333333333")
        #expect(narrow(1.0 / 3, 5) == "0.333")
        #expect(narrow(2.0 / 3, 5) == "0.667")
        #expect(narrow(-1.0 / 3, 6) == "-0.333")
        #expect(narrow(1234.5678, 6) == "1234.6")
        #expect(narrow(1234.5678, 5) == "1235")
        #expect(narrow(1234.5678, 4) == "1235")
        #expect(narrow(9.97, 3) == "10")
        #expect(narrow(0.000123, 6) == "0.0001")
        #expect(narrow(0.000123, 5) == "1E-04")
        #expect(narrow(123_456_789, 5) == "1E+08")
        #expect(narrow(123_456_789, 7) == "1.2E+08")
        #expect(narrow(123_456_789_012, 10) == "1.2346E+11")
        #expect(narrow(1_234_567_890_123_456, 8) == "1.23E+15")
        #expect(narrow(1e15, 3) == "1E+15")
        #expect(narrow(5, 1) == "5")
        #expect(narrow(0.5, 0) == "")
        for length in 6...12 {
            #expect(narrow(Double.pi * 1e7, length).count <= length)
            #expect(narrow(-Double.pi / 1e4, length).count <= length)
        }
    }

    @Test func formulaText() {
        #expect(NumberText.general(1.0 / 3) == "0.333333333333333")
        #expect(NumberText.general(2.0 / 3) == "0.666666666666667")
        #expect(NumberText.general(1e20) == "1E+20")
        #expect(NumberText.general(1e15) == "1E+15")
        #expect(NumberText.general(1e-7) == "1E-07")
        #expect(NumberText.general(0.000001) == "0.000001")
        #expect(NumberText.general(123_456_789_012_345) == "123456789012345")
        #expect(NumberText.general(1_234_567.125) == "1234567.125")
        #expect(NumberText.general(12_345_678_901_234_568) == "1.23456789012346E+16")
        #expect(NumberText.general(0.1 + 0.2) == "0.3")
        #expect(NumberText.general(-2.5) == "-2.5")
        #expect(NumberText.general(-0.0) == "0")
        #expect(NumberText.general(42) == "42")
        #expect(NumberText.general(1.5e-10) == "1.5E-10")
    }

    @Test func editTextForNumbers() {
        func edit(_ number: Double, _ pattern: String?) -> String {
            var cell = Cell(value: .number(number))
            cell.format.numberFormat = pattern
            return CellDisplay.editText(for: cell)
        }
        #expect(edit(1234.5, "\"$\"#,##0.00") == "1234.5")
        #expect(edit(1234.5, nil) == "1234.5")
        #expect(edit(1.0 / 3, nil) == "0.333333333333333")
        #expect(edit(1234.5, NumberFormatPresets.accounting.pattern) == "1234.5")
        #expect(edit(1e20, nil) == "100000000000000000000")
        #expect(edit(1e-7, nil) == "0.0000001")
        #expect(edit(1.5e25, nil) == "1.5E+25")
        #expect(edit(0.12, "0%") == "12%")
        #expect(edit(0.125, "0.00%") == "12.5%")
        #expect(edit(0.07, "0%") == "7%")
        #expect(edit(-0.05, "0%") == "-5%")
        let date = DateSerial.serial(year: 2026, month: 1, day: 2)
        let time = DateSerial.time(hour: 15, minute: 59, second: 0)
        #expect(edit(date, "M/d/yyyy") == "1/2/2026")
        #expect(edit(date, "dddd, mmmm d") == "1/2/2026")
        #expect(edit(date + time, "M/d/yyyy") == "1/2/2026 15:59:00")
        #expect(edit(time, "h:mm:ss AM/PM") == "3:59:00 PM")
        #expect(edit(time, "H:mm") == "3:59:00 PM")
        #expect(edit(DateSerial.time(hour: 0, minute: 5, second: 0), "h:mm") == "12:05:00 AM")
        #expect(edit(DateSerial.time(hour: 9, minute: 0, second: 1.5), "h:mm:ss") == "9:00:01.5 AM")
        #expect(edit(date + time, "M/d/yyyy H:mm:ss") == "1/2/2026 15:59:00")
        #expect(edit(date + time, "h:mm") == "1/2/2026 15:59:00")
        #expect(edit(date, "M/d/yyyy H:mm:ss") == "1/2/2026 0:00:00")
        #expect(edit(1.0625, "[h]:mm:ss") == "25:30:00")
        #expect(edit(-1.0625, "[h]:mm:ss") == "-25:30:00")
        #expect(edit(0.5, "[mm]:ss") == "12:00:00")
        #expect(edit(5, "@") == "5")
    }

    @Test func editTextForOtherValues() {
        #expect(CellDisplay.editText(for: Cell(value: .number(3), formula: "=1+2")) == "=1+2")
        #expect(CellDisplay.editText(for: Cell(value: .boolean(true))) == "TRUE")
        #expect(CellDisplay.editText(for: Cell(value: .error(CellError(.reference)))) == "#REF!")
        #expect(CellDisplay.editText(for: Cell()) == "")
        #expect(CellDisplay.editText(for: Cell(value: .text("hello"))) == "hello")
        #expect(CellDisplay.editText(for: Cell(value: .text("1/2 cup"))) == "1/2 cup")
    }

    @Test func editTextQuotesTextThatWouldReadBackAsSomethingElse() {
        for text in ["123", "1,234", "12%", "$5", "1/2/2026", "1/2", "13:45", "TRUE", "false", "#N/A", "=A1", " 12 ", "'quoted", "1e5"] {
            #expect(CellDisplay.editText(for: Cell(value: .text(text))) == "'" + text)
            // Typing the edit text back gives the same text.
            let reread = InputParser.parse("'" + text, currentFormat: nil)
            #expect(reread.value == .text(text) && reread.formula == nil)
        }
        for text in ["hello", "=", "1,23", "2/30/2026", "12 apples", "-", "TRUE story"] {
            #expect(CellDisplay.editText(for: Cell(value: .text(text))) == text)
        }
        var plain = Cell(value: .text("123"))
        plain.format.numberFormat = "@"
        #expect(CellDisplay.editText(for: plain) == "123")
        plain.value = .text("=A1")
        #expect(CellDisplay.editText(for: plain) == "=A1")
    }

    @Test func editTextReadsBackAsTheSameValue() {
        let date = DateSerial.serial(year: 2026, month: 1, day: 2)
        let cases: [(Double, String?)] = [
            (1234.5, "\"$\"#,##0.00"), (0.125, "0.00%"), (date, "M/d/yyyy"),
            (date + DateSerial.time(hour: 15, minute: 59, second: 0), "M/d/yyyy H:mm:ss"),
            (DateSerial.time(hour: 15, minute: 59, second: 0), "h:mm:ss AM/PM"), (1.0625, "[h]:mm:ss"),
            (1.0 / 3, nil), (-98765.4321, "#,##0.00"), (1e20, nil),
        ]
        for (number, pattern) in cases {
            var cell = Cell(value: .number(number))
            cell.format.numberFormat = pattern
            let reread = InputParser.parse(CellDisplay.editText(for: cell), currentFormat: pattern)
            let value = reread.value.numberValue ?? .nan
            #expect(abs(value - number) <= abs(number) * 1e-14 + 1e-9)
        }
    }
}
