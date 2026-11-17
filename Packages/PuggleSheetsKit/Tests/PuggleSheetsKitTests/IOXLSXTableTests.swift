import Foundation
import Testing
@testable import PuggleSheetsKit

/// Tables and slicers in Excel files.
struct IOXLSXTableTests {
    static func write(_ workbook: Workbook) throws -> Data {
        try SpreadsheetIO.write(workbook, activeSheet: 0, format: .xlsx)
    }

    static func roundTrip(_ workbook: Workbook) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(try write(workbook), format: .xlsx)
    }

    static func part(_ path: String, of data: Data) throws -> String {
        try IOTestPackage.part(path, of: data) ?? ""
    }

    /// A package with some parts changed, as an app editing the file would.
    static func changing(_ data: Data, _ changes: [String: (String) -> String]) throws -> Data {
        let zip = try ZipReader(data: data)
        var parts: [String: Data] = [:]
        for entry in zip.entries {
            let contents = try zip.read(entry)
            parts[entry.path] = changes[entry.path].map { Data($0(String(decoding: contents, as: UTF8.self)).utf8) } ?? contents
        }
        return try IOTestPackage.zip(parts)
    }

    static let ordersRange = CellRange(a1: "A1:D5")!

    /// Orders on A1:D5: region, product, units and price, with a header row.
    static func ordersSheet() -> Sheet {
        var sheet = Sheet(name: "Orders")
        let rows: [[CellValue]] = [
            [.text("Region"), .text("Product"), .text("Units"), .text("Price")],
            [.text("East"), .text("Pens"), .number(10), .number(1.5)],
            [.text("West"), .text("Ink"), .number(20), .number(4)],
            [.text("East"), .text("Ink"), .number(30), .number(4)],
            [.text("North"), .text("Pens"), .number(40), .number(1.5)],
        ]
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() { sheet[row, column] = Cell(value: value) }
        }
        return sheet
    }

    static func slicer(_ spec: SlicerSpec, row: Int = 1, column: Int = 6, title: String = "") -> SheetObject {
        SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: row, column: column), offsetX: 4, offsetY: 2.5, width: 180, height: 240),
                    content: .slicer(spec), title: title)
    }

    // MARK: - Tables

    @Test func tablesRoundTrip() throws {
        var sheet = Self.ordersSheet()
        let table = SheetTable(name: "Orders", range: Self.ordersRange,
                               columnTypes: [1: .dropdown(["Pens", "Ink"]), 2: .number, 3: .currency, 0: .text],
                               color: SheetTable.colors[4], criteria: [0: FilterCriterion(hiddenValues: ["North"]),
                                                                       2: FilterCriterion(condition: CellCondition(.greaterThan, ["5"]))])
        sheet.tables = [table]
        sheet.filteredRows = [4]
        var other = Sheet(name: "Plain")
        other[0, 0] = Cell(value: .text("Item"))
        other[1, 0] = Cell(value: .text("A"))
        other.tables = [SheetTable(name: "Items", range: CellRange(a1: "A1:A2")!, color: SheetTable.colors[7])]
        let file = try Self.roundTrip(Workbook(sheets: [sheet, other]))
        #expect(file.warnings.isEmpty)
        let copy = file.workbook.sheets[0]
        #expect(copy.tables == [table])
        #expect(file.workbook.sheets[1].tables == other.tables)
        #expect(copy.filteredRows == [4] && copy.hiddenRows.isEmpty)
        // The cells are as they were.
        for row in 0..<5 {
            for column in 0..<4 { #expect(copy[row, column].value == sheet[row, column].value) }
        }
        #expect(file.workbook.table(named: "items")?.sheet == 1)
    }

    @Test func tablePartsHaveExcelsStructure() throws {
        var sheet = Self.ordersSheet()
        sheet.tables = [SheetTable(name: "Orders", range: Self.ordersRange, color: SheetTable.colors[1],
                                   criteria: [0: FilterCriterion(hiddenValues: ["North"])])]
        var second = Sheet(name: "More")
        second[2, 1] = Cell(value: .text("Code"))
        second[3, 1] = Cell(value: .number(7))
        second.tables = [SheetTable(name: "Codes", range: CellRange(a1: "B3:B4")!, color: SheetTable.colors[0])]
        let data = try Self.write(Workbook(sheets: [sheet, second]))
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)

        let table = try Self.part("xl/tables/table1.xml", of: data)
        #expect(table.contains("<table xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" id=\"1\" name=\"Orders\" "
            + "displayName=\"Orders\" ref=\"A1:D5\" totalsRowShown=\"0\">"))
        #expect(table.contains("<autoFilter ref=\"A1:D5\"><filterColumn colId=\"0\"><filters><filter val=\"East\"/><filter val=\"West\"/>"
            + "</filters></filterColumn></autoFilter>"))
        #expect(table.contains("<tableColumns count=\"4\"><tableColumn id=\"1\" name=\"Region\"/><tableColumn id=\"2\" name=\"Product\"/>"
            + "<tableColumn id=\"3\" name=\"Units\"/><tableColumn id=\"4\" name=\"Price\"/></tableColumns>"))
        #expect(table.contains("<tableStyleInfo name=\"TableStyleMedium2\" showFirstColumn=\"0\" showLastColumn=\"0\" showRowStripes=\"1\" "
            + "showColumnStripes=\"0\"/></table>"))
        let codes = try Self.part("xl/tables/table2.xml", of: data)
        #expect(codes.contains("id=\"2\" name=\"Codes\" displayName=\"Codes\" ref=\"B3:B4\""))
        #expect(codes.contains("TableStyleMedium7"))

        let worksheet = try Self.part("xl/worksheets/sheet1.xml", of: data)
        #expect(worksheet.contains("<tableParts count=\"1\"><tablePart r:id=\"rId1\"/></tableParts></worksheet>"))
        // The table's filter is the table's own, not a sheet filter.
        #expect(!worksheet.contains("<autoFilter"))
        let relationships = try Self.part("xl/worksheets/_rels/sheet1.xml.rels", of: data)
        #expect(relationships.contains("Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" "
            + "Target=\"../tables/table1.xml\""))
        let types = try Self.part("[Content_Types].xml", of: data)
        #expect(types.contains("<Override PartName=\"/xl/tables/table1.xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml\"/>"))
        #expect(types.contains("/xl/tables/table2.xml"))
        let workbook = try Self.part("xl/workbook.xml", of: data)
        #expect(!workbook.contains("_FilterDatabase"))
    }

    @Test func headerCellsBecomeUniqueColumnNames() throws {
        var sheet = Sheet(name: "Data")
        sheet[0, 0] = Cell(value: .text("Region"))
        sheet[0, 2] = Cell(value: .text("Sales"))
        sheet[0, 3] = Cell(value: .text("sales"))
        sheet[0, 4] = Cell(value: .number(2024))
        sheet[0, 5] = Cell(value: .text("Q1"), formula: "=\"Q\"&1")
        sheet[0, 6] = Cell(value: .text("  "))
        sheet[0, 7] = Cell(value: .text("Column2"))
        sheet[0, 8] = Cell(value: .text("Sales2"))
        sheet[0, 9] = Cell(value: .text("Sales"))
        for column in 0..<10 { sheet[1, column] = Cell(value: .number(Double(column))) }
        let table = SheetTable(name: "Data", range: CellRange(a1: "A1:J2")!)
        // Header texts keep their names the first time they appear; new names avoid all of them.
        let names = ["Region", "Column3", "Sales", "sales3", "2024", "Q1", "Column7", "Column2", "Sales2", "Sales4"]
        #expect(XLSXTables.columnNames(table, sheet: sheet) == names)
        sheet.tables = [table]
        let data = try Self.write(Workbook(sheets: [sheet]))
        let part = try Self.part("xl/tables/table1.xml", of: data)
        #expect(part.contains("<tableColumn id=\"2\" name=\"Column3\"/>") && part.contains("<tableColumn id=\"10\" name=\"Sales4\"/>"))
        // Excel requires the header cells to hold the names as text.
        let copy = try SpreadsheetIO.read(data, format: .xlsx).workbook.sheets[0]
        #expect((0..<10).map { copy[0, $0].value } == names.map { CellValue.text($0) })
        #expect(copy[0, 5].formula == nil)
        #expect(copy.tables.first?.range == table.range)
        // Data rows are untouched.
        #expect(copy[1, 4].value == .number(4))
    }

    @Test func headerOnlyTablesGetADataRowInExcel() throws {
        var sheet = Self.ordersSheet()
        let table = SheetTable(name: "Empty", range: CellRange(a1: "F1:G1")!, color: SheetTable.colors[2])
        sheet[0, 5] = Cell(value: .text("Name"))
        sheet[0, 6] = Cell(value: .text("Score"))
        sheet.tables = [table]
        let data = try Self.write(Workbook(sheets: [sheet]))
        let part = try Self.part("xl/tables/table1.xml", of: data)
        #expect(part.contains("ref=\"F1:G2\" totalsRowShown=\"0\"><autoFilter ref=\"F1:G2\"/>"))
        #expect(try SpreadsheetIO.read(data, format: .xlsx).workbook.sheets[0].tables == [table])
        // Once Excel's table has grown, its range wins.
        let grown = try Self.changing(data, ["xl/tables/table1.xml": {
            $0.replacingOccurrences(of: "F1:G2", with: "F1:G4")
        }])
        #expect(try SpreadsheetIO.read(grown, format: .xlsx).workbook.sheets[0].tables.first?.range == CellRange(a1: "F1:G4"))
    }

    @Test func tableStylesFollowColors() throws {
        // Each color the table menu offers gets the closest of TableStyleMedium1–7 (dark gray, then accents 1–6).
        let styles = SheetTable.colors.map(XLSXTables.style(for:))
        #expect(styles == ["TableStyleMedium7", "TableStyleMedium2", "TableStyleMedium1", "TableStyleMedium2", "TableStyleMedium3",
                           "TableStyleMedium3", "TableStyleMedium6", "TableStyleMedium3"])
        // Read back without PuggleSheets' part, the styles give the closest colors in the theme.
        let colors = ["TableStyleMedium7", "TableStyleMedium2", "TableStyleMedium1", "TableStyleMedium3", "TableStyleLight9",
                      "TableStyleDark11", "TableStyleLight15", "TableStyleMedium5", "MyCustomStyle"].map {
            XLSXTables.color(forStyle: $0, theme: .office).hex
        }
        #expect(colors == ["0B8043", "1A73E8", "5F6368", "E37400", "1A73E8", "1A73E8", "5F6368", "E37400", "0B8043"])
        #expect(XLSXTables.color(forStyle: nil, theme: .office) == SheetTable.colors[0])
    }

    /// A worksheet with a table in Excel's own form and whatever else `extra` adds.
    static func excelSheet(extra: String = "", trailing: String = "", relationships: [(type: String, target: String)] = []) -> IOTestPackage.SheetPart {
        func text(_ reference: String, _ value: String) -> String { "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(value)</t></is></c>" }
        let body = "<sheetData><row r=\"1\">\(text("A1", "Region"))\(text("B1", "Units"))\(text("C1", "Price"))</row>"
            + "<row r=\"2\">\(text("A2", "East"))<c r=\"B2\"><v>3</v></c><c r=\"C2\"><v>1.5</v></c></row>"
            + "<row r=\"3\" hidden=\"1\">\(text("A3", "West"))<c r=\"B3\"><v>4</v></c><c r=\"C3\"><v>2</v></c></row>"
            + "<row r=\"4\">\(text("A4", "East"))<c r=\"B4\"><v>5</v></c><c r=\"C4\"><v>2.5</v></c></row>"
            + "<row r=\"5\">\(text("A5", "Total"))<c r=\"B5\"><f>SUBTOTAL(109,Sales[Units])</f><v>8</v></c></row>"
            + "<row r=\"6\" hidden=\"1\"><c r=\"A6\"><v>1</v></c></row>"
            + "<row r=\"7\"><c r=\"A7\"><f>SUM(Sales[])+ROWS(Sales)+SUM(Sales[#All])+COUNTA(Sales[[#Headers],[Units]])</f><v>0</v></c>"
            + "<c r=\"B7\"><f>Sales[[#This Row],[Units]]+SUM(Sales[[#Totals],[Units]])</f><v>0</v></c></row></sheetData>"
            + extra + "<tableParts count=\"1\"><tablePart r:id=\"rId1\"/></tableParts>" + trailing
        return IOTestPackage.SheetPart("Data", body, relationships: [("table", "../tables/table1.xml")] + relationships)
    }

    static func excelTable(style: String = "TableStyleMedium7", header: String = "") -> String {
        IOTestPackage.declaration + "<table xmlns=\"\(IOTestPackage.mainNamespace)\" id=\"2\" name=\"Table2\" displayName=\"Sales\" "
            + "ref=\"A1:C5\" totalsRowCount=\"1\"\(header)><autoFilter ref=\"A1:C4\"><filterColumn colId=\"0\"><filters><filter val=\"East\"/>"
            + "</filters></filterColumn></autoFilter><tableColumns count=\"3\"><tableColumn id=\"1\" name=\"Region\" totalsRowLabel=\"Total\"/>"
            + "<tableColumn id=\"2\" name=\"Units\" totalsRowFunction=\"sum\"/><tableColumn id=\"3\" name=\"Price\"/></tableColumns>"
            + "<tableStyleInfo name=\"\(style)\" showFirstColumn=\"0\" showLastColumn=\"0\" showRowStripes=\"1\" showColumnStripes=\"0\"/></table>"
    }

    @Test func excelTablesAreRead() throws {
        let data = try IOTestPackage.xlsx(sheets: [Self.excelSheet()], parts: ["xl/tables/table1.xml": Self.excelTable()])
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        // The totals row stays as cells below the table.
        #expect(sheet.tables.map(\.name) == ["Sales"])
        let table = try #require(sheet.tables.first)
        #expect(table.range == CellRange(a1: "A1:C4"))
        #expect(table.criteria == [0: FilterCriterion(hiddenValues: ["West"])])
        #expect(table.color == SheetTable.colors[0])
        #expect(table.columnTypes.isEmpty)
        // Rows the table's filter hides are the filter's; others stay hidden by hand.
        #expect(sheet.filteredRows == [2] && sheet.hiddenRows == [5])
        // Excel's bare names and empty brackets mean the data rows; its casing becomes PuggleSheets'.
        #expect(sheet[4, 1].formula == "=SUBTOTAL(109,Sales[Units])")
        #expect(sheet[6, 0].formula == "=SUM(Sales[#DATA])+ROWS(Sales[#DATA])+SUM(Sales[#ALL])+COUNTA(Sales[[#HEADERS],[Units]])")
        #expect(sheet[6, 1].formula == "=Sales[[#This Row],[Units]]+SUM(Sales[[#Totals],[Units]])")
        #expect(file.workbook.resolveTableReference("Sales[Units]")?.range == CellRange(a1: "B2:B4"))
    }

    @Test func tablesExcelCannotMatchWarn() throws {
        // Without a header row there's no PuggleSheets table; the cells stay.
        let data = try IOTestPackage.xlsx(sheets: [Self.excelSheet()],
                                          parts: ["xl/tables/table1.xml": Self.excelTable(header: " headerRowCount=\"0\"")])
        let file = try IOTestPackage.read(data)
        #expect(file.warnings == [.filters])
        #expect(file.workbook.sheets[0].tables.isEmpty)
        #expect(file.workbook.sheets[0][1, 0].value == .text("East"))
        // A missing table part is skipped too.
        let missing = try IOTestPackage.read(try IOTestPackage.xlsx(sheets: [Self.excelSheet()]))
        #expect(missing.warnings == [.filters] && missing.workbook.sheets[0].tables.isEmpty)
    }

    @Test func tableFormulasRoundTrip() throws {
        var sheet = Self.ordersSheet()
        sheet.tables = [SheetTable(name: "Orders", range: Self.ordersRange)]
        sheet[7, 0] = Cell(formula: "=ROWS(Orders)")
        sheet[8, 0] = Cell(formula: "=SUM(Orders[Units])+COUNTA(Orders[#HEADERS])+ROWS(Orders[#DATA])+ROWS(Orders[#ALL])")
        sheet[9, 0] = Cell(formula: "=Orders[[#HEADERS],[Units]]&SUM(Orders[[Units]:[Price]])")
        sheet[10, 0] = Cell(formula: "=LET(total, SUM(Orders[Units]), MAP(Orders[Price], LAMBDA(p, p*total)))")
        let data = try Self.write(Workbook(sheets: [sheet]))
        let worksheet = try Self.part("xl/worksheets/sheet1.xml", of: data)
        #expect(worksheet.contains("<f>ROWS(Orders[#All])</f>"))
        #expect(worksheet.contains("<f>SUM(Orders[Units])+COUNTA(Orders[#Headers])+ROWS(Orders[#Data])+ROWS(Orders[#All])</f>"))
        #expect(worksheet.contains("<f>Orders[[#Headers],[Units]]&amp;SUM(Orders[[Units]:[Price]])</f>"))
        #expect(worksheet.contains("<f>_xlfn.LET(_xlpm.total, SUM(Orders[Units]), _xlfn.MAP(Orders[Price], "
            + "_xlfn.LAMBDA(_xlpm.p, _xlpm.p*_xlpm.total)))</f>"))
        let copy = try SpreadsheetIO.read(data, format: .xlsx).workbook.sheets[0]
        #expect(copy[7, 0].formula == "=ROWS(Orders[#ALL])")
        for row in 8...10 { #expect(copy[row, 0].formula == sheet[row, 0].formula) }
    }

    // MARK: - Slicers

    /// Orders as a table, a slicer on its regions with a selection, one on its products with a title and
    /// color, a slicer on a plain range, and an image between them.
    static func slicerWorkbook() -> Workbook {
        var sheet = Self.ordersSheet()
        sheet.tables = [SheetTable(name: "Orders", range: Self.ordersRange, color: SheetTable.colors[1])]
        sheet.filteredRows = [2]
        sheet.objects = [
            Self.slicer(SlicerSpec(range: "Orders", column: 0, criterion: FilterCriterion(hiddenValues: ["West"])), title: "Regions slicer"),
            SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 8, column: 1), width: 4, height: 2),
                        content: .image(IOXLSXObjectTests.image(IOXLSXObjectTests.png))),
            Self.slicer(SlicerSpec(range: "A1:C5", column: 2, title: "Units (plain range)", appliesToPivotTables: false), row: 1, column: 10),
            Self.slicer(SlicerSpec(range: "Orders", column: 1, title: "Products", backgroundColor: RGBColor(hex: "FCE8B2")), row: 14),
        ]
        var summary = Sheet(name: "Summary")
        summary[0, 0] = Cell(formula: "=SUM(Orders[Units])")
        summary.objects = [Self.slicer(SlicerSpec(range: "Orders!A1:D5", column: 2,
                                                  criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["15"]))), row: 2, column: 2)]
        return Workbook(sheets: [sheet, summary])
    }

    @Test func tableSlicersBecomeExcelSlicers() throws {
        let data = try Self.write(Self.slicerWorkbook())
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
        // One slicer cache per table slicer, each on its table column.
        let x14 = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"
        let cache = try Self.part("xl/slicerCaches/slicerCache1.xml", of: data)
        #expect(cache.contains("<slicerCacheDefinition xmlns=\"\(x14)\" xmlns:x=\"\(IOTestPackage.mainNamespace)\" name=\"Slicer_Region\" "
            + "sourceName=\"Region\"><extLst><x:ext uri=\"{2F2917AC-EB37-4324-AD4E-5DD8C200BD13}\" "
            + "xmlns:x15=\"http://schemas.microsoft.com/office/spreadsheetml/2010/11/main\"><x15:tableSlicerCache tableId=\"1\" column=\"1\"/>"))
        #expect(try Self.part("xl/slicerCaches/slicerCache2.xml", of: data).contains("name=\"Slicer_Product\" sourceName=\"Product\""))
        #expect(try Self.part("xl/slicerCaches/slicerCache3.xml", of: data).contains("<x15:tableSlicerCache tableId=\"1\" column=\"3\"/>"))
        #expect(try IOTestPackage.part("xl/slicerCaches/slicerCache4.xml", of: data) == nil)
        // Each sheet's slicers, named uniquely, captioned with the title or the column's name.
        let slicers = try Self.part("xl/slicers/slicer1.xml", of: data)
        #expect(slicers.contains("<slicers xmlns=\"\(x14)\" xmlns:x=\"\(IOTestPackage.mainNamespace)\"><slicer name=\"Region\" "
            + "cache=\"Slicer_Region\" caption=\"Region\" rowHeight=\"241300\"/><slicer name=\"Products\" cache=\"Slicer_Product\" "
            + "caption=\"Products\" rowHeight=\"241300\"/></slicers>"))
        #expect(try Self.part("xl/slicers/slicer2.xml", of: data).contains("<slicer name=\"Units\" cache=\"Slicer_Units\" caption=\"Units\""))
        // The drawing has a slicer frame with a stand-in shape for older apps; the plain-range slicer isn't drawn.
        let drawing = try Self.part("xl/drawings/drawing1.xml", of: data)
        #expect(drawing.components(separatedBy: "<mc:AlternateContent").count == 3)
        #expect(drawing.contains("<mc:Choice xmlns:sle15=\"http://schemas.microsoft.com/office/drawing/2012/slicer\" Requires=\"sle15\">"))
        #expect(drawing.contains("<xdr:cNvPr id=\"2\" name=\"Region\" title=\"Regions slicer\"/>"))
        #expect(drawing.contains("<a:graphicData uri=\"http://schemas.microsoft.com/office/drawing/2010/slicer\"><sle:slicer "
            + "xmlns:sle=\"http://schemas.microsoft.com/office/drawing/2010/slicer\" name=\"Region\"/></a:graphicData>"))
        #expect(drawing.contains("<mc:Fallback><xdr:sp macro=\"\" textlink=\"\">"))
        #expect(drawing.components(separatedBy: "<xdr:pic>").count == 2)
        #expect(!drawing.contains("Units (plain range)"))
        // The worksheet lists its slicers; the workbook lists the caches, each with its defined name.
        let worksheet = try Self.part("xl/worksheets/sheet1.xml", of: data)
        #expect(worksheet.contains("<extLst><ext uri=\"{3A4CF648-6AED-40f4-86FF-DC5316D8AED3}\" "
            + "xmlns:x15=\"http://schemas.microsoft.com/office/spreadsheetml/2010/11/main\"><x14:slicerList xmlns:x14=\"\(x14)\">"
            + "<x14:slicer r:id=\"rId3\"/></x14:slicerList></ext></extLst></worksheet>"))
        let sheetRelationships = try Self.part("xl/worksheets/_rels/sheet1.xml.rels", of: data)
        #expect(sheetRelationships.contains("Id=\"rId3\" Type=\"http://schemas.microsoft.com/office/2007/relationships/slicer\" "
            + "Target=\"../slicers/slicer1.xml\""))
        let workbook = try Self.part("xl/workbook.xml", of: data)
        #expect(workbook.contains("<definedName name=\"Slicer_Region\">#N/A</definedName><definedName name=\"Slicer_Product\">#N/A</definedName>"
            + "<definedName name=\"Slicer_Units\">#N/A</definedName>"))
        #expect(workbook.contains("<extLst><ext uri=\"{46BE6895-7355-4a93-B00E-2C351335B9C9}\" "
            + "xmlns:x15=\"http://schemas.microsoft.com/office/spreadsheetml/2010/11/main\"><x15:slicerCaches xmlns:x14=\"\(x14)\">"))
        let workbookRelationships = try Self.part("xl/_rels/workbook.xml.rels", of: data)
        for number in 1...3 {
            #expect(workbookRelationships.contains("Type=\"http://schemas.microsoft.com/office/2007/relationships/slicerCache\" "
                + "Target=\"slicerCaches/slicerCache\(number).xml\""))
        }
        let types = try Self.part("[Content_Types].xml", of: data)
        #expect(types.contains("<Override PartName=\"/xl/slicers/slicer1.xml\" ContentType=\"application/vnd.ms-excel.slicer+xml\"/>"))
        #expect(types.contains("<Override PartName=\"/xl/slicerCaches/slicerCache1.xml\" ContentType=\"application/vnd.ms-excel.slicerCache+xml\"/>"))
    }

    @Test func slicerSelectionsFilterTheirTables() throws {
        var workbook = Self.slicerWorkbook()
        // The table filters the region column itself as well: rows either hides stay hidden.
        workbook.sheets[0].tables[0].criteria = [0: FilterCriterion(hiddenValues: ["North"])]
        let table = try Self.part("xl/tables/table1.xml", of: try Self.write(workbook))
        #expect(table.contains("<autoFilter ref=\"A1:D5\"><filterColumn colId=\"0\"><filters><filter val=\"East\"/></filters></filterColumn>"
            + "<filterColumn colId=\"2\"><customFilters><customFilter operator=\"greaterThan\" val=\"15\"/></customFilters></filterColumn>"
            + "</autoFilter>"))
    }

    /// Objects as they come back: slicers whole, images (which get new ids) by their content and place.
    static func comparable(_ objects: [SheetObject]) -> [String] {
        objects.map { $0.slicer != nil ? "\($0)" : "\($0.content) \($0.anchor) \($0.title)" }
    }

    @Test func slicersRoundTripExactly() throws {
        let workbook = Self.slicerWorkbook()
        let file = try Self.roundTrip(workbook)
        #expect(file.warnings.isEmpty)
        for index in workbook.sheets.indices {
            #expect(Self.comparable(file.workbook.sheets[index].objects) == Self.comparable(workbook.sheets[index].objects))
            #expect(file.workbook.sheets[index].tables == workbook.sheets[index].tables)
        }
        #expect(file.workbook.sheets[0].filteredRows == [2])
        #expect(file.workbook.namedRanges.isEmpty)
    }

    @Test func rowsHiddenBySlicersStayFiltered() throws {
        var sheet = Self.ordersSheet()
        sheet.objects = [Self.slicer(SlicerSpec(range: "A1:D5", column: 0, criterion: FilterCriterion(hiddenValues: ["West"])))]
        sheet.filteredRows = [2]
        sheet.hiddenRows = [7]
        var other = Sheet(name: "Controls")
        other.objects = [Self.slicer(SlicerSpec(range: "Orders!A1:D5", column: 3, criterion: FilterCriterion(hiddenValues: ["4"])))]
        var workbook = Workbook(sheets: [sheet, other])
        workbook.sheets[0].filteredRows = [2, 3]
        let file = try Self.roundTrip(workbook)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[0].filteredRows == [2, 3] && file.workbook.sheets[0].hiddenRows == [7])
        #expect(file.workbook.sheets[1].objects == other.objects)
    }

    /// The slicer workbook's file with its custom part taken out, as an app that drops it would save it.
    static func withoutCustomPart(_ data: Data) throws -> Data {
        try Self.changing(data, ["xl/_rels/workbook.xml.rels": {
            $0.replacingOccurrences(of: "<Relationship Id=\"rId[0-9]+\" Type=\"[^\"]+/customXml\" Target=\"[^\"]+\"/>", with: "",
                                    options: .regularExpression)
        }])
    }

    @Test func excelsSlicersReadAsSlicersOnTheirTables() throws {
        let data = try Self.withoutCustomPart(try Self.write(Self.slicerWorkbook()))
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        // The table's filter on a slicer's column is the slicer's selection; Excel's table slicers leave pivot tables alone.
        #expect(sheet.tables.first?.criteria == [:])
        #expect(sheet.objects.map(\.slicer) == [
            SlicerSpec(range: "Orders", column: 0, criterion: FilterCriterion(hiddenValues: ["West"]), appliesToPivotTables: false),
            nil,
            SlicerSpec(range: "Orders", column: 1, title: "Products", appliesToPivotTables: false),
        ])
        #expect(sheet.objects.first?.title == "Regions slicer")
        #expect(sheet.objects.first?.anchor.cell == CellAddress(row: 1, column: 6))
        let summary = file.workbook.sheets[1]
        #expect(summary.objects.map(\.slicer) == [SlicerSpec(range: "Orders", column: 2,
                                                             criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["15"])),
                                                             appliesToPivotTables: false)])
        #expect(file.workbook.namedRanges.isEmpty)
    }

    @Test func slicersAddedOrDeletedInExcelAreKept() throws {
        let workbook = Self.slicerWorkbook()
        let data = try Self.write(workbook)
        // Deleted in Excel: its anchor is gone from the drawing and it from the sheet's slicers. The
        // plain-range slicer, which Excel never saw, stays.
        let deleted = try Self.changing(data, ["xl/drawings/drawing1.xml": { drawing in
            let anchors = drawing.components(separatedBy: "</xdr:twoCellAnchor>")
            var result = ""
            for (index, piece) in anchors.enumerated() {
                guard index < anchors.count - 1 else {
                    result += piece
                    break
                }
                guard piece.contains("name=\"Region\""), let open = piece.range(of: "<xdr:twoCellAnchor", options: .backwards) else {
                    result += piece + "</xdr:twoCellAnchor>"
                    continue
                }
                result += piece[..<open.lowerBound]
            }
            return result
        }, "xl/slicers/slicer1.xml": {
            $0.replacingOccurrences(of: "<slicer name=\"Region\" cache=\"Slicer_Region\" caption=\"Region\" rowHeight=\"241300\"/>", with: "")
        }])
        let afterDelete = try IOTestPackage.read(deleted)
        #expect(afterDelete.warnings.isEmpty)
        #expect(Self.comparable(afterDelete.workbook.sheets[0].objects) == Self.comparable(Array(workbook.sheets[0].objects.dropFirst())))
        // Added in Excel: another slicer on the regions, which isn't in PuggleSheets' part.
        let added = try Self.changing(data, ["xl/slicers/slicer1.xml": {
            $0.replacingOccurrences(of: "</slicers>", with: "<slicer name=\"Region 1\" cache=\"Slicer_Region\" caption=\"Where\" rowHeight=\"241300\"/>"
                + "</slicers>")
        }, "xl/drawings/drawing1.xml": { drawing in
            let frame = "<xdr:absoluteAnchor><xdr:pos x=\"0\" y=\"0\"/><xdr:ext cx=\"952500\" cy=\"952500\"/><mc:AlternateContent "
                + "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><mc:Choice Requires=\"sle15\" "
                + "xmlns:sle15=\"http://schemas.microsoft.com/office/drawing/2012/slicer\"><xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr>"
                + "<xdr:cNvPr id=\"9\" name=\"Region 1\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x=\"0\" y=\"0\"/>"
                + "<a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/drawing/2010/slicer\">"
                + "<sle:slicer xmlns:sle=\"http://schemas.microsoft.com/office/drawing/2010/slicer\" name=\"Region 1\"/></a:graphicData></a:graphic>"
                + "</xdr:graphicFrame></mc:Choice></mc:AlternateContent><xdr:clientData/></xdr:absoluteAnchor>"
            return drawing.replacingOccurrences(of: "</xdr:wsDr>", with: frame + "</xdr:wsDr>")
        }])
        let file = try IOTestPackage.read(added)
        #expect(file.warnings.isEmpty)
        let objects = file.workbook.sheets[0].objects
        #expect(objects.count == 5)
        #expect(Self.comparable(Array(objects.prefix(4))) == Self.comparable(workbook.sheets[0].objects))
        #expect(objects.last?.slicer == SlicerSpec(range: "Orders", column: 0, title: "Where", criterion: FilterCriterion(hiddenValues: ["West"]),
                                                    appliesToPivotTables: false))
    }

    /// An Excel workbook with the table, a slicer on its regions, and `cache` as the slicer's cache.
    static func excelSlicerPackage(cache: String) throws -> Data {
        let x14 = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"
        let x15 = "http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"
        let extensions = "<extLst><ext uri=\"{3A4CF648-6AED-40f4-86FF-DC5316D8AED3}\" xmlns:x15=\"\(x15)\"><x14:slicerList "
            + "xmlns:x14=\"\(x14)\"><x14:slicer r:id=\"rId3\"/></x14:slicerList></ext></extLst>"
        let sheet = Self.excelSheet(extra: "<drawing r:id=\"rId2\"/>", trailing: extensions,
                                    relationships: [("drawing", "../drawings/drawing1.xml"),
                                                    ("http://schemas.microsoft.com/office/2007/relationships/slicer", "../slicers/slicer1.xml")])
        let drawing = IOTestPackage.declaration
            + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" "
            + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><xdr:twoCellAnchor editAs=\"oneCell\">"
            + "<xdr:from><xdr:col>4</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>"
            + "<xdr:to><xdr:col>7</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>14</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>"
            + "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\">"
            + "<mc:Choice xmlns:sle15=\"http://schemas.microsoft.com/office/drawing/2012/slicer\" Requires=\"sle15\"><xdr:graphicFrame macro=\"\">"
            + "<xdr:nvGraphicFramePr><xdr:cNvPr id=\"2\" name=\"Region\" descr=\"Pick regions\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>"
            + "<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic>"
            + "<a:graphicData uri=\"http://schemas.microsoft.com/office/drawing/2010/slicer\">"
            + "<sle:slicer xmlns:sle=\"http://schemas.microsoft.com/office/drawing/2010/slicer\" name=\"Region\"/></a:graphicData></a:graphic>"
            + "</xdr:graphicFrame></mc:Choice><mc:Fallback xmlns=\"\"><xdr:sp macro=\"\" textlink=\"\"><xdr:nvSpPr><xdr:cNvPr id=\"0\" name=\"\"/>"
            + "<xdr:cNvSpPr><a:spLocks noTextEdit=\"1\"/></xdr:cNvSpPr></xdr:nvSpPr><xdr:spPr/></xdr:sp></mc:Fallback></mc:AlternateContent>"
            + "<xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>"
        let slicers = IOTestPackage.declaration + "<slicers xmlns=\"\(x14)\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" "
            + "mc:Ignorable=\"x xr10\" xmlns:x=\"\(IOTestPackage.mainNamespace)\" xmlns:xr10=\"http://schemas.microsoft.com/office/spreadsheetml/2016/revision10\">"
            + "<slicer name=\"Region\" xr10:uid=\"{1C2B3A4D-0000-4000-8000-000000000001}\" cache=\"Slicer_Region\" caption=\"Region\" rowHeight=\"241300\"/>"
            + "</slicers>"
        return try IOTestPackage.xlsx(
            sheets: [sheet],
            workbookSuffix: "<definedNames><definedName name=\"Slicer_Region\">#N/A</definedName></definedNames>"
                + "<extLst><ext uri=\"{46BE6895-7355-4a93-B00E-2C351335B9C9}\" xmlns:x15=\"\(x15)\"><x15:slicerCaches xmlns:x14=\"\(x14)\">"
                + "<x14:slicerCache r:id=\"rId200\"/></x15:slicerCaches></ext></extLst>",
            workbookRelationships: [("http://schemas.microsoft.com/office/2007/relationships/slicerCache", "slicerCaches/slicerCache1.xml")],
            parts: ["xl/tables/table1.xml": Self.excelTable(), "xl/drawings/drawing1.xml": drawing, "xl/slicers/slicer1.xml": slicers,
                    "xl/slicerCaches/slicerCache1.xml": IOTestPackage.declaration + cache])
    }

    @Test func excelTableSlicersAreRead() throws {
        let cache = "<slicerCacheDefinition xmlns=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\" "
            + "xmlns:x=\"\(IOTestPackage.mainNamespace)\" name=\"Slicer_Region\" sourceName=\"Region\"><extLst><x:ext "
            + "uri=\"{2F2917AC-EB37-4324-AD4E-5DD8C200BD13}\" xmlns:x15=\"http://schemas.microsoft.com/office/spreadsheetml/2010/11/main\">"
            + "<x15:tableSlicerCache tableId=\"2\" column=\"1\"/></x:ext></extLst></slicerCacheDefinition>"
        let file = try IOTestPackage.read(try Self.excelSlicerPackage(cache: cache))
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        #expect(sheet.objects.count == 1)
        let object = try #require(sheet.objects.first)
        #expect(object.slicer == SlicerSpec(range: "Sales", column: 0, criterion: FilterCriterion(hiddenValues: ["West"]), appliesToPivotTables: false))
        #expect(object.altDescription == "Pick regions")
        #expect(object.anchor.cell == CellAddress(row: 1, column: 4))
        #expect(sheet.tables.first?.criteria == [:])
        // The rows the slicer hides are still the filter's, and the cache's defined name isn't a named range.
        #expect(sheet.filteredRows == [2])
        #expect(file.workbook.namedRanges.isEmpty)
    }

    @Test func pivotTableSlicersWarn() throws {
        let cache = "<slicerCacheDefinition xmlns=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\" name=\"Slicer_Region\" "
            + "sourceName=\"Region\"><pivotTables><pivotTable tabId=\"1\" name=\"PivotTable1\"/></pivotTables><data><tabular pivotCacheId=\"1\">"
            + "<items count=\"1\"><i x=\"0\" s=\"1\"/></items></tabular></data></slicerCacheDefinition>"
        let file = try IOTestPackage.read(try Self.excelSlicerPackage(cache: cache))
        #expect(file.warnings == [.filters])
        #expect(file.workbook.sheets[0].objects.isEmpty)
        // The table keeps its own filter.
        #expect(file.workbook.sheets[0].tables.first?.criteria == [0: FilterCriterion(hiddenValues: ["West"])])
        #expect(file.workbook.namedRanges.isEmpty)
    }

    @Test func slicerAndTableNamesStayUnique() throws {
        var sheet = Self.ordersSheet()
        sheet.tables = [SheetTable(name: "Orders", range: Self.ordersRange)]
        sheet.objects = [Self.slicer(SlicerSpec(range: "Orders")), Self.slicer(SlicerSpec(range: "Orders"), row: 12),
                         Self.slicer(SlicerSpec(range: "orders", column: 1, title: "Region"), row: 24)]
        let workbook = Workbook(sheets: [sheet], namedRanges: [NamedRange(name: "Slicer_Region", reference: "Orders!$A$1")])
        let data = try Self.write(workbook)
        let slicers = try Self.part("xl/slicers/slicer1.xml", of: data)
        #expect(slicers.contains("<slicer name=\"Region\" cache=\"Slicer_Region1\" caption=\"Region\""))
        #expect(slicers.contains("<slicer name=\"Region 1\" cache=\"Slicer_Region2\" caption=\"Region\""))
        #expect(slicers.contains("<slicer name=\"Region 2\" cache=\"Slicer_Product\" caption=\"Region\""))
        let file = try SpreadsheetIO.read(data, format: .xlsx)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.namedRanges == workbook.namedRanges)
        #expect(file.workbook.sheets[0].objects == sheet.objects)
    }
}
