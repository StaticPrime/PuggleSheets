import Foundation
import Testing
@testable import PuggleSheetsKit

struct IODelimitedTests {
    static func records(_ text: String, _ delimiter: CSVDelimiter = .comma) -> [[String]] {
        DelimitedReader.records(in: text, delimiter: delimiter)
    }

    static func csv(_ text: String) throws -> Sheet {
        try #require(try SpreadsheetIO.read(Data(text.utf8), format: .csv).workbook.sheets.first)
    }

    // MARK: - Parsing

    @Test func splitsFieldsAndRecords() {
        #expect(Self.records("a,b,c\r\n1,2,3") == [["a", "b", "c"], ["1", "2", "3"]])
        #expect(Self.records("a,b\nc,d\n") == [["a", "b"], ["c", "d"]])
        #expect(Self.records("a\rb\rc\r") == [["a"], ["b"], ["c"]])
        #expect(Self.records("a\r\n\r\nb") == [["a"], [""], ["b"]])
        #expect(Self.records("a\n\n") == [["a"], [""]])
        #expect(Self.records("") == [])
        #expect(Self.records("\n") == [[""]])
    }

    @Test func emptyAndRaggedFields() {
        #expect(Self.records("a,,c") == [["a", "", "c"]])
        #expect(Self.records(",,") == [["", "", ""]])
        #expect(Self.records("a,") == [["a", ""]])
        #expect(Self.records("1,2,3\n4\n5,6") == [["1", "2", "3"], ["4"], ["5", "6"]])
    }

    @Test func quotedFields() {
        #expect(Self.records("\"a, b\",c") == [["a, b", "c"]])
        #expect(Self.records("\"say \"\"hi\"\"\",x") == [["say \"hi\"", "x"]])
        #expect(Self.records("\"\"") == [[""]])
        #expect(Self.records("\"\",\"\"\"\"") == [["", "\""]])
        #expect(Self.records("\"line 1\nline 2\",b\r\nc,d") == [["line 1\nline 2", "b"], ["c", "d"]])
        #expect(Self.records("\"crlf\r\ninside\",\"cr\rinside\"") == [["crlf\ninside", "cr\ninside"]])
        // Leniency: text after a closing quote is kept, quotes inside unquoted fields are literal,
        // and an unterminated quote runs to the end.
        #expect(Self.records("\"ab\"cd,e") == [["abcd", "e"]])
        #expect(Self.records("5\" screen,x") == [["5\" screen", "x"]])
        #expect(Self.records(" \"spaced\" ,x") == [[" \"spaced\" ", "x"]])
        #expect(Self.records("\"never closed,a\nb") == [["never closed,a\nb"]])
    }

    @Test func tabSeparatedValues() {
        #expect(Self.records("a\tb\tc\n1\t\t3", .tab) == [["a", "b", "c"], ["1", "", "3"]])
        #expect(Self.records("a,b\tc", .tab) == [["a,b", "c"]])
        #expect(Self.records("\"tab\there\"\tx", .tab) == [["tab\there", "x"]])
    }

    // MARK: - Encodings

    @Test func detectsEncodings() {
        #expect(DelimitedTextDecoding.decode(Data([0xEF, 0xBB, 0xBF] + Array("é,ü".utf8))) == "é,ü")
        #expect(DelimitedTextDecoding.decode(Data("plain, ascii".utf8)) == "plain, ascii")
        #expect(DelimitedTextDecoding.decode(Data("naïve, 漢字, 😀".utf8)) == "naïve, 漢字, 😀")
        let utf16LE = Data([0xFF, 0xFE]) + "é,😀\r\n".data(using: .utf16LittleEndian)!
        #expect(DelimitedTextDecoding.decode(utf16LE) == "é,😀\r\n")
        let utf16BE = Data([0xFE, 0xFF]) + "a\tb".data(using: .utf16BigEndian)!
        #expect(DelimitedTextDecoding.decode(utf16BE) == "a\tb")
        // Not valid UTF-8: Windows-1252, including its typographic characters and undefined bytes.
        #expect(DelimitedTextDecoding.decode(Data([0x93, 0x48, 0x69, 0x94, 0x2C, 0xE9, 0x80, 0x2C, 0x81, 0xFF])) == "“Hi”,é€,\u{81}ÿ")
        #expect(DelimitedTextDecoding.decode(Data([0x43, 0x61, 0x66, 0xE9])) == "Café")
    }

