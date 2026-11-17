import Foundation
import Testing
@testable import PuggleSheetsKit

/// Reading charts' data: the rules Excel and OpenDocument import and export share.
struct ChartTableTests {
    static let months: [String: CellValue] = [
        "A1": .text("Month"), "B1": .text("Sales"), "C1": .text("Costs"),
        "A2": .text("Jan"), "B2": .number(10), "C2": .number(4),
        "A3": .text("Feb"), "B3": .number(20), "C3": .number(5),
        "A4": .text("Mar"), "C4": .text("n/a"),
    ]

    func table(_ spec: ChartSpec, _ workbook: Workbook, sheet: Int = 0) -> ChartTable {
        ChartBuilder.table(for: spec, sheetIndex: sheet, workbook: workbook)
    }

    @Test func headerRowAndLabelColumn() {
        let result = table(ChartSpec(ranges: ["A1:C4"]), ChartFixtures.book(Self.months))
        #expect(result.labels == ["Jan", "Feb", "Mar"])
        #expect(result.labelValues == [nil, nil, nil])
        #expect(result.labelHeading == "Month")
        #expect(result.series.map(\.name) == ["Sales", "Costs"])
        #expect(result.series[0].values == [10, 20, nil])
        #expect(result.series[1].values == [4, 5, nil])
        #expect(!result.isEmpty)
    }

    @Test func withoutHeaderOrLabels() {
        let spec = ChartSpec(ranges: ["A1:C4"], firstRowIsHeader: false, firstColumnIsLabels: false)
        let result = table(spec, ChartFixtures.book(Self.months))
        #expect(result.labels == ["1", "2", "3", "4"])
        #expect(result.labelValues == [1, 2, 3, 4])
        #expect(result.labelHeading == "")
        #expect(result.series.map(\.name) == ["Series 1", "Series 2", "Series 3"])
        #expect(result.series[0].values == [nil, nil, nil, nil])
        #expect(result.series[1].values == [nil, 10, 20, nil])
        #expect(result.series[2].values == [nil, 4, 5, nil])

        // A header row without labels names every column; a label column without a header names none.
        let named = table(ChartSpec(ranges: ["B1:C4"], firstColumnIsLabels: false), ChartFixtures.book(Self.months))
        #expect(named.series.map(\.name) == ["Sales", "Costs"] && named.labels == ["1", "2", "3"])
        let unnamed = table(ChartSpec(ranges: ["A2:C4"], firstRowIsHeader: false), ChartFixtures.book(Self.months))
        #expect(unnamed.series.map(\.name) == ["Series 1", "Series 2"] && unnamed.labels == ["Jan", "Feb", "Mar"])
    }

    @Test func switchingRowsAndColumns() {
        let book = ChartFixtures.book([
            "B1": .text("Q1"), "C1": .text("Q2"), "D1": .text("Q3"),
            "A2": .text("North"), "B2": .number(1), "C2": .number(2), "D2": .number(3),
            "A3": .text("South"), "B3": .number(4), "C3": .number(5), "D3": .number(6),
        ])
        let byRow = table(ChartSpec(ranges: ["A1:D3"], switchRowsAndColumns: true), book)
        #expect(byRow.labels == ["Q1", "Q2", "Q3"])
        #expect(byRow.series.map(\.name) == ["North", "South"])
        #expect(byRow.series.map(\.values) == [[1, 2, 3], [4, 5, 6]])
        #expect(byRow.labelHeading == "")

        let byColumn = table(ChartSpec(ranges: ["A1:D3"]), book)
        #expect(byColumn.labels == ["North", "South"])
        #expect(byColumn.series.map(\.name) == ["Q1", "Q2", "Q3"])
        #expect(byColumn.series.map(\.values) == [[1, 4], [2, 5], [3, 6]])
    }

