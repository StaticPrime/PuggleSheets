import Foundation
import Testing
@testable import PuggleSheetsKit

/// Phase 5's model: tables, table references and slicers.
struct TableModelTests {
    static func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    static func salesWorkbook() -> Workbook {
        var sheet = Sheet(name: "Sales")
        for (column, header) in ["Region", "Amount", "Done"].enumerated() { sheet[1, column + 1] = Cell(value: .text(header)) }
        for row in 2...5 {
            sheet[row, 1] = Cell(value: .text(["East", "West"][row % 2]))
            sheet[row, 2] = Cell(value: .number(Double(row * 10)))
        }
        sheet.tables = [SheetTable(name: "Orders", range: range("B2:D6"), columnTypes: [2: .currency, 3: .checkbox],
                                   criteria: [1: FilterCriterion(hiddenValues: ["West"])])]
        return Workbook(sheets: [sheet])
    }

    @Test func tableReferences() {
        let workbook = Self.salesWorkbook()
        #expect(workbook.table(named: "orders")?.table.name == "Orders")
        #expect(workbook.resolveTableReference("Orders")! == (0, Self.range("B2:D6")))
        #expect(workbook.resolveTableReference("Orders[#ALL]")! == (0, Self.range("B2:D6")))
        #expect(workbook.resolveTableReference("Orders[#DATA]")! == (0, Self.range("B3:D6")))
        #expect(workbook.resolveTableReference("Orders[#HEADERS]")! == (0, Self.range("B2:D2")))
        #expect(workbook.resolveTableReference("Orders[amount]")! == (0, Self.range("C3:C6")))
        #expect(workbook.resolveTableReference("Orders[[Amount]]")! == (0, Self.range("C3:C6")))
        #expect(workbook.resolveTableReference("Orders[Missing]") == nil)
        #expect(workbook.resolve("Orders[Amount]", onSheet: 0)! == (0, Self.range("C3:C6")))
        #expect(TableColumnType.currency.numberFormat == "\"$\"#,##0.00" && TableColumnType.checkbox.numberFormat == nil)
    }

    @Test func tablesFollowRowsAndColumns() {
        var workbook = Self.salesWorkbook()
        workbook.apply(.insertColumns(at: 0, count: 1), toSheet: 0)
        var table = workbook.sheets[0].tables[0]
        #expect(table.range == Self.range("C2:E6"))
        #expect(table.columnTypes == [3: .currency, 4: .checkbox] && table.criteria.keys.sorted() == [2])
        workbook.apply(.insertRows(at: 3, count: 2), toSheet: 0)
        table = workbook.sheets[0].tables[0]
        #expect(table.range == Self.range("C2:E8") && table.dataRange == Self.range("C3:E8"))
        workbook.apply(.deleteColumns(at: 3, count: 1), toSheet: 0)
        table = workbook.sheets[0].tables[0]
        #expect(table.range == Self.range("C2:D8") && table.columnTypes == [3: .checkbox])
        workbook.apply(.deleteRows(at: 0, count: 20), toSheet: 0)
        #expect(workbook.sheets[0].tables.isEmpty)
    }

    @Test func slicersFollowRenamedSheets() {
        var workbook = Self.salesWorkbook()
        workbook.sheets.append(Sheet(name: "Dashboard"))
        workbook.sheets[1].objects = [SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 0, column: 0), width: 200, height: 60),
                                                  content: .slicer(SlicerSpec(range: "Sales!B2:D6", column: 0)))]
        workbook.renameSheet(at: 0, to: "Sales 2026")
        #expect(workbook.sheets[1].objects[0].slicer?.range == "'Sales 2026'!B2:D6")
        workbook.apply(.insertRows(at: 0, count: 1), toSheet: 0)
        #expect(workbook.sheets[1].objects[0].slicer?.range == "'Sales 2026'!B3:D7")
    }
}
