import Foundation
import Testing
@testable import PuggleSheetsKit

/// Phase 5 in OpenDocument files: tables, table references in formulas, slicers and the new functions.
struct IOODSTablesTests {
    static func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    static func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    static func write(_ workbook: Workbook) throws -> Data {
        try SpreadsheetIO.write(workbook, activeSheet: 0, format: .ods)
    }

    static func read(_ data: Data) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(data, format: .ods)
    }

    static func content(_ data: Data) throws -> String {
        try ZipReader(data: data).read("content.xml").map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The package with `old` replaced by `new` in one of its parts, as another app might edit it.
    static func replacing(_ old: String, with new: String, in path: String, of data: Data) throws -> Data {
        let zip = try ZipReader(data: data)
        var writer = ZipWriter()
        for entry in zip.entries {
            var part = try zip.read(entry)
            if entry.path == path {
                let text = String(decoding: part, as: UTF8.self)
                #expect(text.contains(old))
                part = Data(text.replacingOccurrences(of: old, with: new).utf8)
            }
            try writer.add(entry.path, part, compress: entry.path != "mimetype")
        }
        return try writer.finish()
    }

    /// Orders in B2:D6 of "Sales": Region, Amount and Done columns, the West rows filtered out.
    static func salesSheet(name: String = "Sales") -> Sheet {
        var sheet = Sheet(name: name)
        for (column, header) in ["Region", "Amount", "Done"].enumerated() { sheet[1, column + 1] = Cell(value: .text(header)) }
        for row in 2...5 {
            sheet[row, 1] = Cell(value: .text(["East", "West"][row % 2]))
            sheet[row, 2] = Cell(value: .number(Double(row * 10)))
            sheet[row, 3] = Cell(value: .boolean(row > 3))
        }
        sheet.tables = [SheetTable(name: "Orders", range: range("B2:D6"), columnTypes: [2: .currency, 3: .checkbox],
                                   color: SheetTable.colors[3], criteria: [1: FilterCriterion(hiddenValues: ["West"])])]
        return sheet
    }

    // MARK: - Tables

    @Test func tablesRoundTrip() throws {
        var sales = Self.salesSheet()
        // A second table whose criteria and column types OpenDocument can't hold: kept in PuggleSheets' settings.
        for row in 9...12 {
            sales[row, 0] = Cell(value: .text("Item \(row)"))
            sales[row, 1] = Cell(value: .number(Double(row)))
        }
        sales[8, 0] = Cell(value: .text("Item"))
        sales[8, 1] = Cell(value: .text("Size"))
        let custom = FilterCriterion(condition: CellCondition(.customFormula, ["=B10>10"]))
        let dated = FilterCriterion(condition: CellCondition(.dateIsAfter, ["2026-01-31"]))
        sales.tables.append(SheetTable(name: "Stock.Items", range: Self.range("A9:B13"), columnTypes: [0: .dropdown(["S", "M", "L"]), 1: .number],
                                       criteria: [0: dated, 1: custom]))
        sales.filter = SheetFilter(range: Self.range("F1:G5"), criteria: [5: FilterCriterion(condition: CellCondition(.textContains, ["a"]))])
        let workbook = Workbook(sheets: [sales])
        let data = try Self.write(workbook)
        let content = try Self.content(data)
        // A named database range for each table, after the sheet's own one, with a header row and filter buttons.
        #expect(content.contains("<table:database-ranges><table:database-range table:name=\"__Anonymous_Sheet_DB__0\" "
            + "table:target-range-address=\"Sales.F1:Sales.G5\" table:display-filter-buttons=\"true\">"))
        #expect(content.contains("<table:database-range table:name=\"Orders\" table:target-range-address=\"Sales.B2:Sales.D6\" "
            + "table:contains-header=\"true\" table:display-filter-buttons=\"true\"><table:filter><table:filter-condition table:field-number=\"0\" "
            + "table:value=\"East\" table:operator=\"=\"><table:filter-set-item table:value=\"East\"/></table:filter-condition></table:filter></table:database-range>"))
        #expect(content.contains("<table:database-range table:name=\"Stock.Items\" table:target-range-address=\"Sales.A9:Sales.B13\" "
            + "table:contains-header=\"true\" table:display-filter-buttons=\"true\">"))

        let file = try Self.read(data)
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        #expect(sheet.tables == workbook.sheets[0].tables)
        #expect(sheet.filter == workbook.sheets[0].filter)

        // As LibreOffice would save it: the tables, their ranges and the filters their database ranges hold.
        let plain = try Self.read(try IOODSObjectsTests.withoutPuggleSettings(data))
        let tables = plain.workbook.sheets[0].tables
        #expect(tables.map(\.name) == ["Orders", "Stock.Items"])
        #expect(tables.map(\.range) == [Self.range("B2:D6"), Self.range("A9:B13")])
        #expect(tables[0].criteria == [1: FilterCriterion(hiddenValues: ["West"])])
        #expect(tables[0].color == SheetTable.colors[0] && tables[0].columnTypes.isEmpty)
        // The date written as a number; the custom formula has no OpenDocument form.
        #expect(tables[1].criteria == [0: FilterCriterion(condition: CellCondition(.greaterThan, ["46053"]))])
        #expect(plain.workbook.sheets[0].filter == workbook.sheets[0].filter)
    }

    @Test func keptCriteriaNeedTheSameFilter() throws {
        var sheet = Self.salesSheet()
        sheet.tables[0].criteria = [2: FilterCriterion(condition: CellCondition(.dateIsBefore, ["2026-03-01"]))]
        let data = try Self.write(Workbook(sheets: [sheet]))
        #expect(try Self.read(data).workbook.sheets[0].tables[0].criteria == sheet.tables[0].criteria)
        // Another app changed the filter: what the file says wins.
        let edited = try Self.replacing("table:value=\"46082\" table:operator=\"&lt;\"", with: "table:value=\"40\" table:operator=\"&lt;\"",
                                        in: "content.xml", of: data)
        let table = try Self.read(edited).workbook.sheets[0].tables[0]
        #expect(table.criteria == [2: FilterCriterion(condition: CellCondition(.lessThan, ["40"]))])
        #expect(table.color == sheet.tables[0].color && table.columnTypes == sheet.tables[0].columnTypes)
    }

    @Test func readsLibreOfficeDatabaseRanges() throws {
        func text(_ value: String) -> String { "<table:table-cell office:value-type=\"string\" calcext:value-type=\"string\"><text:p>\(value)</text:p></table:table-cell>" }
        func float(_ value: Int) -> String {
            "<table:table-cell office:value-type=\"float\" office:value=\"\(value)\" calcext:value-type=\"float\"><text:p>\(value)</text:p></table:table-cell>"
        }
        let body = """
            <table:table table:name="Stock">
            <table:table-row>\(text("Item"))\(text("Count"))</table:table-row>
            <table:table-row>\(text("Pens"))\(float(4))</table:table-row>
            <table:table-row table:visibility="filter">\(text("Ink"))\(float(9))</table:table-row>
            <table:table-row>\(text("Total"))<table:table-cell table:formula="of:=SUM(Inventory)" office:value-type="float" office:value="13" calcext:value-type="float"><text:p>13</text:p></table:table-cell></table:table-row>
            </table:table>
            <table:table table:name="Other">
            <table:table-row>\(text("Name"))\(text("Score"))</table:table-row>
            <table:table-row>\(text("Ann"))\(float(3))</table:table-row>
            <table:table-row>\(text("Bo"))\(float(8))</table:table-row>
            </table:table>
            <table:named-expressions><table:named-range table:name="Rates" table:base-cell-address="$Other.$A$1" table:cell-range-address="$Other.$A$1:.$A$3"/></table:named-expressions>
            <table:database-ranges>
            <table:database-range table:name="Inventory" table:target-range-address="Stock.A1:Stock.B4" table:display-filter-buttons="true" calcext:contains-footer="true">
            <table:filter><table:filter-condition table:field-number="0" table:value="Pens" table:operator="="><table:filter-set-item table:value="Pens"/></table:filter-condition></table:filter>
            </table:database-range>
            <table:database-range table:name="__Anonymous_Sheet_DB__1" table:target-range-address="Other.A1:Other.B3" table:display-filter-buttons="true">
            <table:filter><table:filter-condition table:field-number="1" table:value="5" table:operator="&gt;" table:data-type="number"/></table:filter>
            </table:database-range>
            <table:database-range table:name="Plain" table:target-range-address="Other.D1:Other.E3" table:contains-header="false"/>
            <table:database-range table:name="Sideways" table:target-range-address="Other.G1:Other.H3" table:orientation="column"/>
            <table:database-range table:name="Rates" table:target-range-address="Other.J1:Other.K3"/>
            <table:database-range table:name="Overlap" table:target-range-address="Other.K2:Other.L3"/>
            </table:database-ranges>
            """
        let file = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(body)))
        #expect(file.warnings.isEmpty)
        let stock = file.workbook.sheets[0], other = file.workbook.sheets[1]
        // A named range with a header row is a table; its totals row isn't part of it.
        #expect(stock.tables.count == 1)
        #expect(stock.tables[0].name == "Inventory" && stock.tables[0].range == Self.range("A1:B3"))
        #expect(stock.tables[0].criteria == [0: FilterCriterion(hiddenValues: ["Ink"])])
        #expect(stock.tables[0].color == SheetTable.colors[0] && stock.tables[0].columnTypes.isEmpty)
        #expect(stock.filteredRows == [2] && stock.filter == nil)
        // A bare database range name in a formula is the whole range, as a table name is.
        #expect(stock[3, 1].formula == "=SUM(Inventory)")
        // The sheet's own range is its filter; ranges without a header row or sorted by columns aren't tables,
        // a name taken by a named range gets another, and a range overlapping a table is left out.
        #expect(other.filter == SheetFilter(range: Self.range("A1:B3"), criteria: [1: FilterCriterion(condition: CellCondition(.greaterThan, ["5"]))]))
        #expect(other.tables.map(\.name) == ["Rates_2"] && other.tables[0].range == Self.range("J1:K3"))
        #expect(file.workbook.namedRanges.map(\.name) == ["Rates"])
    }

    // MARK: - Table references

    @Test func tableReferencesBecomeCells() throws {
        var report = Sheet(name: "Q1 Report")
        let formulas = [
            "=SUM(Orders[Amount])", "=COUNTA(Orders[#ALL])", "=ROWS(Orders[#DATA])", "=INDEX(Orders[#HEADERS],1)",
            "=Orders[[#HEADERS],[Amount]]", "=SUM(Orders[[Amount]:[Done]])", "=SUM(Orders)", "=SUM(Missing[Amount])",
            "=SUM(Orders[Nope])", "=COUNTA(Orders[[#Headers],[#Data],[Region]])", "=SUM(orders[amount])+'Q1 Report'!A1",
        ]
        for (row, formula) in formulas.enumerated() { report[row, 0] = Cell(value: .number(1), formula: formula) }
        var sales = Self.salesSheet()
        sales[3, 5] = Cell(value: .number(30), formula: "=Orders[@Amount]*2")
        sales[0, 5] = Cell(value: .number(30), formula: "=Orders[@Amount]")
        let workbook = Workbook(sheets: [report, sales])
        let data = try Self.write(workbook)
        let content = try Self.content(data)
        // As LibreOffice writes table references in OpenFormula: the cells they cover.
        for expected in [
            "of:=SUM([$Sales.$C$3:.$C$6])", "of:=COUNTA([$Sales.$B$2:.$D$6])", "of:=ROWS([$Sales.$B$3:.$D$6])",
            "of:=INDEX([$Sales.$B$2:.$D$2];1)", "of:=[$Sales.$C$2]", "of:=SUM([$Sales.$C$3:.$D$6])", "of:=SUM(Orders)",
            "of:=SUM(#REF!)", "of:=COUNTA([$Sales.$B$2:.$B$6])", "of:=SUM([$Sales.$C$3:.$C$6])+['Q1 Report'.A1]",
            "of:=[$Sales.$C$4]*2", "of:=#VALUE!",
        ] {
            #expect(content.contains("table:formula=\"\(expected)\""), "\(expected)")
        }

        // The formulas as typed come back.
        let file = try Self.read(data)
        for (row, formula) in formulas.enumerated() { #expect(file.workbook.sheets[0][row, 0].formula == formula) }
        #expect(file.workbook.sheets[1][3, 5].formula == "=Orders[@Amount]*2")
        #expect(file.workbook.sheets[1][0, 5].formula == "=Orders[@Amount]")

        // As LibreOffice would save it: the cells.
        let plain = try Self.read(try IOODSObjectsTests.withoutPuggleSettings(data)).workbook.sheets[0]
        #expect(plain[0, 0].formula == "=SUM(Sales!$C$3:$C$6)")
        #expect(plain[4, 0].formula == "=Sales!$C$2")
        #expect(plain[6, 0].formula == "=SUM(Orders)")
        #expect(plain[7, 0].formula == "=SUM(#REF!)")

        // A formula another app changed keeps its new text.
        let edited = try Self.replacing("of:=ROWS([$Sales.$B$3:.$D$6])", with: "of:=ROWS([$Sales.$B$3:.$D$9])", in: "content.xml", of: data)
        let changed = try Self.read(edited).workbook.sheets[0]
        #expect(changed[2, 0].formula == "=ROWS(Sales!$B$3:$D$9)")
        #expect(changed[0, 0].formula == "=SUM(Orders[Amount])")
    }

    @Test func tableReferenceSyntax() {
        var sheet = Self.salesSheet(name: "My Sales")
        sheet[1, 2] = Cell(value: .text("Price [USD]"))
        let tables = ODSTableReferences(workbook: Workbook(sheets: [sheet]), names: ["My Sales"])
        #expect(tables.reference("Orders", "[Price '[USD']]", row: 0) == "[$'My Sales'.$C$3:.$C$6]")
        #expect(tables.reference("ORDERS", "[ [#Headers] , [Region] : [Price '[USD']] ]", row: 0) == "[$'My Sales'.$B$2:.$C$2]")
        #expect(tables.reference("Orders", "[]", row: 0) == "[$'My Sales'.$B$2:.$D$6]")
        #expect(tables.reference("Orders", "[@[Done]]", row: 4) == "[$'My Sales'.$D$5]")
        #expect(tables.reference("Orders", "[[#This Row],[Region]]", row: 2) == "[$'My Sales'.$B$3]")
        #expect(tables.reference("Orders", "[#Totals]", row: 0) == "#REF!")
        #expect(tables.reference("Orders", "[[Region],[Done]]", row: 0) == "#REF!")
        #expect(tables.reference("Orders", "[#Everything]", row: 0) == "#REF!")
    }

    // MARK: - Slicers

    @Test func slicersRoundTrip() throws {
        var sheet = Self.salesSheet()
        let image = SheetObject(anchor: ObjectAnchor(cell: Self.address("F2"), width: 40, height: 30), content: .image(IOODSObjectsTests.png(width: 4, height: 3)))
        let spec = SlicerSpec(range: "Orders", column: 1, title: "Amounts", criterion: FilterCriterion(hiddenValues: ["20", "40"],
                              condition: CellCondition(.greaterThan, ["10"])), appliesToPivotTables: false, backgroundColor: RGBColor(hex: "FCE8B2"))
        let slicer = SheetObject(anchor: ObjectAnchor(cell: Self.address("H3"), offsetX: 4.5, offsetY: 2, width: 180, height: 64.25),
                                 content: .slicer(spec), title: "Amount slicer", altDescription: "Filters the orders")
        let plainSlicer = SheetObject(anchor: ObjectAnchor(cell: Self.address("H8"), width: 200, height: 60), content: .slicer(SlicerSpec(range: "Sales!B2:D6")))
        sheet.objects = [slicer, image, plainSlicer]
        var dashboard = Sheet(name: "Dashboard")
        dashboard.objects = [SheetObject(anchor: ObjectAnchor(cell: Self.address("A1"), width: 200, height: 60), content: .slicer(SlicerSpec(range: "Sales!B2:D6")))]
        let workbook = Workbook(sheets: [sheet, dashboard])
        let data = try Self.write(workbook)
        let content = try Self.content(data)
        // Only the image has a frame; a sheet with only slicers has none.
        #expect(content.components(separatedBy: "<draw:frame ").count == 2)
        #expect(!content.contains("Dashboard.A1"))

        let file = try Self.read(data)
        #expect(file.warnings.isEmpty)
        // The slicers, exactly, in their places among the objects.
        let objects = file.workbook.sheets[0].objects
        #expect(objects.map { $0.slicer != nil } == [true, false, true])
        #expect(objects.filter { $0.slicer != nil } == [slicer, plainSlicer])
        #expect(file.workbook.sheets[1].objects == workbook.sheets[1].objects)

        // LibreOffice has no slicers: without PuggleSheets' settings, only the image is left.
        let plain = try Self.read(try IOODSObjectsTests.withoutPuggleSettings(data))
        #expect(plain.workbook.sheets[0].objects.map(\.content) == [image.content])
        #expect(plain.workbook.sheets[1].objects.isEmpty)
    }

    @Test func slicersAloneNeedNoGraphicStyle() throws {
        var sheet = Sheet(name: "Only")
        sheet.objects = [SheetObject(anchor: ObjectAnchor(cell: Self.address("B2"), width: 200, height: 60), content: .slicer(SlicerSpec(range: "A1:B5")))]
        let content = try Self.content(try Self.write(Workbook(sheets: [sheet])))
        #expect(!content.contains("style:name=\"gr1\""))
    }

    // MARK: - New functions

    @Test func newFunctionsWriteLibreOfficeNames() {
        let size: ODSFormula.SheetSize = { _ in (1000, 26) }
        let cases = [
            ("=LET(x,1,y,x+1,x*y)", "of:=COM.MICROSOFT.LET(_xlpm.x;1;_xlpm.y;_xlpm.x+1;_xlpm.x*_xlpm.y)"),
            ("=MAP(A1:A3,LAMBDA(v,v*2))", "of:=COM.MICROSOFT.MAP([.A1:.A3];COM.MICROSOFT.LAMBDA(_xlpm.v;_xlpm.v*2))"),
            ("=REDUCE(0,A1:A3,LAMBDA(acc,v,acc+v))", "of:=COM.MICROSOFT.REDUCE(0;[.A1:.A3];COM.MICROSOFT.LAMBDA(_xlpm.acc;_xlpm.v;_xlpm.acc+_xlpm.v))"),
            ("=SCAN(0, A1:A3, LAMBDA(a, b, a + b))", "of:=COM.MICROSOFT.SCAN(0; [.A1:.A3]; COM.MICROSOFT.LAMBDA(_xlpm.a; _xlpm.b; _xlpm.a + _xlpm.b))"),
            ("=BYROW(A1:B3,LAMBDA(r,SUM(r)))", "of:=COM.MICROSOFT.BYROW([.A1:.B3];COM.MICROSOFT.LAMBDA(_xlpm.r;SUM(_xlpm.r)))"),
            ("=BYCOL(A1:B3,LAMBDA(c,MAX(c)))", "of:=COM.MICROSOFT.BYCOL([.A1:.B3];COM.MICROSOFT.LAMBDA(_xlpm.c;MAX(_xlpm.c)))"),
            ("=MAKEARRAY(2,3,LAMBDA(r,c,r*c))", "of:=COM.MICROSOFT.MAKEARRAY(2;3;COM.MICROSOFT.LAMBDA(_xlpm.r;_xlpm.c;_xlpm.r*_xlpm.c))"),
            // A name that's also a function: called, it's the function.
            ("=LET(sum,SUM(A1:A3),sum/2)", "of:=COM.MICROSOFT.LET(_xlpm.sum;SUM([.A1:.A3]);_xlpm.sum/2)"),
            // A name holding a lambda, called.
            ("=LET(f,LAMBDA(x,x*2),f(3))", "of:=COM.MICROSOFT.LET(_xlpm.f;COM.MICROSOFT.LAMBDA(_xlpm.x;_xlpm.x*2);_xlpm.f(3))"),
            // An optional parameter.
            ("=LAMBDA(a,[b],IF(ISOMITTED(b),a,a+b))(1)",
             "of:=COM.MICROSOFT.LAMBDA(_xlpm.a;_xlop.b;IF(COM.MICROSOFT.ISOMITTED(_xlpm.b);_xlpm.a;_xlpm.a+_xlpm.b))(1)"),
            // Names stay names only inside their call; sheets, cells and strings aren't names.
            ("=LET(data,{1,2},SUM(data,X1,\"data\",data!A1))+data",
             "of:=COM.MICROSOFT.LET(_xlpm.data;{1;2};SUM(_xlpm.data;[.X1];\"data\";[data.A1]))+data"),
            // Functions with no OpenFormula name are written as they are; GETPIVOTDATA keeps its own.
            ("=QUERY(A1:B3,\"select A where B > 1\",1)", "of:=QUERY([.A1:.B3];\"select A where B > 1\";1)"),
            ("=SPARKLINE(A1:A3,{\"charttype\",\"bar\";\"max\",10})", "of:=SPARKLINE([.A1:.A3];{\"charttype\";\"bar\"|\"max\";10})"),
            ("=SORTN(A1:B3,2,0,2,FALSE)", "of:=SORTN([.A1:.B3];2;0;2;FALSE())"),
            ("=GETPIVOTDATA(\"SUM of Sales\",A1,\"Region\",\"East\")", "of:=GETPIVOTDATA(\"SUM of Sales\";[.A1];\"Region\";\"East\")"),
            ("=VSTACK(A1:A2,TOCOL(B1:C2))", "of:=COM.MICROSOFT.VSTACK([.A1:.A2];COM.MICROSOFT.TOCOL([.B1:.C2]))"),
        ]
        for (formula, written) in cases {
            #expect(ODSFormula.exporting(formula, size: size) == written)
            #expect(ODSFormula.importing(written) == formula)
        }
    }

    @Test func readsLibreOfficeLambdas() {
        #expect(ODSFormula.importing("of:=COM.MICROSOFT.LET(_xlpm.x;1;_xlpm.x+1)") == "=LET(x,1,x+1)")
        #expect(ODSFormula.importing("of:=COM.MICROSOFT.LAMBDA(_XLPM.Total;_xlop.rate;_xlpm.Total*2)(3)") == "=LAMBDA(Total,[rate],Total*2)(3)")
        #expect(ODSFormula.importing("of:=COM.MICROSOFT.LAMBDA(_xlpm.a;[_xlpm.b];_xlpm.a)(1)") == "=LAMBDA(a,[b],a)(1)")
        #expect(ODSFormula.importing("of:=COM.MICROSOFT.LET(_xlpm.f;COM.MICROSOFT.LAMBDA(_xlpm.n;_xlpm.n);_xlpm.f(2))") == "=LET(f,LAMBDA(n,n),f(2))")
        // Error values keep their "!".
        #expect(ODSFormula.importing("of:=IF(ISERROR(#DIV/0!);#N/A;#ref!)") == "=IF(ISERROR(#DIV/0!),#N/A,#ref!)")
        #expect(ODSFormula.importing("of:=[.A1]![.B1]") == "=A1 B1")
    }

    @Test func newFunctionsRoundTrip() throws {
        var sheet = Sheet(name: "Lambdas")
        let formulas = ["=LET(x,A1,x*2)", "=LAMBDA(a,[b],IF(ISOMITTED(b),a,a+b))(1,2)", "=SORTN(A1:A3,1)", "=SPARKLINE(A1:A3)",
                        "=QUERY(A1:A3,\"select *\")", "=MAP(A1:A3,LAMBDA(v,v+1))"]
        for (row, formula) in formulas.enumerated() { sheet[row, 1] = Cell(value: .number(0), formula: formula) }
        let data = try Self.write(Workbook(sheets: [sheet]))
        // Nothing needs keeping: these formulas read back as written.
        #expect(try IOODSObjectsTests.part("settings.xml", of: data)?.contains("config:name=\"Formulas\"") == false)
        let file = try Self.read(data)
        for (row, formula) in formulas.enumerated() { #expect(file.workbook.sheets[0][row, 1].formula == formula) }
    }
}
