import Foundation
import Testing
@testable import PuggleSheetsKit

/// Insert ▸ Chart's first guess.
struct ChartSuggestionTests {
    func suggest(_ a1: String, _ book: Workbook) -> ChartSpec {
        ChartBuilder.suggestedSpec(for: CellRange(a1: a1)!, sheetIndex: 0, workbook: book)
    }

    @Test func textLabelsMakeAColumnChart() {
        let book = ChartFixtures.book([
            "A1": .text("Task"), "B1": .text("Estimate"),
            "A2": .text("Design"), "B2": .number(5),
            "A3": .text("Build"), "B3": .number(13),
            "A4": .text("Test"), "B4": .number(8),
        ])
        let spec = suggest("A1:B4", book)
        #expect(spec.kind == .column)
        #expect(spec.ranges == ["A1:B4"])
        #expect(spec.firstRowIsHeader && spec.firstColumnIsLabels)
        #expect(spec.title == "Estimate vs. Task")
        #expect(spec.horizontalAxisTitle == "Task" && spec.verticalAxisTitle == "Estimate")
        #expect(spec.legend == .auto)
    }

    @Test func datesMakeALineChart() {
        let start = DateSerial.serial(year: 2026, month: 3, day: 1)
        var cells: [String: CellValue] = ["A1": .text("Date"), "B1": .text("Visitors"), "C1": .text("Signups")]
        var formats: [String: String] = [:]
        for row in 2...6 {
            cells["A\(row)"] = .number(start + Double(row))
            formats["A\(row)"] = "M/d/yyyy"
            cells["B\(row)"] = .number(Double(row * 10))
            cells["C\(row)"] = .number(Double(row))
        }
        let spec = suggest("A1:C6", ChartFixtures.book(cells, formats: formats))
        #expect(spec.kind == .line)
        #expect(spec.firstRowIsHeader && spec.firstColumnIsLabels)
        #expect(spec.title == "Visitors and Signups")
        #expect(spec.horizontalAxisTitle == "Date" && spec.verticalAxisTitle == "")
    }

    @Test func numbersAgainstNumbersMakeAScatterChart() {
        var cells: [String: CellValue] = ["A1": .text("Height"), "B1": .text("Weight")]
        for (row, height) in [170.0, 160, 182, 175, 165].enumerated() {
            cells["A\(row + 2)"] = .number(height)
            cells["B\(row + 2)"] = .number(height / 2.5)
        }
        let spec = suggest("A1:B6", ChartFixtures.book(cells))
        #expect(spec.kind == .scatter)
        #expect(spec.firstRowIsHeader && spec.firstColumnIsLabels)
        #expect(spec.title == "Weight vs. Height")
        #expect(spec.horizontalAxisTitle == "Height")
    }

    @Test func orderedNumbersWithManyRowsMakeALineChart() {
        var cells: [String: CellValue] = ["A1": .text("Year"), "B1": .text("Revenue")]
        for row in 2...13 {
            cells["A\(row)"] = .number(Double(2010 + row))
            cells["B\(row)"] = .number(Double(row * row))
        }
        #expect(suggest("A1:B13", ChartFixtures.book(cells)).kind == .line)
        // A few ordered years are still a scatter chart.
        #expect(suggest("A1:B5", ChartFixtures.book(cells)).kind == .scatter)
    }

    @Test func titlesNameUpToThreeSeries() {
        #expect(ChartBuilder.defaultTitle(seriesNames: ["Sales"], labelHeading: "Month") == "Sales vs. Month")
        #expect(ChartBuilder.defaultTitle(seriesNames: ["Sales"], labelHeading: "") == "Sales")
        #expect(ChartBuilder.defaultTitle(seriesNames: ["Sales", "Costs"], labelHeading: "Month") == "Sales and Costs")
        #expect(ChartBuilder.defaultTitle(seriesNames: ["Sales", "Costs", "Profit"], labelHeading: "Month") == "Sales, Costs and Profit")
        #expect(ChartBuilder.defaultTitle(seriesNames: ["A", "B", "C", "D"], labelHeading: "Month") == "")
        #expect(ChartBuilder.defaultTitle(seriesNames: [], labelHeading: "Month") == "")
    }

    @Test func plainNumbersHaveNoHeaderOrLabels() {
        let book = ChartFixtures.book(["A1": .number(3), "A2": .number(1), "A3": .number(4), "A4": .number(1)])
        let spec = suggest("A1:A4", book)
        #expect(spec.kind == .column)
        #expect(!spec.firstRowIsHeader && !spec.firstColumnIsLabels)
        #expect(spec.title.isEmpty && spec.horizontalAxisTitle.isEmpty)
        // Numbers on top aren't a header.
        let years = ChartFixtures.book(["A1": .number(2024), "B1": .number(2025), "A2": .number(5), "B2": .number(6)])
        #expect(!suggest("A1:B2", years).firstRowIsHeader)
    }

    @Test func aSingleCellGrowsToItsBlock() {
        let book = ChartFixtures.book([
            "B2": .text("Region"), "C2": .text("Units"),
            "B3": .text("North"), "C3": .number(10),
            "B4": .text("South"), "C4": .number(12),
            "B5": .text("East"), "C5": .number(7),
            "E9": .text("unrelated"),
        ])
        let spec = suggest("C3", book)
        #expect(spec.ranges == ["B2:C5"])
        #expect(spec.firstRowIsHeader && spec.firstColumnIsLabels)
        #expect(spec.title == "Units vs. Region")
        // Whole columns shrink to the data in them.
        #expect(suggest("B1:C1000", book).ranges == ["B2:C5"])
        // An empty selection stays as it is.
        #expect(suggest("H1:H3", book).ranges == ["H1:H3"])
    }
}
