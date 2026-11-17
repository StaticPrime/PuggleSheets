import Foundation
import Testing
@testable import PuggleSheetsKit

/// A workbook with pivot tables kept up to date by one engine.
struct PivotBook {
    var workbook: Workbook
    let engine = FormulaEngine()
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init(_ sheets: [Sheet], namedRanges: [NamedRange] = []) {
        workbook = Workbook(sheets: sheets, namedRanges: namedRanges)
        engine.recalculateAll(&workbook, now: now)
    }

    /// Sets cells and recalculates incrementally.
    mutating func set(_ cells: [String: CellInput], sheet: Int = 0) {
        var changed: [SheetCell] = []
        for (a1, input) in cells {
            let address = CellAddress(a1: a1)!
            workbook.sheets[sheet][address] = input.cell
            changed.append(SheetCell(sheet: workbook.sheets[sheet].id, address: address))
        }
        engine.recalculate(&workbook, changed: changed, now: now)
    }

    /// Edits a sheet's pivot tables, then recalculates with no cells changed (as the app does).
    mutating func editPivots(sheet: Int = 0, _ edit: (inout [PivotTable]) -> Void) {
        edit(&workbook.sheets[sheet].pivotTables)
        engine.recalculate(&workbook, changed: [], now: now)
    }

    /// What a cell shows: its own value or a spilled one.
    func shown(_ a1: String, sheet: Int = 0) -> CellValue {
        workbook.sheets[sheet].value(at: CellAddress(a1: a1)!)
    }

    /// The shown values of a block, as text.
    func block(_ range: String, sheet: Int = 0) -> [[String]] {
        let block = CellRange(a1: range)!
        return block.rows.map { row in block.columns.map { pivotText(workbook.sheets[sheet].value(at: CellAddress(row: row, column: $0))) } }
    }

    func spillRange(_ a1: String, sheet: Int = 0) -> CellRange? {
        workbook.sheets[sheet].spillRanges[CellAddress(a1: a1)!]
    }

    /// The incremental results equal a fresh full recalculation: values, spills and links, error messages included.
    func expectMatchesFull(_ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        var fresh = workbook
        FormulaEngine().recalculateAll(&fresh, now: now)
        expectSameResults(workbook, fresh, note, sourceLocation: sourceLocation)
    }
}

/// Equal values (error messages included).
func identical(_ a: CellValue?, _ b: CellValue?) -> Bool {
    if case .error(let x)? = a, case .error(let y)? = b { return x.kind == y.kind && x.message == y.message }
    return a == b
}

/// Two workbooks hold the same formula results, spills and formula links.
func expectSameResults(_ incremental: Workbook, _ full: Workbook, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for (index, sheet) in full.sheets.enumerated() {
        let mine = incremental.sheets[index]
        for (address, cell) in sheet.cells {
            let value = mine[address].value
            #expect(identical(value, cell.value), "\(note) \(sheet.name)!\(address.a1) \(cell.formula ?? ""): incremental \(value) full \(cell.value)",
                    sourceLocation: sourceLocation)
        }
        #expect(mine.spilledValues.count == sheet.spilledValues.count, "\(note) \(sheet.name): spilled value count", sourceLocation: sourceLocation)
        for (address, value) in sheet.spilledValues where !identical(mine.spilledValues[address], value) {
            Issue.record("\(note) \(sheet.name)!\(address.a1): spilled \(String(describing: mine.spilledValues[address])) full \(value)",
                         sourceLocation: sourceLocation)
        }
        #expect(mine.spillRanges == sheet.spillRanges, "\(note) \(sheet.name): spill ranges", sourceLocation: sourceLocation)
        #expect(mine.formulaLinks == sheet.formulaLinks, "\(note) \(sheet.name): formula links", sourceLocation: sourceLocation)
        #expect(mine.sparklines == sheet.sparklines, "\(note) \(sheet.name): sparklines", sourceLocation: sourceLocation)
    }
}

