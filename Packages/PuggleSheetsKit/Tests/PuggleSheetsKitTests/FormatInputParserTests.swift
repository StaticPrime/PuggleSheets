import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormatInputParserTests {
    func parse(_ input: String, _ format: String? = nil) -> ParsedInput {
        InputParser.parse(input, currentFormat: format)
    }

    func number(_ input: String) -> (value: Double?, format: String?) {
        let parsed = parse(input)
        return (parsed.value.numberValue, parsed.impliedFormat)
    }

    let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())

    @Test func emptyFormulasAndApostrophes() {
        #expect(parse("") == ParsedInput(value: .empty))
        #expect(parse("=SUM(A1:A3)") == ParsedInput(value: .empty, formula: "=SUM(A1:A3)"))
        #expect(parse("=1+1") == ParsedInput(value: .empty, formula: "=1+1"))
        #expect(parse("=") == ParsedInput(value: .text("=")))
        #expect(parse("'123") == ParsedInput(value: .text("123")))
        #expect(parse("'=1+1") == ParsedInput(value: .text("=1+1")))
        #expect(parse("''x") == ParsedInput(value: .text("'x")))
        #expect(parse("'") == ParsedInput(value: .text("")))
        #expect(parse(" =1") == ParsedInput(value: .text(" =1")))
    }

    @Test func plainTextFormatKeepsEverythingAsTyped() {
        for input in ["=1+1", "123", "'abc", "TRUE", "1/2/2026", "12%", "  5 ", "#N/A"] {
            #expect(parse(input, "@") == ParsedInput(value: .text(input)))
        }
        #expect(parse("", "@") == ParsedInput(value: .empty))
        #expect(parse("123", "\"No. \"@") == ParsedInput(value: .text("123")))
    }

    @Test func plainNumbers() {
        #expect(parse("42") == ParsedInput(value: .number(42)))
        #expect(parse("  42  ") == ParsedInput(value: .number(42)))
        #expect(parse("-3.5") == ParsedInput(value: .number(-3.5)))
        #expect(parse("+7") == ParsedInput(value: .number(7)))
        #expect(parse(".5") == ParsedInput(value: .number(0.5)))
        #expect(parse("-.5") == ParsedInput(value: .number(-0.5)))
        #expect(parse("5.") == ParsedInput(value: .number(5)))
        #expect(parse("007") == ParsedInput(value: .number(7)))
        #expect(parse("0.1") == ParsedInput(value: .number(0.1)))
        #expect(parse("-0") == ParsedInput(value: .number(0)))
        #expect(parse("1234567890123456789") == ParsedInput(value: .number(Double("1234567890123456789")!)))
    }

    @Test func groupedNumbers() {
        #expect(number("1,234") == (1234, "#,##0"))
        #expect(number("1,234,567.89") == (1_234_567.89, "#,##0.00"))
        #expect(number("-1,234.5") == (-1234.5, "#,##0.00"))
        #expect(number("12,345") == (12345, "#,##0"))
        for text in ["1,23", "1,2345", "1234,567", ",123", "1,,234", "1,234,56", "1,234.5,6"] {
            #expect(parse(text) == ParsedInput(value: .text(text)))
        }
    }

    @Test func exponents() {
        #expect(number("1e5") == (100_000, "0.00E+00"))
        #expect(number("1E+05") == (100_000, "0.00E+00"))
        #expect(number("-1.5E-3") == (-0.0015, "0.00E+00"))
        #expect(number("2.5e10") == (2.5e10, "0.00E+00"))
        for text in ["e5", "1e", "1e+", ".e5", "1e5.5", "1e400"] {
            #expect(parse(text) == ParsedInput(value: .text(text)))
        }
    }

    @Test func percentages() {
        #expect(number("12%") == (0.12, "0%"))
        #expect(number("12.5 %") == (0.125, "0.00%"))
        #expect(number("-5%") == (-0.05, "0%"))
        #expect(number("7%") == (0.07, "0%"))
        #expect(number("1.1%") == (0.011, "0.00%"))
        #expect(number(".5%") == (0.005, "0.00%"))
        #expect(number("1,000%") == (10, "0%"))
        for text in ["%5", "5%%", "$5%", "1e2%"] {
            #expect(parse(text) == ParsedInput(value: .text(text)))
        }
    }

    @Test func currency() {
        #expect(number("$5") == (5, "\"$\"#,##0"))
        #expect(number("$5.50") == (5.5, "\"$\"#,##0.00"))
        #expect(number("-$1,200") == (-1200, "\"$\"#,##0"))
        #expect(number("$-5") == (-5, "\"$\"#,##0"))
        #expect(number("$1,234.5") == (1234.5, "\"$\"#,##0.00"))
        #expect(number("$ 5") == (5, "\"$\"#,##0"))
        for text in ["$", "5$", "$$5", "-$-5", "$1e5"] {
            #expect(parse(text) == ParsedInput(value: .text(text)))
        }
    }

    @Test func dates() {
        let january2 = DateSerial.serial(year: 2026, month: 1, day: 2)
        for text in ["1/2/2026", "01/02/2026", "1/2/26", "1-2-2026", "2026-01-02", "2026/1/2", "2026-1-2", "Jan 2, 2026",
                     "January 2 2026", "jan 2,2026", "Jan. 2, 2026", "2 Jan 2026", "2 January, 2026", "2-Jan-2026",
                     "2-Jan-26", "Jan-2-2026", " 1/2/2026 "] {
            #expect(number(text) == (january2, "M/d/yyyy"), "\(text)")
        }
        let thisYearsJanuary2 = DateSerial.serial(year: thisYear, month: 1, day: 2)
        for text in ["1/2", "Jan 2", "2 Jan", "2-Jan", "Jan. 2"] {
            #expect(number(text) == (thisYearsJanuary2, "M/d/yyyy"), "\(text)")
        }
        #expect(number("12/31/1999").value == DateSerial.serial(year: 1999, month: 12, day: 31))
        #expect(number("2/29/2024").value == DateSerial.serial(year: 2024, month: 2, day: 29))
        #expect(number("Sept 9, 2026").value == DateSerial.serial(year: 2026, month: 9, day: 9))
    }

    @Test func twoDigitYears() {
        #expect(number("1/2/00").value == DateSerial.serial(year: 2000, month: 1, day: 2))
        #expect(number("1/2/29").value == DateSerial.serial(year: 2029, month: 1, day: 2))
        #expect(number("1/2/30").value == DateSerial.serial(year: 1930, month: 1, day: 2))
        #expect(number("1/2/99").value == DateSerial.serial(year: 1999, month: 1, day: 2))
        #expect(number("1/2/5").value == DateSerial.serial(year: 2005, month: 1, day: 2))
    }

    @Test func impossibleDatesStayText() {
        for text in ["2/30/2026", "2/29/2026", "13/1/2026", "0/5/2026", "1/32", "4/31/2026", "1/2/123", "Jan 32, 2026",
                     "Foo 2, 2026", "2026-13-01", "1/2/2026/3", "1-2"] {
            #expect(parse(text) == ParsedInput(value: .text(text)), "\(text)")
        }
    }

    @Test func times() {
        func time(_ hour: Int, _ minute: Int, _ second: Double = 0) -> Double {
            DateSerial.time(hour: hour, minute: minute, second: second)
        }
        #expect(number("13:45") == (time(13, 45), "H:mm"))
        #expect(number("0:30") == (time(0, 30), "H:mm"))
        #expect(number("1:45 PM") == (time(13, 45), "h:mm AM/PM"))
        #expect(number("1:45pm") == (time(13, 45), "h:mm AM/PM"))
        #expect(number("1:45 am") == (time(1, 45), "h:mm AM/PM"))
        #expect(number("12:15 AM") == (time(0, 15), "h:mm AM/PM"))
        #expect(number("12:15 PM") == (time(12, 15), "h:mm AM/PM"))
        #expect(number("1:45:30") == (time(1, 45, 30), "H:mm:ss"))
        #expect(number("1:45:30 PM") == (time(13, 45, 30), "h:mm:ss AM/PM"))
        #expect(number("1:45:30.5") == (time(1, 45, 30.5), "H:mm:ss"))
        #expect(number("1 PM") == (time(13, 0), "h:mm AM/PM"))
        #expect(number("11 a") == (time(11, 0), "h:mm AM/PM"))
        #expect(number("12 AM") == (0, "h:mm AM/PM"))
        for text in ["25:30:00", "24:00", "100:00:00"] {
            #expect(number(text).format == "[h]:mm:ss")
        }
        #expect(number("25:30:00").value == 1.0625)
        for text in ["1:60", "1:30:60", "13 PM", "25:00 PM", "1:2:3:4", "1:", ":30", "1:30 XM", "1:5555"] {
            #expect(parse(text) == ParsedInput(value: .text(text)), "\(text)")
        }
    }

    @Test func datesWithTimes() {
        let january2 = DateSerial.serial(year: 2026, month: 1, day: 2)
        #expect(number("1/2/2026 13:45") == (january2 + DateSerial.time(hour: 13, minute: 45, second: 0), "M/d/yyyy H:mm"))
        #expect(number("1/2/2026 1:45:30 PM") == (january2 + DateSerial.time(hour: 13, minute: 45, second: 30), "M/d/yyyy H:mm:ss"))
        #expect(number("2026-01-02T13:45:30") == (january2 + DateSerial.time(hour: 13, minute: 45, second: 30), "M/d/yyyy H:mm:ss"))
        #expect(number("Jan 2, 2026 9:05 AM") == (january2 + DateSerial.time(hour: 9, minute: 5, second: 0), "M/d/yyyy H:mm"))
        let thisYears = DateSerial.serial(year: thisYear, month: 1, day: 2)
        #expect(number("Jan 2 13:45") == (thisYears + DateSerial.time(hour: 13, minute: 45, second: 0), "M/d/yyyy H:mm"))
        #expect(parse("1/2/2026 25:00") == ParsedInput(value: .text("1/2/2026 25:00")))
        #expect(parse("1/2/2026 noon") == ParsedInput(value: .text("1/2/2026 noon")))
    }

    @Test func booleansAndErrors() {
        #expect(parse("TRUE") == ParsedInput(value: .boolean(true)))
        #expect(parse("true") == ParsedInput(value: .boolean(true)))
        #expect(parse(" False ") == ParsedInput(value: .boolean(false)))
        for kind in CellError.Kind.allCases {
            #expect(parse(kind.rawValue) == ParsedInput(value: .error(CellError(kind))))
            #expect(parse(kind.rawValue.lowercased()) == ParsedInput(value: .error(CellError(kind))))
        }
        #expect(parse("#NA") == ParsedInput(value: .text("#NA")))
    }

    @Test func everythingElseIsTextAsTyped() {
        for text in ["hello", "  spaced  ", "12 apples", "1.2.3", "--5", "+-5", "Infinity", "nan", "0x10", "١٢٣", "5 5", "€5", "   "] {
            #expect(parse(text) == ParsedInput(value: .text(text)), "\(text)")
        }
    }

    @Test func numberFromText() {
        #expect(InputParser.number(from: "12%") == 0.12)
        #expect(InputParser.number(from: "1,234") == 1234)
        #expect(InputParser.number(from: "$5") == 5)
        #expect(InputParser.number(from: " 42 ") == 42)
        #expect(InputParser.number(from: "-1e3") == -1000)
        #expect(InputParser.number(from: "1/2/2026") == DateSerial.serial(year: 2026, month: 1, day: 2))
        #expect(InputParser.number(from: "13:45") == DateSerial.time(hour: 13, minute: 45, second: 0))
        #expect(InputParser.number(from: "25:30:00") == 1.0625)
        for text in ["", "  ", "abc", "TRUE", "#N/A", "=1+1", "'5", "1,23", "2/30/2026"] {
            #expect(InputParser.number(from: text) == nil, "\(text)")
        }
    }

    @Test func oddInputsNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["1", "2", "12", "2026", "999999999999", "0", ".", ",", "/", "-", "+", ":", "%", "$", "e", "E", " ", "'", "=",
                      "AM", "pm", "a", "Jan", "T", "#", "N/A", "TRUE", "(", "é", "€", "\t", "\n"]
        for _ in 0..<5000 {
            let length = Int.random(in: 1...7, using: &generator)
            let input = (0..<length).map { _ in pieces.randomElement(using: &generator)! }.joined()
            let parsed = InputParser.parse(input, currentFormat: nil)
            if case .number(let value) = parsed.value { #expect(value.isFinite) }
            _ = InputParser.number(from: input)
        }
    }

    @Test func impliedFormatsDisplayWhatWasTyped() {
        let cases = ["1,234": "1,234", "1,234.50": "1,234.50", "12%": "12%", "12.5%": "12.50%", "$1,200": "$1,200",
                     "$5.5": "$5.50", "1/2/2026": "1/2/2026", "13:45": "13:45", "1:45 PM": "1:45 PM", "1:45:30 PM": "1:45:30 PM",
                     "25:30:00": "25:30:00", "1/2/2026 13:45": "1/2/2026 13:45", "1e5": "1.00E+05"]
        for (input, display) in cases {
            let parsed = parse(input)
            #expect(CellDisplay.text(for: parsed.value, pattern: parsed.impliedFormat).text == display, "\(input)")
        }
    }
}