    @Test func joiningSeveralRanges() {
        var other = ChartFixtures.sheet("Plan data", ["B1": .text("Plan"), "B2": .number(9), "B3": .number(8), "B4": .number(7), "B5": .number(6)])
        other.name = "Plan data"
        let main = ChartFixtures.sheet("Sheet1", [
            "A1": .text("Month"), "A2": .text("Jan"), "A3": .text("Feb"), "A4": .text("Mar"),
            "C1": .text("Sales"), "C2": .number(1), "C3": .number(2), "C4": .number(3),
            "E1": .text("Costs"), "E2": .number(7), "E3": .number(8),
        ])
        let book = Workbook(sheets: [main, other])
        // Side by side in order; shorter ranges are padded; references that don't resolve are skipped.
        let result = table(ChartSpec(ranges: ["A1:A4", "C1:C4", "Nowhere!A1:A4", "E1:E3", "'Plan data'!B1:B5"]), book)
        #expect(result.labels == ["Jan", "Feb", "Mar", ""])
        #expect(result.series.map(\.name) == ["Sales", "Costs", "Plan"])
        #expect(result.series[0].values == [1, 2, 3, nil])
        #expect(result.series[1].values == [7, 8, nil, nil])
        #expect(result.series[2].values == [9, 8, 7, 6])

        // From another sheet, references resolve against the chart's sheet.
        let fromSecond = table(ChartSpec(ranges: ["B1:B5"], firstColumnIsLabels: false), book, sheet: 1)
        #expect(fromSecond.series.map(\.values) == [[9, 8, 7, 6]])
    }

    @Test func namedAndOpenRanges() {
        var book = ChartFixtures.book(Self.months)
        book.namedRanges = [NamedRange(name: "Totals", reference: "Sheet1!$A$1:$B$4")]
        let named = table(ChartSpec(ranges: ["Totals"]), book)
        #expect(named.series.map(\.name) == ["Sales"] && named.series[0].values == [10, 20, nil])
        // Whole columns end at the last row with data.
        let open = table(ChartSpec(ranges: ["A:C"]), book)
        #expect(open.labels == ["Jan", "Feb", "Mar"])
        #expect(open.series.map(\.values) == [[10, 20, nil], [4, 5, nil]])
        let unresolved = table(ChartSpec(ranges: ["#REF!", "Nowhere!A1:B3", ""]), book)
        #expect(unresolved.isEmpty && unresolved.labels.isEmpty)
    }

    @Test func hiddenRowsAndColumnsAreLeftOut() {
        var sheet = ChartFixtures.sheet("Sheet1", [
            "A1": .text("Item"), "B1": .text("Hidden"), "C1": .text("Shown"),
            "A2": .text("a"), "B2": .number(1), "C2": .number(10),
            "A3": .text("b"), "B3": .number(2), "C3": .number(20),
            "A4": .text("c"), "B4": .number(3), "C4": .number(30),
            "A5": .text("d"), "B5": .number(4), "C5": .number(40),
        ])
        sheet.hiddenRows = [2]
        sheet.filteredRows = [4]
        sheet.hiddenColumns = [1]
        let result = table(ChartSpec(ranges: ["A1:C5"]), Workbook(sheets: [sheet]))
        #expect(result.labels == ["a", "c"])
        #expect(result.series.map(\.name) == ["Shown"])
        #expect(result.series[0].values == [10, 30])
        // A hidden header row: the first visible row becomes the header.
        sheet.hiddenRows = [0]
        let headless = table(ChartSpec(ranges: ["A1:C5"]), Workbook(sheets: [sheet]))
        #expect(headless.series.map(\.name) == ["10"] && headless.labels == ["b", "c"])
    }

    @Test func aggregatingRepeatedLabels() {
        let book = ChartFixtures.book([
            "A1": .text("Fruit"), "B1": .text("Sold"), "C1": .text("Returned"),
            "A2": .text("Apple"), "B2": .number(1), "C2": .number(10),
            "A3": .text("Pear"), "B3": .number(2),
            "A4": .text("Apple"), "B4": .number(3), "C4": .number(30),
            "A5": .text("Plum"), "B5": .number(4), "C5": .text("x"),
            "A6": .text("Pear"), "B6": .number(5), "C6": .number(50),
        ])
        func aggregated(_ function: ChartSpec.Aggregation) -> ChartTable {
            table(ChartSpec(ranges: ["A1:C6"], aggregation: function), book)
        }
        #expect(aggregated(.sum).labels == ["Apple", "Pear", "Plum"])
        #expect(aggregated(.sum).series.map(\.values) == [[4, 7, 4], [40, 50, nil]])
        #expect(aggregated(.average).series.map(\.values) == [[2, 3.5, 4], [20, 50, nil]])
        #expect(aggregated(.count).series.map(\.values) == [[2, 2, 1], [2, 1, 0]])
        #expect(aggregated(.max).series[0].values == [3, 5, 4])
        #expect(aggregated(.min).series[0].values == [1, 2, 4])
        #expect(aggregated(.median).series[0].values == [2, 3.5, 4])
        #expect(table(ChartSpec(ranges: ["A1:C6"]), book).labels.count == 5)
    }

