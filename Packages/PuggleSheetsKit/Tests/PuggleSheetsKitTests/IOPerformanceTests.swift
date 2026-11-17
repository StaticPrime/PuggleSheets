import Foundation
import Testing
@testable import PuggleSheetsKit

/// Speed checks with generous limits. The meaningful numbers come from `swift test -c release`;
/// debug builds only get a sanity limit.
struct IOPerformanceTests {
    #if DEBUG
    static let limit: Duration = .seconds(60)
    #else
    static let limit: Duration = .seconds(3)
    #endif

    /// 10,000 rows × 10 columns: numbers, repeated and unique text, formulas, a few formats.
    static func largeWorkbook() -> Workbook {
        var sheet = Sheet(name: "Large")
        let bold = IOTest.format { $0.bold = true }
        let money = IOTest.format { $0.numberFormat = "\"$\"#,##0.00" }
        for row in 0..<10_000 {
            sheet[row, 0] = Cell(value: .number(Double(row)))
            sheet[row, 1] = Cell(value: .text("Item \(row)"))
            sheet[row, 2] = Cell(value: .text(row % 2 == 0 ? "even" : "odd"), format: bold)
            sheet[row, 3] = Cell(value: .number(Double(row) * 1.25), format: money)
            sheet[row, 4] = Cell(value: .number(Double(row) / 7))
            sheet[row, 5] = Cell(value: .boolean(row % 3 == 0))
            sheet[row, 6] = Cell(value: .number(Double(row) * 2.5), formula: "=A\(row + 1)*2.5")
            sheet[row, 7] = Cell(value: .text("Item \(row)!"), formula: "=CONCAT(B\(row + 1),\"!\")")
            sheet[row, 8] = Cell(value: .number(46_000 + Double(row)), format: IOTest.format { $0.numberFormat = "M/d/yyyy" })
            sheet[row, 9] = Cell(value: .text("Note \(row % 100)"))
        }
        return Workbook(sheets: [sheet])
    }

    @Test func writesAndReadsAHundredThousandCells() throws {
        let workbook = Self.largeWorkbook()
        let clock = ContinuousClock()
        var data = Data()
        let writing = try clock.measure {
            data = try SpreadsheetIO.write(workbook, activeSheet: 0, format: .xlsx)
        }
        var file: SpreadsheetFile?
        let reading = try clock.measure {
            file = try SpreadsheetIO.read(data, format: .xlsx)
        }
        print("100,000 cells: wrote \(data.count / 1024) KB in \(writing), read in \(reading)")
        #expect(writing < Self.limit)
        #expect(reading < Self.limit)

        let sheet = try #require(file?.workbook.sheets.first)
        #expect(sheet.cells.count == 100_000)
        #expect(sheet[9_999, 1].value == .text("Item 9999"))
        #expect(sheet[9_999, 6].formula == "=A10000*2.5")
        #expect(sheet[9_999, 7].formula == "=CONCAT(B10000,\"!\")")
        #expect(sheet[5_000, 3] == workbook.sheets[0][5_000, 3])
    }

    @Test func writesAndReadsAHundredThousandCellsOfODS() throws {
        let workbook = Self.largeWorkbook()
        let clock = ContinuousClock()
        var data = Data()
        let writing = try clock.measure {
            data = try SpreadsheetIO.write(workbook, activeSheet: 0, format: .ods)
        }
        var file: SpreadsheetFile?
        let reading = try clock.measure {
            file = try SpreadsheetIO.read(data, format: .ods)
        }
        print("100,000 ODS cells: wrote \(data.count / 1024) KB in \(writing), read in \(reading)")
        #expect(writing < Self.limit)
        #expect(reading < Self.limit)

        let sheet = try #require(file?.workbook.sheets.first)
        #expect(sheet.cells.count == 100_000)
        #expect(sheet[9_999, 1].value == .text("Item 9999"))
        #expect(sheet[9_999, 6].formula == "=A10000*2.5")
        #expect(sheet[9_999, 7].formula == "=CONCAT(B10000,\"!\")")
        for column in 0..<10 {
            #expect(sheet[5_000, column] == workbook.sheets[0][5_000, column], "\(column)")
        }
    }

    @Test func readsSharedFormulasQuickly() throws {
        // Excel stores a filled-down formula once and refers to it from every other cell.
        var rows = ""
        for row in 1...50_000 {
            let formula = row == 1 ? "<f t=\"shared\" ref=\"B1:B50000\" si=\"0\">A1*2+$A$1</f>" : "<f t=\"shared\" si=\"0\"/>"
            rows += "<row r=\"\(row)\"><c r=\"A\(row)\"><v>\(row)</v></c><c r=\"B\(row)\">\(formula)<v>\(row * 2 + 1)</v></c></row>"
        }
        let data = try IOTestPackage.xlsx(sheet: "<sheetData>\(rows)</sheetData>")
        let clock = ContinuousClock()
        var file: SpreadsheetFile?
        let reading = try clock.measure { file = try SpreadsheetIO.read(data, format: .xlsx) }
        print("50,000 shared formulas read in \(reading)")
        #expect(reading < Self.limit)
        let sheet = try #require(file?.workbook.sheets.first)
        #expect(sheet[49_999, 1].formula == "=A50000*2+$A$1")
        #expect(sheet.rowCount == 50_000)
    }

    @Test func readsAndWritesLargeCSV() throws {
        var text = ""
        for row in 0..<10_000 {
            text += "\(row),Item \(row),\(Double(row) * 1.5),\"quoted, \(row)\",TRUE,x,y,z,\(row % 7),end\r\n"
        }
        let clock = ContinuousClock()
        var file: SpreadsheetFile?
        let reading = clock.measure { file = try? SpreadsheetIO.read(Data(text.utf8), format: .csv) }
        let workbook = try #require(file?.workbook)
        var output = Data()
        let writing = try clock.measure { output = try SpreadsheetIO.write(workbook, activeSheet: 0, format: .csv) }
        print("100,000 CSV fields: read in \(reading), wrote in \(writing)")
        #expect(reading < Self.limit)
        #expect(writing < Self.limit)
        #expect(workbook.sheets[0].cells.count == 100_000)
        #expect(output.count > 500_000)
    }
}
