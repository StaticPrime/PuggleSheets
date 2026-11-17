import Foundation
import Testing
@testable import PuggleSheetsKit

struct IOXLSXWriteTests {
    // MARK: - A workbook using everything

    static let red = RGBColor(hex: "CC0000")!
    static let teal = RGBColor(hex: "008080")!

    static let fancy = IOTest.format {
        $0.fontFamily = "Georgia"
        $0.fontSize = 14.5
        $0.bold = true
        $0.italic = true
        $0.underline = true
        $0.strikethrough = true
        $0.textColor = red
        $0.fillColor = RGBColor(hex: "FFF2CC")
        $0.horizontalAlignment = .center
        $0.verticalAlignment = .middle
        $0.wrap = .wrap
        $0.numberFormat = "#,##0.000;[Red]-#,##0.000"
        $0.borders = CellBorders(top: BorderLine(style: .thin, color: .black), left: BorderLine(style: .medium, color: teal),
                                 bottom: BorderLine(style: .double, color: red), right: BorderLine(style: .dotted, color: .black))
    }

    static func everythingWorkbook() -> Workbook {
        var summary = Sheet(name: "Summary")
        summary[0, 0] = Cell(value: .text("Region"), format: IOTest.format {
            $0.bold = true
            $0.fillColor = RGBColor(hex: "D9EAD3")
            $0.borders = CellBorders(bottom: BorderLine(style: .thick, color: .black))
        })
        summary[0, 1] = Cell(value: .text("Total"), format: IOTest.format {
            $0.bold = true
            $0.horizontalAlignment = .right
        })
        summary[1, 0] = Cell(value: .text("North"))
        summary[1, 1] = Cell(value: .number(1234.5), format: fancy)
        summary[2, 0] = Cell(value: .text("  padded  "))
        summary[2, 1] = Cell(value: .number(-0.000_012_5), format: IOTest.format { $0.numberFormat = "0.00E+00" })
        summary[3, 0] = Cell(value: .text("Line 1\nLine 2"), format: IOTest.format {
            $0.wrap = .wrap
            $0.verticalAlignment = .top
        })
        summary[3, 1] = Cell(value: .number(0.1 + 0.2))
        summary[4, 0] = Cell(value: .text("Quotes \"<&>\" and 'apostrophes'"))
        summary[4, 1] = Cell(value: .number(1e20))
        summary[5, 0] = Cell(value: .text("Emoji 😀 and accents éü and 漢字"))
        summary[5, 1] = Cell(value: .number(46_342.75), format: IOTest.format { $0.numberFormat = "M/d/yyyy H:mm:ss" })
        summary[6, 0] = Cell(value: .text("_x0041_ is not an escape"))
        summary[6, 1] = Cell(value: .number(46_342), format: IOTest.format { $0.numberFormat = "M/d/yyyy" })
        summary[7, 0] = Cell(value: .boolean(true))
        summary[7, 1] = Cell(value: .boolean(false), format: IOTest.format { $0.horizontalAlignment = .left })
        let errors: [CellError.Kind] = [.null, .divideByZero, .value, .reference, .name, .number, .notAvailable]
        for (index, kind) in errors.enumerated() {
            summary[8, index] = Cell(value: .error(CellError(kind)))
        }
        // Formulas with each kind of cached result.
        summary[9, 0] = Cell(value: .number(1236.5), formula: "=B2+2")
        summary[9, 1] = Cell(value: .text("North!"), formula: "=CONCAT(A2,\"!\")")
        summary[9, 2] = Cell(value: .boolean(true), formula: "=ISNUMBER(B2)")
        summary[9, 3] = Cell(value: .error(CellError(.divideByZero)), formula: "=1/0")
        summary[9, 4] = Cell(formula: "=NOW()", format: IOTest.format { $0.numberFormat = "M/d/yyyy" })
        summary[9, 5] = Cell(value: .text(""), formula: "=IF(B2>0,\"\",\"no\")")
        summary[9, 6] = Cell(value: .number(3), formula: "=SUM(FILTER(B2:B8,B2:B8>0))")
        summary[9, 7] = Cell(value: .text("a,b"), formula: "=JOIN(\",\",SPLIT(\"a b\",\" \"))")
        // Formatting without a value, and a few more fonts and formats.
        summary[11, 0] = Cell(format: IOTest.format {
            $0.fillColor = RGBColor(hex: "000000")
            $0.textColor = .white
        })
        summary[11, 1] = Cell(value: .number(0.256), format: IOTest.format {
            $0.numberFormat = "0.00%"
            $0.fontFamily = "Courier New"
            $0.fontSize = 8
        })
        summary[11, 2] = Cell(value: .number(42), format: IOTest.format {
            $0.numberFormat = "\"$\"#,##0.00"
            $0.horizontalAlignment = .center
        })
        summary[11, 3] = Cell(value: .text("0042"), format: IOTest.format { $0.numberFormat = "@" })
        summary[11, 4] = Cell(value: .number(1.5), format: IOTest.format { $0.numberFormat = "[h]:mm:ss" })
        summary[11, 5] = Cell(value: .number(7), format: fancy)
        summary[1499, 27] = Cell(value: .text("far away"))
        summary.columnWidths = [0: 180, 3: 40, 27: 250]
        summary.hiddenColumns = [5, 6]
        summary.rowHeights = [0: 40, 10: 25, 2000: 60]
        summary.hiddenRows = [4, 12]
        summary.merges = [CellRange(a1: "C1:D2")!, CellRange(a1: "A14:F20")!]
        summary.frozenRows = 2
        summary.frozenColumns = 1
        summary.tabColor = RGBColor(hex: "4285F4")
        summary.showsGridlines = false
        summary.defaultColumnWidth = 120
        summary.defaultRowHeight = 24

        var data = Sheet(name: "Data & <Stuff>")
        for row in 0..<50 {
            data[row, 0] = Cell(value: .number(Double(row)))
            data[row, 1] = Cell(value: .text("Item \(row % 7)"))
            data[row, 2] = Cell(value: .number(Double(row) * 1.5), formula: "=A\(row + 1)*1.5")
        }
        data.frozenRows = 1
        data.tabColor = RGBColor(hex: "34A853")

        var columnsOnly = Sheet(name: "Frozen columns")
        columnsOnly.frozenColumns = 3
        columnsOnly[0, 0] = Cell(value: .text("x"))

        return Workbook(sheets: [summary, data, columnsOnly, Sheet(name: "Empty")])
    }