    @Test func onlyNumbersAreValues() {
        let book = ChartFixtures.book([
            "A1": .text("Label"), "B1": .text("Value"),
            "A2": .text("text"), "B2": .text("12"),
            "A3": .text("bool"), "B3": .boolean(true),
            "A4": .text("error"), "B4": .error(CellError(.divideByZero)),
            "A5": .text("empty"),
            "A6": .text("number"), "B6": .number(-2.5),
        ])
        let result = table(ChartSpec(ranges: ["A1:B6"]), book)
        #expect(result.series[0].values == [nil, nil, nil, nil, -2.5])
        #expect(!result.isEmpty)
        // Numbers in the label column become label values; everything still shows as text.
        let mixed = table(ChartSpec(ranges: ["B1:B6"], firstRowIsHeader: false, firstColumnIsLabels: true),
                          ChartFixtures.book(["B1": .boolean(false), "B2": .number(3), "B3": .error(CellError(.notAvailable))]))
        #expect(mixed.labels == ["FALSE", "3", "#N/A"])
        #expect(mixed.labelValues == [nil, 3, nil])
        #expect(mixed.series.isEmpty && mixed.isEmpty)
    }

    @Test func numberFormatsShapeLabels() {
        let jan2 = DateSerial.serial(year: 2026, month: 1, day: 2), jan3 = jan2 + 1
        let book = ChartFixtures.book(
            ["A1": .text("Day"), "B1": .text("Revenue"), "C1": .text("Share"),
             "A2": .number(jan2), "B2": .text("pending"), "C2": .number(0.25),
             "A3": .number(jan3), "B3": .number(1234.5), "C3": .number(0.5)],
            formats: ["A2": "M/d/yyyy", "A3": "M/d/yyyy", "B2": "@", "B3": "\"$\"#,##0.00", "C2": "0%", "C3": "0%"])
        let result = table(ChartSpec(ranges: ["A1:C3"]), book)
        #expect(result.labels == ["1/2/2026", "1/3/2026"])
        #expect(result.labelValues == [jan2, jan3])
        #expect(result.labelFormat == "M/d/yyyy")
        // A series' format is its first number's.
        #expect(result.series[0].numberFormat == "\"$\"#,##0.00")
        #expect(result.series[1].numberFormat == "0%")
        #expect(result.series[0].values == [nil, 1234.5])
    }

    @Test func spilledValuesAreRead() {
        let book = TestBook(["A1": "Step", "B1": "Square", "A2": "=SEQUENCE(4)", "B2": "=ARRAYFORMULA(A2:A5*A2:A5)"])
        let result = table(ChartSpec(ranges: ["A1:B5"]), book.workbook)
        #expect(result.labels == ["1", "2", "3", "4"])
        #expect(result.labelValues == [1, 2, 3, 4])
        #expect(result.series.map(\.name) == ["Square"])
        #expect(result.series[0].values == [1, 4, 9, 16])
    }

    @Test func raggedTablesStillDraw() {
        // Tables built by hand may miss labels or have short series; the renderer pads them.
        let ragged = ChartTable(series: [ChartTable.Series(name: "A", values: [1, 2, 3]), ChartTable.Series(name: "B", values: [4])])
        let data = ChartData(ragged)
        #expect(data.count == 3 && data.labels == ["1", "2", "3"] && data.labelValues == [1, 2, 3])
        #expect(data.series[1].values == [4, nil, nil])
        #expect(ragged.rowCount == 3)
        #expect(ChartRenderer.svg(ChartSpec(kind: .line, ranges: []), table: ragged, size: CGSize(width: 300, height: 200)).contains("<path"))
    }
}