    @Test func readsEncodedFiles() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("name,city\nZoë,Zürich".utf8)
        let sheet = try #require(try SpreadsheetIO.read(bom, format: .csv).workbook.sheets.first)
        #expect(sheet[0, 0].value == .text("name"))
        #expect(sheet[1, 0].value == .text("Zoë"))
        #expect(sheet[1, 1].value == .text("Zürich"))

        let latin = Data([0x4E, 0x61, 0x6D, 0x65, 0x0D, 0x0A, 0x4A, 0x6F, 0x73, 0xE9])
        let latinSheet = try #require(try SpreadsheetIO.read(latin, format: .csv).workbook.sheets.first)
        #expect(latinSheet[1, 0].value == .text("José"))

        let utf16 = Data([0xFF, 0xFE]) + "a\tb\r\n1\t2".data(using: .utf16LittleEndian)!
        let tsv = try #require(try SpreadsheetIO.read(utf16, format: .tsv).workbook.sheets.first)
        #expect(tsv[0, 1].value == .text("b"))
        #expect(tsv[1, 1].value == .number(2))
    }

    // MARK: - Values

    @Test func fieldsAreInterpretedAsIfTyped() throws {
        let sheet = try Self.csv("Item,Qty,Price,Done\nPen,3,1.5,TRUE\n\"Note, long\",,0.25,false\nTotal,=SUM(B2:B3),'42,\n")
        #expect(sheet.name == "Sheet1")
        #expect(sheet[0, 0].value == .text("Item"))
        #expect(sheet[1, 1].value == .number(3))
        #expect(sheet[1, 2].value == .number(1.5))
        #expect(sheet[1, 3].value == .boolean(true))
        #expect(sheet[2, 0].value == .text("Note, long"))
        #expect(sheet.cells[CellAddress(row: 2, column: 1)] == nil)
        #expect(sheet[2, 3].value == .boolean(false))
        // Formulas are kept for the app to calculate.
        #expect(sheet[3, 1].formula == "=SUM(B2:B3)")
        #expect(sheet[3, 1].value == .empty)
        #expect(sheet[3, 2].value == .text("42"))
        #expect(sheet.cells[CellAddress(row: 3, column: 3)] == nil)
        #expect(sheet.rowCount == 1000 && sheet.columnCount == 26)
    }

    @Test func gridGrowsToFitTheFile() throws {
        var text = ""
        for row in 0..<1500 {
            text += (0..<30).map { "\(row * 30 + $0)" }.joined(separator: ",") + "\n"
        }
        let sheet = try Self.csv(text)
        #expect(sheet.rowCount == 1500)
        #expect(sheet.columnCount == 30)
        #expect(sheet.cells.count == 45_000)
        #expect(sheet[1499, 29].value == .number(44_999))
        // Columns count even when the last ones are empty.
        #expect(try Self.csv("a,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,\nb").columnCount == 32)
    }

    @Test func blankLinesKeepTheirRows() throws {
        let sheet = try Self.csv("a\n\nc\n")
        #expect(sheet[0, 0].value == .text("a"))
        #expect(sheet.cells[CellAddress(row: 1, column: 0)] == nil)
        #expect(sheet[2, 0].value == .text("c"))
        #expect(try SpreadsheetIO.read(Data(), format: .csv).workbook.sheets.first?.cells.isEmpty == true)
    }

    // MARK: - Writing

    static func write(_ sheet: Sheet, _ format: SpreadsheetFileFormat = .csv) throws -> String {
        String(decoding: try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: format), as: UTF8.self)
    }

    @Test func writesDisplayedValues() throws {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .text("Name"))
        sheet[0, 1] = Cell(value: .text("Score"))
        sheet[1, 0] = Cell(value: .text("Ada"))
        sheet[1, 1] = Cell(value: .number(97.5))
        sheet[2, 0] = Cell(value: .boolean(true))
        sheet[2, 1] = Cell(value: .error(CellError(.notAvailable)), formula: "=NA()")
        sheet[3, 1] = Cell(value: .number(12), formula: "=B2/8")
        #expect(try Self.write(sheet) == "Name,Score\r\nAda,97.5\r\nTRUE,#N/A\r\n,12")
    }

    @Test func quotesFieldsThatNeedIt() throws {
        var sheet = Sheet(name: "Sheet1")
        let texts = ["comma, inside", "say \"hi\"", "line 1\nline 2", " leading", "trailing ", "tab\there", "plain", "crlf\r\nx"]
        for (row, text) in texts.enumerated() { sheet[row, 0] = Cell(value: .text(text)) }
        let csv = try Self.write(sheet)
        #expect(csv == "\"comma, inside\"\r\n\"say \"\"hi\"\"\"\r\n\"line 1\nline 2\"\r\n\" leading\"\r\n\"trailing \"\r\ntab\there\r\nplain\r\n\"crlf\r\nx\"")
        let tsv = try Self.write(sheet, .tsv)
        #expect(tsv == "comma, inside\r\n\"say \"\"hi\"\"\"\r\n\"line 1\nline 2\"\r\n\" leading\"\r\n\"trailing \"\r\n\"tab\there\"\r\nplain\r\n\"crlf\r\nx\"")
        // What's written reads back as the same fields (line breaks inside cells become "\n").
        #expect(Self.records(csv) == texts.map { [$0.replacingOccurrences(of: "\r\n", with: "\n")] })
        #expect(Self.records(tsv, .tab) == texts.map { [$0.replacingOccurrences(of: "\r\n", with: "\n")] })
    }

    @Test func writesFromA1ToTheLastContent() throws {
        var sheet = Sheet(name: "Sheet1")
        sheet[1, 2] = Cell(value: .text("x"))
        sheet[3, 1] = Cell(value: .number(1))
        // Formatting alone doesn't extend the range.
        sheet[10, 10] = Cell(format: IOTest.format { $0.bold = true })
        #expect(try Self.write(sheet) == ",,\r\n,,x\r\n,,\r\n,1,")
        #expect(try Self.write(sheet, .tsv) == "\t\t\r\n\t\tx\r\n\t\t\r\n\t1\t")
        #expect(try Self.write(Sheet(name: "Empty")) == "")
    }

    @Test func writesOnlyTheActiveSheetAsUTF8() throws {
        var first = Sheet(name: "First")
        first[0, 0] = Cell(value: .text("one"))
        var second = Sheet(name: "Second")
        second[0, 0] = Cell(value: .text("Zoë 😀"))
        let workbook = Workbook(sheets: [first, second])
        let data = try SpreadsheetIO.write(workbook, activeSheet: 1, format: .csv)
        #expect(data == Data("Zoë 😀".utf8))
        #expect(!data.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(try SpreadsheetIO.write(workbook, activeSheet: 9, format: .tsv) == Data("Zoë 😀".utf8))
        #expect(try SpreadsheetIO.write(workbook, activeSheet: -3, format: .csv) == Data("one".utf8))
    }

    @Test func roundTripsThroughCSV() throws {
        let text = "id,name,notes\r\n1,Widget,\"Comes in red, blue\"\r\n2,Gadget,\"Says \"\"hello\"\"\"\r\n3,,\"two\nlines\""
        let file = try SpreadsheetIO.read(Data(text.utf8), format: .csv)
        #expect(file.warnings.isEmpty)
        #expect(file.activeSheet == 0)
        #expect(try SpreadsheetIO.write(file.workbook, activeSheet: 0, format: .csv) == Data(text.utf8))
    }
}
