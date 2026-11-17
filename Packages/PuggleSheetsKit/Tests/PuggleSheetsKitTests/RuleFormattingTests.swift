import Foundation
import Testing
@testable import PuggleSheetsKit

struct RuleFormattingTests {
    private let red = RGBColor(red: 255, green: 0, blue: 0)
    private let yellow = RGBColor(red: 255, green: 255, blue: 0)
    private let green = RGBColor(red: 0, green: 128, blue: 0)

    private func formats(_ book: TestBook, _ range: String) -> [CellAddress: ConditionalFormat] {
        RuleEvaluator.conditionalFormats(in: CellRange(a1: range)!, sheetIndex: 0, workbook: book.workbook, now: ruleNow)
    }

    @Test func earlierRulesWinEachPart() {
        var book = ruleBook(["A1": 3, "A2": 7, "A3": "x", "A4": 200])
        book.workbook.sheets[0].conditionalFormats = [
            ConditionalFormatRule(ranges: [CellRange(a1: "A1:A5")!],
                                  style: .condition(CellCondition(.greaterThan, ["5"]), ConditionalFormat(bold: true, textColor: red))),
            ConditionalFormatRule(ranges: [CellRange(a1: "A1:A5")!],
                                  style: .condition(CellCondition(.lessThan, ["100"]), ConditionalFormat(bold: false, fillColor: yellow))),
        ]
        let result = formats(book, "A1:C10")
        #expect(result[CellAddress(a1: "A2")!] == ConditionalFormat(bold: true, textColor: red, fillColor: yellow))
        #expect(result[CellAddress(a1: "A1")!] == ConditionalFormat(bold: false, fillColor: yellow))
        #expect(result[CellAddress(a1: "A5")!] == ConditionalFormat(bold: false, fillColor: yellow))
        #expect(result[CellAddress(a1: "A4")!] == ConditionalFormat(bold: true, textColor: red))
        #expect(result[CellAddress(a1: "A3")!] == nil)
        #expect(result[CellAddress(a1: "B1")!] == nil)
        #expect(formats(book, "A2:A2").keys.sorted() == [CellAddress(a1: "A2")!])
        let applied = result[CellAddress(a1: "A2")!]!.applied(to: CellFormat())
        #expect(applied.bold && applied.textColor == red && applied.fillColor == yellow)
    }

    @Test func customFormulasCountFromTheFirstRangeTopLeft() {
        var book = ruleBook(["A2": 1, "A3": 5, "B2": "x", "B3": "y"])
        book.workbook.sheets[0].conditionalFormats = [
            ConditionalFormatRule(ranges: [CellRange(a1: "A2:B3")!],
                                  style: .condition(CellCondition(.customFormula, ["=$A2>2"]), ConditionalFormat(italic: true))),
        ]
        let result = formats(book, "A1:D5")
        #expect(result[CellAddress(a1: "A3")!]?.italic == true)
        #expect(result[CellAddress(a1: "B3")!]?.italic == true)
        #expect(result[CellAddress(a1: "A2")!] == nil)
        #expect(result[CellAddress(a1: "B2")!] == nil)
    }

    @Test func twoColorScale() {
        var book = ruleBook(["A1": 0, "A2": 25, "A3": 50, "A4": 75, "A5": 100, "A6": "text"])
        book.workbook.sheets[0].conditionalFormats = [
            ConditionalFormatRule(ranges: [CellRange(a1: "A1:A6")!],
                                  style: .colorScale(ColorScale(minimum: .init(kind: .minimum, color: .white),
                                                                maximum: .init(kind: .maximum, color: green)))),
        ]
        let result = formats(book, "A1:A10")
        #expect(result[CellAddress(a1: "A1")!]?.fillColor == .white)
        #expect(result[CellAddress(a1: "A5")!]?.fillColor == green)
        #expect(result[CellAddress(a1: "A3")!]?.fillColor == RGBColor(red: 128, green: 192, blue: 128))
        #expect(result[CellAddress(a1: "A6")!] == nil)
        #expect(result[CellAddress(a1: "A7")!] == nil)
    }