struct PivotRecalculationTests {
    private func regionPivot(anchor: String = "H1", source: String = "A1:E6") -> PivotTable {
        PivotTable(anchor: CellAddress(a1: anchor)!, source: source, rows: [PivotGroup(sourceColumn: 0)], values: [PivotValue(sourceColumn: 3)])
    }

    private func book(_ pivots: [PivotTable], rows: [[CellInput]] = salesRows, rowCount: Int = Sheet.defaultRowCount,
                      columnCount: Int = Sheet.defaultColumnCount) -> PivotBook {
        var sheet = pivotSheet(rows, rowCount: rowCount, columnCount: columnCount)
        sheet.pivotTables = pivots
        return PivotBook([sheet])
    }

    @Test func pivotTablesSpillFromTheirAnchor() {
        let pivot = regionPivot()
        let book = book([pivot])
        #expect(book.block("H1:I4") == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
        let sheet = book.workbook.sheets[0]
        #expect(sheet.spilledValues[CellAddress(a1: "H1")!] == .text("Region"))
        #expect(sheet.spilledValues.count == 8)
        #expect(book.spillRange("H1") == CellRange(a1: "H1:I4"))
        #expect(sheet.spillSource(of: CellAddress(a1: "I3")!) == CellAddress(a1: "H1"))
        #expect(sheet.pivotTable(covering: CellAddress(a1: "I4")!)?.id == pivot.id)
        #expect(sheet.pivotTable(covering: CellAddress(a1: "J1")!) == nil)
        #expect(book.engine.pivotOutput(for: pivot.id) == PivotEngine.output(for: pivot, sheetIndex: 0, workbook: book.workbook))
        #expect(book.engine.pivotOutput(for: UUID()) == nil)
    }

    @Test func sourceEditsUpdateIncrementally() {
        var book = book([regionPivot(source: "A1:E10")])
        book.set(["D2": 100])
        #expect(book.block("H2:I4") == [["East", "127"], ["West", "6"], ["Grand Total", "133"]])
        book.set(["A7": "North", "D7": 9])
        #expect(book.block("H1:I5") == [["Region", "SUM of Sales"], ["East", "127"], ["North", "9"], ["West", "6"], ["Grand Total", "142"]])
        book.expectMatchesFull("added a record")
        book.set(["A7": .empty, "D7": .empty])
        #expect(book.block("H1:I5") == [["Region", "SUM of Sales"], ["East", "127"], ["West", "6"], ["Grand Total", "133"], ["", ""]])
        #expect(book.spillRange("H1") == CellRange(a1: "H1:I4"))
        book.expectMatchesFull("removed a record")
    }

    @Test func formulasReadPivotCells() {
        var book = book([regionPivot()])
        book.set(["K1": "=I2*2", "K2": "=SUM(I2:I3)", "K3": "=COUNTA(H1:I4)", "K4": "=H1", "K5": "=INDEX(H1:I4, 4, 2)"])
        #expect(book.block("K1:K5") == [["74"], ["43"], ["8"], ["Region"], ["43"]])
        book.set(["D3": 0])
        #expect(book.block("K1:K5") == [["34"], ["23"], ["8"], ["Region"], ["23"]])
        book.expectMatchesFull()
    }

    @Test func pivotTablesReadFreshFormulaResults() {
        var rows = salesRows
        for row in 1...5 { rows[row][3] = .formula("=E\(row + 1)*10") }
        var book = book([regionPivot()], rows: rows)
        #expect(book.block("I2:I4") == [["70"], ["80"], ["150"]])
        book.set(["E2": 11])
        #expect(book.block("I2:I4") == [["170"], ["80"], ["250"]])
        book.expectMatchesFull()
    }

