import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaSparklineTests {
    private func sparkline(_ book: TestBook, _ a1: String = "Z1") -> SparklineSpec? {
        book.workbook.sheets[0].sparklines[CellAddress(a1: a1)!]
    }

    @Test func sparklinesRecordTheirData() {
        let book = TestBook(["A1": 1, "A2": "x", "A4": 3, "B1": "Charttype", "C1": "winloss", "B2": "RTL", "C2": true,
                             "Z1": "=SPARKLINE(A1:A4)",
                             "Z2": "=SPARKLINE({1,2;3,4}, {\"charttype\",\"column\";\"color\",\"red\";\"max\",100})",
                             "Z3": "=SPARKLINE({5,6,7}, {\"charttype\",\"bar\"})",
                             "Z4": "=SPARKLINE(A1:A4, B1:C2)",
                             "Z5": "=SPARKLINE(A1:A4, {\"charttype\",\"pie\"})",
                             "Z6": "=SPARKLINE({1,NA()})",
                             "Z7": "=SPARKLINE(A1:A4, {1,2,3})",
                             "Z8": "=IF(A1>0, SPARKLINE({1,2}), \"none\")"])
        #expect(book["Z1"] == .empty)
        #expect(sparkline(book) == SparklineSpec(kind: .line, values: [1, nil, nil, 3]))
        #expect(sparkline(book, "Z2") == SparklineSpec(kind: .column, values: [1, 2, 3, 4], options: ["charttype": "column", "color": "red", "max": "100"]))
        #expect(sparkline(book, "Z3") == SparklineSpec(kind: .bar, values: [5, 6], options: ["charttype": "bar"]))
        #expect(sparkline(book, "Z4") == SparklineSpec(kind: .winloss, values: [1, nil, nil, 3], options: ["charttype": "winloss", "rtl": "true"]))
        #expect(book["Z5"] == err(.value) && sparkline(book, "Z5") == nil)
        #expect(book["Z6"] == err(.notAvailable) && sparkline(book, "Z6") == nil)
        #expect(book["Z7"] == err(.value))
        #expect(sparkline(book, "Z8")?.values == [1, 2])
    }

    @Test func sparklinesFollowRecalculation() {
        var book = TestBook(["A1": 1, "A2": 2, "B1": 1, "Z1": "=IF(B1>0, SPARKLINE(A1:A2), \"off\")"])
        book.set("A2", 5)
        #expect(sparkline(book)?.values == [1, 5])
        book.set("B1", 0)
        #expect(sparkline(book) == nil && book["Z1"] == .text("off"))
        book.set("B1", 1)
        #expect(sparkline(book)?.values == [1, 5])
        book.set("Z1", 7)
        #expect(book.workbook.sheets[0].sparklines.isEmpty)
        book.set("Z1", "=SPARKLINE(A1:A2)")
        book.workbook.sheets[0].sparklines[CellAddress(a1: "Y9")!] = SparklineSpec(values: [])
        book.engine.recalculateAll(&book.workbook, now: book.now)
        #expect(Array(book.workbook.sheets[0].sparklines.keys) == [CellAddress(a1: "Z1")!])
        book.set("Z1", .empty)
        #expect(book.workbook.sheets[0].sparklines.isEmpty)
    }
}

struct FormulaSortnTests {
    private static let scores: [String: CellInput] = [
        "A1": "a", "B1": 90, "A2": "b", "B2": 80, "A3": "c", "B3": 90,
        "A4": "d", "B4": 70, "A5": "e", "B5": 80, "A6": "f", "B6": 60,
    ]

    private func names(_ formula: String) -> [String] {
        spilled(formula, Self.scores).map { pivotText($0[0]) }
    }

    @Test func tiesModes() {
        #expect(names("=SORTN(A1:B6, 2, 0, 2, FALSE)") == ["a", "c"])
        #expect(names("=SORTN(A1:B6, 3, 0, 2, FALSE)") == ["a", "c", "b"])
        #expect(names("=SORTN(A1:B6, 3, 1, 2, FALSE)") == ["a", "c", "b", "e"])
        #expect(names("=SORTN(A1:B6, 3, 2, 2, FALSE)") == ["a", "b", "d"])
        #expect(names("=SORTN(A1:B6, 2, 3, 2, FALSE)") == ["a", "c", "b", "e"])
        #expect(names("=SORTN(A1:B6)") == ["a"])
        #expect(names("=SORTN(A1:B6, 2, , 2, TRUE)") == ["f", "d"])
        #expect(names("=SORTN(A1:B6, 2, 0, B1:B6, FALSE, 1, FALSE)") == ["c", "a"])
        #expect(spilled("=SORTN(A1:B6, 1, 0, 2, FALSE)", Self.scores) == [[.text("a"), .number(90)]])
        #expect(eval("=SORTN({1;2}, 1, 4)") == err(.value))
        #expect(eval("=SORTN({1;2}, 0)") == err(.notAvailable))
        #expect(eval("=SORTN({1;2}, 1, 0, 3)") == err(.value))
    }
}

