import Foundation
import Testing
@testable import PuggleSheetsKit

/// File-format behavior that depends on the number-format module (InputParser, CellDisplay,
/// NumberFormatPresets.kind). Enable once it replaces the placeholders.
struct IOFormattingTests {
    static func csv(_ text: String) throws -> Sheet {
        try #require(try SpreadsheetIO.read(Data(text.utf8), format: .csv).workbook.sheets.first)
    }

    @Test
    func csvPercentagesKeepTheirFormat() throws {
        let sheet = try Self.csv("12%,0.5%,-3%")
        #expect(sheet[0, 0] == Cell(value: .number(0.12), format: IOTest.format { $0.numberFormat = "0%" }))
        #expect(sheet[0, 1] == Cell(value: .number(0.005), format: IOTest.format { $0.numberFormat = "0.00%" }))
        #expect(sheet[0, 2].value == .number(-0.03))
    }

    @Test
    func csvDatesBecomeSerials() throws {
        let sheet = try Self.csv("1/2/2026,2026-11-16,1/2/2026 13:45:00,3:30 PM")
        #expect(sheet[0, 0] == Cell(value: .number(DateSerial.serial(year: 2026, month: 1, day: 2)),
                                    format: IOTest.format { $0.numberFormat = "M/d/yyyy" }))
        #expect(sheet[0, 1].value == .number(46_342))
        #expect(sheet[0, 1].format.numberFormat != nil)
        #expect(sheet[0, 2].value == .number(DateSerial.serial(year: 2026, month: 1, day: 2, hour: 13, minute: 45, second: 0)))
        #expect(sheet[0, 3].value == .number(DateSerial.time(hour: 15, minute: 30, second: 0)))
    }

    @Test
    func csvCurrencyAndGrouping() throws {
        let sheet = try Self.csv("\"$1,200\",\"1,234.5\",$5.25")
        #expect(sheet[0, 0] == Cell(value: .number(1200), format: IOTest.format { $0.numberFormat = "\"$\"#,##0" }))
        #expect(sheet[0, 1].value == .number(1234.5))
        #expect(sheet[0, 2].value == .number(5.25))
        #expect(sheet[0, 2].format.numberFormat != nil)
    }

    @Test
    func csvExportShowsFormattedValues() throws {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .number(0.125), format: IOTest.format { $0.numberFormat = "0.00%" })
        sheet[0, 1] = Cell(value: .number(DateSerial.serial(year: 2026, month: 1, day: 2)), format: IOTest.format { $0.numberFormat = "M/d/yyyy" })
        sheet[0, 2] = Cell(value: .number(1200), format: IOTest.format { $0.numberFormat = "\"$\"#,##0.00" })
        sheet[0, 3] = Cell(value: .number(1234.5), format: IOTest.format { $0.numberFormat = "#,##0.00" })
        sheet[0, 4] = Cell(value: .number(0.5), format: IOTest.format { $0.numberFormat = "h:mm AM/PM" })
        let csv = String(decoding: try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .csv), as: UTF8.self)
        #expect(csv == "12.50%,1/2/2026,\"$1,200.00\",\"1,234.50\",12:00 PM")
        let tsv = String(decoding: try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .tsv), as: UTF8.self)
        #expect(tsv == "12.50%\t1/2/2026\t$1,200.00\t1,234.50\t12:00 PM")
    }

    @Test
    func csvRoundTripOfFormattedValues() throws {
        let text = "Date,Amount,Share\r\n1/2/2026,\"$1,200\",12%"
        let file = try SpreadsheetIO.read(Data(text.utf8), format: .csv)
        #expect(try SpreadsheetIO.write(file.workbook, activeSheet: 0, format: .csv) == Data(text.utf8))
    }

    @Test
    func dateKindsDriveThe1904Shift() {
        // The format module's kinds should agree with the built-in detection.
        #expect(NumberFormatPresets.kind(of: "M/d/yyyy") == .date)
        #expect(NumberFormatPresets.kind(of: "M/d/yyyy H:mm") == .dateTime)
        #expect(NumberFormatPresets.kind(of: "h:mm AM/PM") == .time)
        #expect(NumberFormatPresets.kind(of: "[h]:mm:ss") == .duration)
        for id in [14, 15, 16, 17, 22] {
            #expect(XLSXNumberFormats.showsDate(XLSXNumberFormats.builtIn[id]), "\(id)")
        }
        for id in [18, 19, 20, 21, 45, 46, 47] {
            #expect(!XLSXNumberFormats.showsDate(XLSXNumberFormats.builtIn[id]), "\(id)")
        }
    }
}