    @Test func dataInTheWayBlocksThePivotTable() {
        var book = book([regionPivot()])
        book.set(["I3": "x"])
        #expect(book.shown("H1") == err(.reference))
        #expect(message(book.shown("H1")) == "Array result was not expanded because it would overwrite data in I3.")
        #expect(book.spillRange("H1") == CellRange(a1: "H1"))
        #expect(book.shown("H2") == .empty && book.shown("I2") == .empty)
        #expect(book.workbook.sheets[0].spilledValues.count == 1)
        book.expectMatchesFull("blocked")
        book.set(["I3": .empty])
        #expect(book.block("H1:I4") == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
        book.expectMatchesFull("unblocked")

        // Images in cells count as data.
        book.workbook.sheets[0][CellAddress(a1: "H4")!] = Cell(image: CellImage(image: ImageData(data: Data([1]), format: .png, pixelWidth: 1, pixelHeight: 1)))
        book.engine.recalculate(&book.workbook, changed: [SheetCell(sheet: book.workbook.sheets[0].id, address: CellAddress(a1: "H4")!)], now: book.now)
        #expect(message(book.shown("H1")) == "Array result was not expanded because it would overwrite data in H4.")
        book.expectMatchesFull("image")
    }

    @Test func dataInTheAnchorHidesThePivotTable() {
        var book = book([regionPivot()])
        book.set(["H1": "note"])
        #expect(book.shown("H1") == .text("note"))
        #expect(book.spillRange("H1") == nil)
        #expect(book.workbook.sheets[0].spilledValues.isEmpty)
        book.expectMatchesFull("anchor taken")
        book.set(["H1": "=1+1"])
        #expect(book.shown("H1") == .number(2) && book.workbook.sheets[0].spilledValues.isEmpty)
        book.set(["H1": .empty])
        #expect(book.shown("H1") == .text("Region") && book.shown("I4") == .number(43))
        book.expectMatchesFull("anchor free")
    }

    @Test func theGridsEdgeBlocksThePivotTable() {
        let tall = book([regionPivot(anchor: "H4")], rowCount: 6, columnCount: 10)
        #expect(message(tall.shown("H4")) == "Result was not automatically expanded, please insert more rows (1).")
        #expect(tall.spillRange("H4") == CellRange(a1: "H4"))
        let wide = book([regionPivot(anchor: "J1")], rowCount: 10, columnCount: 10)
        #expect(message(wide.shown("J1")) == "Result was not automatically expanded, please insert more columns (1).")
        let outside = book([regionPivot(anchor: "Z1")], rowCount: 10, columnCount: 10)
        #expect(outside.workbook.sheets[0].spilledValues.isEmpty && outside.workbook.sheets[0].spillRanges.isEmpty)
        let fits = book([regionPivot(anchor: "H1")], rowCount: 6, columnCount: 9)
        #expect(fits.block("H1:I4") == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
    }

    @Test func badSourcesShowReferenceErrors() {
        var book = book([regionPivot(source: "Gone!A1:E6")])
        #expect(book.shown("H1") == err(.reference))
        #expect(message(book.shown("H1")) == "Unresolved sheet name 'Gone'.")
        #expect(book.spillRange("H1") == CellRange(a1: "H1"))
        book.editPivots { $0[0].source = "A1:E6" }
        #expect(book.shown("I4") == .number(43))
        book.editPivots { $0[0].source = "A1:" }
        #expect(message(book.shown("H1")) == "Unable to parse range: A1:")
        #expect(book.shown("I4") == .empty)
        book.expectMatchesFull()
    }

    @Test func pivotTableEditsAreNoticed() {
        var book = book([])
        var pivot = regionPivot()
        book.editPivots { $0.append(pivot) }
        #expect(book.block("H1:I4") == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
        book.expectMatchesFull("added")

        pivot.columns = [PivotGroup(sourceColumn: 2)]
        book.editPivots { $0[0] = pivot }
        #expect(book.block("H1:L2") == [["SUM of Sales", "Product", "", "", ""], ["Region", "Apple", "Banana", "Cherry", "Grand Total"]])
        #expect(book.spillRange("H1") == CellRange(a1: "H1:L5"))
        book.expectMatchesFull("edited")

        pivot.columns = []
        pivot.anchor = CellAddress(a1: "H10")!
        book.editPivots { $0[0] = pivot }
        #expect(book.spillRange("H1") == nil && book.shown("H1") == .empty && book.shown("L5") == .empty)
        #expect(book.block("H10:I13") == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
        book.expectMatchesFull("moved")

        book.editPivots { $0.removeAll() }
        #expect(book.workbook.sheets[0].spilledValues.isEmpty && book.workbook.sheets[0].spillRanges.isEmpty)
        book.expectMatchesFull("removed")
    }

