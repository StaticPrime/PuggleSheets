import Foundation
import Testing
@testable import PuggleSheetsKit

/// Phase 3's model: images, objects over the grid, links, charts, pivot tables and filter views.
struct ObjectModelTests {
    static func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    static func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    @Test func imageHeaders() {
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
        png += [0, 0, 0x01, 0x2C, 0, 0, 0, 0xC8] + [8, 6, 0, 0, 0]
        let image = ImageData(data: Data(png))
        #expect(image?.format == .png && image?.pixelWidth == 300 && image?.pixelHeight == 200)

        let gif = Data(Array("GIF89a".utf8) + [0x40, 0x01, 0xF0, 0x00] + [0, 0, 0])
        #expect(ImageData(data: gif).map { ($0.format, $0.pixelWidth, $0.pixelHeight) } ?? (.png, 0, 0) == (.gif, 320, 240))

        // SOI, an APP0 segment, then a baseline start-of-frame holding 480 × 640.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x80, 0x01, 0xE0, 0x03] + Array(repeating: 0, count: 12))
        #expect(ImageData(data: jpeg).map { ($0.format, $0.pixelWidth, $0.pixelHeight) } ?? (.png, 0, 0) == (.jpeg, 480, 640))

        #expect(ImageData(data: Data("hello".utf8)) == nil)
    }

    @Test func resolvingReferences() {
        var data = Sheet(name: "My data", rowCount: 100, columnCount: 10)
        data[0, 0] = Cell(value: .text("x"))
        let workbook = Workbook(sheets: [Sheet(name: "Sheet1"), data], namedRanges: [NamedRange(name: "Sales", reference: "'My data'!$B$2:$B$9")])
        #expect(workbook.resolve("B2:D10", onSheet: 0)! == (0, Self.range("B2:D10")))
        #expect(workbook.resolve("'My data'!$A$1:$C$5", onSheet: 0)! == (1, Self.range("A1:C5")))
        #expect(workbook.resolve("'My data'!A:C", onSheet: 0)! == (1, Self.range("A1:C100")))
        #expect(workbook.resolve("'My data'!2:5", onSheet: 0)! == (1, Self.range("A2:J5")))
        #expect(workbook.resolve("'My data'!B3:B", onSheet: 0)! == (1, Self.range("B3:B100")))
        #expect(workbook.resolve("Sales", onSheet: 0)! == (1, Self.range("B2:B9")))
        #expect(workbook.resolve("=C4", onSheet: 1)! == (1, Self.range("C4")))
        #expect(workbook.resolve("Nowhere!A1", onSheet: 0) == nil)
        #expect(workbook.resolve("#REF!", onSheet: 0) == nil)
    }

    @Test func linksAndImagesInCells() {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .text("Docs"), link: "https://example.com/docs")
        sheet[1, 0] = Cell(value: .text("www.example.com"))
        sheet[2, 0] = Cell(value: .text("not a link"))
        sheet[3, 0] = Cell(formula: "=HYPERLINK(\"https://a.example\",\"A\")")
        sheet.formulaLinks[Self.address("A4")] = "https://a.example"
        #expect(sheet.link(at: Self.address("A1")) == "https://example.com/docs")
        #expect(sheet.link(at: Self.address("A2")) == "https://www.example.com")
        #expect(sheet.link(at: Self.address("A3")) == nil)
        #expect(sheet.link(at: Self.address("A4")) == "https://a.example")

        let image = CellImage(image: ImageData(data: Data([1, 2, 3]), format: .png, pixelWidth: 10, pixelHeight: 10))
        let cell = Cell(image: image)
        #expect(cell.hasContent && !cell.isEmpty)
        #expect(!Cell(link: "https://x.example").isEmpty)