    @Test func colorScalePoints() {
        var book = ruleBook(["A1": 0, "A2": 10, "A3": 20, "A4": 30, "A5": 100])
        func fill(_ scale: ColorScale, _ a1: String) -> RGBColor? {
            book.workbook.sheets[0].conditionalFormats = [ConditionalFormatRule(ranges: [CellRange(a1: "A1:A5")!], style: .colorScale(scale))]
            return formats(book, "A1:A5")[CellAddress(a1: a1)!]?.fillColor
        }
        let numbers = ColorScale(minimum: .init(kind: .number, value: "0", color: .black),
                                 maximum: .init(kind: .number, value: "200", color: .white))
        #expect(fill(numbers, "A5") == RGBColor(red: 128, green: 128, blue: 128))
        let percents = ColorScale(minimum: .init(kind: .percent, value: "50", color: .black),
                                  maximum: .init(kind: .maximum, color: .white))
        #expect(fill(percents, "A4") == .black)
        #expect(fill(percents, "A5") == .white)
        let percentiles = ColorScale(minimum: .init(kind: .minimum, color: .black),
                                     midpoint: .init(kind: .percentile, value: "50", color: red),
                                     maximum: .init(kind: .maximum, color: .white))
        #expect(fill(percentiles, "A3") == red)
        #expect(fill(percentiles, "A2") == RGBColor(red: 128, green: 0, blue: 0))
        let formulas = ColorScale(minimum: .init(kind: .number, value: "=MIN(A1:A5)", color: .black),
                                  maximum: .init(kind: .number, value: "=A3", color: .white))
        #expect(fill(formulas, "A2") == RGBColor(red: 128, green: 128, blue: 128))
        #expect(fill(formulas, "A5") == .white)
    }

    @Test func colorScalesDontOverrideEarlierFills() {
        var book = ruleBook(["A1": 1, "A2": 2])
        book.workbook.sheets[0].conditionalFormats = [
            ConditionalFormatRule(ranges: [CellRange(a1: "A1")!],
                                  style: .condition(CellCondition(.isNotEmpty), ConditionalFormat(bold: true, fillColor: red))),
            ConditionalFormatRule(ranges: [CellRange(a1: "A1:A2")!],
                                  style: .colorScale(ColorScale(minimum: .init(kind: .minimum, color: .white),
                                                                maximum: .init(kind: .maximum, color: green)))),
        ]
        let result = formats(book, "A1:A2")
        #expect(result[CellAddress(a1: "A1")!] == ConditionalFormat(bold: true, fillColor: red))
        #expect(result[CellAddress(a1: "A2")!]?.fillColor == green)
    }

    @Test func performance() {
        var sheet = Sheet(name: "Sheet1", rowCount: 100_000, columnCount: 4)
        for row in 0..<50_000 { sheet[row, 0] = Cell(value: .number(Double(row % 97))) }
        let all = CellRange(a1: "A1:A100000")!
        sheet.conditionalFormats = [
            ConditionalFormatRule(ranges: [all], style: .condition(CellCondition(.greaterThan, ["50"]), ConditionalFormat(bold: true))),
            ConditionalFormatRule(ranges: [all], style: .condition(CellCondition(.customFormula, ["=MOD(A1, 2)=0"]),
                                                                   ConditionalFormat(italic: true))),
            ConditionalFormatRule(ranges: [all], style: .colorScale(ColorScale(minimum: .init(kind: .minimum, color: .white),
                                                                                midpoint: .init(kind: .percentile, value: "50", color: red),
                                                                                maximum: .init(kind: .maximum, color: green)))),
        ]
        let workbook = Workbook(sheets: [sheet])
        let visible = CellRange(rows: 20_000...20_499, columns: 0...3)
        var result: [CellAddress: ConditionalFormat] = [:]
        let elapsed = ContinuousClock().measure {
            result = RuleEvaluator.conditionalFormats(in: visible, sheetIndex: 0, workbook: workbook, now: ruleNow)
        }
        print("conditionalFormats over 100,000-cell rules, 2,000 visible cells: \(elapsed)")
        #expect(result.count == 500)
        #expect(result[CellAddress(row: 20_001, column: 0)]?.fillColor != nil)
        #if DEBUG
        #expect(elapsed < .seconds(2))
        #else
        #expect(elapsed < .milliseconds(100))
        #endif
    }
}