    @Test func spillConflictsFollowReadingOrder() {
        // A later formula's spill gives way to the pivot table...
        var book = book([regionPivot()])
        book.set(["G2": "=SEQUENCE(1, 3)"])
        #expect(message(book.shown("G2")) == "Array result was not expanded because it would overwrite data in H2.")
        #expect(book.shown("I4") == .number(43))
        book.expectMatchesFull("formula blocked")
        book.editPivots { $0.removeAll() }
        #expect(book.block("G2:I2") == [["1", "2", "3"]])
        book.expectMatchesFull("pivot removed")

        // ...and an earlier one blocks it.
        var second = self.book([regionPivot(anchor: "H3")])
        second.set(["I1": "=SEQUENCE(5)"])
        #expect(message(second.shown("H3")) == "Array result was not expanded because it would overwrite data in I3.")
        #expect(second.spillRange("H3") == CellRange(a1: "H3"))
        #expect(second.block("I1:I5") == [["1"], ["2"], ["3"], ["4"], ["5"]])
        second.expectMatchesFull("pivot blocked")
        second.set(["I1": .empty])
        #expect(second.block("H3:I6") == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
        second.expectMatchesFull("pivot unblocked")
    }

    @Test func pivotAnchorsBlockSpillsLikeData() {
        var book = book([regionPivot(anchor: "H3")])
        book.set(["H1": "=SEQUENCE(5)"])
        #expect(message(book.shown("H1")) == "Array result was not expanded because it would overwrite data in H3.")
        #expect(book.shown("I6") == .number(43))
        book.expectMatchesFull("blocked by the anchor")
        book.editPivots { $0[0].anchor = CellAddress(a1: "K3")! }
        #expect(book.block("H1:H5") == [["1"], ["2"], ["3"], ["4"], ["5"]])
        #expect(book.shown("L6") == .number(43))
        book.expectMatchesFull("anchor moved away")
    }

    @Test func pivotTablesSharingAnAnchor() {
        var first = regionPivot()
        first.values = [PivotValue(sourceColumn: 4)]
        var book = book([first, regionPivot()])
        #expect(book.shown("I1") == .text("SUM of Units"))
        book.editPivots { $0.removeFirst() }
        #expect(book.shown("I1") == .text("SUM of Sales"))
        book.expectMatchesFull()
    }

    @Test func pivotTablesOfPivotTables() {
        var report = Sheet(name: "Report")
        report.pivotTables = [PivotTable(anchor: CellAddress(a1: "A1")!, source: "Data!H1:I3", rows: [PivotGroup(sourceColumn: 1)],
                                         values: [PivotValue(sourceColumn: 0, summary: .countA)])]
        var data = pivotSheet(salesRows)
        data.pivotTables = [regionPivot()]
        var book = PivotBook([report, data])
        #expect(book.block("A1:B4", sheet: 0) == [["SUM of Sales", "COUNTA of Region"], ["6", "1"], ["37", "1"], ["Grand Total", "2"]])
        book.set(["D6": 40], sheet: 1)
        #expect(book.block("A2:A3", sheet: 0) == [["37"], ["45"]])
        book.expectMatchesFull()
    }