struct FormulaGetPivotDataTests {
    private func book(_ pivot: PivotTable, formulas: [String: String]) -> PivotBook {
        var sheet = pivotSheet(salesRows)
        sheet.pivotTables = [pivot]
        for (a1, formula) in formulas { sheet[CellAddress(a1: a1)!] = Cell(formula: formula) }
        return PivotBook([sheet])
    }

    @Test func valuesByRowAndColumnItems() {
        let pivot = PivotTable(anchor: CellAddress(a1: "H1")!, source: "A1:E6", rows: [PivotGroup(sourceColumn: 0)],
                               columns: [PivotGroup(sourceColumn: 2)], values: [PivotValue(sourceColumn: 3)])
        var book = book(pivot, formulas: [
            "Q1": "=GETPIVOTDATA(\"SUM of Sales\", H1, \"Region\", \"East\")",
            "Q2": "=GETPIVOTDATA(\"SUM of Sales\", H1)",
            "Q3": "=GETPIVOTDATA(\"SUM of Sales\", I3, \"Region\", \"West\", \"Product\", \"Apple\")",
            "Q4": "=GETPIVOTDATA(\"sales\", H1, \"region\", \"east\", \"PRODUCT\", \"banana\")",
            "Q5": "=GETPIVOTDATA(\"SUM of Sales\", H1, \"Product\", \"Cherry\")",
            "Q6": "=GETPIVOTDATA(\"SUM of Sales\", H1, \"Region\", \"North\")",
            "Q7": "=GETPIVOTDATA(\"SUM of Sales\", H1, \"Rep\", \"Alice\")",
            "Q8": "=GETPIVOTDATA(\"SUM of Sales\", A1)",
            "Q9": "=GETPIVOTDATA(\"SUM of Sales\", H1, \"Region\")",
            "Q10": "=GETPIVOTDATA(\"COUNT of Sales\", H1)",
        ])
        #expect(book.block("Q1:Q5") == [["37"], ["43"], ["5"], ["27"], ["1"]])
        for a1 in ["Q6", "Q7", "Q8", "Q10"] { #expect(book.shown(a1) == err(.reference), "\(a1)") }
        #expect(book.shown("Q9") == err(.notAvailable))
        #expect(message(book.shown("Q6")) == "GETPIVOTDATA couldn't find that combination of items in the pivot table.")
        // The values follow the pivot table.
        book.set(["D2": 100])
        #expect(book.block("Q1:Q3") == [["127"], ["133"], ["5"]])
        book.expectMatchesFull("source edited")
        book.editPivots { $0[0].values[0].summary = .max }
        #expect(book.shown("Q1") == err(.reference))
        book.set(["Q1": .formula("=GETPIVOTDATA(\"MAX of Sales\", H1, \"Region\", \"East\")")])
        #expect(book.shown("Q1") == .number(100))
        book.expectMatchesFull("pivot edited")
    }

    @Test func nestedGroupsAndStandaloneEvaluation() {
        let pivot = PivotTable(anchor: CellAddress(a1: "H1")!, source: "A1:E6", rows: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 1)],
                               values: [PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 4, summary: .countA)])
        let book = book(pivot, formulas: [
            "Q1": "=GETPIVOTDATA(\"SUM of Sales\", H1, \"Rep\", \"Alice\")",
            "Q2": "=GETPIVOTDATA(\"SUM of Sales\", H1, \"Region\", \"East\")",
            "Q3": "=GETPIVOTDATA(\"COUNTA of Units\", H1, \"Region\", \"West\", \"Rep\", \"Dan\")",
        ])
        #expect(book.block("Q1:Q3") == [["17"], ["37"], ["1"]])
        let standalone = FormulaEngine.evaluate("=GETPIVOTDATA(\"SUM of Sales\", I2, \"Region\", \"West\")", inSheet: 0,
                                                at: CellAddress(a1: "Z1")!, workbook: book.workbook)
        #expect(standalone == .number(6))
    }
}
