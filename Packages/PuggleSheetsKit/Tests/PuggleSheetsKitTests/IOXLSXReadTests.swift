import Foundation
import Testing
@testable import PuggleSheetsKit

/// Reading packages built by hand to look like the files spreadsheet apps write.
struct IOXLSXReadTests {
    // MARK: - Fixtures

    /// A theme with distinctive colors so the index order (lt1, dk1, lt2, dk2, accent1, …) is visible.
    static let theme = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements>
        <a:clrScheme name="Test">
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
        <a:dk2><a:srgbClr val="112233"/></a:dk2><a:lt2><a:srgbClr val="EEEEEE"/></a:lt2>
        <a:accent1><a:srgbClr val="336699"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
        <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4>
        <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6>
        <a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Test"><a:majorFont><a:latin typeface="Aptos Display"/></a:majorFont>
        <a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme>
        </a:themeElements></a:theme>
        """

    static let excelStyles = IOTestPackage.styles("""
        <numFmts count="2"><numFmt numFmtId="164" formatCode="0.0%"/><numFmt numFmtId="165" formatCode="&quot;$&quot;#,##0.00"/></numFmts>
        <fonts count="5" x14ac:knownFonts="1" xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac">
        <font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/><scheme val="minor"/></font>
        <font><b/><i/><strike/><u/><sz val="14"/><color theme="4"/><name val="Georgia"/><family val="1"/></font>
        <font><sz val="10"/><color rgb="FF000000"/><name val="Arial"/><family val="2"/></font>
        <font><b val="0"/><u val="none"/><sz val="12"/><color indexed="10"/><name val="Arial"/></font>
        <font><sz val="11"/><color theme="1" tint="0.499984740745262"/><scheme val="minor"/></font>
        </fonts>
        <fills count="5">
        <fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/><bgColor indexed="64"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor theme="0" tint="-0.249977111117893"/><bgColor indexed="64"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor indexed="22"/><bgColor indexed="64"/></patternFill></fill>
        </fills>
        <borders count="3">
        <border><left/><right/><top/><bottom/><diagonal/></border>
        <border><left style="thin"><color indexed="64"/></left><right style="mediumDashDot"><color rgb="FF00FF00"/></right>
        <top style="double"><color theme="4"/></top><bottom style="hair"/><diagonal/></border>
        <border><start style="thick"/><end style="dotted"><color theme="3"/></end><top/><bottom style="medium"><color auto="1"/></bottom><diagonal/></border>
        </borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="9">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="164" fontId="1" fillId="2" borderId="1" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
        <xf numFmtId="165" fontId="2" fillId="3" borderId="2" xfId="0"><alignment horizontal="right" vertical="top"/></xf>
        <xf numFmtId="22" fontId="3" fillId="4" borderId="0" xfId="0"><alignment horizontal="general" vertical="bottom" wrapText="0"/></xf>
        <xf numFmtId="49" fontId="2" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="20" fontId="4" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="3" fontId="2" fillId="0" borderId="0" xfId="0"><alignment horizontal="left"/></xf>
        <xf numFmtId="46" fontId="2" fillId="0" borderId="0" xfId="0"/>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        <dxfs count="0"/><tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>
        """)

    static let excelStrings = IOTestPackage.sharedStrings("""
        <si><t>Name</t></si>
        <si><t xml:space="preserve">  padded  </t></si>
        <si><r><t>Bold</t></r><r><rPr><b/><sz val="11"/><color theme="1"/><rFont val="Calibri"/></rPr><t xml:space="preserve"> and plain</t></r></si>
        <si><t>漢字</t><rPh sb="0" eb="2"><t>カンジ</t></rPh><phoneticPr fontId="1"/></si>
        <si><t>Line 1_x000D_
        Line 2</t></si>
        <si><t>  trimmed  </t></si>
        <si><t>Tab_x0009_here &amp; _x005F_x0041_</t></si>
        """)

    static let excelSheet = """
        <sheetPr><tabColor theme="1" tint="0.499984740745262"/><pageSetUpPr fitToPage="1"/></sheetPr>
        <dimension ref="A1:F12"/>
        <sheetViews><sheetView tabSelected="1" zoomScale="125" workbookViewId="0">
        <pane xSplit="1" ySplit="2" topLeftCell="B3" activePane="bottomRight" state="frozen"/>
        <selection pane="topRight" activeCell="B1" sqref="B1"/><selection pane="bottomRight" activeCell="B3" sqref="B3"/>
        </sheetView></sheetViews>
        <sheetFormatPr defaultRowHeight="15" x14ac:dyDescent="0.25"/>
        <cols><col min="1" max="1" width="21.42578125" customWidth="1"/><col min="3" max="4" width="0" hidden="1" customWidth="1"/>
        <col min="6" max="16384" width="9.140625" style="1"/></cols>
        <sheetData>
        <row r="1" spans="1:6" x14ac:dyDescent="0.25"><c r="A1" t="s"><v>0</v></c><c r="B1" s="2" t="s"><v>2</v></c>
        <c r="C1" t="s"><v>1</v></c><c r="D1" t="s"><v>3</v></c><c r="E1" t="s"><v>4</v></c><c r="F1" t="s"><v>5</v></c></row>
        <row r="2" spans="1:6" ht="30" customHeight="1"><c r="A2" s="1"><v>45306</v></c><c r="B2"><v>1.5</v></c><c r="C2" t="b"><v>1</v></c>
        <c r="D2" t="e"><v>#DIV/0!</v></c><c r="E2" t="inlineStr"><is><t>inline</t></is></c><c r="F2" t="s"><v>6</v></c></row>
        <row r="3" hidden="1"><c r="A3"><f>A2+1</f><v>45307</v></c><c r="B3"><f t="shared" ref="B3:B6" si="0">B2*2</f><v>3</v></c></row>
        <row r="4"><c r="B4"><f t="shared" si="0"/><v>6</v></c><c r="C4" t="str"><f>_xlfn.CONCAT("a","b")</f><v>ab</v></c></row>
        <row r="5" ht="14.4"><c r="B5"><f t="shared" si="0"/><v>12</v></c><c r="D5" t="b"><f>ISNUMBER(B5)</f><v>1</v></c></row>
        <row r="6"><c r="B6"><f t="shared" si="0"/><v>24</v></c><c r="C6" t="e"><f>1/0</f><v>#DIV/0!</v></c></row>
        <row r="8"><c r="A8"><f t="array" ref="A8:A10">ROW(A1:A3)</f><v>1</v></c></row>
        <row r="9"><c r="A9"><v>2</v></c></row>
        <row r="10"><c r="A10"><v>3</v></c></row>
        <row r="12"><c r="A12" s="3"><v>1234.5</v></c><c r="B12" s="4"/><c r="C12" s="7"><v>-2</v></c>
        <c r="D12" s="5"><v>7</v></c><c r="E12" s="6"><v>0.75</v></c><c r="F12" s="8"><v>1.25</v></c></row>
        </sheetData>
        <mergeCells count="2"><mergeCell ref="A1:B1"/><mergeCell ref="D8:E9"/></mergeCells>
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>
        <pageSetup orientation="portrait" r:id="rId1"/>
        """

    static func excelWorkbook() throws -> SpreadsheetFile {
        try IOTestPackage.read(IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Data", excelSheet)], sharedStrings: excelStrings,
                                              styles: excelStyles, theme: theme))
    }

    static let calibri = IOTest.format {
        $0.fontFamily = "Calibri"
        $0.fontSize = 11
    }

    // MARK: - Excel

    @Test func excelValues() throws {
        let file = try Self.excelWorkbook()
        #expect(file.warnings == [.richText])
        #expect(file.activeSheet == 0)
        let sheet = try #require(file.workbook.sheets.first)
        #expect(sheet.name == "Data")
        #expect(sheet[0, 0].value == .text("Name"))
        #expect(sheet[0, 1].value == .text("Bold and plain"))
        #expect(sheet[0, 2].value == .text("  padded  "))
        #expect(sheet[0, 3].value == .text("漢字"))
        #expect(sheet[0, 4].value == .text("Line 1\nLine 2"))
        #expect(sheet[0, 5].value == .text("trimmed"))
        #expect(sheet[1, 0].value == .number(45306))
        #expect(sheet[1, 1].value == .number(1.5))
        #expect(sheet[1, 2].value == .boolean(true))
        #expect(sheet[1, 3].value == .error(CellError(.divideByZero)))
        #expect(sheet[1, 4].value == .text("inline"))
        #expect(sheet[1, 5].value == .text("Tab\there & _x0041_"))
        #expect(sheet[11, 0].value == .number(1234.5))
        #expect(sheet[11, 2].value == .number(-2))
        #expect(sheet[0, 0].formula == nil)
    }

    @Test func excelFormulasKeepTheirCachedResults() throws {
        let sheet = try #require(try Self.excelWorkbook().workbook.sheets.first)
        #expect(sheet[2, 0] == Cell(value: .number(45307), formula: "=A2+1", format: Self.calibri))
        // Shared formulas: each cell shifts the first cell's references.
        #expect(sheet[2, 1].formula == "=B2*2")
        #expect(sheet[3, 1].formula == "=B3*2")
        #expect(sheet[4, 1].formula == "=B4*2")
        #expect(sheet[5, 1].formula == "=B5*2")
        #expect(sheet[5, 1].value == .number(24))
        #expect(sheet[3, 2] == Cell(value: .text("ab"), formula: "=CONCAT(\"a\",\"b\")", format: Self.calibri))
        #expect(sheet[4, 3] == Cell(value: .boolean(true), formula: "=ISNUMBER(B5)", format: Self.calibri))
        #expect(sheet[5, 2] == Cell(value: .error(CellError(.divideByZero)), formula: "=1/0", format: Self.calibri))
        // An array formula lives in its first cell; the rest of its block is left for it to fill.
        #expect(sheet[7, 0] == Cell(value: .number(1), formula: "=ROW(A1:A3)", format: Self.calibri))
        #expect(sheet[8, 0] == Cell(format: Self.calibri))
        #expect(sheet[9, 0] == Cell(format: Self.calibri))
    }

    @Test func excelStylesWithThemeAndIndexedColors() throws {
        let sheet = try #require(try Self.excelWorkbook().workbook.sheets.first)
        let accent1 = RGBColor(hex: "336699")!
        #expect(sheet[0, 0].format == Self.calibri)
        #expect(sheet[1, 0].format == IOTest.format {
            $0.fontFamily = "Calibri"
            $0.fontSize = 11
            $0.numberFormat = "M/d/yyyy"
        })
        #expect(sheet[0, 1].format == IOTest.format {
            $0.numberFormat = "0.0%"
            $0.fontFamily = "Georgia"
            $0.fontSize = 14
            $0.bold = true
            $0.italic = true
            $0.underline = true
            $0.strikethrough = true
            $0.textColor = accent1
            $0.fillColor = RGBColor(hex: "FFFF00")
            $0.horizontalAlignment = .center
            $0.verticalAlignment = .middle
            $0.wrap = .wrap
            $0.borders = CellBorders(top: BorderLine(style: .double, color: accent1), left: BorderLine(style: .thin, color: .black),
                                     bottom: BorderLine(style: .thin, color: .black),
                                     right: BorderLine(style: .dashed, color: RGBColor(hex: "00FF00")!))
        })
        // Arial 10 in black is the default, so only what differs is set.
        #expect(sheet[11, 0].format == IOTest.format {
            $0.numberFormat = "\"$\"#,##0.00"
            $0.fillColor = RGBColor(hex: "BFBFBF")
            $0.horizontalAlignment = .right
            $0.verticalAlignment = .top
            $0.borders = CellBorders(left: BorderLine(style: .thick, color: .black), bottom: BorderLine(style: .medium, color: .black),
                                     right: BorderLine(style: .dotted, color: RGBColor(hex: "112233")!))
        })
        #expect(sheet[11, 1] == Cell(format: IOTest.format {
            $0.numberFormat = "M/d/yyyy H:mm"
            $0.fontSize = 12
            $0.textColor = RGBColor(hex: "FF0000")
            $0.fillColor = RGBColor(hex: "C0C0C0")
        }))
        #expect(sheet[11, 2].format == IOTest.format {
            $0.numberFormat = "#,##0"
            $0.horizontalAlignment = .left
        })
        #expect(sheet[11, 3].format == IOTest.format { $0.numberFormat = "@" })
        // A font without a name takes the theme's body font; a tinted theme color.
        #expect(sheet[11, 4].format == IOTest.format {
            $0.numberFormat = "H:mm"
            $0.fontFamily = "Aptos"
            $0.fontSize = 11
            $0.textColor = RGBColor(hex: "7F7F7F")
        })
        #expect(sheet[11, 5].format == IOTest.format { $0.numberFormat = "[h]:mm:ss" })
    }

    @Test func excelLayout() throws {
        let sheet = try #require(try Self.excelWorkbook().workbook.sheets.first)
        #expect(sheet.tabColor == RGBColor(hex: "7F7F7F"))
        #expect(sheet.showsGridlines)
        #expect(sheet.frozenRows == 2)
        #expect(sheet.frozenColumns == 1)
        // No baseColWidth: Excel's 8 digits, 64 pixels. 15 points are 20 pixels.
        #expect(sheet.defaultColumnWidth == 64)
        #expect(sheet.defaultRowHeight == 20)
        #expect(sheet.columnWidths == [0: 150])
        #expect(sheet.hiddenColumns == [2, 3])
        #expect(sheet.rowHeights == [1: 40])
        #expect(sheet.hiddenRows == [2])
        #expect(sheet.merges == [CellRange(a1: "A1:B1")!, CellRange(a1: "D8:E9")!])
        #expect(sheet.rowCount == 1000)
        #expect(sheet.columnCount == 26)
    }

    // MARK: - Exported workbook

    static let exportStyles = IOTestPackage.styles("""
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/></numFmts>
        <fonts count="3">
        <font><sz val="10.0"/><color rgb="FF000000"/><name val="Arial"/><scheme val="minor"/></font>
        <font><b/><sz val="10.0"/><color rgb="FFFF0000"/><name val="Arial"/><scheme val="minor"/></font>
        <font><color theme="1"/><name val="Arial"/><scheme val="minor"/></font>
        </fonts>
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="lightGray"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FF00FFFF"/><bgColor rgb="FF00FFFF"/></patternFill></fill></fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf borderId="0" fillId="0" fontId="0" numFmtId="0" applyAlignment="1" applyFont="1"/></cellStyleXfs>
        <cellXfs count="4">
        <xf borderId="0" fillId="0" fontId="0" numFmtId="0" xfId="0" applyAlignment="1" applyFont="1"><alignment readingOrder="0" shrinkToFit="0" vertical="bottom" wrapText="0"/></xf>
        <xf borderId="0" fillId="2" fontId="1" numFmtId="0" xfId="0" applyAlignment="1" applyFill="1" applyFont="1"><alignment readingOrder="0"/></xf>
        <xf borderId="0" fillId="0" fontId="2" numFmtId="10" xfId="0" applyAlignment="1" applyFont="1" applyNumberFormat="1"><alignment horizontal="right" vertical="bottom"/></xf>
        <xf borderId="0" fillId="0" fontId="0" numFmtId="164" xfId="0" applyAlignment="1" applyFont="1" applyNumberFormat="1"><alignment vertical="bottom"/></xf>
        </cellXfs>
        <cellStyles count="1"><cellStyle xfId="0" name="Normal" builtinId="0"/></cellStyles><dxfs count="0"/>
        """)

    static let exportSheet = """
        <sheetPr><tabColor rgb="FF4285F4"/><outlinePr summaryBelow="0" summaryRight="0"/></sheetPr>
        <sheetViews><sheetView workbookViewId="0" showGridLines="0">
        <pane ySplit="1.0" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection activeCell="B3" sqref="B3" pane="bottomLeft"/>
        </sheetView></sheetViews>
        <sheetFormatPr customHeight="1" defaultColWidth="14.43" defaultRowHeight="15.75"/>
        <cols><col customWidth="1" min="1" max="1" width="25.43"/><col customWidth="1" min="2" max="3" width="8.0"/></cols>
        <sheetData>
        <row r="1"><c r="A1" s="1" t="s"><v>0</v></c><c r="B1" s="1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" s="2"><v>0.256</v></c><c r="B2" s="3"><v>45306.0</v></c><c r="C2" s="0"/></row>
        <row r="40"><c r="AD40" t="s"><v>2</v></c></row>
        </sheetData>
        """

    @Test func exportedWorkbookReads() throws {
        let data = try IOTestPackage.xlsx(
            sheets: [IOTestPackage.SheetPart("Intro", "<sheetData/>"), IOTestPackage.SheetPart("Scores", Self.exportSheet)],
            sharedStrings: IOTestPackage.sharedStrings("""
                <si><t xml:space="preserve">Name</t></si><si><t xml:space="preserve">Score</t></si><si><t xml:space="preserve">far</t></si>
                """),
            styles: Self.exportStyles, activeTab: 1)
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets.map(\.name) == ["Intro", "Scores"])
        #expect(file.activeSheet == 1)

        let intro = file.workbook.sheets[0]
        #expect(intro.cells.isEmpty)
        #expect(intro.rowCount == 1000 && intro.columnCount == 26)

        let sheet = file.workbook.sheets[1]
        let header = IOTest.format {
            $0.bold = true
            $0.textColor = RGBColor(hex: "FF0000")
            $0.fillColor = RGBColor(hex: "00FFFF")
        }
        #expect(sheet[0, 0] == Cell(value: .text("Name"), format: header))
        #expect(sheet[0, 1] == Cell(value: .text("Score"), format: header))
        #expect(sheet[1, 0] == Cell(value: .number(0.256), format: IOTest.format {
            $0.numberFormat = "0.00%"
            $0.horizontalAlignment = .right
        }))
        #expect(sheet[1, 1] == Cell(value: .number(45306), format: IOTest.format { $0.numberFormat = "yyyy-mm-dd" }))
        // The file's default style (Arial 10, black, bottom aligned) leaves nothing to store.
        #expect(sheet.cells[CellAddress(row: 1, column: 2)] == nil)
        #expect(sheet[39, 29].value == .text("far"))
        #expect(sheet[39, 29].format.isDefault)

        #expect(sheet.tabColor == RGBColor(hex: "4285F4"))
        #expect(!sheet.showsGridlines)
        #expect(sheet.frozenRows == 1)
        #expect(sheet.frozenColumns == 0)
        #expect(sheet.defaultRowHeight == 21)
        #expect(sheet.defaultColumnWidth == 101)
        #expect(sheet.columnWidths == [0: 178, 1: 56, 2: 56])
        #expect(sheet.rowCount == 1000)
        #expect(sheet.columnCount == 30)
    }

    // MARK: - Values and dates

    @Test func dates1904AreShifted() throws {
        let styles = IOTestPackage.styles("""
            <fonts count="1"><font><sz val="10"/><name val="Arial"/></font></fonts>
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
            <borders count="1"><border/></borders>
            <cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="18"/><xf numFmtId="22"/></cellXfs>
            """)
        let data = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Dates", """
            <sheetData><row r="1"><c r="A1" s="1"><v>0</v></c><c r="B1" s="2"><v>0.5</v></c><c r="C1"><v>100</v></c>
            <c r="D1" s="3"><f>A1+1.25</f><v>1.25</v></c><c r="E1" s="1"><v>44927</v></c></row></sheetData>
            """)], styles: styles, workbookPrefix: "<workbookPr date1904=\"1\"/>")
        let sheet = try #require(try IOTestPackage.read(data).workbook.sheets.first)
        #expect(sheet[0, 0].value == .number(1462))
        let start = DateSerial.parts(of: 1462)
        #expect(start.year == 1904 && start.month == 1 && start.day == 1)
        // Times of day and plain numbers don't move.
        #expect(sheet[0, 1].value == .number(0.5))
        #expect(sheet[0, 2].value == .number(100))
        #expect(sheet[0, 3].value == .number(1463.25))
        #expect(sheet[0, 4].value == .number(44927 + 1462))
        #expect(sheet[0, 4].value.numberValue == DateSerial.serial(year: 2027, month: 1, day: 2))
    }

    @Test func isoDateCellsBecomeSerials() throws {
        let data = try IOTestPackage.xlsx(sheet: """
            <sheetData><row r="1"><c r="A1" t="d"><v>2026-11-16</v></c><c r="B1" t="d"><v>2026-11-16T18:30:00.500Z</v></c>
            <c r="C1" t="d"><v>T06:00:00</v></c><c r="D1" t="d"><v>not a date</v></c></row></sheetData>
            """)
        let sheet = try #require(try IOTestPackage.read(data).workbook.sheets.first)
        #expect(sheet[0, 0] == Cell(value: .number(46_342), format: IOTest.format { $0.numberFormat = NumberFormatPresets.date.pattern }))
        let evening = 46_342 + DateSerial.time(hour: 18, minute: 30, second: 0.5)
        #expect(sheet[0, 1] == Cell(value: .number(evening), format: IOTest.format { $0.numberFormat = NumberFormatPresets.dateTime.pattern }))
        #expect(sheet[0, 2] == Cell(value: .number(0.25), format: IOTest.format { $0.numberFormat = NumberFormatPresets.time.pattern }))
        #expect(sheet.cells[CellAddress(row: 0, column: 3)] == nil)
    }

    @Test func errorsBooleansAndOddValues() throws {
        let data = try IOTestPackage.xlsx(sheet: """
            <sheetData><row r="1">
            <c r="A1" t="e"><v>#N/A</v></c><c r="B1" t="e"><v>#REF!</v></c><c r="C1" t="e"><v>#NAME?</v></c><c r="D1" t="e"><v>#NUM!</v></c>
            <c r="E1" t="e"><v>#NULL!</v></c><c r="F1" t="e"><v>#VALUE!</v></c><c r="G1" t="e"><v>#SPILL!</v></c><c r="H1" t="e"><v>#CALC!</v></c>
            </row><row r="2">
            <c r="A2" t="b"><v>0</v></c><c r="B2" t="b"><v>true</v></c><c r="C2"><v>1.2345678901234567E-5</v></c><c r="D2"><v>1E+21</v></c>
            <c r="E2" t="s"><v>99</v></c><c r="F2"><v>abc</v></c><c r="G2" t="str"><f>""</f><v></v></c><c r="H2" t="inlineStr"><is><t></t></is></c>
            </row></sheetData>
            """)
        let sheet = try #require(try IOTestPackage.read(data).workbook.sheets.first)
        let errors: [CellError.Kind] = [.notAvailable, .reference, .name, .number, .null, .value, .reference, .value]
        for (column, kind) in errors.enumerated() {
            #expect(sheet[0, column].value == .error(CellError(kind)))
        }
        #expect(sheet[1, 0].value == .boolean(false))
        #expect(sheet[1, 1].value == .boolean(true))
        #expect(sheet[1, 2].value == .number(1.2345678901234567E-5))
        #expect(sheet[1, 3].value == .number(1e21))
        // An unknown shared string and a value that isn't a number leave the cell empty.
        #expect(sheet.cells[CellAddress(row: 1, column: 4)] == nil)
        #expect(sheet.cells[CellAddress(row: 1, column: 5)] == nil)
        // A formula's empty string is kept; an empty inline string is no value at all.
        #expect(sheet[1, 6] == Cell(value: .text(""), formula: "=\"\""))
        #expect(sheet.cells[CellAddress(row: 1, column: 7)] == nil)
    }

    @Test func implicitReferencesAndPrefixedElements() throws {
        let prefixed = IOTestPackage.declaration + """
            <x:worksheet xmlns:x="\(IOTestPackage.mainNamespace)"><x:sheetData>
            <x:row><x:c><x:v>1</x:v></x:c><x:c><x:v>2</x:v></x:c><x:c r="E1"><x:v>5</x:v></x:c><x:c><x:v>6</x:v></x:c></x:row>
            <x:row><x:c t="inlineStr"><x:is><x:r><x:t>rich</x:t></x:r><x:r><x:rPr><x:b/></x:rPr><x:t xml:space="preserve"> text</x:t></x:r></x:is></x:c></x:row>
            <x:row r="5"><x:c t="str"><x:f>A1&amp;"!"</x:f><x:v>1!</x:v></x:c></x:row>
            </x:sheetData><x:mergeCells><x:mergeCell ref="A5:B5"/></x:mergeCells></x:worksheet>
            """
        let data = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Prefixed", "")], parts: ["xl/worksheets/sheet1.xml": prefixed])
        let file = try IOTestPackage.read(data)
        let sheet = try #require(file.workbook.sheets.first)
        #expect(sheet[0, 0].value == .number(1))
        #expect(sheet[0, 1].value == .number(2))
        #expect(sheet[0, 4].value == .number(5))
        #expect(sheet[0, 5].value == .number(6))
        #expect(sheet[1, 0].value == .text("rich text"))
        #expect(sheet[4, 0] == Cell(value: .text("1!"), formula: "=A1&\"!\""))
        #expect(sheet.merges == [CellRange(a1: "A5:B5")!])
        #expect(file.warnings == [.richText])
    }

    // MARK: - Workbook structure

    @Test func hiddenSheetsStayVisibleAndChartSheetsAreSkipped() throws {
        let chartSheet = IOTestPackage.declaration
            + "<chartsheet xmlns=\"\(IOTestPackage.mainNamespace)\" xmlns:r=\"\(IOTestPackage.relationshipNamespace)\"><drawing r:id=\"rId1\"/></chartsheet>"
        let data = try IOTestPackage.xlsx(sheets: [
            IOTestPackage.SheetPart("Chart1", chartSheet, type: "chartsheet"),
            IOTestPackage.SheetPart("Visible", "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>"),
            IOTestPackage.SheetPart("Secret", "<sheetData/>", state: "hidden"),
            IOTestPackage.SheetPart("visible", "<sheetData/>", state: "veryHidden"),
        ], activeTab: 3)
        let file = try IOTestPackage.read(data)
        #expect(file.workbook.sheets.map(\.name) == ["Visible", "Secret", "visible (2)"])
        #expect(file.activeSheet == 2)
        #expect(file.warnings == [.charts, .hiddenSheets])
    }

    @Test func emptyAndMinimalWorkbooks() throws {
        // No styles, no shared strings, no sheets: still a workbook with one sheet.
        let file = try IOTestPackage.read(try IOTestPackage.xlsx(sheets: []))
        #expect(file.workbook.sheets.count == 1)
        #expect(file.activeSheet == 0)

        // A package without relationships for the workbook falls back to its usual place.
        var parts: [String: Data] = [:]
        parts["xl/workbook.xml"] = Data((IOTestPackage.declaration + "<workbook xmlns=\"\(IOTestPackage.mainNamespace)\" "
            + "xmlns:r=\"\(IOTestPackage.relationshipNamespace)\"><sheets><sheet name=\"Only\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>").utf8)
        parts["xl/_rels/workbook.xml.rels"] = Data(IOTestPackage.relationships([("rId1", "worksheet", "/xl/worksheets/only.xml")]).utf8)
        parts["xl/worksheets/only.xml"] = Data(IOTestPackage.worksheet("<sheetData><row r=\"2\"><c r=\"B2\"><v>42</v></c></row></sheetData>").utf8)
        let minimal = try IOTestPackage.read(try IOTestPackage.zip(parts))
        #expect(minimal.workbook.sheets.first?.name == "Only")
        #expect(minimal.workbook.sheets.first?[1, 1].value == .number(42))
    }

    @Test func gridGrowsToFitData() throws {
        let data = try IOTestPackage.xlsx(sheet: """
            <cols><col min="40" max="40" width="20" customWidth="1"/><col min="41" max="1024" width="5" customWidth="1"/></cols>
            <sheetData><row r="2500"><c r="B2500"><v>1</v></c></row><row r="3000" hidden="1"/></sheetData>
            <mergeCells count="1"><mergeCell ref="AA10:AB11"/></mergeCells>
            """)
        let sheet = try #require(try IOTestPackage.read(data).workbook.sheets.first)
        #expect(sheet.rowCount == 3000)
        #expect(sheet.columnCount == 40)
        #expect(sheet.hiddenRows == [2999])
        #expect(sheet.columnWidths == [39: XLSXUnits.pixels(fromColumnWidth: 20)])
    }

    @Test func baseColumnWidthSetsTheDefault() throws {
        let data = try IOTestPackage.xlsx(sheet: "<sheetFormatPr baseColWidth=\"10\" defaultRowHeight=\"16\"/><sheetData/>")
        let sheet = try #require(try IOTestPackage.read(data).workbook.sheets.first)
        #expect(sheet.defaultColumnWidth == 80)
        #expect(sheet.defaultRowHeight == 21)
    }

    @Test func strictOpenXML() throws {
        // ISO 29500 strict files use other namespaces and relationship types.
        let strictMain = "http://purl.oclc.org/ooxml/spreadsheetml/main"
        let strictRelationships = "http://purl.oclc.org/ooxml/officeDocument/relationships"
        var parts: [String: Data] = [:]
        parts["_rels/.rels"] = Data(IOTestPackage.relationships([("rId1", "\(strictRelationships)/officeDocument", "xl/workbook.xml")]).utf8)
        parts["xl/workbook.xml"] = Data((IOTestPackage.declaration + "<workbook xmlns=\"\(strictMain)\" xmlns:r=\"\(strictRelationships)\">"
            + "<workbookPr dateCompatibility=\"0\"/><sheets><sheet name=\"Strict\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>").utf8)
        parts["xl/_rels/workbook.xml.rels"] = Data(IOTestPackage.relationships([
            ("rId1", "\(strictRelationships)/worksheet", "worksheets/sheet1.xml"),
            ("rId2", "\(strictRelationships)/sharedStrings", "sharedStrings.xml"),
        ]).utf8)
        parts["xl/sharedStrings.xml"] = Data((IOTestPackage.declaration + "<sst xmlns=\"\(strictMain)\"><si><t>strict</t></si></sst>").utf8)
        parts["xl/worksheets/sheet1.xml"] = Data((IOTestPackage.declaration + "<worksheet xmlns=\"\(strictMain)\"><sheetData>"
            + "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"d\"><v>2026-01-02T00:00:00</v></c></row></sheetData></worksheet>").utf8)
        let sheet = try #require(try IOTestPackage.read(try IOTestPackage.zip(parts)).workbook.sheets.first)
        #expect(sheet.name == "Strict")
        #expect(sheet[0, 0].value == .text("strict"))
        #expect(sheet[0, 1].value == .number(DateSerial.serial(year: 2026, month: 1, day: 2)))
        #expect(sheet[0, 1].format.numberFormat == NumberFormatPresets.date.pattern)
    }

    @Test func lenientAboutCommonWriterQuirks() throws {
        let data = try IOTestPackage.xlsx(sheet: """
            <sheetFormatPr defaultRowHeight="15.75" customHeight="1"/>
            <sheetData>
            <row r="1" ht="15.75" customHeight="1"><c r="A1" t="inlineStr"><v>in v</v></c></row>
            <row r="2" ht="31.5" customHeight="1"><c r="A2" t="str"><v>plain str</v></c></row>
            <row r="3" ht="0" customHeight="1"/>
            </sheetData>
            """)
        let sheet = try #require(try IOTestPackage.read(data).workbook.sheets.first)
        #expect(sheet[0, 0].value == .text("in v"))
        #expect(sheet[1, 0].value == .text("plain str"))
        // A row marked with the default height keeps no height of its own; a zero height hides it.
        #expect(sheet.rowHeights == [1: 42])
        #expect(sheet.hiddenRows == [2])
    }

    // MARK: - Things PuggleSheets can't keep

    @Test func warnsAboutFeaturesItCannotKeep() throws {
        let drawing = IOTestPackage.declaration + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\"/>"
        let sheet = IOTestPackage.SheetPart("Report", """
            <sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData>
            <sheetProtection sheet="1" objects="1" scenarios="1"/>
            <autoFilter ref="A1:B3"/>
            <conditionalFormatting sqref="A1:A3"><cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan"><formula>1</formula></cfRule></conditionalFormatting>
            <dataValidations count="1"><dataValidation type="list" sqref="B1"><formula1>"a,b"</formula1></dataValidation></dataValidations>
            <hyperlinks><hyperlink ref="A1" r:id="rId5"/></hyperlinks>
            <drawing r:id="rId1"/><legacyDrawing r:id="rId2"/>
            """, relationships: [("drawing", "../drawings/drawing1.xml"), ("vmlDrawing", "../drawings/vmlDrawing1.vml"),
                                  ("comments", "../comments1.xml"), ("pivotTable", "../pivotTables/pivotTable1.xml"),
                                  ("hyperlink", "https://example.com")])
        let data = try IOTestPackage.xlsx(
            sheets: [sheet, IOTestPackage.SheetPart("Hidden", "<sheetData/>", state: "hidden")],
            sharedStrings: IOTestPackage.sharedStrings("<si><r><t>a</t></r><r><t>b</t></r></si>"),
            workbookPrefix: "<workbookProtection lockStructure=\"1\"/>",
            workbookSuffix: "<definedNames><definedName name=\"TaxRate\">Report!$B$1</definedName>"
                + "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">Report!$A$1:$B$3</definedName></definedNames>",
            parts: [
                "xl/drawings/drawing1.xml": drawing,
                "xl/drawings/_rels/drawing1.xml.rels": IOTestPackage.relationships([("rId1", "chart", "../charts/chart1.xml"),
                                                                                    ("rId2", "image", "../media/image1.png")]),
            ],
            binaryParts: ["xl/vbaProject.bin": Data([0xD0, 0xCF, 0x11, 0xE0])])
        let file = try IOTestPackage.read(data)
        // The conditional format, validation, filter, named range, link and sheet protection are kept now, and
        // the empty drawing holds nothing; the comments and the pivot table (whose parts are missing) can't be,
        // nor the workbook's structure protection.
        #expect(file.warnings == [.comments, .pivotTables, .hiddenSheets, .macros, .richText, .protection])
        let report = file.workbook.sheets[0]
        #expect(report[0, 0].value == .number(1))
        #expect(report[0, 0].link == "https://example.com")
        #expect(report.protections.map(\.scope) == [.sheet(except: [])] && report.protections.first?.warningOnly == false)
        #expect(report.conditionalFormats.count == 1)
        #expect(report.validations.count == 1)
        #expect(report.filter?.range == CellRange(a1: "A1:B3"))
        #expect(file.workbook.namedRanges == [NamedRange(name: "TaxRate", reference: "Report!$B$1")])
    }

    @Test func warnsAboutRulesItCannotKeep() throws {
        let sheet = IOTestPackage.SheetPart("Report", """
            <sheetData><row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v>2</v></c></row></sheetData>
            <autoFilter ref="A1:A2"><filterColumn colId="0"><top10 top="1" val="1"/></filterColumn></autoFilter>
            <conditionalFormatting sqref="A1:A3"><cfRule type="dataBar" priority="1"><dataBar><cfvo type="min"/><cfvo type="max"/>
            <color rgb="FF638EC6"/></dataBar></cfRule></conditionalFormatting>
            <dataValidations count="1"><dataValidation type="list" sqref="B1"/></dataValidations>
            <tableParts count="1"><tablePart r:id="rId9"/></tableParts>
            """)
        let data = try IOTestPackage.xlsx(sheets: [sheet],
                                          workbookSuffix: "<definedNames><definedName name=\"Rate\">0.07</definedName></definedNames>")
        let file = try IOTestPackage.read(data)
        #expect(file.warnings == [.filters, .conditionalFormatting, .dataValidation, .namedRanges])
        #expect(file.workbook.namedRanges.isEmpty)
        #expect(file.workbook.sheets[0].filter?.criteria.isEmpty == true)
    }

    @Test func builtInNamesAndUnprotectedSheetsDoNotWarn() throws {
        let data = try IOTestPackage.xlsx(
            sheets: [IOTestPackage.SheetPart("Sheet1", "<sheetData/><sheetProtection sheet=\"0\"/><dataValidations count=\"0\"/>")],
            workbookSuffix: "<definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">Sheet1!$A$1:$C$9</definedName>"
                + "<definedName name=\"_xlfn.CONCAT\" hidden=\"1\">#NAME?</definedName>"
                + "<definedName name=\"SolverData\" hidden=\"1\">1</definedName></definedNames>")
        #expect(try IOTestPackage.read(data).warnings.isEmpty)
    }

    @Test func drawingsAreToldApart() throws {
        func warnings(drawingRelationships: [(id: String, type: String, target: String)], anchors: String,
                      media: [String: Data] = [:]) throws -> Set<ImportWarning> {
            let drawing = IOTestPackage.declaration
                + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" "
                + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(IOTestPackage.relationshipNamespace)\" "
                + "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\">\(anchors)</xdr:wsDr>"
            var parts = ["xl/drawings/drawing1.xml": drawing]
            if !drawingRelationships.isEmpty {
                parts["xl/drawings/_rels/drawing1.xml.rels"] = IOTestPackage.relationships(drawingRelationships)
            }
            let data = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("S", "<sheetData/><drawing r:id=\"rId1\"/>",
                                                                            relationships: [("drawing", "../drawings/drawing1.xml")])],
                                            parts: parts, binaryParts: media)
            return try IOTestPackage.read(data).warnings
        }
        let from = "<xdr:from><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>"
            + "<xdr:ext cx=\"952500\" cy=\"952500\"/>"
        func picture(_ embed: String) -> String {
            "<xdr:oneCellAnchor>\(from)<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"2\" name=\"Picture 1\"/><xdr:cNvPicPr/></xdr:nvPicPr>"
                + "<xdr:blipFill><a:blip r:embed=\"\(embed)\"/></xdr:blipFill><xdr:spPr/></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>"
        }
        // A picture in a format PuggleSheets can't show (EMF) can't be kept; a PNG can.
        #expect(try warnings(drawingRelationships: [("rId1", "image", "../media/image1.emf")], anchors: picture("rId1"),
                             media: ["xl/media/image1.emf": Data([1, 0, 0, 0, 0x6C, 0, 0, 0])]) == [.images])
        #expect(try warnings(drawingRelationships: [("rId1", "image", "../media/image1.png")], anchors: picture("rId1"),
                             media: ["xl/media/image1.png": IOXLSXObjectTests.png]).isEmpty)
        // Excel 2016's chart types come with a stand-in shape for older apps.
        let chartEx = "<xdr:twoCellAnchor>\(from.replacingOccurrences(of: "<xdr:ext cx=\"952500\" cy=\"952500\"/>", with: ""))"
            + "<xdr:to><xdr:col>5</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>9</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>"
            + "<mc:AlternateContent><mc:Choice Requires=\"cx1\"><xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"2\" name=\"Chart 1\"/>"
            + "<xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm/><a:graphic>"
            + "<a:graphicData uri=\"http://schemas.microsoft.com/office/drawing/2014/chartex\"><cx:chart xmlns:cx=\"http://schemas.microsoft.com/office/drawing/2014/chartex\" r:id=\"rId1\"/>"
            + "</a:graphicData></a:graphic></xdr:graphicFrame></mc:Choice><mc:Fallback><xdr:sp macro=\"\" textlink=\"\"/></mc:Fallback>"
            + "</mc:AlternateContent><xdr:clientData/></xdr:twoCellAnchor>"
        #expect(try warnings(drawingRelationships: [("rId1", "http://schemas.microsoft.com/office/2014/relationships/chartEx", "../charts/chartEx1.xml")],
                             anchors: chartEx) == [.charts])
        // Shapes and text boxes can't be kept; an empty drawing has nothing to lose.
        #expect(try warnings(drawingRelationships: [], anchors: "<xdr:oneCellAnchor>\(from)<xdr:sp macro=\"\" textlink=\"\"/><xdr:clientData/></xdr:oneCellAnchor>")
            == [.images])
        #expect(try warnings(drawingRelationships: [], anchors: "<xdr:twoCellAnchor/>").isEmpty)
        #expect(try warnings(drawingRelationships: [], anchors: "").isEmpty)
    }

    @Test func extensionListsAreScanned() throws {
        let data = try IOTestPackage.xlsx(sheet: """
            <sheetData/><extLst>
            <ext uri="{78C0D931-6437-407d-A8EE-F0AAD7539E65}"><x14:conditionalFormattings><x14:conditionalFormatting>
            <x14:cfRule type="dataBar" id="{1}"/><xm:sqref>A1:A9</xm:sqref></x14:conditionalFormatting></x14:conditionalFormattings></ext>
            <ext uri="{CCE6A557-97BC-4b89-ADB6-D9C93CAAB3DF}"><x14:dataValidations count="1"><x14:dataValidation type="list">
            <x14:formula1><xm:f>Lists!$A$1:$A$3</xm:f></x14:formula1><xm:sqref>B1</xm:sqref></x14:dataValidation></x14:dataValidations></ext>
            <ext uri="{05C60535-1F16-4fd2-B633-F4F36F0B64E0}"><x14:sparklineGroups><x14:sparklineGroup/></x14:sparklineGroups></ext>
            </extLst>
            """)
        let file = try IOTestPackage.read(data)
        // Excel 2010's validations are read; its data bars and sparklines can't be kept.
        #expect(file.warnings == [.conditionalFormatting, .charts])
        #expect(file.workbook.sheets[0].cells.isEmpty)
        #expect(file.workbook.sheets[0].validations.map(\.criterion) == [.listFromRange("Lists!$A$1:$A$3")])
        #expect(file.workbook.sheets[0].validations.first?.ranges == [CellRange(a1: "B1")!])
    }

    @Test func macroEnabledContentTypesWarn() throws {
        let data = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("S", "<sheetData/>")],
                                        contentTypesExtra: "<Override PartName=\"/xl/other.xml\" ContentType=\"application/vnd.ms-excel.sheet.macroEnabled.main+xml\"/>")
        #expect(try IOTestPackage.read(data).warnings == [.macros])
    }

    // MARK: - Files that can't be read

    static func unreadableMessage(_ data: Data) -> String? {
        do {
            _ = try IOTestPackage.read(data)
            return nil
        } catch SpreadsheetIOError.unreadable(let message) {
            return message
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test func refusesFilesThatAreNotWorkbooks() throws {
        #expect(Self.unreadableMessage(Data()) == XLSXMessages.notAWorkbook)
        #expect(Self.unreadableMessage(Data("name,score\nAda,1".utf8)) == XLSXMessages.notAWorkbook)
        #expect(Self.unreadableMessage(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 600)))
                == XLSXMessages.legacyOrEncrypted)
        // A ZIP archive without a workbook (say, a .docx).
        let notExcel = try IOTestPackage.zip(["word/document.xml": Data("<w:document/>".utf8)])
        #expect(Self.unreadableMessage(notExcel) == XLSXMessages.notAWorkbook)
    }

    @Test func refusesDamagedParts() throws {
        let brokenSheet = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Sales", "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></row>")])
        #expect(Self.unreadableMessage(brokenSheet) == XLSXMessages.damagedSheet("Sales"))

        let entity = IOTestPackage.declaration + "<!DOCTYPE worksheet [<!ENTITY lol \"lol\">]>"
            + "<worksheet xmlns=\"\(IOTestPackage.mainNamespace)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>&lol;</t></is></c></row></sheetData></worksheet>"
        let withEntity = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Sheet1", "")], parts: ["xl/worksheets/sheet1.xml": entity])
        #expect(Self.unreadableMessage(withEntity) == XLSXMessages.damagedSheet("Sheet1"))

        let missingSheet = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Gone", "<sheetData/>")])
        var parts = try ZipReader(data: missingSheet).entries.reduce(into: [String: Data]()) { result, entry in
            result[entry.path] = try ZipReader(data: missingSheet).read(entry)
        }
        parts["xl/worksheets/sheet1.xml"] = nil
        #expect(Self.unreadableMessage(try IOTestPackage.zip(parts)) == XLSXMessages.damagedSheet("Gone"))

        let brokenStrings = try IOTestPackage.xlsx(sheet: "<sheetData/>", sharedStrings: "<sst><si><t>unclosed</si></sst>")
        #expect(Self.unreadableMessage(brokenStrings) == XLSXMessages.damaged)

        let brokenWorkbook = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("S", "<sheetData/>")],
                                                  parts: ["xl/workbook.xml": "<workbook><sheets>"])
        #expect(Self.unreadableMessage(brokenWorkbook) == XLSXMessages.damaged)

        let danglingWorkbook = IOTestPackage.declaration + "<workbook xmlns=\"\(IOTestPackage.mainNamespace)\" xmlns:r=\"\(IOTestPackage.relationshipNamespace)\">"
            + "<sheets><sheet name=\"X\" sheetId=\"1\" r:id=\"rId9\"/></sheets></workbook>"
        let danglingSheet = try IOTestPackage.xlsx(sheets: [], parts: ["xl/workbook.xml": danglingWorkbook])
        #expect(Self.unreadableMessage(danglingSheet) == XLSXMessages.damaged)
    }

    @Test func survivesRandomDamage() throws {
        let original = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Data", Self.excelSheet)], sharedStrings: Self.excelStrings,
                                            styles: Self.excelStyles, theme: Self.theme)
        var random = IOTestRandom(seed: 2026)
        for _ in 0..<300 {
            var damaged = original
            for _ in 0..<(1 + Int(random.next() % 8)) {
                let offset = Int(random.next() % UInt64(damaged.count))
                damaged[offset] = UInt8(truncatingIfNeeded: random.next())
            }
            if random.next() % 4 == 0 { damaged = damaged.prefix(Int(random.next() % UInt64(damaged.count))) }
            // Either it reads (the damage hit something unimportant) or it fails with a message; never a crash.
            do {
                _ = try IOTestPackage.read(damaged)
            } catch let error as SpreadsheetIOError {
                #expect(!(error.errorDescription ?? "").isEmpty)
            }
        }
    }

    @Test func survivesDamagedXML() throws {
        let fragments = ["<c r=\"A1\">", "</row>", "<v>", "</v>", "&amp;", "\"", "<f t=\"shared\" si=\"0\"/>", "<row r=\"999999999999999\">",
                         "<c r=\"XFD1048576\" t=\"s\"><v>99999999</v></c>", "<mergeCell ref=\"A1:XFD1048576\"/>",
                         "<col min=\"1\" max=\"16384\" width=\"1e308\" hidden=\"1\"/>", "<f t=\"array\" ref=\"A1:XFD1048576\">1</f>",
                         "<![CDATA[x]]>", "<x:c>", "_x0000_", "<pane xSplit=\"99999999999\" state=\"frozen\"/>", "<xf fontId=\"-5\" fillId=\"999\"/>",
                         "<color theme=\"-1\" tint=\"NaN\"/>", "<si>", "<t xml:space=\"preserve\">", "<sheet name=\"\" r:id=\"rId1\"/>", "<extLst>"]
        var random = IOTestRandom(seed: 99)
        func mutated(_ text: String) -> String {
            var scalars = Array(text.unicodeScalars)
            for _ in 0..<(1 + Int(random.next() % 4)) {
                let position = Int(random.next() % UInt64(scalars.count + 1))
                switch random.next() % 3 {
                case 0:
                    let length = min(Int(random.next() % 30), scalars.count - position)
                    scalars.removeSubrange(position..<(position + length))
                case 1:
                    scalars.insert(contentsOf: fragments[Int(random.next() % UInt64(fragments.count))].unicodeScalars, at: position)
                default:
                    let length = min(Int(random.next() % 60), scalars.count - position)
                    scalars.insert(contentsOf: scalars[position..<(position + length)], at: position)
                }
            }
            return String(String.UnicodeScalarView(scalars))
        }
        var readable = 0
        for iteration in 0..<400 {
            let target = iteration % 4
            let workbookParts = target == 3
                ? ["xl/workbook.xml": mutated(IOTestPackage.declaration + "<workbook xmlns=\"\(IOTestPackage.mainNamespace)\" "
                    + "xmlns:r=\"\(IOTestPackage.relationshipNamespace)\"><bookViews><workbookView activeTab=\"0\"/></bookViews>"
                    + "<sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")]
                : [:]
            let data = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Data", target == 0 ? mutated(Self.excelSheet) : Self.excelSheet)],
                                            sharedStrings: target == 1 ? mutated(Self.excelStrings) : Self.excelStrings,
                                            styles: target == 2 ? mutated(Self.excelStyles) : Self.excelStyles, theme: Self.theme,
                                            parts: workbookParts)
            do {
                let file = try IOTestPackage.read(data)
                readable += 1
                #expect(!file.workbook.sheets.isEmpty)
                #expect(file.workbook.sheets.indices.contains(file.activeSheet))
            } catch let error as SpreadsheetIOError {
                #expect(!(error.errorDescription ?? "").isEmpty)
            }
        }
        // Some damage is harmless (inside text, or in parts read leniently).
        #expect(readable > 0)
    }

    // MARK: - Colors

    @Test func tintsFollowTheSpecification() {
        let red = RGBColor(hex: "FF0000")!
        #expect(XLSXColorPalette.tinted(red, by: 0.5) == RGBColor(hex: "FF8080"))
        #expect(XLSXColorPalette.tinted(red, by: -0.5) == RGBColor(hex: "800000"))
        // Excel's shades of white and black.
        let white = RGBColor.white, black = RGBColor.black
        #expect(XLSXColorPalette.tinted(white, by: -0.0499893185216834) == RGBColor(hex: "F2F2F2"))
        #expect(XLSXColorPalette.tinted(white, by: -0.149998474074526) == RGBColor(hex: "D9D9D9"))
        #expect(XLSXColorPalette.tinted(white, by: -0.349986266670736) == RGBColor(hex: "A6A6A6"))
        #expect(XLSXColorPalette.tinted(black, by: 0.349986266670736) == RGBColor(hex: "595959"))
        #expect(XLSXColorPalette.tinted(black, by: 0.0499893185216834) == RGBColor(hex: "0D0D0D"))
        #expect(XLSXColorPalette.tinted(black, by: 1) == white)
    }

    @Test func colorAttributes() {
        let palette = XLSXColorPalette(theme: .office)
        #expect(palette.color(["rgb": "FF123456"]) == RGBColor(hex: "123456"))
        #expect(palette.color(["rgb": "ABCDEF"]) == RGBColor(hex: "ABCDEF"))
        #expect(palette.color(["rgb": "nonsense"]) == nil)
        #expect(palette.color(["theme": "0"]) == .white)
        #expect(palette.color(["theme": "1"]) == .black)
        #expect(palette.color(["theme": "3"]) == RGBColor(hex: "44546A"))
        #expect(palette.color(["theme": "99"]) == nil)
        #expect(palette.color(["indexed": "2"]) == RGBColor(hex: "FF0000"))
        #expect(palette.color(["indexed": "64"]) == nil)
        #expect(palette.color(["indexed": "65"]) == .white)
        #expect(palette.color(["auto": "1", "rgb": "FFFF0000"]) == nil)
        #expect(XLSXColorPalette.legacyIndexedColors.count == 64)
    }

    @Test func customIndexedPalette() throws {
        let styles = IOTestPackage.styles("""
            <fonts count="1"><font><sz val="10"/><color indexed="1"/><name val="Arial"/></font></fonts>
            <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>
            <fill><patternFill patternType="solid"><fgColor indexed="0"/></patternFill></fill></fills>
            <borders count="1"><border/></borders>
            <cellXfs count="2"><xf/><xf fillId="2" fontId="0"/></cellXfs>
            <colors><indexedColors><rgbColor rgb="FF010203"/><rgbColor rgb="FF040506"/></indexedColors></colors>
            """)
        let data = try IOTestPackage.xlsx(sheet: "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>1</v></c></row></sheetData>", styles: styles)
        let cell = try #require(try IOTestPackage.read(data).workbook.sheets.first)[0, 0]
        #expect(cell.format.fillColor == RGBColor(hex: "010203"))
        #expect(cell.format.textColor == RGBColor(hex: "040506"))
    }

    // MARK: - Pieces

    @Test func numberFormatTables() {
        #expect(XLSXNumberFormats.pattern(for: 0, custom: [:]) == nil)
        #expect(XLSXNumberFormats.pattern(for: 14, custom: [:]) == "M/d/yyyy")
        #expect(XLSXNumberFormats.pattern(for: 22, custom: [:]) == "M/d/yyyy H:mm")
        #expect(XLSXNumberFormats.pattern(for: 49, custom: [:]) == "@")
        #expect(XLSXNumberFormats.pattern(for: 164, custom: [164: "0.000"]) == "0.000")
        #expect(XLSXNumberFormats.pattern(for: 164, custom: [164: "General"]) == nil)
        #expect(XLSXNumberFormats.pattern(for: 14, custom: [14: "dd/mm/yyyy"]) == "dd/mm/yyyy")
        #expect(XLSXNumberFormats.pattern(for: 300, custom: [:]) == nil)
        for id in 0...49 where ![5, 6, 7, 8, 23, 24, 25, 26, 41, 42, 43, 44].contains(id) && (id < 27 || id > 36) {
            if let pattern = XLSXNumberFormats.builtIn[id] { #expect(XLSXNumberFormats.builtInIDs[pattern] == id) }
        }
    }

    @Test func dateFormatsAreRecognized() {
        for pattern in ["M/d/yyyy", "d-mmm-yy", "mmm-yy", "yyyy-mm-dd hh:mm", "[$-F800]dddd, mmmm dd, yyyy", "M/d/yyyy H:mm", "mmmm"] {
            #expect(XLSXNumberFormats.showsDate(pattern), "\(pattern)")
        }
        for pattern in ["General", "0.00", "h:mm AM/PM", "H:mm:ss", "[h]:mm:ss", "mm:ss", "0.00E+00", "\"day\" 0", "@", "#,##0 [$€-407]"] {
            #expect(!XLSXNumberFormats.showsDate(pattern), "\(pattern)")
        }
        #expect(!XLSXNumberFormats.showsDate(nil))
    }

    @Test func columnWidthsFollowExcel() {
        #expect(XLSXUnits.pixels(fromColumnWidth: 8.7109375) == 61)
        #expect(XLSXUnits.pixels(fromColumnWidth: 9.140625) == 64)
        #expect(XLSXUnits.columnWidth(fromPixels: 64) == 9.140625)
        #expect(XLSXUnits.columnWidth(fromPixels: 100) == 14.28515625)
        for pixels in 0...1000 {
            #expect(XLSXUnits.pixels(fromColumnWidth: XLSXUnits.columnWidth(fromPixels: Double(pixels))) == Double(pixels))
        }
        #expect(XLSXUnits.pixels(fromBaseColumnWidth: 8) == 64)
        #expect(XLSXUnits.pixels(fromPoints: 15.75) == 21)
        #expect(XLSXUnits.points(fromPixels: 21) == 15.75)
    }

    @Test func packagePaths() {
        #expect(XLSXPackage.relationshipsPath(for: "") == "_rels/.rels")
        #expect(XLSXPackage.relationshipsPath(for: "xl/workbook.xml") == "xl/_rels/workbook.xml.rels")
        #expect(XLSXPackage.resolve("worksheets/sheet1.xml", from: "xl/workbook.xml") == "xl/worksheets/sheet1.xml")
        #expect(XLSXPackage.resolve("/xl/styles.xml", from: "xl/workbook.xml") == "xl/styles.xml")
        #expect(XLSXPackage.resolve("../drawings/drawing1.xml", from: "xl/worksheets/sheet1.xml") == "xl/drawings/drawing1.xml")
        #expect(XLSXPackage.resolve("./media/image%201.png", from: "xl/drawings/drawing1.xml") == "xl/drawings/media/image 1.png")
        #expect(XLSXPackage.resolve("xl/workbook.xml", from: "") == "xl/workbook.xml")
    }

    @Test func textEscapes() {
        #expect(XLSXText.decode("a_x000D_\nb") == "a\nb")
        #expect(XLSXText.decode("a\r\nb\rc") == "a\nb\nc")
        #expect(XLSXText.decode("_x0041__x005f_x0042_") == "A_x0042_")
        #expect(XLSXText.decode("_xD83D__xDE00_") == "😀")
        #expect(XLSXText.decode("_xD800_ alone") == "_xD800_ alone")
        #expect(XLSXText.decode("snake_case_xyz_") == "snake_case_xyz_")
        #expect(XLSXText.encode("_x0041_ and _x") == "_x005F_x0041_ and _x")
        for text in ["_x0041_", "plain", "_x005F_", "a_xFFFF_b"] {
            #expect(XLSXText.decode(XLSXText.encode(text)) == text)
        }
        #expect(XLSXText.trimmingXMLWhitespace("\n  hi there \t") == "hi there")
        #expect(XLSXText.trimmingXMLWhitespace("   ") == "")
        #expect(XLSXText.needsPreservedSpace(" x") && XLSXText.needsPreservedSpace("x\n") && !XLSXText.needsPreservedSpace("x y"))
    }

    @Test func documentTypeDeclarationsAreRefused() {
        #expect(XMLParsing.declaresDocumentType(Data("<?xml version=\"1.0\"?><!DOCTYPE x><x/>".utf8)))
        #expect(XMLParsing.declaresDocumentType(Data("<!-- c --><!DOCTYPE x [<!ENTITY a \"b\">]><x>&a;</x>".utf8)))
        #expect(!XMLParsing.declaresDocumentType(Data("<?xml version=\"1.0\"?>\n<!-- <!DOCTYPE in a comment --><x/>".utf8)))
        #expect(!XMLParsing.declaresDocumentType(Data("<x><![CDATA[<!DOCTYPE>]]></x>".utf8)))
        let utf16 = "\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x><x/>".data(using: .utf16LittleEndian)!
        #expect(XMLParsing.declaresDocumentType(utf16))
        #expect(throws: MalformedXMLError.self) { try XMLTree.parse(Data("<!DOCTYPE x [<!ENTITY a \"b\">]><x>&a;</x>".utf8)) }
    }
}