    @Test func namedRangeSources() {
        var data = pivotSheet(salesRows)
        data.pivotTables = [regionPivot(source: "Sales")]
        var book = PivotBook([data], namedRanges: [NamedRange(name: "Sales", reference: "Data!$A$1:$E$6")])
        #expect(book.shown("I4") == .number(43))
        book.workbook.namedRanges = [NamedRange(name: "Sales", reference: "Data!$A$1:$E$4")]
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book.block("H1:I4") == [["Region", "SUM of Sales"], ["East", "30"], ["West", "5"], ["Grand Total", "35"]])
        book.set(["D2": 1])
        #expect(book.shown("I2") == .number(21))
        book.expectMatchesFull()
    }

    @Test func filtersWithFormulasRecomputeEveryTime() {
        var pivot = regionPivot()
        pivot.filters = [PivotFilter(sourceColumn: 3, criterion: FilterCriterion(condition: CellCondition(.customFormula, ["=$D2>$K$1"])))]
        var book = book([pivot])
        book.set(["K1": 6])
        #expect(book.block("H1:I3") == [["Region", "SUM of Sales"], ["East", "37"], ["Grand Total", "37"]])
        book.set(["K1": 15])
        #expect(book.block("H2:I3") == [["East", "20"], ["Grand Total", "20"]])
        #expect(book.engine.hasVolatileFormulas)
        book.expectMatchesFull()
    }

    @Test func aPivotTableInsideItsOwnSourceIsCircular() {
        var book = book([PivotTable(anchor: CellAddress(a1: "B8")!, source: "A1:E20", rows: [PivotGroup(sourceColumn: 0)],
                                    values: [PivotValue(sourceColumn: 3)])])
        #expect(book.shown("B8") == err(.reference))
        #expect(message(book.shown("B8")) == FormulaErrors.circularMessage)
        book.set(["D2": 50])
        #expect(message(book.shown("B8")) == FormulaErrors.circularMessage)
        book.expectMatchesFull()
    }

    @Test func structuralChangesRebuildPivotTables() {
        var book = book([regionPivot()])
        book.workbook.apply(.insertRows(at: 0, count: 2), toSheet: 0)
        book.engine.recalculateAll(&book.workbook, now: book.now)
        #expect(book.block("H3:I6") == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
    }

    /// A formula computed while a pivot table's filter formula runs (shifted to each record) isn't shifted.
    @Test func filterFormulasDontShiftFormulasTheyRead() {
        var sheet = pivotSheet([["Group", "Value"], ["a", 1], ["b", 2], ["c", 3]])
        sheet[CellAddress(a1: "Z9")!] = Cell(formula: "=A2")
        sheet.pivotTables = [PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B4", rows: [PivotGroup(sourceColumn: 0)],
                                        values: [PivotValue(sourceColumn: 1)],
                                        filters: [PivotFilter(sourceColumn: 0, criterion: FilterCriterion(condition: CellCondition(.customFormula, ["=IF(ROW()>2, $A2<>$Z$9, TRUE)"])))])]
        let book = PivotBook([sheet])
        #expect(book.shown("Z9") == .text("a"))
        #expect(book.block("E2:E4") == [["a"], ["b"], ["c"]])
        book.expectMatchesFull()
    }

    @Test func slicersFilterPivotTablesOverTheSameRange() {
        var data = pivotSheet(salesRows)
        data.pivotTables = [regionPivot()]
        var book = PivotBook([data, Sheet(name: "Controls")])
        func slicer(_ spec: SlicerSpec) -> SheetObject {
            SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 0, column: 0), width: 200, height: 120), content: .slicer(spec))
        }
        book.workbook.sheets[1].objects = [slicer(SlicerSpec(range: "Data!A1:E6", column: 0, criterion: FilterCriterion(hiddenValues: ["West"])))]
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book.block("H1:I3") == [["Region", "SUM of Sales"], ["East", "37"], ["Grand Total", "37"]])
        #expect(PivotEngine.output(for: book.workbook.sheets[0].pivotTables[0], sheetIndex: 0, workbook: book.workbook).rowCount == 3)
        book.expectMatchesFull("slicer added")
        // Editing the slicer updates the pivot table.
        book.workbook.sheets[1].objects[0].content = .slicer(SlicerSpec(range: "Data!A1:E6", column: 3,
                                                                        criterion: FilterCriterion(condition: CellCondition(.lessThan, ["8"]))))
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book.block("H2:I4") == [["East", "7"], ["West", "6"], ["Grand Total", "13"]])
        book.expectMatchesFull("slicer edited")
        // Slicers that don't apply to pivot tables, or cover other cells, change nothing.
        book.workbook.sheets[1].objects = [
            slicer(SlicerSpec(range: "Data!A1:E6", column: 0, criterion: FilterCriterion(hiddenValues: ["East"]), appliesToPivotTables: false)),
            slicer(SlicerSpec(range: "Data!A1:E5", column: 0, criterion: FilterCriterion(hiddenValues: ["East"]))),
        ]
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book.block("H2:I4") == [["East", "37"], ["West", "6"], ["Grand Total", "43"]])
        book.expectMatchesFull("slicers that don't apply")
        book.workbook.sheets[1].objects = []
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book.shown("I4") == .number(43))
    }

    /// Random pivot table edits (added, changed, moved, removed), source edits and formulas reading pivot cells,
    /// without cycles, so recalculations stay incremental; after each step everything must equal a full recalculation.
    @Test(.serialized, arguments: [11, 2027, 90210]) func randomPivotEditsMatchFullRecalculation(seed: Int) {
        var random = SeededGenerator(state: UInt64(seed))
        var data = Sheet(name: "Data", rowCount: 30, columnCount: 6)
        let regions: [CellInput] = ["East", "West", "North", .empty, "east"]
        func record() -> [CellInput] {
            let number = { (range: ClosedRange<Int>) -> CellInput in .value(.number(Double(Int.random(in: range, using: &random)))) }
            return [regions.randomElement(using: &random)!, .value(.text("Rep \(Int.random(in: 1...4, using: &random))")),
                    number(1...3), number(-5...20), Int.random(in: 0..<6, using: &random) == 0 ? "n/a" : number(0...9)]
        }
        for (column, title) in ["Region", "Rep", "Year", "Sales", "Units"].enumerated() { data[0, column] = Cell(value: .text(title)) }
        for row in 1...15 { for (column, input) in record().enumerated() { data[row, column] = input.cell } }
        var workbook = Workbook(sheets: [Sheet(name: "Report", rowCount: 40, columnCount: 14), data],
                                namedRanges: [NamedRange(name: "Sales", reference: "Data!$A$1:$E$20")])
        let engine = FormulaEngine()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        engine.recalculateAll(&workbook, now: now)

        func randomPivot(id: UUID = UUID()) -> PivotTable {
            let sources = ["Data!A1:E20", "Data!A:E", "Sales", "Data!A1:E12", "Data!B1:D18", "Data!A1:E1"]
            let width = 5
            func group() -> PivotGroup {
                PivotGroup(sourceColumn: Int.random(in: 0..<width, using: &random), ascending: Bool.random(using: &random),
                           showsTotals: Int.random(in: 0..<3, using: &random) > 0, sortByValue: Bool.random(using: &random) ? 0 : nil)
            }
            var filters: [PivotFilter] = []
            if Int.random(in: 0..<4, using: &random) == 0 {
                filters.append(PivotFilter(sourceColumn: 3, criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["3"]))))
            }
            if Int.random(in: 0..<5, using: &random) == 0 {
                filters.append(PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["West", ""])))
            }
            return PivotTable(id: id, anchor: CellAddress(row: Int.random(in: 0..<36, using: &random), column: Int.random(in: 0..<11, using: &random)),
                              source: sources.randomElement(using: &random)!,
                              rows: (0..<Int.random(in: 0...2, using: &random)).map { _ in group() },
                              columns: (0..<Int.random(in: 0...1, using: &random)).map { _ in group() },
                              values: (0..<Int.random(in: 0...2, using: &random)).map { _ in
                                  PivotValue(sourceColumn: Int.random(in: 2..<width, using: &random),
                                             summary: PivotValue.Summary.allCases.randomElement(using: &random)!,
                                             showAs: Int.random(in: 0..<4, using: &random) == 0 ? .percentOfGrandTotal : .default)
                              },
                              filters: filters, valuesInRows: Int.random(in: 0..<4, using: &random) == 0)
        }
        func readerFormula() -> String {
            let column = CellAddress.columnName(Int.random(in: 0..<11, using: &random)), row = Int.random(in: 1...30, using: &random)
            switch Int.random(in: 0..<7, using: &random) {
            case 0: return "=SUM(A1:K40)"
            case 1: return "=COUNTA(\(column)1:\(column)40)"
            case 2: return "=\(column)\(row)&\"\""
            case 3: return "=IFERROR(INDEX(A1:K40, \(row), \(Int.random(in: 1...11, using: &random))), \"-\")"
            case 4: return "=GETPIVOTDATA(\"SUM of Sales\", \(column)\(row))"
            case 5: return "=IFERROR(GETPIVOTDATA(\"Sales\", \(column)\(row), \"Region\", \"East\"), \"-\")"
            default: return "=SEQUENCE(\(Int.random(in: 1...3, using: &random)), \(Int.random(in: 1...2, using: &random)))"
            }
        }

        var shownSteps = 0
        for step in 0..<300 {
            var changed: [SheetCell] = []
            switch Int.random(in: 0..<11, using: &random) {
            case 10:
                // Slicers over the data, which pivot tables reading "Data!A1:E20" (or "Sales") apply.
                if Bool.random(using: &random), !workbook.sheets[1].objects.isEmpty {
                    workbook.sheets[1].objects.removeLast()
                } else {
                    let criterion = Bool.random(using: &random) ? FilterCriterion(hiddenValues: ["West", "Rep 2"])
                        : FilterCriterion(condition: CellCondition(.greaterThan, ["\(Int.random(in: 0...8, using: &random))"]))
                    let spec = SlicerSpec(range: Bool.random(using: &random) ? "Data!A1:E20" : "A1:E12", column: Int.random(in: 0..<5, using: &random),
                                          criterion: criterion, appliesToPivotTables: Int.random(in: 0..<4, using: &random) > 0)
                    workbook.sheets[1].objects.append(SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 0, column: 0), width: 100, height: 100),
                                                                  content: .slicer(spec)))
                }
            case 0..<3:
                var pivots = workbook.sheets[0].pivotTables
                switch Int.random(in: 0..<5, using: &random) {
                case 0, 1: if pivots.count < 3 { pivots.append(randomPivot()) } else { pivots.removeLast() }
                case 2: if !pivots.isEmpty { pivots.remove(at: Int.random(in: 0..<pivots.count, using: &random)) }
                case 3:
                    if !pivots.isEmpty {
                        let index = Int.random(in: 0..<pivots.count, using: &random)
                        let anchor = pivots[index].anchor
                        pivots[index] = randomPivot(id: pivots[index].id)
                        pivots[index].anchor = anchor
                    }
                default:
                    if !pivots.isEmpty {
                        let index = Int.random(in: 0..<pivots.count, using: &random)
                        pivots[index].anchor = CellAddress(row: Int.random(in: 0..<36, using: &random), column: Int.random(in: 0..<11, using: &random))
                    }
                }
                workbook.sheets[0].pivotTables = pivots
            case 3..<8:
                let row = Int.random(in: 1...19, using: &random)
                if Int.random(in: 0..<6, using: &random) == 0 {
                    for column in 0..<5 { workbook.sheets[1][row, column] = Cell() }
                    for column in 0..<5 { changed.append(SheetCell(sheet: workbook.sheets[1].id, address: CellAddress(row: row, column: column))) }
                } else {
                    let column = Int.random(in: 0..<5, using: &random)
                    let input = Int.random(in: 0..<5, using: &random) == 0 ? CellInput.formula("=D\(Int.random(in: 2...20, using: &random))*2") : record()[column]
                    workbook.sheets[1][row, column] = input.cell
                    changed.append(SheetCell(sheet: workbook.sheets[1].id, address: CellAddress(row: row, column: column)))
                }
            default:
                // Readers live in columns L to N, next to (and sometimes in the way of) the pivot tables.
                let address = CellAddress(row: Int.random(in: 0..<40, using: &random), column: Int.random(in: 11..<14, using: &random))
                workbook.sheets[0][address] = Int.random(in: 0..<5, using: &random) == 0 ? Cell() : Cell(formula: readerFormula())
                changed.append(SheetCell(sheet: workbook.sheets[0].id, address: address))
            }
            engine.recalculate(&workbook, changed: changed, now: now)
            var fresh = workbook
            FormulaEngine().recalculateAll(&fresh, now: now)
            expectSameResults(workbook, fresh, "seed \(seed) step \(step):")
            if workbook.sheets[0].pivotTables.contains(where: { (workbook.sheets[0].spillRanges[$0.anchor]?.cellCount ?? 0) > 1 }) { shownSteps += 1 }
        }
        #expect(shownSteps > 100)
    }

    /// 100,000 records, two row groups, a column group and two values.
    @Test func largePivotTablesAreFast() {
        let regions = ["North", "South", "East", "West", "Central", "Islands", "Coast", "Hills"]
        let products = (1...12).map { "Product \($0)" }
        var sheet = Sheet(name: "Data", rowCount: 100_001, columnCount: 8)
        for (column, title) in ["Region", "Rep", "Product", "Sales", "Units"].enumerated() { sheet[0, column] = Cell(value: .text(title)) }
        var random = SeededGenerator(state: 42)
        for row in 1...100_000 {
            sheet[row, 0] = Cell(value: .text(regions[Int.random(in: 0..<regions.count, using: &random)]))
            sheet[row, 1] = Cell(value: .text("Rep \(Int.random(in: 1...25, using: &random))"))
            sheet[row, 2] = Cell(value: .text(products[Int.random(in: 0..<products.count, using: &random)]))
            sheet[row, 3] = Cell(value: .number(Double(Int.random(in: 1...10_000, using: &random)) / 100))
            sheet[row, 4] = Cell(value: .number(Double(Int.random(in: 1...20, using: &random))))
        }
        var workbook = Workbook(sheets: [sheet, Sheet(name: "Report", rowCount: 400, columnCount: 40)])
        let pivot = PivotTable(anchor: CellAddress(row: 0, column: 0), source: "Data!A1:E100001",
                               rows: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 1)], columns: [PivotGroup(sourceColumn: 2)],
                               values: [PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 4, summary: .average)])
        let clock = ContinuousClock()
        var fastest = Duration.seconds(1000)
        var output = PivotOutput()
        for _ in 0..<3 {
            fastest = min(fastest, clock.measure { output = PivotEngine.output(for: pivot, sheetIndex: 1, workbook: workbook) })
        }
        #expect(output.rowCount == 3 + 8 * 25 + 8 + 1)
        #expect(output.columnCount == 2 + 13 * 2)
        // The grand total of the sales sum matches SUM over the column.
        let total = FormulaEngine.evaluate("=SUM(Data!D2:D100001)", inSheet: 1, at: CellAddress(row: 0, column: 0), workbook: workbook)
        #expect(close(output.values[output.rowCount - 1][output.columnCount - 2], total.numberValue ?? 0, tolerance: 1e-12))

        workbook.sheets[1].pivotTables = [pivot]
        let engine = FormulaEngine()
        let full = clock.measure { engine.recalculateAll(&workbook) }
        #expect(workbook.sheets[1].spillRanges[CellAddress(row: 0, column: 0)]?.rowCount == output.rowCount)
        workbook.sheets[0][5, 3] = Cell(value: .number(1))
        let edit = clock.measure {
            engine.recalculate(&workbook, changed: [SheetCell(sheet: workbook.sheets[0].id, address: CellAddress(row: 5, column: 3))])
        }
        print("Pivot table over 100,000 records: \(fastest) (fastest of 3); full recalculation \(full); source edit \(edit)")
        #if DEBUG
        let scale = 15.0
        #else
        let scale = 1.0
        #endif
        #expect(fastest < .milliseconds(150 * scale))
        #expect(edit < .milliseconds(250 * scale))
    }
}
