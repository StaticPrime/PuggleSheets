import Foundation
import Testing
@testable import PuggleSheetsKit

/// A small deterministic random generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct FormulaRecalculationTests {
    @Test func chainsUpdateIncrementally() {
        var cells: [String: CellInput] = ["A1": 1]
        for row in 2...10 { cells["A\(row)"] = .formula("=A\(row - 1)*2") }
        var book = TestBook(cells)
        #expect(book["A10"] == .number(512))
        book.set("A1", 3)
        #expect(book["A10"] == .number(1536))
        book.set("A5", 1)
        #expect(book["A10"] == .number(32))
        #expect(book["A4"] == .number(24))
        book.set("A5", "=A4*2")
        #expect(book["A10"] == .number(1536))
    }

    @Test func formulasKeepTextAndFormat() {
        var book = TestBook(["A1": 2, "B1": "=A1*10"])
        var bold = CellFormat()
        bold.bold = true
        book.workbook.sheets[0][CellAddress(a1: "B1")!].format = bold
        book.set("A1", 3)
        let cell = book.workbook.sheets[0][CellAddress(a1: "B1")!]
        #expect(cell.value == .number(30))
        #expect(cell.formula == "=A1*10")
        #expect(cell.format.bold)
        #expect(book["A1"] == .number(3))
    }

    @Test func rangesAndWholeColumns() {
        var book = TestBook(["A1": 1, "A2": 2, "B1": "=SUM(A1:A10)", "C1": "=SUM(A:A)", "D5": "=COUNT(1:2)",
                             "E1": "=SUM(A3:A)", "F1": "=SUMIF(A1:A3, \">0\", G1)"])
        #expect(book["B1"] == .number(3))
        #expect(book["C1"] == .number(3))
        #expect(book["D5"] == .number(6))
        book.set("G3", 4)
        #expect(book["F1"] == .number(0))
        book.set("A3", 1)
        #expect(book["F1"] == .number(4))
        book.set("A10", 10)
        #expect(book["B1"] == .number(14))
        #expect(book["C1"] == .number(14))
        #expect(book["E1"] == .number(11))
        book.set("A500", 100)
        #expect(book["B1"] == .number(14))
        #expect(book["C1"] == .number(114))
        #expect(book["E1"] == .number(111))
        book.set("A2", .empty)
        #expect(book["C1"] == .number(112))
        #expect(book["D5"] == .number(5))
    }

    @Test func crossSheetReferences() {
        var book = TestBook([("Sheet1", ["A1": 5]), ("Totals", ["A1": "=Sheet1!A1*2", "B1": "=SUM(Sheet1!A:A)+A1"])])
        #expect(book.value("A1", sheet: 1) == .number(10))
        #expect(book.value("B1", sheet: 1) == .number(15))
        book.set("A2", 7)
        #expect(book.value("B1", sheet: 1) == .number(22))
        book.set("A1", 1)
        #expect(book.value("A1", sheet: 1) == .number(2))
        #expect(book.value("B1", sheet: 1) == .number(10))
    }

    @Test func circularReferences() {
        var book = TestBook(["A1": "=B1+1", "B1": "=A1+1", "C1": "=A1*2", "D1": "=D1+1", "E1": 5])
        for a1 in ["A1", "B1", "D1"] {
            #expect(book[a1] == err(.reference), "\(a1)")
            #expect(message(book[a1]) == FormulaErrors.circularMessage)
        }
        #expect(book["C1"] == err(.reference))
        book.set("B1", "=E1+1")
        #expect(book["A1"] == .number(7))
        #expect(book["C1"] == .number(14))
        book.set("E1", "=C1")
        #expect(book["A1"] == err(.reference))
        #expect(book["E1"] == err(.reference))
        book.set("E1", 1)
        #expect(book["C1"] == .number(6))
    }

    @Test func rangeIncludingItselfIsCircular() {
        let book = TestBook(["A1": 1, "A5": "=SUM(A:A)", "B1": "=SUM(A1:A3)", "C1": "=ROW(C1)+COLUMN(C1)+ROWS(C1:C3)"])
        #expect(book["A5"] == err(.reference))
        #expect(book["B1"] == .number(1))
        #expect(book["C1"] == .number(7))
    }

    @Test func ifBranchesDontHideCycles() {
        let book = TestBook(["A1": "=IF(TRUE, 1, B1)", "B1": "=A1"])
        #expect(book["A1"] == err(.reference))
        #expect(book["B1"] == err(.reference))
    }

    @Test func volatileFunctionsUseNow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var book = TestBook([("Sheet1", ["A1": "=NOW()", "B1": "=TODAY()", "C1": "=A1-B1", "D1": "=RAND()", "E1": 1])], now: now)
        let serial = DateSerial.serial(from: now, timeZone: .current)
        #expect(close(book["A1"], serial))
        #expect(book["B1"] == .number(serial.rounded(.down)))
        #expect(close(book["C1"], serial - serial.rounded(.down)))
        let random = num(book["D1"]) ?? -1
        #expect(random >= 0 && random < 1)
        #expect(book.engine.hasVolatileFormulas)
        #expect(!TestBook(["A1": "=1+1"]).engine.hasVolatileFormulas)
        book.now = now.addingTimeInterval(86_400 * 2)
        book.set("E1", 2)
        #expect(close(book["A1"], serial + 2))
        #expect(book["B1"] == .number(serial.rounded(.down) + 2))
    }

    @Test func dynamicReferencesRecalculate() {
        var book = TestBook(["A1": "=INDIRECT(\"B\"&C1)", "C1": 2, "B2": 5, "B3": 7, "D1": "=SUM(OFFSET(B1,1,0,2,1))",
                             "E1": "=A1*10"])
        #expect(book["A1"] == .number(5))
        #expect(book["D1"] == .number(12))
        #expect(book["E1"] == .number(50))
        book.set("B2", 6)
        #expect(book["A1"] == .number(6))
        #expect(book["D1"] == .number(13))
        #expect(book["E1"] == .number(60))
        book.set("C1", 3)
        #expect(book["A1"] == .number(7))
        book.set("B3", "=B2*100")
        #expect(book["A1"] == .number(600))
        #expect(book["E1"] == .number(6000))
    }

    @Test func dynamicCycles() {
        let book = TestBook(["A1": "=INDIRECT(\"A1\")", "B1": "=INDIRECT(\"C1\")", "C1": "=B1+1", "D1": "=OFFSET(D1,1,0)",
                             "D2": 4])
        #expect(book["A1"] == err(.reference))
        #expect(book["B1"] == err(.reference))
        #expect(book["C1"] == err(.reference))
        #expect(book["D1"] == .number(4))
    }

    @Test func dynamicReadOfPendingChain() {
        var cells: [String: CellInput] = ["A1": 1, "B1": "=INDIRECT(\"A2000\")"]
        for row in 2...2000 { cells["A\(row)"] = .formula("=A\(row - 1)+1") }
        var book = TestBook([("Sheet1", cells)])
        book.workbook.sheets[0].rowCount = 3000
        book.engine.recalculateAll(&book.workbook, now: book.now)
        #expect(book["B1"] == .number(2000))
        book.set("A1", 11)
        #expect(book["B1"] == .number(2010))
    }

    @Test func longChainsOfDynamicReferences() {
        var sheet = Sheet(name: "Sheet1", rowCount: 5000, columnCount: 3)
        sheet[0, 0] = Cell(value: .number(1))
        sheet[4999, 1] = Cell(value: .number(0))
        for row in 1..<5000 { sheet[row, 0] = Cell(formula: "=OFFSET(A\(row + 1), -1, 0)+1") }
        for row in 0..<4999 { sheet[row, 1] = Cell(formula: "=INDIRECT(\"B\" & ROW()+1)+1") }
        var workbook = Workbook(sheets: [sheet])
        let engine = FormulaEngine()
        engine.recalculateAll(&workbook)
        #expect(workbook.sheets[0][4999, 0].value == .number(5000))
        #expect(workbook.sheets[0][0, 1].value == .number(4999))
        workbook.sheets[0][4999, 1] = Cell(value: .number(10))
        engine.recalculate(&workbook, changed: [SheetCell(sheet: workbook.sheets[0].id, address: CellAddress(row: 4999, column: 1))])
        #expect(workbook.sheets[0][0, 1].value == .number(5009))
        #expect(workbook.sheets[0][4999, 0].value == .number(5000))
    }

    @Test func deepChainsDontOverflowTheStack() {
        var sheet = Sheet(name: "Sheet1", rowCount: 30_000, columnCount: 2)
        sheet[0, 0] = Cell(value: .number(0))
        for row in 1..<30_000 { sheet[row, 0] = Cell(formula: "=A\(row)+1") }
        var workbook = Workbook(sheets: [sheet])
        let engine = FormulaEngine()
        engine.recalculateAll(&workbook)
        #expect(workbook.sheets[0][29_999, 0].value == .number(29_999))
        workbook.sheets[0][0, 0] = Cell(value: .number(1))
        engine.recalculate(&workbook, changed: [SheetCell(sheet: workbook.sheets[0].id, address: CellAddress(row: 0, column: 0))])
        #expect(workbook.sheets[0][29_999, 0].value == .number(30_000))
    }

    @Test func clearingAndReplacingFormulas() {
        var book = TestBook(["A1": 1, "B1": "=A1+1", "C1": "=B1+1"])
        #expect(book["C1"] == .number(3))
        book.set("B1", 10)
        #expect(book["C1"] == .number(11))
        book.set("A1", 5)
        #expect(book["B1"] == .number(10))
        book.set("B1", .empty)
        #expect(book["C1"] == .number(1))
        book.set("B1", "=A1*3")
        #expect(book["C1"] == .number(16))
    }

    @Test func parseErrorsAndMissingSheetsAreStored() {
        var book = TestBook(["A1": "=1+", "B1": "=Other!A1", "C1": "=A1"])
        #expect(book["A1"] == err(.parse))
        #expect(book["B1"] == err(.reference))
        #expect(book["C1"] == err(.parse))
        var other = Sheet(name: "Other")
        other[0, 0] = Cell(value: .number(9))
        book.workbook.sheets.append(other)
        book.engine.recalculate(&book.workbook, changed: [SheetCell](), now: book.now)
        #expect(book["B1"] == .number(9))
    }

    @Test func structuralChangesFallBackToFullRecalculation() {
        var book = TestBook([("Sheet1", ["A1": "=Data!A1"]), ("Data", ["A1": 3])])
        #expect(book["A1"] == .number(3))
        book.workbook.sheets[1].name = "Renamed"
        book.set("B1", 1)
        #expect(book["A1"] == err(.reference))
    }

    @Test func emptyResultsStayEmpty() {
        let book = TestBook(["A1": "=B1", "A2": "=B1+0", "A3": "=IF(TRUE,B1)"])
        #expect(book["A1"] == .empty)
        #expect(book["A2"] == .number(0))
        #expect(book["A3"] == .empty)
    }

    /// Hundreds of random edits (spilling formulas, cross-sheet and dynamic references, cycles among them,
    /// HYPERLINK formulas, and pivot tables added, edited, moved and removed, with formulas reading their
    /// cells); after each one the incremental results, spill maps and formula links must equal a fresh full
    /// recalculation, error messages included.
    @Test(.serialized, arguments: [2026, 7, 116, 5267]) func incrementalMatchesFullRecalculation(seed: Int) {
        var random = SeededGenerator(state: UInt64(seed))
        var workbook = Workbook(sheets: [Sheet(name: "Sheet1", rowCount: 40, columnCount: 12),
                                         Sheet(name: "Data Sheet", rowCount: 40, columnCount: 12)])
        let engine = FormulaEngine()
        engine.recalculateAll(&workbook)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func ref() -> String {
            let column = CellAddress.columnName(Int.random(in: 0..<5, using: &random))
            return "\(Bool.random(using: &random) ? "$" : "")\(column)\(Int.random(in: 1...12, using: &random))"
        }
        func range() -> String {
            let top = Int.random(in: 1...10, using: &random), left = Int.random(in: 0..<4, using: &random)
            return "\(CellAddress.columnName(left))\(top):\(CellAddress.columnName(left + Int.random(in: 0...1, using: &random)))\(top + Int.random(in: 0...4, using: &random))"
        }
        func sheetPrefix() -> String { Bool.random(using: &random) ? "'Data Sheet'!" : "Sheet1!" }
        func column(_ index: Int) -> String { CellAddress.columnName(index) }
        func pivotColumn() -> String { column(Int.random(in: 5..<12, using: &random)) }
        func formula() -> String {
            if Int.random(in: 0..<10, using: &random) < 3 { return spillingFormula() }
            switch Int.random(in: 0..<20, using: &random) {
            case 0: return "=SUM(F1:L20)+COUNTA(\(pivotColumn())1:\(pivotColumn())12)"
            case 1: return "=\(pivotColumn())\(Int.random(in: 1...14, using: &random))&\"\""
            case 2: return "=HYPERLINK(\"https://example.com/\" & \(ref()), \(ref()))"
            case 3: return "=IF(\(ref())>3, HYPERLINK(\"example.com\"), \"none\")"
            case 4: return "=IFERROR(HYPERLINK(\(ref()), 1/\(ref())), HYPERLINK(\"#gid=0\", \"back\"))"
            case 5: return "=LET(x, \(ref()), y, \(ref()), IF(x>y, x*2, LAMBDA(v, v+y)(x)))"
            case 6: return "=REDUCE(0, \(range()), LAMBDA(a, v, a+N(v)))"
            case 7: return "=IF(\(ref())>2, SPARKLINE(\(range())), \"-\")"
            case 8: return "=SUM(Tbl[#DATA])+ROWS(Tbl)+COUNTA(Tbl[[#ALL],[a]])"
            case 9: return "=IFERROR(GETPIVOTDATA(\(ref()), \(pivotColumn())\(Int.random(in: 1...14, using: &random))), \"none\")"
            default: break
            }
            switch Int.random(in: 0..<20, using: &random) {
            case 0: return "=\(ref())+\(ref())"
            case 1: return "=\(ref())*2"
            case 2: return "=SUM(\(range()))"
            case 3: return "=SUM(\(CellAddress.columnName(Int.random(in: 0..<5, using: &random))):\(CellAddress.columnName(Int.random(in: 0..<5, using: &random))))"
            case 4: return "=\(sheetPrefix())\(ref())+1"
            case 5: return "=SUM(\(sheetPrefix())\(range()))"
            case 6: return "=IF(\(ref())>3, \(ref()), \(ref())*2)"
            case 7: return "=COUNTIF(\(range()), \">2\")"
            case 8: return "=AVERAGE(\(range()))"
            case 9: return "=\(ref())&\"x\""
            case 10: return "=VLOOKUP(\(ref()), \(range()), 2, FALSE)"
            case 11: return "=MAX(\(range()))+MIN(\(range()))"
            case 12: return "=SUMPRODUCT(\(range())*2)"
            case 13: return "=IFERROR(1/\(ref()), -1)"
            case 14: return "=ROW()+COLUMN()+NOW()*0"
            case 15: return "=INDEX(\(range()), 2)"
            case 16: return "=INDIRECT(\"\(ref())\")+1"
            case 17: return "=SUM(OFFSET(\(ref()), 1, 1, 2, 2))"
            case 18: return "=SUMIF(\(range()), \">=1\", \(range()))"
            default: return "=MATCH(\(ref()), \(CellAddress.columnName(Int.random(in: 0..<5, using: &random))):\(CellAddress.columnName(Int.random(in: 0..<5, using: &random))), 0)"
            }
        }

        func spillingFormula() -> String {
            switch Int.random(in: 0..<16, using: &random) {
            case 11: return "=MAP(\(range()), LAMBDA(v, IF(ISNUMBER(v), v*2, \"\")))"
            case 12: return "=SORTN(\(range()), 2, \(Int.random(in: 0...3, using: &random)), 1, \(Bool.random(using: &random) ? "TRUE" : "FALSE"))"
            case 13: return "=QUERY(A1:C12, \"select A, B where B > \(Int.random(in: 0...6, using: &random)) order by B desc\", 0)"
            case 14: return "=QUERY(\(sheetPrefix())A1:C12, \"select A, count(B) group by A\", 0)"
            case 15: return "=Tbl[#HEADERS]"
            case 0: return "=SEQUENCE(\(Int.random(in: 1...3, using: &random)), \(Int.random(in: 1...2, using: &random)))"
            case 1: return "={1,2;3,4}"
            case 2: return "=\(range())"
            case 3: return "=TRANSPOSE(\(range()))"
            case 4:
                let top = Int.random(in: 1...8, using: &random), height = Int.random(in: 1...4, using: &random)
                let a = column(Int.random(in: 0..<5, using: &random)), b = column(Int.random(in: 0..<5, using: &random))
                return "=FILTER(\(a)\(top):\(a)\(top + height), \(b)\(top):\(b)\(top + height)>2)"
            case 5: return "=SORT(\(range()))"
            case 6: return "=UNIQUE(\(range()))"
            case 7: return "=SPLIT(\"a,b\", \",\")"
            case 8: return "=ARRAYFORMULA(\(range())*2)"
            case 9: return "=SEQUENCE(\(ref()))"
            default: return "=SUM(\(range()))+\(ref())"
            }
        }

        /// A random pivot table for `sheet`: its source mostly on the other sheet (pivot tables reading their own
        /// sheet's formulas, which read pivot cells, make cycles that keep every recalculation a full one).
        func pivot(on sheet: Int, id: UUID = UUID()) -> PivotTable {
            let top = Int.random(in: 0...3, using: &random), left = Int.random(in: 0...2, using: &random)
            let width = Int.random(in: 2...3, using: &random), height = Int.random(in: 2...10, using: &random)
            var source = "\(column(left))\(top + 1):\(column(left + width - 1))\(top + height)"
            switch Int.random(in: 0..<12, using: &random) {
            case 0..<8: source = (sheet == 0 ? "'Data Sheet'!" : "Sheet1!") + source
            case 8: source = "'Nowhere'!" + source
            case 5: source = "\(column(left)):\(column(left + width - 1))"
            default: break
            }
            func group() -> PivotGroup {
                PivotGroup(sourceColumn: Int.random(in: 0..<width, using: &random), ascending: Bool.random(using: &random),
                           showsTotals: Int.random(in: 0..<4, using: &random) > 0,
                           sortByValue: Int.random(in: 0..<5, using: &random) == 0 ? 0 : nil)
            }
            let rows = (0..<Int.random(in: 0...2, using: &random)).map { _ in group() }
            let columns = (0..<Int.random(in: 0...1, using: &random)).map { _ in group() }
            let values = (0..<Int.random(in: 0...2, using: &random)).map { _ in
                PivotValue(sourceColumn: Int.random(in: 0..<width, using: &random),
                           summary: PivotValue.Summary.allCases.randomElement(using: &random)!,
                           showAs: Int.random(in: 0..<3, using: &random) == 0 ? PivotValue.ShowAs.allCases.randomElement(using: &random)! : .default)
            }
            var filters: [PivotFilter] = []
            switch Int.random(in: 0..<8, using: &random) {
            case 0: filters.append(PivotFilter(sourceColumn: Int.random(in: 0..<width, using: &random),
                                               criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["2"]))))
            case 1: filters.append(PivotFilter(sourceColumn: Int.random(in: 0..<width, using: &random), criterion: FilterCriterion(hiddenValues: ["a", ""])))
            case 2: filters.append(PivotFilter(sourceColumn: 0, criterion: FilterCriterion(condition: CellCondition(.customFormula, ["=\(ref())<>\(column(left))\(top + 2)"]))))
            default: break
            }
            let anchor = Int.random(in: 0..<8, using: &random) == 0
                ? CellAddress(row: Int.random(in: 0..<14, using: &random), column: Int.random(in: 0..<6, using: &random))
                : CellAddress(row: Int.random(in: 0..<40, using: &random), column: Int.random(in: 5..<12, using: &random))
            return PivotTable(id: id, anchor: anchor, source: source, rows: rows, columns: columns, values: values, filters: filters,
                              valuesInRows: Bool.random(using: &random))
        }

        var sawLinks = false, sawSparklines = false
        for step in 0..<400 {
            var changed: [SheetCell] = []
            if Int.random(in: 0..<10, using: &random) < 2 {
                let sheet = Int.random(in: 0..<4, using: &random) == 0 ? 1 : 0
                var pivots = workbook.sheets[sheet].pivotTables
                switch Int.random(in: 0..<5, using: &random) {
                case 0, 1:
                    if pivots.count < 3 { pivots.append(pivot(on: sheet)) } else { pivots.removeFirst() }
                case 2:
                    if !pivots.isEmpty { pivots.remove(at: Int.random(in: 0..<pivots.count, using: &random)) }
                case 3:
                    if !pivots.isEmpty {
                        let index = Int.random(in: 0..<pivots.count, using: &random)
                        let anchor = pivots[index].anchor
                        pivots[index] = pivot(on: sheet, id: pivots[index].id)
                        if Bool.random(using: &random) { pivots[index].anchor = anchor }
                    }
                default:
                    if !pivots.isEmpty {
                        let index = Int.random(in: 0..<pivots.count, using: &random)
                        pivots[index].anchor = CellAddress(row: Int.random(in: 0..<40, using: &random), column: Int.random(in: 0..<12, using: &random))
                    }
                }
                workbook.sheets[sheet].pivotTables = pivots
            }
            // Tables come and go, slicers too (those over a pivot table's source filter it).
            if Int.random(in: 0..<20, using: &random) == 0 {
                if Bool.random(using: &random) {
                    workbook.sheets[1].tables = []
                } else {
                    let top = Int.random(in: 0...2, using: &random), height = Int.random(in: 2...10, using: &random)
                    workbook.sheets[1].tables = [SheetTable(name: "Tbl", range: CellRange(rows: top...(top + height), columns: 0...Int.random(in: 1...3, using: &random)))]
                }
            }
            if Int.random(in: 0..<20, using: &random) == 0 {
                if Bool.random(using: &random) || workbook.sheets[0].pivotTables.isEmpty {
                    workbook.sheets[0].objects = []
                } else {
                    let source = workbook.sheets[0].pivotTables[Int.random(in: 0..<workbook.sheets[0].pivotTables.count, using: &random)].source
                    workbook.sheets[0].objects = [SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 0, column: 0), width: 100, height: 100),
                                                              content: .slicer(SlicerSpec(range: source, column: Int.random(in: 0...1, using: &random),
                                                                                          criterion: FilterCriterion(hiddenValues: ["a", "10"]))))]
                }
            }
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                let sheet = Int.random(in: 0..<2, using: &random)
                let address = CellAddress(row: Int.random(in: 0..<12, using: &random), column: Int.random(in: 0..<5, using: &random))
                var cell = Cell()
                switch Int.random(in: 0..<10, using: &random) {
                case 0, 1: cell.value = .number(Double(Int.random(in: -5...20, using: &random)))
                case 2: cell.value = .text(["a", "b", "10", ""].randomElement(using: &random)!)
                case 3: cell = Cell()
                default: cell.formula = formula()
                }
                workbook.sheets[sheet][address] = cell
                changed.append(SheetCell(sheet: workbook.sheets[sheet].id, address: address))
            }
            engine.recalculate(&workbook, changed: changed, now: now)

            var fresh = workbook
            FormulaEngine().recalculateAll(&fresh, now: now)
            expectSameResults(workbook, fresh, "seed \(seed) step \(step):")
            if workbook.sheets.contains(where: { !$0.formulaLinks.isEmpty }) { sawLinks = true }
            if workbook.sheets.contains(where: { !$0.sparklines.isEmpty }) { sawSparklines = true }
        }
        #expect(workbook.sheets.contains { !$0.pivotTables.isEmpty })
        #expect(sawLinks && sawSparklines)
    }

    @Test func performance() {
        // 5,000-long chain plus 5,000 sliding SUMs: 10,000 formulas.
        var sheet = Sheet(name: "Sheet1", rowCount: 6000, columnCount: 4)
        for row in 0..<5000 {
            sheet[row, 0] = Cell(value: .number(Double(row % 7)))
            sheet[row, 1] = Cell(formula: row == 0 ? "=A1*2" : "=B\(row)+A\(row + 1)*2")
            sheet[row, 2] = Cell(formula: "=SUM(A\(max(1, row - 8)):A\(row + 1))")
        }
        var workbook = Workbook(sheets: [sheet])
        let engine = FormulaEngine()
        let clock = ContinuousClock()
        let full = clock.measure { engine.recalculateAll(&workbook) }
        let id = workbook.sheets[0].id

        workbook.sheets[0][4990, 0] = Cell(value: .number(100))
        let small = clock.measure {
            engine.recalculate(&workbook, changed: [SheetCell(sheet: id, address: CellAddress(row: 4990, column: 0))])
        }
        workbook.sheets[0][0, 0] = Cell(value: .number(100))
        let large = clock.measure {
            engine.recalculate(&workbook, changed: [SheetCell(sheet: id, address: CellAddress(row: 0, column: 0))])
        }
        var check = workbook
        FormulaEngine().recalculateAll(&check)
        #expect(check.sheets[0][4999, 1].value == workbook.sheets[0][4999, 1].value)
        #expect(check.sheets[0][4995, 2].value == workbook.sheets[0][4995, 2].value)
        print("recalculateAll 10,000 formulas: \(full); small edit: \(small); edit feeding 5,000 formulas: \(large)")
        #if DEBUG
        let scale = 20.0
        #else
        let scale = 1.0
        #endif
        #expect(full < .milliseconds(400 * scale))
        #expect(small < .milliseconds(10 * scale))
        #expect(large < .milliseconds(200 * scale))
    }
}