    @Test func roundTripKeepsEverything() throws {
        let workbook = Self.everythingWorkbook()
        let data = try SpreadsheetIO.write(workbook, activeSheet: 1, format: .xlsx)
        let file = try SpreadsheetIO.read(data, format: .xlsx)
        #expect(file.warnings.isEmpty)
        #expect(file.activeSheet == 1)
        #expect(file.workbook.sheets.map(\.name) == workbook.sheets.map(\.name))
        for (original, copy) in zip(workbook.sheets, file.workbook.sheets) {
            #expect(copy.cells.count == original.cells.count, "\(original.name)")
            for (address, cell) in original.cells {
                #expect(copy[address] == cell, "\(original.name)!\(address)")
            }
            #expect(copy.columnWidths == original.columnWidths, "\(original.name)")
            #expect(copy.rowHeights == original.rowHeights, "\(original.name)")
            #expect(copy.hiddenRows == original.hiddenRows, "\(original.name)")
            #expect(copy.hiddenColumns == original.hiddenColumns, "\(original.name)")
            #expect(copy.merges == original.merges, "\(original.name)")
            #expect(copy.frozenRows == original.frozenRows, "\(original.name)")
            #expect(copy.frozenColumns == original.frozenColumns, "\(original.name)")
            #expect(copy.tabColor == original.tabColor, "\(original.name)")
            #expect(copy.showsGridlines == original.showsGridlines, "\(original.name)")
            #expect(copy.defaultColumnWidth == original.defaultColumnWidth, "\(original.name)")
            #expect(copy.defaultRowHeight == original.defaultRowHeight, "\(original.name)")
        }
        let summary = file.workbook.sheets[0]
        #expect(summary.rowCount == 2001)
        #expect(summary.columnCount == 28)
    }

