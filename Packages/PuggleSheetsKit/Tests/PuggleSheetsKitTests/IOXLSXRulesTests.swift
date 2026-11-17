import Foundation
import Testing
@testable import PuggleSheetsKit

/// Named ranges, data validation, conditional formatting, filters, alternating colors and spills in .xlsx.
struct IOXLSXRulesTests {
    static let red = RGBColor(hex: "CC0000")!
    static let green = RGBColor(hex: "006600")!
    static let yellow = RGBColor(hex: "FFEB84")!

    static func range(_ text: String) -> CellRange { CellRange(a1: text)! }

    /// A small sales table: header row, five data rows.
    static func salesSheet(name: String = "Sales") -> Sheet {
        var sheet = Sheet(name: name)
        let rows: [[CellValue]] = [
            [.text("Fruit"), .text("Qty"), .text("Price")],
            [.text("Apples"), .number(10), .number(1.5)],
            [.text("Pears"), .number(4), .number(2)],
            [.text("Plums"), .number(7), .number(3.25)],
            [.text("Pears"), .number(12), .number(2.1)],
            [.text("Kiwis"), .number(2), .number(0.5)],
        ]
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() { sheet[row, column] = Cell(value: value) }
        }
        return sheet
    }

    static func roundTrip(_ workbook: Workbook, format: SpreadsheetFileFormat = .xlsx) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(try SpreadsheetIO.write(workbook, activeSheet: 0, format: format), format: format)
    }

    static func parts(_ workbook: Workbook) throws -> [String: String] {
        try IOXLSXWriteTests.parts(of: try SpreadsheetIO.write(workbook, activeSheet: 0, format: .xlsx))
    }

    // MARK: - Named ranges

    @Test func namedRangesRoundTrip() throws {
        var other = Sheet(name: "Q1 2026")
        other[0, 0] = Cell(value: .number(1))
        let names = [NamedRange(name: "TaxRate", reference: "Sales!$B$1"), NamedRange(name: "Fruits", reference: "'Q1 2026'!$A$1:$A$50"),
                     NamedRange(name: "Quantities", reference: "Sales!$B:$B"), NamedRange(name: "first_row", reference: "Sales!$1:$1")]
        let workbook = Workbook(sheets: [Self.salesSheet(), other], namedRanges: names + [NamedRange(name: "A1", reference: "Sales!$A$1")])
        let file = try Self.roundTrip(workbook)
        #expect(file.workbook.namedRanges == names)
        #expect(!file.warnings.contains(.namedRanges))
        let workbookPart = try #require(try Self.parts(workbook)["xl/workbook.xml"])
        #expect(workbookPart.contains("<definedNames><definedName name=\"TaxRate\">Sales!$B$1</definedName>"))
        #expect(workbookPart.contains("<definedName name=\"Fruits\">'Q1 2026'!$A$1:$A$50</definedName>"))
        #expect(!workbookPart.contains("name=\"A1\""))
        // definedNames sits between sheets and calcPr.
        #expect(workbookPart.range(of: "</sheets><definedNames>") != nil && workbookPart.range(of: "</definedNames><calcPr") != nil)
    }

    @Test func excelNamesAreRead() throws {
        let data = try IOTestPackage.xlsx(
            sheets: [IOTestPackage.SheetPart("Data", "<sheetData/>"), IOTestPackage.SheetPart("Other", "<sheetData/>")],
            workbookSuffix: """
                <definedNames><definedName name="_xlnm.Print_Area" localSheetId="0">Data!$A$1:$C$9</definedName>
                <definedName name="Budget">Data!$B$2:$B$20</definedName><definedName name="Local" localSheetId="1">$A$1:$A$3</definedName>
                <definedName name="Scoped" localSheetId="0">Other!$C$3</definedName><definedName name="_xlfn.SINGLE" hidden="1">#NAME?</definedName>
                </definedNames>
                """)
        let file = try IOTestPackage.read(data)
        #expect(file.workbook.namedRanges == [NamedRange(name: "Budget", reference: "Data!$B$2:$B$20"),
                                              NamedRange(name: "Local", reference: "Other!$A$1:$A$3"),
                                              NamedRange(name: "Scoped", reference: "Other!$C$3")])
        #expect(file.warnings.isEmpty)
    }

    @Test func namesThatAreNotReferencesWarn() throws {
        for value in ["0.07", "SUM(Data!$A$1:$A$3)", "Data!$A$1,Data!$C$1", "Data!#REF!"] {
            let data = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("Data", "<sheetData/>")],
                                              workbookSuffix: "<definedNames><definedName name=\"Thing\">\(value)</definedName></definedNames>")
            let file = try IOTestPackage.read(data)
            #expect(file.workbook.namedRanges.isEmpty, "\(value)")
            #expect(file.warnings == [.namedRanges], "\(value)")
        }
        #expect(XLSXRules.isReference("Sheet1!$A$1:$B$2"))
        #expect(XLSXRules.isReference("'My sheet'!A:C"))
        #expect(XLSXRules.isReference("$3:$4"))
        #expect(!XLSXRules.isReference("A"))
        #expect(!XLSXRules.isReference("A1+1"))
    }

    // MARK: - Data validation

    static func validationSheet() -> Sheet {
        var sheet = Self.salesSheet()
        sheet.validations = [
            DataValidationRule(ranges: [Self.range("D2:D6")], criterion: .list(["Apples", "Pears", "Plums"]), rejectsInvalid: true,
                               helpText: "Pick a fruit"),
            DataValidationRule(ranges: [Self.range("E2:E6"), Self.range("G2:G6")], criterion: .list(["Yes", "No"]), showsDropdown: false),
            DataValidationRule(ranges: [Self.range("F2:F6")], criterion: .listFromRange("Lists!$A$1:$A$5")),
            DataValidationRule(ranges: [Self.range("H2:H6")], criterion: .checkbox(checked: nil, unchecked: nil)),
            DataValidationRule(ranges: [Self.range("B2:B6")], criterion: .condition(CellCondition(.isBetween, ["1", "100"])), rejectsInvalid: true),
            DataValidationRule(ranges: [Self.range("C2:C6")], criterion: .condition(CellCondition(.greaterThan, ["0"]))),
            DataValidationRule(ranges: [Self.range("I2:I6")], criterion: .condition(CellCondition(.dateIsBefore, ["1/2/2026"]))),
            DataValidationRule(ranges: [Self.range("J2:J6")], criterion: .condition(CellCondition(.dateIsOnOrAfter, ["today"]))),
            DataValidationRule(ranges: [Self.range("K2:K6")], criterion: .condition(CellCondition(.customFormula, ["=K2>B2"]))),
            DataValidationRule(ranges: [Self.range("L2:L6")], criterion: .condition(CellCondition(.textContains, ["abc"]))),
            DataValidationRule(ranges: [Self.range("M2:M6")], criterion: .condition(CellCondition(.isEqual, ["abc"]))),
        ]
        return sheet
    }

    @Test func validationsRoundTrip() throws {
        var lists = Sheet(name: "Lists")
        lists[0, 0] = Cell(value: .text("x"))
        let file = try Self.roundTrip(Workbook(sheets: [Self.validationSheet(), lists]))
        #expect(!file.warnings.contains(.dataValidation))
        let rules = file.workbook.sheets[0].validations
        let original = Self.validationSheet().validations
        #expect(rules.count == original.count)
        // Kept as they are; checkboxes go out as a TRUE,FALSE list and come back as checkboxes.
        for index in [0, 1, 2, 3, 4, 5, 6, 7, 8] {
            #expect(rules[index].ranges == original[index].ranges, "\(index)")
            #expect(rules[index].criterion == original[index].criterion, "\(index)")
            #expect(rules[index].rejectsInvalid == original[index].rejectsInvalid, "\(index)")
            #expect(rules[index].helpText == original[index].helpText, "\(index)")
            #expect(rules[index].showsDropdown == original[index].showsDropdown, "\(index)")
        }
        // Text tests become formulas.
        #expect(rules[9].criterion == .condition(CellCondition(.customFormula, ["=ISNUMBER(SEARCH(\"abc\",L2))"])))
        #expect(rules[10].criterion == .condition(CellCondition(.customFormula, ["=M2=\"abc\""])))
    }

    @Test func validationXML() throws {
        let worksheet = try #require(try Self.parts(Workbook(sheets: [Self.validationSheet()]))["xl/worksheets/sheet1.xml"])
        #expect(worksheet.contains("<dataValidations count=\"11\">"))
        #expect(worksheet.contains("<dataValidation type=\"list\" allowBlank=\"1\" showInputMessage=\"1\" prompt=\"Pick a fruit\" showErrorMessage=\"1\" sqref=\"D2:D6\"><formula1>\"Apples,Pears,Plums\"</formula1></dataValidation>"))
        #expect(worksheet.contains("<dataValidation type=\"list\" allowBlank=\"1\" showDropDown=\"1\" showErrorMessage=\"1\" errorStyle=\"warning\" sqref=\"E2:E6 G2:G6\">"))
        #expect(worksheet.contains("<dataValidation type=\"decimal\" operator=\"between\" allowBlank=\"1\" showErrorMessage=\"1\" sqref=\"B2:B6\"><formula1>1</formula1><formula2>100</formula2></dataValidation>"))
        #expect(worksheet.contains("<dataValidation type=\"date\" operator=\"lessThan\" allowBlank=\"1\" showErrorMessage=\"1\" errorStyle=\"warning\" sqref=\"I2:I6\"><formula1>46024</formula1>"))
        #expect(worksheet.contains("<formula1>TODAY()</formula1>"))
        #expect(worksheet.contains("<dataValidation type=\"custom\" allowBlank=\"1\" showErrorMessage=\"1\" errorStyle=\"warning\" sqref=\"K2:K6\"><formula1>K2&gt;B2</formula1>"))
        // After the merges, before the page margins.
        let order = ["</sheetData>", "<dataValidations", "<pageMargins"]
        let positions = order.compactMap { worksheet.range(of: $0)?.lowerBound }
        #expect(positions.count == 3 && positions == positions.sorted())
    }

    @Test func excelValidationsAreRead() throws {
        let data = try IOTestPackage.xlsx(sheet: """
            <sheetData/>
            <dataValidations count="7">
            <dataValidation type="list" allowBlank="1" showDropDown="1" showInputMessage="1" showErrorMessage="1" prompt="Choose" sqref="A1:A9"><formula1>"Red,Green,Blue"</formula1></dataValidation>
            <dataValidation type="list" errorStyle="warning" showErrorMessage="1" sqref="B1"><formula1>$H$1:$H$4</formula1></dataValidation>
            <dataValidation type="whole" operator="greaterThanOrEqual" sqref="C1"><formula1>5</formula1></dataValidation>
            <dataValidation type="decimal" operator="notBetween" showErrorMessage="1" sqref="D1 D3"><formula1>-1.5</formula1><formula2>$H$9</formula2></dataValidation>
            <dataValidation type="date" operator="greaterThan" sqref="E1"><formula1>45658</formula1></dataValidation>
            <dataValidation type="textLength" operator="lessThanOrEqual" sqref="F1:F3"><formula1>10</formula1></dataValidation>
            <dataValidation type="custom" sqref="G1"><formula1>_xlfn.ISFORMULA(G1)</formula1></dataValidation>
            </dataValidations>
            """)
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        let rules = file.workbook.sheets[0].validations
        #expect(rules.count == 7)
        #expect(rules[0] == DataValidationRule(id: rules[0].id, ranges: [Self.range("A1:A9")], criterion: .list(["Red", "Green", "Blue"]),
                                               rejectsInvalid: true, helpText: "Choose", showsDropdown: false))
        #expect(rules[1].criterion == .listFromRange("$H$1:$H$4") && !rules[1].rejectsInvalid && rules[1].showsDropdown)
        #expect(rules[2].criterion == .condition(CellCondition(.greaterThanOrEqual, ["5"])) && !rules[2].rejectsInvalid)
        #expect(rules[3].criterion == .condition(CellCondition(.isNotBetween, ["-1.5", "=$H$9"])) && rules[3].rejectsInvalid)
        #expect(rules[3].ranges == [Self.range("D1"), Self.range("D3")])
        #expect(rules[4].criterion == .condition(CellCondition(.dateIsAfter, ["1/1/2025"])))
        #expect(rules[5].criterion == .condition(CellCondition(.customFormula, ["=LEN(F1)<=10"])))
        #expect(rules[6].criterion == .condition(CellCondition(.customFormula, ["=ISFORMULA(G1)"])))
    }

    // MARK: - Conditional formatting

    static func formattingSheet() -> Sheet {
        var sheet = Self.salesSheet()
        let bold = ConditionalFormat(bold: true, textColor: red)
        sheet.conditionalFormats = [
            ConditionalFormatRule(ranges: [Self.range("B2:B6")], style: .condition(CellCondition(.greaterThan, ["5"]), bold)),
            ConditionalFormatRule(ranges: [Self.range("B2:B6"), Self.range("D2:D6")],
                                  style: .condition(CellCondition(.isBetween, ["1", "3"]), ConditionalFormat(fillColor: yellow))),
            ConditionalFormatRule(ranges: [Self.range("A2:A6")], style: .condition(CellCondition(.textContains, ["ea"]), ConditionalFormat(italic: true))),
            ConditionalFormatRule(ranges: [Self.range("A2:A6")], style: .condition(CellCondition(.textDoesNotContain, ["x"]), ConditionalFormat(underline: true))),
            ConditionalFormatRule(ranges: [Self.range("A2:A6")], style: .condition(CellCondition(.textStartsWith, ["P"]), ConditionalFormat(strikethrough: true))),
            ConditionalFormatRule(ranges: [Self.range("A2:A6")], style: .condition(CellCondition(.textEndsWith, ["s"]), ConditionalFormat(textColor: green))),
            ConditionalFormatRule(ranges: [Self.range("A2:A6")], style: .condition(CellCondition(.textIsExactly, ["Kiwis"]), ConditionalFormat(bold: false, strikethrough: true))),
            ConditionalFormatRule(ranges: [Self.range("C2:C6")], style: .condition(CellCondition(.isEmpty), ConditionalFormat(fillColor: red))),
            ConditionalFormatRule(ranges: [Self.range("C2:C6")], style: .condition(CellCondition(.isNotEmpty), ConditionalFormat(fillColor: green))),
            ConditionalFormatRule(ranges: [Self.range("E2:E6")], style: .condition(CellCondition(.dateIs, ["today"]), bold)),
            ConditionalFormatRule(ranges: [Self.range("E2:E6")], style: .condition(CellCondition(.dateIs, ["past week"]), bold)),
            ConditionalFormatRule(ranges: [Self.range("A2:C6")], style: .condition(CellCondition(.customFormula, ["=$B2>10"]), ConditionalFormat(fillColor: yellow))),
            ConditionalFormatRule(ranges: [Self.range("C2:C6")], style: .colorScale(ColorScale(
                minimum: .init(kind: .minimum, color: red), midpoint: .init(kind: .percentile, value: "50", color: yellow),
                maximum: .init(kind: .maximum, color: green)))),
            ConditionalFormatRule(ranges: [Self.range("B2:B6")], style: .colorScale(ColorScale(
                minimum: .init(kind: .number, value: "0", color: .white), maximum: .init(kind: .percent, value: "90", color: green)))),
            ConditionalFormatRule(ranges: [Self.range("E2:E6")], style: .condition(CellCondition(.dateIs, ["past month"]), bold)),
        ]
        return sheet
    }

    @Test func conditionalFormatsRoundTrip() throws {
        let original = Self.formattingSheet().conditionalFormats
        let file = try Self.roundTrip(Workbook(sheets: [Self.formattingSheet()]))
        #expect(!file.warnings.contains(.conditionalFormatting))
        let rules = file.workbook.sheets[0].conditionalFormats
        #expect(rules.count == original.count)
        for index in 0..<(original.count - 1) {
            #expect(rules[index].ranges == original[index].ranges, "\(index)")
            #expect(rules[index].style == original[index].style, "\(index)")
        }
        // A relative span Excel has no time period for comes back as its formula.
        #expect(rules.last?.style == .condition(CellCondition(.customFormula, ["=AND(INT(E2)>=EDATE(TODAY(),-1),INT(E2)<=TODAY())"]),
                                                ConditionalFormat(bold: true, textColor: Self.red)))
    }

    @Test func conditionalFormatXML() throws {
        let parts = try Self.parts(Workbook(sheets: [Self.formattingSheet()]))
        let worksheet = try #require(parts["xl/worksheets/sheet1.xml"])
        #expect(worksheet.contains("<conditionalFormatting sqref=\"B2:B6\"><cfRule type=\"cellIs\" dxfId=\"0\" priority=\"1\" operator=\"greaterThan\"><formula>5</formula></cfRule></conditionalFormatting>"))
        #expect(worksheet.contains("<conditionalFormatting sqref=\"B2:B6 D2:D6\"><cfRule type=\"cellIs\" dxfId=\"1\" priority=\"2\" operator=\"between\"><formula>1</formula><formula>3</formula>"))
        #expect(worksheet.contains("<cfRule type=\"containsText\" dxfId=\"2\" priority=\"3\" operator=\"containsText\" text=\"ea\"><formula>NOT(ISERROR(SEARCH(\"ea\",A2)))</formula>"))
        #expect(worksheet.contains("<cfRule type=\"timePeriod\" dxfId=\"0\" priority=\"10\" timePeriod=\"today\"><formula>FLOOR(E2,1)=TODAY()</formula>"))
        #expect(worksheet.contains("<cfRule type=\"colorScale\" priority=\"13\"><colorScale><cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/><color rgb=\"FFCC0000\"/><color rgb=\"FFFFEB84\"/><color rgb=\"FF006600\"/></colorScale>"))
        let styles = try #require(parts["xl/styles.xml"])
        #expect(styles.contains("<dxfs count=\"9\"><dxf><font><b/><color rgb=\"FFCC0000\"/></font></dxf><dxf><fill><patternFill><bgColor rgb=\"FFFFEB84\"/></patternFill></fill></dxf>"))
        #expect(styles.contains("<dxf><font><b val=\"0\"/><strike/></font></dxf>"))
        #expect(IOTestPackage.isWellFormed(Data(styles.utf8)) && IOTestPackage.isWellFormed(Data(worksheet.utf8)))
    }

    @Test func excelConditionalFormatsAreRead() throws {
        let styles = IOTestPackage.styles("""
            <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
            <borders count="1"><border/></borders><cellXfs count="1"><xf/></cellXfs>
            <dxfs count="2"><dxf><font><color rgb="FF9C0006"/></font><fill><patternFill><bgColor rgb="FFFFC7CE"/></patternFill></fill></dxf>
            <dxf><font><b/><i val="0"/><color theme="4"/></font><fill><patternFill patternType="solid"><fgColor indexed="5"/></patternFill></fill></dxf></dxfs>
            """)
        let data = try IOTestPackage.xlsx(sheet: """
            <sheetData/>
            <conditionalFormatting sqref="A1:A10"><cfRule type="cellIs" dxfId="0" priority="3" operator="lessThan"><formula>0</formula></cfRule>
            <cfRule type="dataBar" priority="2"><dataBar><cfvo type="min"/><cfvo type="max"/><color rgb="FF638EC6"/></dataBar></cfRule></conditionalFormatting>
            <conditionalFormatting sqref="B1:B10"><cfRule type="beginsWith" dxfId="1" priority="1" operator="beginsWith" text="ok"><formula>LEFT(B1,LEN("ok"))="ok"</formula></cfRule>
            <cfRule type="timePeriod" dxfId="1" priority="4" timePeriod="lastMonth"><formula>AND(MONTH(B1)=MONTH(EDATE(TODAY(),0-1)),YEAR(B1)=YEAR(EDATE(TODAY(),0-1)))</formula></cfRule>
            <cfRule type="containsErrors" dxfId="0" priority="5"><formula>ISERROR(B1)</formula></cfRule>
            <cfRule type="cellIs" dxfId="0" priority="6" operator="equal"><formula>"Done"</formula></cfRule>
            <cfRule type="colorScale" priority="7"><colorScale><cfvo type="num" val="0"/><cfvo type="max"/><color theme="0"/><color rgb="FF63BE7B"/></colorScale></cfRule></conditionalFormatting>
            """, styles: styles)
        let file = try IOTestPackage.read(data)
        #expect(file.warnings == [.conditionalFormatting])
        let rules = file.workbook.sheets[0].conditionalFormats
        let pink = ConditionalFormat(textColor: RGBColor(hex: "9C0006"), fillColor: RGBColor(hex: "FFC7CE"))
        let accent = ConditionalFormat(bold: true, italic: false, textColor: XLSXTheme.office.colors[4], fillColor: RGBColor(hex: "FFFF00"))
        #expect(rules.map(\.style) == [
            .condition(CellCondition(.textStartsWith, ["ok"]), accent),
            .condition(CellCondition(.lessThan, ["0"]), pink),
            .condition(CellCondition(.customFormula, ["=AND(MONTH(B1)=MONTH(EDATE(TODAY(),0-1)),YEAR(B1)=YEAR(EDATE(TODAY(),0-1)))"]), accent),
            .condition(CellCondition(.customFormula, ["=ISERROR(B1)"]), pink),
            .condition(CellCondition(.textIsExactly, ["Done"]), pink),
            .colorScale(ColorScale(minimum: .init(kind: .number, value: "0", color: .white), maximum: .init(kind: .maximum, color: RGBColor(hex: "63BE7B")!))),
        ])
        #expect(rules.map(\.ranges) == [[Self.range("B1:B10")], [Self.range("A1:A10")], [Self.range("B1:B10")], [Self.range("B1:B10")],
                                        [Self.range("B1:B10")], [Self.range("B1:B10")]])
    }

    // MARK: - Filters

    static func filteredSheet() -> Sheet {
        var sheet = Self.salesSheet()
        sheet[10, 0] = Cell(value: .text("below"))
        sheet.filter = SheetFilter(range: Self.range("A1:C6"), criteria: [
            0: FilterCriterion(hiddenValues: ["Pears"]),
            1: FilterCriterion(condition: CellCondition(.greaterThan, ["3"])),
        ])
        sheet.filteredRows = [2, 4, 5]
        sheet.hiddenRows = [10]
        return sheet
    }

    @Test func filtersRoundTrip() throws {
        let file = try Self.roundTrip(Workbook(sheets: [Self.filteredSheet()]))
        #expect(!file.warnings.contains(.filters))
        let sheet = file.workbook.sheets[0]
        #expect(sheet.filter == Self.filteredSheet().filter)
        #expect(sheet.filteredRows == [2, 4, 5])
        #expect(sheet.hiddenRows == [10])
    }

    @Test func filterXML() throws {
        let parts = try Self.parts(Workbook(sheets: [Self.filteredSheet()]))
        let worksheet = try #require(parts["xl/worksheets/sheet1.xml"])
        #expect(worksheet.contains("<sheetPr filterMode=\"1\">"))
        #expect(worksheet.contains("<autoFilter ref=\"A1:C6\"><filterColumn colId=\"0\"><filters><filter val=\"Apples\"/><filter val=\"Plums\"/><filter val=\"Kiwis\"/></filters></filterColumn><filterColumn colId=\"1\"><customFilters><customFilter operator=\"greaterThan\" val=\"3\"/></customFilters></filterColumn></autoFilter>"))
        // Filtered rows are written hidden, as Excel stores them.
        for row in [3, 5, 6, 11] { #expect(worksheet.contains("<row r=\"\(row)\" hidden=\"1\">"), "\(row)") }
        let order = ["</sheetData>", "<autoFilter", "<pageMargins"]
        let positions = order.compactMap { worksheet.range(of: $0)?.lowerBound }
        #expect(positions.count == 3 && positions == positions.sorted())
        #expect(try #require(parts["xl/workbook.xml"]).contains("<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">Sales!$A$1:$C$6</definedName>"))
    }

    @Test func excelFiltersAreRead() throws {
        let data = try IOTestPackage.xlsx(sheet: """
            <sheetPr filterMode="1"/>
            <sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>City</t></is></c><c r="B1" t="inlineStr"><is><t>Sales</t></is></c><c r="C1" t="inlineStr"><is><t>Note</t></is></c></row>
            <row r="2"><c r="A2" t="inlineStr"><is><t>Oslo</t></is></c><c r="B2"><v>50</v></c><c r="C2" t="inlineStr"><is><t>new store</t></is></c></row>
            <row r="3" hidden="1"><c r="A3" t="inlineStr"><is><t>Rome</t></is></c><c r="B3"><v>200</v></c></row>
            <row r="4"><c r="A4" t="inlineStr"><is><t>LIMA</t></is></c><c r="B4"><v>75</v></c><c r="C4" t="inlineStr"><is><t>old store</t></is></c></row>
            <row r="5" hidden="1"><c r="B5"><v>10</v></c></row>
            <row r="9" hidden="1"><c r="A9" t="inlineStr"><is><t>outside</t></is></c></row>
            </sheetData>
            <autoFilter ref="A1:C5"><filterColumn colId="0"><filters><filter val="oslo"/><filter val="Lima"/></filters></filterColumn>
            <filterColumn colId="1"><customFilters and="1"><customFilter operator="greaterThanOrEqual" val="20"/><customFilter operator="lessThanOrEqual" val="100"/></customFilters></filterColumn>
            <filterColumn colId="2"><customFilters><customFilter val="*store"/></customFilters></filterColumn></autoFilter>
            """)
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        #expect(sheet.filter == SheetFilter(range: Self.range("A1:C5"), criteria: [
            0: FilterCriterion(hiddenValues: ["Rome", ""]),
            1: FilterCriterion(condition: CellCondition(.isBetween, ["20", "100"])),
            2: FilterCriterion(condition: CellCondition(.textEndsWith, ["store"])),
        ]))
        #expect(sheet.filteredRows == [2, 4])
        #expect(sheet.hiddenRows == [8])
    }

    @Test func customFilterConditions() throws {
        let conditions: [CellCondition] = [
            CellCondition(.isEmpty), CellCondition(.isNotEmpty), CellCondition(.textContains, ["a*b"]), CellCondition(.textDoesNotContain, ["x"]),
            CellCondition(.textStartsWith, ["A"]), CellCondition(.textIsExactly, ["Kiwis"]), CellCondition(.isEqual, ["7"]),
            CellCondition(.isNotEqual, ["7"]), CellCondition(.lessThanOrEqual, ["7"]), CellCondition(.isNotBetween, ["2", "9"]),
        ]
        for condition in conditions {
            var sheet = Self.salesSheet()
            sheet.filter = SheetFilter(range: Self.range("A1:C6"), criteria: [1: FilterCriterion(condition: condition)])
            let read = try Self.roundTrip(Workbook(sheets: [sheet])).workbook.sheets[0]
            #expect(read.filter?.criteria[1]?.condition == condition, "\(condition)")
        }
        // Conditions custom filters can't hold are left out, without failing.
        var sheet = Self.salesSheet()
        sheet.filter = SheetFilter(range: Self.range("A1:C6"), criteria: [0: FilterCriterion(condition: CellCondition(.customFormula, ["=A2<>\"\""]))])
        #expect(try Self.roundTrip(Workbook(sheets: [sheet])).workbook.sheets[0].filter?.criteria.isEmpty == true)
    }

    // MARK: - Alternating colors and spills

    @Test func bandingBecomesFills() throws {
        var sheet = Self.salesSheet()
        let header = RGBColor(hex: "4285F4")!, light = RGBColor(hex: "E8F0FE")!, footer = RGBColor(hex: "BDBDBD")!
        sheet.bandings = [Banding(range: Self.range("A1:C6"), headerColor: header, firstColor: light, secondColor: .white, footerColor: footer)]
        sheet[2, 1] = Cell(value: .number(4), format: IOTest.format { $0.fillColor = Self.red })
        let read = try Self.roundTrip(Workbook(sheets: [sheet])).workbook.sheets[0]
        #expect(read.bandings.isEmpty)
        #expect(read[0, 0].format.fillColor == header)
        #expect(read[1, 1].format.fillColor == light)
        #expect(read[2, 0].format.fillColor == .white)
        #expect(read[2, 1].format.fillColor == Self.red)
        #expect(read[3, 2].format.fillColor == light)
        #expect(read[5, 2].format.fillColor == footer)
        #expect(read[1, 1].value == .number(10))
        #expect(read.cells[CellAddress(row: 6, column: 0)] == nil)
    }

    static func spillingSheet() -> Sheet {
        var sheet = Sheet(name: "Spill")
        sheet[0, 0] = Cell(value: .number(1), formula: "=SEQUENCE(3,2)")
        sheet[1, 1] = Cell(format: IOTest.format { $0.bold = true })
        sheet.spillRanges = [CellAddress(row: 0, column: 0): Self.range("A1:B3")]
        sheet.spilledValues = [CellAddress(row: 0, column: 1): .number(2), CellAddress(row: 1, column: 0): .number(3),
                               CellAddress(row: 1, column: 1): .number(4), CellAddress(row: 2, column: 0): .number(5),
                               CellAddress(row: 2, column: 1): .number(6)]
        sheet[5, 0] = Cell(value: .text("x"), formula: "=UPPER(\"x\")")
        return sheet
    }

    @Test func spillsAreWrittenAsArrayFormulas() throws {
        let worksheet = try #require(try Self.parts(Workbook(sheets: [Self.spillingSheet()]))["xl/worksheets/sheet1.xml"])
        #expect(worksheet.contains("<c r=\"A1\"><f t=\"array\" ref=\"A1:B3\">_xlfn.SEQUENCE(3,2)</f><v>1</v></c><c r=\"B1\"><v>2</v></c>"))
        #expect(worksheet.contains("<c r=\"A2\"><v>3</v></c><c r=\"B2\" s=\"1\"><v>4</v></c>"))
        #expect(worksheet.contains("<c r=\"A6\" t=\"str\"><f>UPPER(\"x\")</f><v>x</v></c>"))
        // Read back, the formula is plain again and the engine spills it.
        let read = try Self.roundTrip(Workbook(sheets: [Self.spillingSheet()])).workbook.sheets[0]
        #expect(read[0, 0] == Cell(value: .number(1), formula: "=SEQUENCE(3,2)"))
        #expect(read[1, 1] == Cell(format: IOTest.format { $0.bold = true }))
        #expect(read.cells[CellAddress(row: 2, column: 1)] == nil)
    }

    @Test func spilledValuesAreExportedToCSV() throws {
        let csv = String(decoding: try SpreadsheetIO.write(Workbook(sheets: [Self.spillingSheet()]), activeSheet: 0, format: .csv), as: UTF8.self)
        #expect(csv == "1,2\r\n3,4\r\n5,6\r\n,\r\n,\r\nx,")
    }
}