        let sheetID = UUID()
        let target = LinkTarget.sheet(sheetID, Self.range("B2:C3"))
        #expect(LinkTarget(link: target.link) == target)
        #expect(LinkTarget(link: LinkTarget.namedRange("Q1 Sales").link) == .namedRange("Q1 Sales"))
        #expect(LinkTarget.normalizedURL("example.com") == "https://example.com")
        #expect(LinkTarget.normalizedURL("me@example.com") == "mailto:me@example.com")
        #expect(LinkTarget.detectedURL(in: "https://") == nil)
    }

    @Test func objectsFollowRowsAndColumns() {
        var sheet = Sheet(name: "Sheet1")
        let chart = SheetObject(anchor: ObjectAnchor(cell: Self.address("C5"), offsetX: 4, offsetY: 2, width: 600, height: 371),
                                content: .chart(ChartSpec(ranges: ["A1:B10"])))
        sheet.objects = [chart]
        sheet.applyStructuralChange(.insertRows(at: 1, count: 2))
        #expect(sheet.objects[0].anchor.cell == Self.address("C7"))
        sheet.applyStructuralChange(.deleteColumns(at: 0, count: 1))
        #expect(sheet.objects[0].anchor.cell == Self.address("B7"))
        // Deleting the anchor's row leaves the object at the deletion point.
        sheet.applyStructuralChange(.deleteRows(at: 5, count: 3))
        #expect(sheet.objects[0].anchor.cell == Self.address("B6"))
        #expect(sheet.objects[0].anchor.offsetX == 4 && sheet.objects[0].anchor.width == 600)
    }

    @Test func chartsAndPivotTablesFollowEdits() {
        var data = Sheet(name: "Data")
        for row in 0..<5 { for column in 0..<4 { data[row, column] = Cell(value: .number(Double(row * 4 + column))) } }
        var report = Sheet(name: "Report")
        report.objects = [SheetObject(anchor: ObjectAnchor(cell: Self.address("A1"), width: 400, height: 300),
                                      content: .chart(ChartSpec(ranges: ["Data!A1:C5"])))]
        report.pivotTables = [PivotTable(anchor: Self.address("B2"), source: "Data!A1:D5",
                                         rows: [PivotGroup(sourceColumn: 0)], columns: [PivotGroup(sourceColumn: 3, sortByValue: 1)],
                                         values: [PivotValue(sourceColumn: 1), PivotValue(sourceColumn: 2, summary: .average)],
                                         filters: [PivotFilter(sourceColumn: 2)])]
        var workbook = Workbook(sheets: [data, report])

        workbook.renameSheet(at: 0, to: "Raw data")
        #expect(workbook.sheets[1].objects[0].chart?.ranges == ["'Raw data'!A1:C5"])
        #expect(workbook.sheets[1].pivotTables[0].source == "'Raw data'!A1:D5")

        // A column inserted inside the source shifts the pivot table's columns after it.
        workbook.apply(.insertColumns(at: 1, count: 1), toSheet: 0)
        var pivot = workbook.sheets[1].pivotTables[0]
        #expect(pivot.source == "'Raw data'!A1:E5")
        #expect(pivot.rows.map(\.sourceColumn) == [0] && pivot.columns.map(\.sourceColumn) == [4])
        #expect(pivot.values.map(\.sourceColumn) == [2, 3] && pivot.filters.map(\.sourceColumn) == [3])
        #expect(workbook.sheets[1].objects[0].chart?.ranges == ["'Raw data'!A1:D5"])

        // Deleting a value's column removes that value and keeps "Sort by" pointing at the right one.
        workbook.apply(.deleteColumns(at: 2, count: 1), toSheet: 0)
        pivot = workbook.sheets[1].pivotTables[0]
        #expect(pivot.values.map(\.sourceColumn) == [2] && pivot.values[0].summary == .average)
        #expect(pivot.columns[0].sourceColumn == 3 && pivot.columns[0].sortByValue == 0)

        // The pivot table moves with its anchor and goes when the anchor is deleted.
        workbook.apply(.insertRows(at: 0, count: 1), toSheet: 1)
        #expect(workbook.sheets[1].pivotTables[0].anchor == Self.address("B3"))
        workbook.apply(.deleteRows(at: 2, count: 1), toSheet: 1)
        #expect(workbook.sheets[1].pivotTables.isEmpty)
    }

    @Test func filterViewsFollowEdits() {
        var sheet = Sheet(name: "Sheet1")
        sheet.filterViews = [FilterView(name: "Filter 1", range: Self.range("A1:D20"),
                                        criteria: [2: FilterCriterion(condition: CellCondition(.customFormula, ["=C2>B$1"]))])]
        var workbook = Workbook(sheets: [sheet])
        workbook.apply(.insertColumns(at: 0, count: 1), toSheet: 0)
        let view = workbook.sheets[0].filterViews[0]
        #expect(view.range == Self.range("B1:E20"))
        #expect(view.criteria[3]?.condition?.values == ["=D2>C$1"])
        workbook.apply(.deleteColumns(at: 0, count: 6), toSheet: 0)
        #expect(workbook.sheets[0].filterViews.isEmpty)
    }
}
