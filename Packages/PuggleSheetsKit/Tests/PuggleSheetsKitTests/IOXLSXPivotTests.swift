import Foundation
import Testing
@testable import PuggleSheetsKit

/// Pivot tables in Excel files: cache and table definitions, and their stored results.
struct IOXLSXPivotTests {
    /// Region, Product, Month, Sales, Units.
    static func dataSheet() -> Sheet {
        var sheet = Sheet(name: "Data")
        let rows: [[CellValue]] = [
            [.text("Region"), .text("Product"), .text("Month"), .text("Sales"), .text("Units")],
            [.text("East"), .text("Apples"), .text("Jan"), .number(100), .number(10)],
            [.text("West"), .text("Pears"), .text("Jan"), .number(80), .number(8)],
            [.text("East"), .text("Pears"), .text("Feb"), .number(120), .number(12)],
            [.text("North"), .text("Apples"), .text("Feb"), .number(90), .number(9)],
            [.text("West"), .text("Apples"), .text("Mar"), .number(70), .number(7)],
            [.text("East"), .text("Apples"), .text("Mar"), .number(110), .number(11)],
        ]
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() { sheet[row, column] = Cell(value: value) }
        }
        return sheet
    }

    static let byRegion = PivotTable(anchor: CellAddress(a1: "A3")!, source: "Data!A1:E7",
                                     rows: [PivotGroup(sourceColumn: 0, ascending: false, sortByValue: 0)],
                                     columns: [PivotGroup(sourceColumn: 1)],
                                     values: [PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 4, summary: .average, name: "Avg units")],
                                     filters: [PivotFilter(sourceColumn: 2, criterion: FilterCriterion(hiddenValues: ["Mar"]))])
    static let stacked = PivotTable(anchor: CellAddress(a1: "H1")!, source: "Data!A1:E7",
                                    rows: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 1, showsTotals: false)],
                                    values: [PivotValue(sourceColumn: 3, summary: .max),
                                             PivotValue(sourceColumn: 4, summary: .count, showAs: .percentOfGrandTotal)],
                                    filters: [PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["North"]))],
                                    valuesInRows: true)

    /// A report sheet with the pivot tables and the results the engine would have placed.
    static func workbook(_ pivots: [PivotTable] = [byRegion, stacked]) -> Workbook {
        var report = Sheet(name: "Report")
        report[0, 0] = Cell(value: .text("Sales report"))
        report.pivotTables = pivots
        if pivots.contains(where: { $0.anchor == CellAddress(a1: "A3") }) {
            report.spillRanges[CellAddress(a1: "A3")!] = CellRange(a1: "A3:E8")!
            report.spilledValues[CellAddress(a1: "A3")!] = .text("Region")
            report.spilledValues[CellAddress(a1: "A4")!] = .text("West")
            report.spilledValues[CellAddress(a1: "B4")!] = .number(150)
            report.spilledValues[CellAddress(a1: "A8")!] = .text("Grand Total")
        }
        return Workbook(sheets: [dataSheet(), report])
    }

    /// Pivot tables compared without their ids.
    static func same(_ a: PivotTable?, _ b: PivotTable) -> Bool {
        guard let a else { return false }
        return a.anchor == b.anchor && a.source == b.source && a.rows == b.rows && a.columns == b.columns && a.values == b.values
            && a.filters == b.filters && a.valuesInRows == b.valuesInRows
    }

    @Test func pivotTablesRoundTrip() throws {
        let workbook = Self.workbook()
        let data = try SpreadsheetIO.write(workbook, activeSheet: 1, format: .xlsx)
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
        // Other apps see the results as cells before Excel recomputes them.
        let sheetPart = try #require(try IOTestPackage.part("xl/worksheets/sheet2.xml", of: data))
        #expect(sheetPart.contains("<c r=\"B4\"><v>150</v></c>"))
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        let report = file.workbook.sheets[1]
        #expect(report.pivotTables.count == 2)
        #expect(Self.same(report.pivotTables.first, Self.byRegion))
        #expect(Self.same(report.pivotTables.last, Self.stacked))
        // The stored results are cleared, so PuggleSheets computes them again; other cells stay.
        #expect(report.cells(in: CellRange(a1: "A3:E8")!).isEmpty)
        #expect(report[0, 0].value == .text("Sales report"))
    }

    @Test func cacheDefinitionXML() throws {
        let data = try SpreadsheetIO.write(Self.workbook([Self.byRegion]), activeSheet: 1, format: .xlsx)
        let cache = try #require(try IOTestPackage.part("xl/pivotCache/pivotCacheDefinition1.xml", of: data))
        #expect(cache.contains("saveData=\"0\" refreshOnLoad=\"1\""))
        #expect(cache.contains("recordCount=\"6\""))
        #expect(cache.contains("<cacheSource type=\"worksheet\"><worksheetSource ref=\"A1:E7\" sheet=\"Data\"/></cacheSource>"))
        // Grouped and filtered columns list their values; summarized ones only their kinds and range.
        #expect(cache.contains("<cacheField name=\"Region\" numFmtId=\"0\"><sharedItems count=\"3\"><s v=\"East\"/><s v=\"West\"/><s v=\"North\"/>"
            + "</sharedItems></cacheField>"))
        #expect(cache.contains("<cacheField name=\"Month\" numFmtId=\"0\"><sharedItems count=\"3\"><s v=\"Jan\"/><s v=\"Feb\"/><s v=\"Mar\"/>"))
        #expect(cache.contains("<cacheField name=\"Sales\" numFmtId=\"0\"><sharedItems containsSemiMixedTypes=\"0\" containsString=\"0\" "
            + "containsNumber=\"1\" containsInteger=\"1\" minValue=\"70\" maxValue=\"120\"/></cacheField>"))
        let workbook = try #require(try IOTestPackage.part("xl/workbook.xml", of: data))
        #expect(workbook.contains("<calcPr fullCalcOnLoad=\"1\"/><pivotCaches><pivotCache cacheId=\"1\" r:id=\"rId5\"/></pivotCaches></workbook>"))
        let relationships = try #require(try IOTestPackage.part("xl/_rels/workbook.xml.rels", of: data))
        #expect(relationships.contains("<Relationship Id=\"rId5\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotCacheDefinition\" "
            + "Target=\"pivotCache/pivotCacheDefinition1.xml\"/>"))
        let types = try #require(try IOTestPackage.part("[Content_Types].xml", of: data))
        #expect(types.contains("<Override PartName=\"/xl/pivotCache/pivotCacheDefinition1.xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml\"/>"))
        #expect(types.contains("<Override PartName=\"/xl/pivotTables/pivotTable1.xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml\"/>"))
    }

    @Test func tableDefinitionXML() throws {
        let data = try SpreadsheetIO.write(Self.workbook(), activeSheet: 1, format: .xlsx)
        let table = try #require(try IOTestPackage.part("xl/pivotTables/pivotTable1.xml", of: data))
        #expect(table.contains("name=\"PivotTable1\" cacheId=\"1\""))
        #expect(table.contains("<location ref=\"A3:E8\" firstHeaderRow=\"1\" firstDataRow=\"2\" firstDataCol=\"1\" rowPageCount=\"1\" colPageCount=\"1\"/>"))
        // Region, sorted descending by the first value: West, North, East.
        #expect(table.contains("<pivotField axis=\"axisRow\" compact=\"0\" outline=\"0\" showAll=\"0\" sortType=\"descending\"><items count=\"4\">"
            + "<item x=\"1\"/><item x=\"2\"/><item x=\"0\"/><item t=\"default\"/></items><autoSortScope>"))
        #expect(table.contains("<reference field=\"4294967294\" count=\"1\" selected=\"0\"><x v=\"0\"/></reference>"))
        // Month filters as a report filter with March left out.
        #expect(table.contains("<pivotField axis=\"axisPage\" compact=\"0\" outline=\"0\" showAll=\"0\" multipleItemSelectionAllowed=\"1\">"
            + "<items count=\"4\"><item x=\"1\"/><item x=\"0\"/><item h=\"1\" x=\"2\"/><item t=\"default\"/></items></pivotField>"))
        #expect(table.contains("<pivotField dataField=\"1\" compact=\"0\" outline=\"0\" showAll=\"0\"/>"))
        #expect(table.contains("<colFields count=\"2\"><field x=\"1\"/><field x=\"-2\"/></colFields>"))
        #expect(table.contains("<pageFields count=\"1\"><pageField fld=\"2\" hier=\"-1\"/></pageFields>"))
        #expect(table.contains("<dataFields count=\"2\"><dataField name=\"SUM of Sales\" fld=\"3\" subtotal=\"sum\" baseField=\"0\" baseItem=\"0\"/>"
            + "<dataField name=\"Avg units\" fld=\"4\" subtotal=\"average\" baseField=\"0\" baseItem=\"0\"/></dataFields>"))

        let second = try #require(try IOTestPackage.part("xl/pivotTables/pivotTable2.xml", of: data))
        #expect(second.contains("dataOnRows=\"1\""))
        #expect(second.contains("<rowFields count=\"3\"><field x=\"0\"/><field x=\"1\"/><field x=\"-2\"/></rowFields>"))
        // A single cell when the results aren't known.
        #expect(second.contains("<location ref=\"H1\" firstHeaderRow=\"0\" firstDataRow=\"0\" firstDataCol=\"0\"/>"))
        #expect(second.contains("<pivotField axis=\"axisRow\" compact=\"0\" outline=\"0\" showAll=\"0\" sortType=\"ascending\" defaultSubtotal=\"0\">"
            + "<items count=\"2\"><item x=\"0\"/><item x=\"1\"/></items></pivotField>"))
        #expect(second.contains("<item h=\"1\" x=\"2\"/>"))
        #expect(second.contains("<dataField name=\"COUNT of Units\" fld=\"4\" subtotal=\"countNums\" showDataAs=\"percentOfTotal\" baseField=\"0\" "
            + "baseItem=\"0\" numFmtId=\"10\"/>"))
        let relationships = try #require(try IOTestPackage.part("xl/worksheets/_rels/sheet2.xml.rels", of: data))
        #expect(relationships.contains("Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotTable\" Target=\"../pivotTables/pivotTable2.xml\""))
        let tableRelationships = try #require(try IOTestPackage.part("xl/pivotTables/_rels/pivotTable2.xml.rels", of: data))
        #expect(tableRelationships.contains("Target=\"../pivotCache/pivotCacheDefinition2.xml\""))
    }

    @Test func summariesExcelLacksBecomeTheClosest() throws {
        let pivot = PivotTable(anchor: CellAddress(a1: "A3")!, source: "Data!A1:E7", rows: [PivotGroup(sourceColumn: 0)],
                               values: [PivotValue(sourceColumn: 3, summary: .median), PivotValue(sourceColumn: 1, summary: .countUnique),
                                        PivotValue(sourceColumn: 3, summary: .median, name: "Typical")])
        let data = try SpreadsheetIO.write(Self.workbook([pivot]), activeSheet: 1, format: .xlsx)
        let table = try #require(try IOTestPackage.part("xl/pivotTables/pivotTable1.xml", of: data))
        #expect(table.contains("<dataField name=\"AVERAGE of Sales\" fld=\"3\" subtotal=\"average\""))
        #expect(table.contains("<dataField name=\"COUNTA of Product\" fld=\"1\" subtotal=\"count\""))
        let read = try IOTestPackage.read(data).workbook.sheets[1].pivotTables.first
        #expect(read?.values == [PivotValue(sourceColumn: 3, summary: .average), PivotValue(sourceColumn: 1, summary: .countA),
                                 PivotValue(sourceColumn: 3, summary: .average, name: "Typical")])
    }

    @Test func headingsStayUnique() throws {
        // Excel needs data field names unlike each other and the source's headings.
        let pivot = PivotTable(anchor: CellAddress(a1: "A3")!, source: "Data!A1:E7", rows: [PivotGroup(sourceColumn: 0)],
                               values: [PivotValue(sourceColumn: 3, name: "Sales"), PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 3)])
        let table = try IOXLSXObjectTests.part("xl/pivotTables/pivotTable1.xml", of: Self.workbook([pivot]))
        #expect(table.contains("<dataField name=\"Sales \" fld=\"3\""))
        #expect(table.contains("<dataField name=\"SUM of Sales\" fld=\"3\""))
        #expect(table.contains("<dataField name=\"SUM of Sales \" fld=\"3\""))
    }

    @Test func conditionFiltersBecomeHiddenItems() throws {
        let pivot = PivotTable(anchor: CellAddress(a1: "A3")!, source: "Data!A1:E7", rows: [PivotGroup(sourceColumn: 3)],
                               values: [PivotValue(sourceColumn: 4)],
                               filters: [PivotFilter(sourceColumn: 3, criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["95"])))])
        let read = try IOXLSXObjectTests.roundTrip(Self.workbook([pivot])).workbook.sheets[1].pivotTables.first
        #expect(read?.filters == [PivotFilter(sourceColumn: 3, criterion: FilterCriterion(hiddenValues: ["70", "80", "90"]))])
    }

    @Test func pivotsWithoutASourceAreLeftOut() throws {
        let pivot = PivotTable(anchor: CellAddress(a1: "A3")!, source: "Missing!A1:B4", rows: [PivotGroup(sourceColumn: 0)])
        let data = try SpreadsheetIO.write(Self.workbook([pivot]), activeSheet: 1, format: .xlsx)
        #expect(try ZipReader(data: data).entries.allSatisfy { !$0.path.contains("pivot") })
        #expect(try IOTestPackage.read(data).workbook.sheets[1].pivotTables.isEmpty)
    }

    // MARK: - Pivot tables from Excel

    static let excelCache = IOTestPackage.declaration
        + "<pivotCacheDefinition xmlns=\"\(IOTestPackage.mainNamespace)\" xmlns:r=\"\(IOTestPackage.relationshipNamespace)\" r:id=\"rId1\" "
        + "refreshedBy=\"Someone\" refreshedDate=\"46000.5\" createdVersion=\"6\" refreshedVersion=\"6\" minRefreshableVersion=\"3\" recordCount=\"6\">"
        + "<cacheSource type=\"worksheet\"><worksheetSource ref=\"A1:E7\" sheet=\"Data\"/></cacheSource><cacheFields count=\"5\">"
        + "<cacheField name=\"Region\" numFmtId=\"0\"><sharedItems count=\"3\"><s v=\"East\"/><s v=\"West\"/><s v=\"North\"/></sharedItems></cacheField>"
        + "<cacheField name=\"Product\" numFmtId=\"0\"><sharedItems count=\"2\"><s v=\"Apples\"/><s v=\"Pears\"/></sharedItems></cacheField>"
        + "<cacheField name=\"Month\" numFmtId=\"0\"><sharedItems count=\"3\"><s v=\"Jan\"/><s v=\"Feb\"/><s v=\"Mar\"/></sharedItems></cacheField>"
        + "<cacheField name=\"Sales\" numFmtId=\"0\"><sharedItems containsSemiMixedTypes=\"0\" containsString=\"0\" containsNumber=\"1\" "
        + "containsInteger=\"1\" minValue=\"70\" maxValue=\"120\"/></cacheField>"
        + "<cacheField name=\"Units\" numFmtId=\"0\"><sharedItems containsSemiMixedTypes=\"0\" containsString=\"0\" containsNumber=\"1\" "
        + "containsInteger=\"1\" minValue=\"7\" maxValue=\"12\"/></cacheField></cacheFields></pivotCacheDefinition>"

    static let excelTable = IOTestPackage.declaration
        + "<pivotTableDefinition xmlns=\"\(IOTestPackage.mainNamespace)\" name=\"PivotTable1\" cacheId=\"5\" applyNumberFormats=\"0\" "
        + "applyBorderFormats=\"0\" applyFontFormats=\"0\" applyPatternFormats=\"0\" applyAlignmentFormats=\"0\" applyWidthHeightFormats=\"1\" "
        + "dataCaption=\"Values\" dataOnRows=\"1\" rowGrandTotals=\"0\" updatedVersion=\"6\" minRefreshableVersion=\"3\" useAutoFormatting=\"1\" "
        + "itemPrintTitles=\"1\" createdVersion=\"6\" indent=\"0\" outline=\"1\" outlineData=\"1\" multipleFieldFilters=\"0\">"
        + "<location ref=\"A4:C9\" firstHeaderRow=\"1\" firstDataRow=\"1\" firstDataCol=\"1\" rowPageCount=\"1\" colPageCount=\"1\"/>"
        + "<pivotFields count=\"5\"><pivotField axis=\"axisRow\" showAll=\"0\" sortType=\"descending\"><items count=\"4\"><item x=\"1\"/>"
        + "<item h=\"1\" x=\"2\"/><item x=\"0\"/><item t=\"default\"/></items><autoSortScope><pivotArea dataOnly=\"0\" outline=\"0\" "
        + "fieldPosition=\"0\"><references count=\"1\"><reference field=\"4294967294\" count=\"1\" selected=\"0\"><x v=\"1\"/></reference>"
        + "</references></pivotArea></autoSortScope></pivotField><pivotField showAll=\"0\"/>"
        + "<pivotField axis=\"axisPage\" showAll=\"0\"><items count=\"4\"><item x=\"0\"/><item x=\"1\"/><item x=\"2\"/><item t=\"default\"/></items></pivotField>"
        + "<pivotField dataField=\"1\" showAll=\"0\"/><pivotField dataField=\"1\" showAll=\"0\"/></pivotFields>"
        + "<rowFields count=\"2\"><field x=\"0\"/><field x=\"-2\"/></rowFields><rowItems count=\"2\"><i><x/></i><i r=\"1\" i=\"1\"><x v=\"1\"/></i></rowItems>"
        + "<colItems count=\"1\"><i/></colItems><pageFields count=\"1\"><pageField fld=\"2\" item=\"1\" hier=\"-1\"/></pageFields>"
        + "<dataFields count=\"2\"><dataField name=\"Sum of Sales\" fld=\"3\" baseField=\"0\" baseItem=\"0\"/>"
        + "<dataField name=\"Average of Units\" fld=\"4\" subtotal=\"average\" baseField=\"0\" baseItem=\"0\" numFmtId=\"2\"/></dataFields>"
        + "<pivotTableStyleInfo name=\"PivotStyleLight16\" showRowHeaders=\"1\" showColHeaders=\"1\" showRowStripes=\"0\" showColStripes=\"0\" "
        + "showLastColumn=\"1\"/></pivotTableDefinition>"

    static func excelPackage(cache: String = excelCache, table: String = excelTable, tableRelationships: Bool = true) throws -> Data {
        let data = dataSheet()
        var rows = ""
        for row in 0..<7 {
            rows += "<row r=\"\(row + 1)\">"
            for column in 0..<5 {
                let reference = CellAddress(row: row, column: column).a1
                switch data[row, column].value {
                case .text(let text): rows += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
                case .number(let number): rows += "<c r=\"\(reference)\"><v>\(XLSXValue.string(number))</v></c>"
                default: break
                }
            }
            rows += "</row>"
        }
        let report = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Title</t></is></c></row>"
            + "<row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>Month</t></is></c><c r=\"B2\" t=\"inlineStr\"><is><t>Feb</t></is></c></row>"
            + "<row r=\"4\"><c r=\"A4\" t=\"inlineStr\"><is><t>Row Labels</t></is></c></row>"
            + "<row r=\"5\"><c r=\"A5\" t=\"inlineStr\"><is><t>West</t></is></c><c r=\"B5\"><v>80</v></c></row>"
            + "<row r=\"12\"><c r=\"A12\" t=\"inlineStr\"><is><t>below</t></is></c></row></sheetData>"
        var parts = ["xl/pivotCache/pivotCacheDefinition1.xml": cache, "xl/pivotTables/pivotTable1.xml": table]
        if tableRelationships {
            parts["xl/pivotTables/_rels/pivotTable1.xml.rels"] = IOTestPackage.relationships([("rId1", "pivotCacheDefinition",
                                                                                              "../pivotCache/pivotCacheDefinition1.xml")])
        }
        return try IOTestPackage.xlsx(sheets: [
            IOTestPackage.SheetPart("Data", "<sheetData>\(rows)</sheetData>"),
            IOTestPackage.SheetPart("Report", report, relationships: [("pivotTable", "../pivotTables/pivotTable1.xml")]),
        ], workbookSuffix: "<pivotCaches><pivotCache cacheId=\"5\" r:id=\"rId200\"/></pivotCaches>",
           workbookRelationships: [("pivotCacheDefinition", "pivotCache/pivotCacheDefinition1.xml")], parts: parts)
    }

    @Test func excelPivotTablesAreRead() throws {
        for tableRelationships in [true, false] {
            let file = try IOTestPackage.read(try Self.excelPackage(tableRelationships: tableRelationships))
            #expect(file.warnings.isEmpty)
            let report = file.workbook.sheets[1]
            let expected = PivotTable(anchor: CellAddress(a1: "A4")!, source: "Data!A1:E7",
                                      rows: [PivotGroup(sourceColumn: 0, ascending: false, showsTotals: false, sortByValue: 1)],
                                      values: [PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 4, summary: .average)],
                                      filters: [PivotFilter(sourceColumn: 2, criterion: FilterCriterion(hiddenValues: ["Jan", "Mar"])),
                                                PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["North"]))],
                                      valuesInRows: true)
            #expect(Self.same(report.pivotTables.first, expected), "\(tableRelationships)")
            // The table's results and its report filter are cleared; the rest of the sheet stays.
            #expect(report.cells(in: CellRange(a1: "A2:C9")!).isEmpty)
            #expect(report[0, 0].value == .text("Title") && report[11, 0].value == .text("below"))
        }
    }

    @Test func excelPivotTablesPuggleSheetsCannotKeep() throws {
        // A calculated field: the pivot table is left as it was stored, with a warning.
        let calculated = Self.excelCache.replacingOccurrences(of: "</cacheFields>", with:
            "<cacheField name=\"Bonus\" numFmtId=\"0\" formula=\"Sales*0.1\" databaseField=\"0\"/></cacheFields>")
        var file = try IOTestPackage.read(try Self.excelPackage(cache: calculated))
        #expect(file.warnings == [.pivotTables])
        #expect(file.workbook.sheets[1].pivotTables.isEmpty)
        #expect(file.workbook.sheets[1][4, 1].value == .number(80))
        // Several consolidation ranges.
        let consolidation = Self.excelCache.replacingOccurrences(of: "<cacheSource type=\"worksheet\"><worksheetSource ref=\"A1:E7\" sheet=\"Data\"/></cacheSource>",
                                                                 with: "<cacheSource type=\"consolidation\"><consolidation/></cacheSource>")
        file = try IOTestPackage.read(try Self.excelPackage(cache: consolidation))
        #expect(file.warnings == [.pivotTables] && file.workbook.sheets[1].pivotTables.isEmpty)
        // "Difference from" has no counterpart: the value is kept as a plain one.
        let difference = Self.excelTable.replacingOccurrences(of: "subtotal=\"average\" baseField=\"0\"", with: "subtotal=\"average\" showDataAs=\"difference\" baseField=\"0\"")
        file = try IOTestPackage.read(try Self.excelPackage(table: difference))
        #expect(file.warnings == [.pivotTables])
        #expect(file.workbook.sheets[1].pivotTables.first?.values.last == PivotValue(sourceColumn: 4, summary: .average))
        // A missing cache.
        file = try IOTestPackage.read(try Self.excelPackage(table: Self.excelTable.replacingOccurrences(of: "cacheId=\"5\"", with: "cacheId=\"9\""),
                                                            tableRelationships: false))
        #expect(file.warnings == [.pivotTables] && file.workbook.sheets[1].pivotTables.isEmpty)
    }

    @Test func damagedPivotPartsOnlyWarn() throws {
        var random = IOTestRandom(seed: 21)
        for _ in 0..<120 {
            var cache = Array(Self.excelCache.unicodeScalars), table = Array(Self.excelTable.unicodeScalars)
            for _ in 0..<2 {
                if random.next() % 2 == 0 {
                    let position = Int(random.next() % UInt64(cache.count))
                    cache.removeSubrange(position..<min(cache.count, position + Int(random.next() % 40)))
                } else {
                    let position = Int(random.next() % UInt64(table.count))
                    table.removeSubrange(position..<min(table.count, position + Int(random.next() % 40)))
                }
            }
            let file = try IOTestPackage.read(try Self.excelPackage(cache: String(String.UnicodeScalarView(cache)),
                                                                   table: String(String.UnicodeScalarView(table))))
            #expect(file.workbook.sheets[0][0, 0].value == .text("Region"))
        }
    }
}
