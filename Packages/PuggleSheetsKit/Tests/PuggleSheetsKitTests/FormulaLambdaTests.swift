import Foundation
import Testing
@testable import PuggleSheetsKit

/// The values a formula spills from `a1` in a workbook holding `cells`, row by row.
func spilled(_ formula: String, _ cells: [String: CellInput] = [:], at a1: String = "H1") -> [[CellValue]] {
    var inputs = cells
    inputs[a1] = .formula(formula)
    let book = TestBook(inputs)
    let sheet = book.workbook.sheets[0]
    let origin = CellAddress(a1: a1)!
    guard let area = sheet.spillRanges[origin] else { return [[sheet[origin].value]] }
    return area.rows.map { row in area.columns.map { sheet.value(at: CellAddress(row: row, column: $0)) } }
}

func numbers(_ rows: [[CellValue]]) -> [[Double?]] { rows.map { $0.map(\.numberValue) } }

struct FormulaLambdaTests {
    @Test func letBindsNamesInOrder() {
        #expect(eval("=LET(x, 2, y, x*3, x+y)") == .number(8))
        #expect(eval("=LET(r, A1:A3, SUM(r))", ["A1": 1, "A2": 2, "A3": 3]) == .number(6))
        #expect(eval("=LET(x, 1, LET(x, 2, x) + x)") == .number(3))
        #expect(eval("=LET(total, 5, Total*2)") == .number(10))
        #expect(eval("=LET(x, 1, y)") == err(.name))
        #expect(message(eval("=LET(x, 1, y, 2)")) == "Wrong number of arguments to LET. Expected an odd number of arguments, but got 4 arguments.")
        #expect(message(eval("=LET(A1, 1, A1)")) == "Argument 1 of function LET must be a valid name.")
    }

    @Test func lambdasAreCalledWithArguments() {
        #expect(eval("=LAMBDA(x, x*2)(3)") == .number(6))
        #expect(eval("=LAMBDA(x, y, x+y)(1, 2)") == .number(3))
        #expect(eval("=LAMBDA(42)()") == .number(42))
        #expect(eval("=(LAMBDA(x, x^2))(5)") == .number(25))
        #expect(eval("=LET(f, LAMBDA(x, x*x), f(4) + f(2))") == .number(20))
        // A LAMBDA sees the names around it where it was made.
        #expect(eval("=LET(a, 10, f, LAMBDA(x, x+a), a + f(1))") == .number(21))
        #expect(eval("=LET(add, LAMBDA(n, LAMBDA(x, x+n)), add(5)(2))") == .number(7))
        #expect(eval("=LET(f, LAMBDA(x, x+1), SUM(MAP({1,2}, f)))") == .number(5))
        #expect(eval("=CHOOSE(2, LAMBDA(x, x), LAMBDA(x, x*10))(3)") == .number(30))
        #expect(message(eval("=LAMBDA(x, x+1)")) == "Wrong number of arguments to LAMBDA. Expected 1 arguments, but got 0 arguments.")
        #expect(message(eval("=LAMBDA(x, x+1)(1, 2)")) == "Wrong number of arguments to LAMBDA. Expected 1 arguments, but got 2 arguments.")
        #expect(eval("=SUM(LAMBDA(x, x))") == err(.notAvailable))
        #expect(eval("=LAMBDA(x, x, 1)(1, 2)") == err(.value))
        #expect(eval("=f(1)") == err(.name))
        #expect(eval("=LAMBDA(x, y, IF(ISOMITTED(y), x, x+y))(1, )") == .number(1))
        #expect(eval("=LAMBDA(x, y, IF(ISOMITTED(y), x, x+y))(1, 2)") == .number(3))
        #expect(eval("=ISOMITTED(1)") == .boolean(false))
    }

    @Test func lambdasCanRecurseThroughThemselves() {
        // In a recalculation, deep calls finish on a big stack; standalone evaluation stops early.
        let sum = "=LET(f, LAMBDA(g, n, IF(n<=0, 0, n + g(g, n-1))), f(f, %d))"
        #expect(eval(String(format: sum, 10)) == .number(55))
        let book = TestBook(["A1": .formula(String(format: sum, 200))])
        #expect(book["A1"] == .number(20_100))
        #expect(eval(String(format: sum, 200)) == .error(FormulaErrors.lambdaDepth))
        let endless = TestBook(["A1": "=LET(f, LAMBDA(g, g(g)), f(f))"])
        #expect(endless["A1"] == .error(FormulaErrors.lambdaDepth))
        #expect(message(endless["A1"]) == "Too many nested LAMBDA calls.")
    }