    @Test func writingTwiceGivesTheSameWorkbook() throws {
        let workbook = Self.everythingWorkbook()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XLSXWriter.write(workbook, activeSheet: 0, date: date)
        let reread = try SpreadsheetIO.read(first, format: .xlsx)
        let second = try XLSXWriter.write(reread.workbook, activeSheet: reread.activeSheet, date: date)
        #expect(first == second)
    }

    // MARK: - Package structure

    static func parts(of data: Data) throws -> [String: String] {
        let zip = try ZipReader(data: data)
        var parts: [String: String] = [:]
        for entry in zip.entries {
            parts[entry.path] = String(decoding: try zip.read(entry), as: UTF8.self)
        }
        return parts
    }

    @Test func everyPartIsWellFormedXML() throws {
        let data = try SpreadsheetIO.write(Self.everythingWorkbook(), activeSheet: 0, format: .xlsx)
        let zip = try ZipReader(data: data)
        #expect(Set(zip.entries.map(\.path)) == [
            "[Content_Types].xml", "_rels/.rels", "docProps/app.xml", "docProps/core.xml", "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/sharedStrings.xml", "xl/worksheets/sheet1.xml",
            "xl/worksheets/sheet2.xml", "xl/worksheets/sheet3.xml", "xl/worksheets/sheet4.xml",
        ])
        #expect(zip.entries.first?.path == "[Content_Types].xml")
        for entry in zip.entries {
            let part = try zip.read(entry)
            #expect(IOTestPackage.isWellFormed(part), "\(entry.path)")
            #expect(part.starts(with: Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>".utf8)), "\(entry.path)")
        }
    }

    @Test func packagePartsDeclareWhatTheyHold() throws {
        let parts = try Self.parts(of: try SpreadsheetIO.write(Self.everythingWorkbook(), activeSheet: 2, format: .xlsx))
        let contentTypes = try #require(parts["[Content_Types].xml"])
        for part in ["/xl/workbook.xml", "/xl/styles.xml", "/xl/sharedStrings.xml", "/xl/worksheets/sheet4.xml", "/docProps/core.xml", "/docProps/app.xml"] {
            #expect(contentTypes.contains("PartName=\"\(part)\""), "\(part)")
        }
        let workbook = try #require(parts["xl/workbook.xml"])
        #expect(workbook.contains("<sheet name=\"Data &amp; &lt;Stuff&gt;\" sheetId=\"2\" r:id=\"rId2\"/>"))
        #expect(workbook.contains("activeTab=\"2\""))
        #expect(workbook.contains("<calcPr fullCalcOnLoad=\"1\"/>"))
        let relationships = try #require(parts["xl/_rels/workbook.xml.rels"])
        #expect(relationships.contains("Target=\"worksheets/sheet4.xml\""))
        #expect(relationships.contains("Target=\"styles.xml\""))
        #expect(relationships.contains("Target=\"sharedStrings.xml\""))
        #expect(try #require(parts["_rels/.rels"]).contains("Target=\"xl/workbook.xml\""))
        #expect(try #require(parts["docProps/core.xml"]).contains("dcterms:modified"))
        // Only the active sheet is selected.
        #expect(try #require(parts["xl/worksheets/sheet3.xml"]).contains("tabSelected=\"1\""))
        #expect(!(try #require(parts["xl/worksheets/sheet1.xml"]).contains("tabSelected")))
    }

    @Test func stylesFollowExcelsConventions() throws {
        let parts = try Self.parts(of: try SpreadsheetIO.write(Self.everythingWorkbook(), activeSheet: 0, format: .xlsx))
        let styles = try XMLTree.parse(Data(try #require(parts["xl/styles.xml"]).utf8))
        let fonts = styles.child("fonts")?.children("font") ?? []
        #expect(fonts.first?.child("name")?["val"] == "Arial")
        #expect(fonts.first?.child("sz")?["val"] == "10")
        #expect(styles.child("fonts")?["count"] == String(fonts.count))
        let fills = styles.child("fills")?.children("fill") ?? []
        #expect(fills.count >= 3)
        #expect(fills[0].child("patternFill")?["patternType"] == "none")
        #expect(fills[1].child("patternFill")?["patternType"] == "gray125")
        #expect(fills[2].child("patternFill")?["patternType"] == "solid")
        let borders = styles.child("borders")?.children("border") ?? []
        #expect(borders.first?.children.allSatisfy { $0["style"] == nil } == true)
        let formats = styles.child("cellXfs")?.children("xf") ?? []
        #expect(formats.first?.attributes == ["numFmtId": "0", "fontId": "0", "fillId": "0", "borderId": "0", "xfId": "0"])
        #expect(styles.child("cellXfs")?["count"] == String(formats.count))
        #expect(styles.child("cellStyleXfs")?.children("xf").count == 1)
        #expect(styles.child("cellStyles")?.child("cellStyle")?["name"] == "Normal")
        // Custom number formats start at 164; built-in ones keep their ids.
        let customIDs = (styles.child("numFmts")?.children("numFmt") ?? []).compactMap { Int($0["numFmtId"] ?? "") }
        #expect(!customIDs.isEmpty && customIDs.allSatisfy { $0 >= 164 })
        let usedIDs = Set(formats.compactMap { $0["numFmtId"] })
        #expect(usedIDs.isSuperset(of: ["10", "11", "14", "46", "49"]))
        // Each distinct format is written once.
        func signature(_ node: XNode) -> String {
            ([node] + node.children).map { $0.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
                .joined(separator: ";")
        }
        #expect(Set(formats.map(signature)).count == formats.count)
    }

    @Test func sharedFormatsAreDeduplicated() throws {
        var sheet = Sheet(name: "Sheet1")
        let bold = IOTest.format { $0.bold = true }
        for row in 0..<100 { sheet[row, 0] = Cell(value: .number(Double(row)), format: bold) }
        sheet[0, 1] = Cell(value: .text("same"), format: IOTest.format {
            $0.bold = true
            $0.fontFamily = "Arial"
            $0.fontSize = 10
        })
        let parts = try Self.parts(of: try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx))
        let styles = try XMLTree.parse(Data(try #require(parts["xl/styles.xml"]).utf8))
        #expect(styles.child("cellXfs")?.children("xf").count == 2)
        #expect(styles.child("fonts")?.children("font").count == 2)
        let worksheet = try #require(parts["xl/worksheets/sheet1.xml"])
        #expect(worksheet.components(separatedBy: " s=\"1\"").count - 1 == 101)
    }

    @Test func sharedStringsAreDeduplicatedAndPreserveSpaces() throws {
        var sheet = Sheet(name: "Sheet1")
        for row in 0..<10 { sheet[row, 0] = Cell(value: .text(row % 2 == 0 ? "even" : " odd ")) }
        sheet[0, 1] = Cell(value: .text("a\u{1}b\u{FFFE}c\td\re"))
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        let strings = try #require(try Self.parts(of: data)["xl/sharedStrings.xml"])
        #expect(strings.contains("count=\"11\" uniqueCount=\"3\""))
        #expect(strings.contains("<si><t>even</t></si>"))
        #expect(strings.contains("<si><t xml:space=\"preserve\"> odd </t></si>"))
        // Characters XML can't hold are dropped; a carriage return survives as a reference.
        #expect(strings.contains("<si><t>abc\td&#13;e</t></si>"))
        let copy = try SpreadsheetIO.read(data, format: .xlsx).workbook.sheets[0]
        #expect(copy[1, 0].value == .text(" odd "))
        #expect(copy[0, 1].value == .text("abc\td\ne"))
    }

    @Test func cellsCarryTypedCachedResults() throws {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .number(2), formula: "=1+1")
        sheet[0, 1] = Cell(value: .text("x<y"), formula: "=\"x<y\"")
        sheet[0, 2] = Cell(value: .boolean(false), formula: "=1>2")
        sheet[0, 3] = Cell(value: .error(CellError(.notAvailable)), formula: "=NA()")
        sheet[0, 4] = Cell(formula: "=RAND()")
        sheet[0, 5] = Cell(value: .error(CellError(.parse)), formula: "=SUM(")
        sheet[0, 6] = Cell(value: .number(.infinity))
        sheet[0, 7] = Cell(value: .number(.nan), formula: "=0/0")
        sheet[0, 8] = Cell(value: .number(-0.0))
        let worksheet = try #require(try Self.parts(of: try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx))["xl/worksheets/sheet1.xml"])
        #expect(worksheet.contains("<c r=\"A1\"><f>1+1</f><v>2</v></c>"))
        #expect(worksheet.contains("<c r=\"B1\" t=\"str\"><f>\"x&lt;y\"</f><v>x&lt;y</v></c>"))
        #expect(worksheet.contains("<c r=\"C1\" t=\"b\"><f>1&gt;2</f><v>0</v></c>"))
        #expect(worksheet.contains("<c r=\"D1\" t=\"e\"><f>NA()</f><v>#N/A</v></c>"))
        #expect(worksheet.contains("<c r=\"E1\"><f>RAND()</f></c>"))
        #expect(worksheet.contains("<c r=\"F1\" t=\"e\"><f>SUM(</f><v>#NAME?</v></c>"))
        #expect(worksheet.contains("<c r=\"G1\" t=\"e\"><v>#NUM!</v></c>"))
        #expect(worksheet.contains("<c r=\"H1\" t=\"e\"><f>0/0</f><v>#NUM!</v></c>"))
        #expect(worksheet.contains("<c r=\"I1\"><v>0</v></c>"))
    }

    @Test func numbersUseTheShortestRoundTripForm() {
        #expect(XLSXValue.string(42) == "42")
        #expect(XLSXValue.string(-3) == "-3")
        #expect(XLSXValue.string(0.1) == "0.1")
        #expect(XLSXValue.string(0.1 + 0.2) == "0.30000000000000004")
        #expect(XLSXValue.string(1e20) == "1E+20")
        #expect(XLSXValue.string(1.5e-7) == "1.5E-07")
        #expect(XLSXValue.string(123_456_789_012_345) == "123456789012345")
        for number in [1.0 / 3, 2.0 / 3, 1e-300, 9_007_199_254_740_992, 46_342.75, -1e15, 1e15 + 0.5] {
            #expect(Double(XLSXValue.string(number)) == number)
        }
    }

    @Test func sheetViewsAndLayout() throws {
        let parts = try Self.parts(of: try SpreadsheetIO.write(Self.everythingWorkbook(), activeSheet: 0, format: .xlsx))
        let summary = try #require(parts["xl/worksheets/sheet1.xml"])
        #expect(summary.contains("<sheetPr><tabColor rgb=\"FF4285F4\"/></sheetPr>"))
        #expect(summary.contains("<dimension ref=\"A1:AB1500\"/>"))
        #expect(summary.contains("<sheetView showGridLines=\"0\" tabSelected=\"1\" workbookViewId=\"0\">"))
        #expect(summary.contains("<pane xSplit=\"1\" ySplit=\"2\" topLeftCell=\"B3\" activePane=\"bottomRight\" state=\"frozen\"/>"))
        #expect(summary.contains("<selection pane=\"bottomRight\" activeCell=\"B3\" sqref=\"B3\"/>"))
        #expect(summary.contains("<sheetFormatPr defaultColWidth=\"17.140625\" defaultRowHeight=\"18\" customHeight=\"1\"/>"))
        #expect(summary.contains("<col min=\"1\" max=\"1\" width=\"25.7109375\" customWidth=\"1\"/>"))
        #expect(summary.contains("<col min=\"6\" max=\"7\" width=\"17.140625\" hidden=\"1\"/>"))
        #expect(summary.contains("<row r=\"1\" ht=\"30\" customHeight=\"1\">"))
        #expect(summary.contains("<row r=\"5\" hidden=\"1\">"))
        #expect(summary.contains("<row r=\"13\" hidden=\"1\"/>"))
        #expect(summary.contains("<row r=\"2001\" ht=\"45\" customHeight=\"1\"/>"))
        #expect(summary.contains("<mergeCells count=\"2\"><mergeCell ref=\"C1:D2\"/><mergeCell ref=\"A14:F20\"/></mergeCells>"))
        // Element order matters to Excel.
        let order = ["<sheetPr>", "<dimension", "<sheetViews>", "<sheetFormatPr", "<cols>", "<sheetData>", "<mergeCells", "<pageMargins"]
        let positions = order.compactMap { summary.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted())

        let data = try #require(parts["xl/worksheets/sheet2.xml"])
        #expect(data.contains("<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"))
        let columns = try #require(parts["xl/worksheets/sheet3.xml"])
        #expect(columns.contains("<pane xSplit=\"3\" topLeftCell=\"D1\" activePane=\"topRight\" state=\"frozen\"/>"))
        let empty = try #require(parts["xl/worksheets/sheet4.xml"])
        #expect(empty.contains("<dimension ref=\"A1\"/>"))
        #expect(empty.contains("<sheetData></sheetData>"))
        #expect(!empty.contains("<cols>") && !empty.contains("<mergeCells"))
    }

    @Test func formulasGetExcelPrefixes() throws {
        let parts = try Self.parts(of: try SpreadsheetIO.write(Self.everythingWorkbook(), activeSheet: 0, format: .xlsx))
        let summary = try #require(parts["xl/worksheets/sheet1.xml"])
        #expect(summary.contains("<f>_xlfn.CONCAT(A2,\"!\")</f>"))
        #expect(summary.contains("<f>SUM(_xlfn._xlws.FILTER(B2:B8,B2:B8&gt;0))</f>"))
        #expect(summary.contains("<f>JOIN(\",\",SPLIT(\"a b\",\" \"))</f>"))
    }

    // MARK: - Details

    @Test func defaultsComeBackAsDefaults() throws {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .number(1), format: IOTest.format {
            $0.fontFamily = "Arial"
            $0.fontSize = 10
            $0.textColor = .black
            $0.verticalAlignment = .bottom
            $0.wrap = .overflow
            $0.numberFormat = "General"
        })
        sheet[0, 1] = Cell(value: .number(2), format: IOTest.format { $0.wrap = .clip })
        sheet[0, 2] = Cell(value: .number(3), format: IOTest.format {
            $0.verticalAlignment = .bottom
            $0.bold = true
        })
        let copy = try SpreadsheetIO.read(try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx), format: .xlsx)
        let read = copy.workbook.sheets[0]
        // Explicit defaults have no separate meaning in Excel; clipping has no Excel equivalent.
        #expect(read[0, 0] == Cell(value: .number(1)))
        #expect(read[0, 1] == Cell(value: .number(2)))
        #expect(read[0, 2] == Cell(value: .number(3), format: IOTest.format { $0.bold = true }))
    }

    @Test func sheetNamesAreMadeValidForExcel() {
        #expect(XLSXSheetNames.sanitized(["Sheet1", "Sales"]) == ["Sheet1", "Sales"])
        #expect(XLSXSheetNames.sanitized(["Q1/Q2: [Sales]*?"]) == ["Q1Q2 Sales"])
        #expect(XLSXSheetNames.sanitized(["'quoted'", "", "  ", "sheet1"]) == ["quoted", "Sheet2", "Sheet3", "sheet1"])
        let long = String(repeating: "x", count: 40)
        #expect(XLSXSheetNames.sanitized([long, long]) == [String(repeating: "x", count: 31), String(repeating: "x", count: 27) + " (2)"])
        #expect(XLSXSheetNames.sanitized(["Data", "DATA", "data"]) == ["Data", "DATA (2)", "data (3)"])
        #expect(XLSXSheetNames.sanitized([String(repeating: "😀", count: 20)]) == [String(repeating: "😀", count: 15)])
    }

    @Test func sheetsTooBigForExcelAreRefused() {
        var sheet = Sheet(name: "Wide", columnCount: 20_000)
        sheet[0, 16_384] = Cell(value: .number(1))
        #expect(throws: SpreadsheetIOError.self) { try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx) }
        var tall = Sheet(name: "Tall", rowCount: 2_000_000)
        tall[1_048_576, 0] = Cell(value: .number(1))
        #expect(throws: SpreadsheetIOError.self) { try SpreadsheetIO.write(Workbook(sheets: [tall]), activeSheet: 0, format: .xlsx) }
        // Sizes beyond Excel's grid are simply left out.
        var sizes = Sheet(name: "Sizes")
        sizes.columnWidths[20_000] = 50
        sizes.rowHeights[2_000_000] = 50
        #expect(throws: Never.self) { try SpreadsheetIO.write(Workbook(sheets: [sizes]), activeSheet: 0, format: .xlsx) }
    }

    @Test func openEndedRangesAreClosedForExcel() throws {
        var totals = Sheet(name: "Totals", rowCount: 300)
        totals[0, 0] = Cell(value: .number(0), formula: "=SUM(B2:B)+SUM(Entries!A2:A)+SUM('Entries'!C3:3)")
        let entries = Sheet(name: "Entries", rowCount: 2500, columnCount: 30)
        let data = try SpreadsheetIO.write(Workbook(sheets: [totals, entries]), activeSheet: 0, format: .xlsx)
        let worksheet = try #require(try Self.parts(of: data)["xl/worksheets/sheet1.xml"])
        #expect(worksheet.contains("<f>SUM(B2:B300)+SUM(Entries!A2:A2500)+SUM('Entries'!C3:AD3)</f>"))
    }

    @Test func overlappingMergesAreDropped() {
        let merges = ["A1:B2", "B2:C3", "D1:E1", "A5:B5", "E1:E3", "XFD1:XFD2"].compactMap { CellRange(a1: $0) }
        #expect(XLSXWriter.validMerges(merges + [CellRange(CellAddress(row: 0, column: 20_000), CellAddress(row: 1, column: 20_000))])
                == ["A1:B2", "D1:E1", "A5:B5", "XFD1:XFD2"].compactMap { CellRange(a1: $0) })
    }

    @Test func impossibleAddressesAreSkipped() throws {
        var sheet = Sheet(name: "Odd")
        sheet[-1, 0] = Cell(value: .number(1))
        sheet[0, -2] = Cell(value: .number(2))
        sheet[0, 0] = Cell(value: .number(3))
        sheet.merges = [CellRange(CellAddress(row: -1, column: 0), CellAddress(row: 1, column: 1))]
        sheet.frozenRows = -4
        let copy = try SpreadsheetIO.read(try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx), format: .xlsx)
        #expect(copy.workbook.sheets[0].cells.count == 1)
        #expect(copy.workbook.sheets[0].merges.isEmpty)
        #expect(copy.workbook.sheets[0].frozenRows == 0)
    }

    @Test func activeSheetIsClamped() throws {
        let workbook = Workbook(sheets: [Sheet(name: "A"), Sheet(name: "B")])
        #expect(try SpreadsheetIO.read(try SpreadsheetIO.write(workbook, activeSheet: 7, format: .xlsx), format: .xlsx).activeSheet == 1)
        #expect(try SpreadsheetIO.read(try SpreadsheetIO.write(workbook, activeSheet: -1, format: .xlsx), format: .xlsx).activeSheet == 0)
    }

    @Test func noSharedStringsPartWithoutText() throws {
        var sheet = Sheet(name: "Numbers")
        sheet[0, 0] = Cell(value: .number(1))
        let zip = try ZipReader(data: try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx))
        #expect(!zip.contains("xl/sharedStrings.xml"))
        #expect(!(String(decoding: try zip.read("[Content_Types].xml") ?? Data(), as: UTF8.self).contains("sharedStrings")))
    }
}
