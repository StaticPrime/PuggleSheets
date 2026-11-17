import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaSpillTests {
    private func spilled(_ book: TestBook, _ a1: String, sheet: Int = 0) -> CellValue? {
        book.workbook.sheets[sheet].spilledValues[CellAddress(a1: a1)!]
    }

    private func spillRange(_ book: TestBook, _ a1: String, sheet: Int = 0) -> CellRange? {
        book.workbook.sheets[sheet].spillRanges[CellAddress(a1: a1)!]
    }

    /// The value a cell shows, spilled values included.
    private func shown(_ book: TestBook, _ a1: String, sheet: Int = 0) -> CellValue {
        book.workbook.sheets[sheet].value(at: CellAddress(a1: a1)!)
    }

    @Test func arraysSpillIntoNeighboringCells() {
        let book = TestBook(["A1": "=SEQUENCE(3)", "B2": "={1,2;3,4}", "E1": 7, "E2": 8, "F1": "x", "H1": "=E1:F2"])
        #expect(book["A1"] == .number(1))
        #expect(spilled(book, "A2") == .number(2))
        #expect(spilled(book, "A3") == .number(3))
        #expect(spilled(book, "A1") == nil)
        #expect(spillRange(book, "A1") == CellRange(a1: "A1:A3"))
        #expect(book["B2"] == .number(1))
        #expect(shown(book, "C2") == .number(2))
        #expect(shown(book, "B3") == .number(3))
        #expect(shown(book, "C3") == .number(4))
        #expect(spillRange(book, "B2") == CellRange(a1: "B2:C3"))
        #expect(book["H1"] == .number(7))
        #expect(shown(book, "I1") == .text("x"))
        #expect(shown(book, "H2") == .number(8))
        #expect(spilled(book, "I2") == .empty)
        #expect(book.workbook.sheets[0].spillSource(of: CellAddress(a1: "I2")!) == CellAddress(a1: "H1"))
    }

    @Test func arrayFunctionsSpill() {
        let cells: [String: CellInput] = ["A1": 3, "A2": 1, "A3": 2, "A4": 1, "B1": "c", "B2": "a", "B3": "b", "B4": "a",
                                          "D1": "=SORT(A1:A4)", "E1": "=UNIQUE(B1:B4)", "F1": "=FILTER(B1:B4, A1:A4>1)",
                                          "G1": "=TRANSPOSE(A1:A3)", "G3": "=SPLIT(\"x,y,z\", \",\")",
                                          "G5": "=ARRAYFORMULA(A1:A2*10)"]
        let book = TestBook(cells)
        #expect([book["D1"], shown(book, "D2"), shown(book, "D3"), shown(book, "D4")] == [.number(1), .number(1), .number(2), .number(3)])
        #expect([book["E1"], shown(book, "E2"), shown(book, "E3"), shown(book, "E4")] == [.text("c"), .text("a"), .text("b"), .empty])
        #expect(spillRange(book, "E1") == CellRange(a1: "E1:E3"))
        #expect([book["F1"], shown(book, "F2")] == [.text("c"), .text("b")])
        #expect([book["G1"], shown(book, "H1"), shown(book, "I1")] == [.number(3), .number(1), .number(2)])
        #expect([book["G3"], shown(book, "H3"), shown(book, "I3")] == [.text("x"), .text("y"), .text("z")])
        #expect([book["G5"], shown(book, "G6")] == [.number(30), .number(10)])
    }

    @Test func contentBlocksTheSpill() {
        var book = TestBook(["A1": "=SEQUENCE(3)", "A3": "x"])
        #expect(book["A1"] == err(.reference))
        #expect(message(book["A1"]) == "Array result was not expanded because it would overwrite data in A3.")
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
        #expect(book.workbook.sheets[0].spillRanges.isEmpty)
        book.set("A3", .empty)
        #expect(book["A1"] == .number(1))
        #expect(shown(book, "A3") == .number(3))
        book.set("A2", 5)
        #expect(book["A1"] == err(.reference))
        #expect(message(book["A1"]) == "Array result was not expanded because it would overwrite data in A2.")
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
        #expect(book["A2"] == .number(5))
        book.set("A2", "=1+1")
        #expect(book["A1"] == err(.reference))
        book.set("A2", .empty)
        #expect(shown(book, "A2") == .number(2))
        #expect(spillRange(book, "A1") == CellRange(a1: "A1:A3"))
    }

    @Test func formattingDoesntBlock() {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(formula: "=SEQUENCE(2)")
        var bold = CellFormat()
        bold.bold = true
        sheet[1, 0] = Cell(format: bold)
        var workbook = Workbook(sheets: [sheet])
        FormulaEngine().recalculateAll(&workbook)
        #expect(workbook.sheets[0].value(at: CellAddress(row: 1, column: 0)) == .number(2))
    }

    @Test func spillsResizeAndReadersFollow() {
        var book = TestBook(["B1": 3, "A1": "=SEQUENCE(B1)", "C1": "=A2*10", "C2": "=SUM(A1:A10)", "C3": "=SUM(A2:A10)",
                             "C4": "=COUNT(A:A)", "C5": "=A5"])
        #expect(spillRange(book, "A1") == CellRange(a1: "A1:A3"))
        #expect(book["C1"] == .number(20))
        #expect(book["C2"] == .number(6))
        #expect(book["C3"] == .number(5))
        #expect(book["C4"] == .number(3))
        #expect(book["C5"] == .empty)
        book.set("B1", 5)
        #expect(spillRange(book, "A1") == CellRange(a1: "A1:A5"))
        #expect(shown(book, "A5") == .number(5))
        #expect(book["C2"] == .number(15))
        #expect(book["C3"] == .number(14))
        #expect(book["C4"] == .number(5))
        #expect(book["C5"] == .number(5))
        book.set("B1", 2)
        #expect(spillRange(book, "A1") == CellRange(a1: "A1:A2"))
        #expect(spilled(book, "A3") == nil)
        #expect(spilled(book, "A5") == nil)
        #expect(book.workbook.sheets[0].spilledValues.count == 1)
        #expect(book["C3"] == .number(2))
        #expect(book["C5"] == .empty)
        book.set("B1", 1)
        #expect(book.workbook.sheets[0].spillRanges.isEmpty)
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
        #expect(book["C1"] == .number(0))
    }

    @Test func removingTheFormulaClearsItsSpill() {
        var book = TestBook(["A1": "=SEQUENCE(3)", "C1": "=A3", "C2": "=SUM(A2:A3)"])
        #expect(book["C1"] == .number(3))
        #expect(book["C2"] == .number(5))
        book.set("A1", .empty)
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
        #expect(book.workbook.sheets[0].spillRanges.isEmpty)
        #expect(book["C1"] == .empty)
        #expect(book["C2"] == .number(0))
        book.set("A1", "={5;6;7}")
        #expect(book["C1"] == .number(7))
        book.set("A1", 9)
        #expect(book["C2"] == .number(0))
    }

    @Test func earlierFormulasWinOverlappingSpills() {
        var book = TestBook(["B1": "=SEQUENCE(3)", "A2": "=SEQUENCE(1, 3)"])
        #expect(spillRange(book, "B1") == CellRange(a1: "B1:B3"))
        #expect(book["A2"] == err(.reference))
        #expect(message(book["A2"]) == "Array result was not expanded because it would overwrite data in B2.")
        book.set("B1", "=SEQUENCE(1)")
        #expect(book["A2"] == .number(1))
        #expect(spillRange(book, "A2") == CellRange(a1: "A2:C2"))
        book.set("B1", "=SEQUENCE(3)")
        #expect(spillRange(book, "B1") == CellRange(a1: "B1:B3"))
        #expect(book["A2"] == err(.reference))
        #expect(spillRange(book, "A2") == nil)
        #expect(shown(book, "B2") == .number(2))
        #expect(shown(book, "C2") == .empty)
    }

    @Test func spillsPastTheGridAreErrors() {
        let book = TestBook(["A999": "=SEQUENCE(3)", "Y1": "=SEQUENCE(1, 3)"])
        #expect(book["A999"] == err(.reference))
        #expect(message(book["A999"]) == "Result was not automatically expanded, please insert more rows (1).")
        #expect(book["Y1"] == err(.reference))
        #expect(message(book["Y1"]) == "Result was not automatically expanded, please insert more columns (1).")
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
    }

    @Test func spillsFeedOtherSpills() {
        var book = TestBook(["A1": "=SEQUENCE(3)", "B1": "=A1:A3*2", "C1": "=SUM(B2:B3)", "D1": "=B3"])
        #expect([book["B1"], shown(book, "B2"), shown(book, "B3")] == [.number(2), .number(4), .number(6)])
        #expect(book["C1"] == .number(10))
        #expect(book["D1"] == .number(6))
        book.set("A1", "=SEQUENCE(3, 1, 10)")
        #expect(book["C1"] == .number(46))
        #expect(book["D1"] == .number(24))
    }

    @Test func readingItsOwnSpillAreaIsCircular() {
        let book = TestBook(["A1": "=SEQUENCE(COUNT(A2:A5) + 2)"])
        #expect(book["A1"] == err(.reference))
        #expect(message(book["A1"]) == FormulaErrors.circularMessage)
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
    }

    @Test func spilledValuesAcrossSheetsAndStandaloneEvaluation() {
        var book = TestBook([("Data", ["A1": "=SEQUENCE(4)"]), ("Report", ["A1": "=SUM(Data!A2:A4)", "B1": "=Data!A4"])])
        #expect(book.value("A1", sheet: 1) == .number(9))
        #expect(book.value("B1", sheet: 1) == .number(4))
        #expect(book.evaluate("=SUM(A1:A4)", sheet: 0) == .number(10))
        #expect(book.evaluate("=A3", sheet: 0) == .number(3))
        #expect(book.evaluate("=ISBLANK(A3)", sheet: 0) == .boolean(false))
        book.set("A1", "=SEQUENCE(4, 1, 0)", sheet: 0)
        #expect(book.value("A1", sheet: 1) == .number(6))
        #expect(book.value("B1", sheet: 1) == .number(3))
    }

    @Test func recalculateAllRebuildsTheMaps() {
        var book = TestBook(["A1": "=SEQUENCE(2)"])
        book.workbook.sheets[0].spilledValues[CellAddress(a1: "Z9")!] = .number(1)
        book.workbook.sheets[0].spillRanges[CellAddress(a1: "Z8")!] = CellRange(a1: "Z8:Z9")
        book.engine.recalculateAll(&book.workbook, now: book.now)
        #expect(book.workbook.sheets[0].spilledValues == [CellAddress(a1: "A2")!: .number(2)])
        #expect(book.workbook.sheets[0].spillRanges == [CellAddress(a1: "A1")!: CellRange(a1: "A1:A2")!])
    }

    @Test func structuralChangesMoveSpillsAfterRecalculation() {
        var book = TestBook(["B2": "=SEQUENCE(2)", "C1": "=SUM(B2:B3)"])
        book.workbook.apply(.insertRows(at: 0, count: 1), toSheet: 0)
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
        book.engine.recalculateAll(&book.workbook, now: book.now)
        #expect(spillRange(book, "B3") == CellRange(a1: "B3:B4"))
        #expect(book["C2"] == .number(3))
        book.workbook.apply(.insertCells(CellRange(a1: "B4")!, shiftDown: true), toSheet: 0)
        book.engine.recalculateAll(&book.workbook, now: book.now)
        #expect(book["B3"] == .number(1))
        #expect(shown(book, "B4") == .number(2))
    }

    @Test func performance() {
        var sheet = Sheet(name: "Sheet1", rowCount: 4000, columnCount: 6)
        for row in 0..<3000 {
            sheet[row, 0] = Cell(formula: "=SEQUENCE(1, 3, \(row))")
            sheet[row, 4] = Cell(formula: "=SUM(B\(row + 1):C\(row + 1))")
        }
        sheet[0, 5] = Cell(formula: "=SUM(C:C)")
        var workbook = Workbook(sheets: [sheet])
        let engine = FormulaEngine()
        let clock = ContinuousClock()
        let full = clock.measure { engine.recalculateAll(&workbook) }
        #expect(workbook.sheets[0][2999, 4].value == .number(Double(2999 * 2 + 3)))
        #expect(workbook.sheets[0].spillRanges.count == 3000)
        workbook.sheets[0][1500, 0] = Cell(formula: "=SEQUENCE(1, 3, 0)")
        let edit = clock.measure {
            engine.recalculate(&workbook, changed: [SheetCell(sheet: workbook.sheets[0].id, address: CellAddress(row: 1500, column: 0))])
        }
        #expect(workbook.sheets[0][1500, 4].value == .number(3))
        print("spills: recalculateAll 3,000 spilling + 3,001 reading formulas: \(full); edit: \(edit)")
        #if DEBUG
        let scale = 20.0
        #else
        let scale = 1.0
        #endif
        #expect(full < .milliseconds(300 * scale))
        #expect(edit < .milliseconds(30 * scale))
    }

    @Test func paradoxesSettleTheSameWayIncrementally() {
        // E3's spill blocks D5's, and E3 reads D5: there is no consistent answer, but it is always the same one.
        var book = TestBook(["B3": 20, "E3": "=FILTER(D5:D8, D5:D8>2)", "D5": "=SPLIT(\"a,b\", \",\")",
                             "D6": "=SUM(C1:D2)+B3", "D8": "a"])
        func matchesFullRecalculation() -> Bool {
            var fresh = book.workbook
            FormulaEngine().recalculateAll(&fresh, now: book.now)
            return fresh.sheets[0].cells.allSatisfy { book.workbook.sheets[0][$0.key].value == $0.value.value }
                && fresh.sheets[0].spilledValues == book.workbook.sheets[0].spilledValues
                && fresh.sheets[0].spillRanges == book.workbook.sheets[0].spillRanges
        }
        #expect(matchesFullRecalculation())
        book.set("B3", 30)
        #expect(matchesFullRecalculation())
        book.set("E3", "=SUM(D9:E10)")
        #expect(matchesFullRecalculation())
        #expect(book["D5"] == .text("a"))
        #expect(shown(book, "E5") == .text("b"))
    }

    @Test func blockedSpillsReturnWhenAnotherSpillShrinks() {
        var book = TestBook(["Z1": 3, "A1": "=SEQUENCE(Z1)", "A4": "=SEQUENCE(2)", "B5": "=A5"])
        #expect(spillRange(book, "A1") == CellRange(a1: "A1:A3"))
        #expect(spillRange(book, "A4") == CellRange(a1: "A4:A5"))
        #expect(book["B5"] == .number(2))
        book.set("Z1", 6)
        #expect(book["A1"] == err(.reference))
        #expect(message(book["A1"]) == "Array result was not expanded because it would overwrite data in A4.")
        book.set("Z1", 2)
        #expect(spillRange(book, "A1") == CellRange(a1: "A1:A2"))
        #expect(book["B5"] == .number(2))
    }
}