    @Test func mapReduceAndScan() {
        #expect(numbers(spilled("=MAP(A1:A3, LAMBDA(v, v*10))", ["A1": 1, "A2": 2, "A3": 3])) == [[10], [20], [30]])
        #expect(numbers(spilled("=MAP({1,2;3,4}, {10,20;30,40}, LAMBDA(a, b, a+b))")) == [[11, 22], [33, 44]])
        #expect(message(eval("=MAP({1,2}, {1,2,3}, LAMBDA(a, b, a+b))")) == "Array arguments to MAP are of incompatible size.")
        #expect(message(eval("=MAP({1,2}, LAMBDA(a, b, a+b))")) == "Wrong number of arguments to LAMBDA. Expected 2 arguments, but got 1 arguments.")
        #expect(message(eval("=MAP({1,2}, 5)")) == "Argument 2 of function MAP must be a LAMBDA.")
        #expect(spilled("=MAP({1,2}, LAMBDA(v, {1,2}))")[0].allSatisfy { $0 == err(.value) })
        #expect(eval("=REDUCE(0, A1:A3, LAMBDA(acc, v, acc+v))", ["A1": 1, "A2": 2, "A3": 3]) == .number(6))
        #expect(eval("=REDUCE(, {1,2,3}, LAMBDA(acc, v, acc&v))") == .text("123"))
        #expect(numbers(spilled("=SCAN(0, {1,2,3;4,5,6}, LAMBDA(acc, v, acc+v))")) == [[1, 3, 6], [10, 15, 21]])
    }

    @Test func byRowByColAndMakeArray() {
        #expect(numbers(spilled("=BYROW({1,2;3,4}, LAMBDA(r, SUM(r)))")) == [[3], [7]])
        #expect(numbers(spilled("=BYCOL({1,2;3,4}, LAMBDA(c, SUM(c)))")) == [[4, 6]])
        #expect(numbers(spilled("=MAKEARRAY(2, 3, LAMBDA(r, c, r*10+c))")) == [[11, 12, 13], [21, 22, 23]])
        #expect(eval("=MAKEARRAY(0, 3, LAMBDA(r, c, 1))") == err(.value))
        #expect(numbers(spilled("=BYROW(A1:B2, LAMBDA(r, MAX(r)))", ["A1": 5, "B1": 7, "A2": 1, "B2": 0])) == [[7], [1]])
    }

    /// A formula computed while another formula's LET is running doesn't see its names.
    @Test func letNamesStayInTheirFormula() {
        let book = TestBook(["B1": "=LET(x, 5, INDIRECT(\"C1\")+x)", "C1": "=x*2"])
        #expect(book["C1"] == err(.name))
        #expect(book["B1"] == err(.name))
    }

    @Test func lambdaResultsRecalculate() {
        var book = TestBook(["A1": 1, "A2": 2, "B1": "=MAP(A1:A2, LAMBDA(x, x*C1))", "C1": 3])
        #expect(book["B1"] == .number(3))
        book.set("C1", 10)
        #expect(book["B1"] == .number(10))
        #expect(book.workbook.sheets[0].value(at: CellAddress(a1: "B2")!) == .number(20))
        book.set("A2", 5)
        #expect(book.workbook.sheets[0].value(at: CellAddress(a1: "B2")!) == .number(50))
    }

    @Test func mapOverTenThousandCellsIsFast() {
        var sheet = Sheet(name: "Sheet1", rowCount: 10_001, columnCount: 4)
        for row in 0..<10_000 { sheet[row, 0] = Cell(value: .number(Double(row))) }
        sheet[0, 2] = Cell(formula: "=MAP(A1:A10000, LAMBDA(x, IF(MOD(x, 2)=0, x*2, x+1)))")
        var workbook = Workbook(sheets: [sheet])
        let engine = FormulaEngine()
        let clock = ContinuousClock()
        var fastest = Duration.seconds(100)
        for _ in 0..<3 {
            var copy = workbook
            fastest = min(fastest, clock.measure { engine.recalculateAll(&copy) })
            workbook = copy
        }
        #expect(workbook.sheets[0].value(at: CellAddress(row: 9_999, column: 2)) == .number(10_000))
        print("MAP over 10,000 cells: \(fastest) (fastest of 3)")
        #if DEBUG
        let scale = 15.0
        #else
        let scale = 1.0
        #endif
        #expect(fastest < .milliseconds(100 * scale))
    }
}
