import Foundation
import Testing
@testable import PuggleSheetsKit

struct ModelTests {
    @Test func columnNamesRoundTrip() {
        #expect(CellAddress.columnName(0) == "A")
        #expect(CellAddress.columnName(25) == "Z")
        #expect(CellAddress.columnName(26) == "AA")
        #expect(CellAddress.columnName(701) == "ZZ")
        #expect(CellAddress.columnName(702) == "AAA")
        for index in [0, 1, 25, 26, 27, 51, 52, 701, 702, 18_277] {
            #expect(CellAddress.columnIndex(CellAddress.columnName(index)) == index)
        }
        #expect(CellAddress.columnIndex("ab") == 27)
        #expect(CellAddress.columnIndex("") == nil)
        #expect(CellAddress.columnIndex("A1") == nil)
    }

    @Test func parsesAddressesAndRanges() {
        #expect(CellAddress(a1: "B3") == CellAddress(row: 2, column: 1))
        #expect(CellAddress(a1: "$c$10") == CellAddress(row: 9, column: 2))
        #expect(CellAddress(a1: "A0") == nil)
        #expect(CellAddress(a1: "1A") == nil)
        #expect(CellAddress(a1: "A") == nil)
        let range = CellRange(a1: "C4:A1")
        #expect(range?.a1 == "A1:C4")
        #expect(range?.rowCount == 4 && range?.columnCount == 3)
        #expect(CellRange(a1: "B2")?.isSingleCell == true)
        #expect(CellRange(a1: "A1:") == nil)
    }

    @Test func rangeGeometry() {
        let a = CellRange(a1: "A1:C3")!, b = CellRange(a1: "B2:D5")!
        #expect(a.intersection(b)?.a1 == "B2:C3")
        #expect(a.union(b).a1 == "A1:D5")
        #expect(a.intersection(CellRange(a1: "E5")!) == nil)
        #expect(a.contains(CellAddress(a1: "C3")!) && !a.contains(CellAddress(a1: "D3")!))
        #expect(a.offsetBy(rows: 1, columns: 2).a1 == "C2:E4")
    }

    @Test func emptyCellsAreNotStored() {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .number(1))
        var bold = CellFormat()
        bold.bold = true
        sheet[1, 1] = Cell(format: bold)
        #expect(sheet.cells.count == 2)
        sheet[0, 0] = Cell()
        #expect(sheet.cells.count == 1)
        #expect(sheet.usedRange?.a1 == "B2")
        #expect(sheet.contentRange == nil)
    }

    @Test func cellsInRangeUsesEitherStrategy() {
        var sheet = Sheet(name: "Sheet1")
        for row in 0..<10 { sheet[row, 0] = Cell(value: .number(Double(row))) }
        #expect(sheet.cells(in: CellRange(a1: "A3:A5")!).count == 3)
        #expect(sheet.cells(in: CellRange(a1: "A1:Z1000")!).count == 10)
    }

    @Test func insertingAndDeletingRowsMovesEverything() {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .text("top"))
        sheet[4, 0] = Cell(value: .text("five"))
        sheet.rowHeights[4] = 40
        sheet.merges = [CellRange(a1: "A3:B6")!]
        sheet.frozenRows = 2
        sheet.applyStructuralChange(.insertRows(at: 1, count: 2))
        #expect(sheet[6, 0].value == .text("five"))
        #expect(sheet.rowHeights[6] == 40)
        #expect(sheet.merges == [CellRange(a1: "A5:B8")!])
        #expect(sheet.frozenRows == 4)
        #expect(sheet.rowCount == 1002)

        sheet.applyStructuralChange(.deleteRows(at: 1, count: 2))
        #expect(sheet[4, 0].value == .text("five"))
        #expect(sheet.merges == [CellRange(a1: "A3:B6")!])
        #expect(sheet.frozenRows == 2)
        sheet.applyStructuralChange(.deleteRows(at: 3, count: 1))
        #expect(sheet.merges == [CellRange(a1: "A3:B5")!])
        sheet.applyStructuralChange(.deleteRows(at: 2, count: 3))
        #expect(sheet.merges.isEmpty)
        #expect(sheet.cells.count == 1)
        #expect(sheet.rowCount == 996)
    }

    @Test func deletingColumnsShrinksMergesAndFrozenColumns() {
        var sheet = Sheet(name: "Sheet1")
        sheet.merges = [CellRange(a1: "B1:D1")!]
        sheet.frozenColumns = 3
        sheet.columnWidths[3] = 150
        sheet.applyStructuralChange(.deleteColumns(at: 2, count: 1))
        #expect(sheet.merges == [CellRange(a1: "B1:C1")!])
        #expect(sheet.frozenColumns == 2)
        #expect(sheet.columnWidths == [2: 150])
        #expect(sheet.columnCount == 25)
    }

    @Test func shiftingCellsMovesOnlyTheBand() {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .text("A1"))
        sheet[1, 0] = Cell(value: .text("A2"))
        sheet[1, 1] = Cell(value: .text("B2"))
        sheet.validations = [DataValidationRule(ranges: [CellRange(a1: "A2:A5")!], criterion: .list(["x"]))]
        let insert = StructuralChange.insertCells(CellRange(a1: "A1:A2")!, shiftDown: true)
        #expect(insert.map(CellAddress(a1: "A2")!) == CellAddress(a1: "A4"))
        #expect(insert.map(CellAddress(a1: "B2")!) == CellAddress(a1: "B2"))
        #expect(insert.map(CellRange(a1: "A1:B3")!) == CellRange(a1: "A1:B3"))
        sheet.applyStructuralChange(insert)
        #expect(sheet[3, 0].value == .text("A2") && sheet[1, 1].value == .text("B2") && sheet[0, 0].isEmpty)
        #expect(sheet.validations.first?.ranges == [CellRange(a1: "A4:A7")!])

        let delete = StructuralChange.deleteCells(CellRange(a1: "A1:A2")!, shiftUp: true)
        #expect(delete.map(CellAddress(a1: "A1")!) == nil)
        sheet.applyStructuralChange(delete)
        #expect(sheet[1, 0].value == .text("A2") && sheet[0, 0].value == .text("A1"))
    }

    @Test func rulesFollowInsertedRows() {
        var sheet = Sheet(name: "Sheet1")
        sheet.conditionalFormats = [ConditionalFormatRule(ranges: [CellRange(a1: "B2:B10")!],
                                                          style: .condition(CellCondition(.greaterThan, ["5"]), ConditionalFormat(bold: true)))]
        sheet.bandings = [Banding(range: CellRange(a1: "A1:C9")!, headerColor: .white, firstColor: .white, secondColor: .black)]
        sheet.filter = SheetFilter(range: CellRange(a1: "A1:C9")!, criteria: [2: FilterCriterion(hiddenValues: ["x"])])
        sheet.filteredRows = [4]
        sheet.applyStructuralChange(.insertRows(at: 1, count: 2))
        #expect(sheet.conditionalFormats[0].ranges == [CellRange(a1: "B4:B12")!])
        #expect(sheet.bandings[0].range == CellRange(a1: "A1:C11")!)
        #expect(sheet.filter?.range == CellRange(a1: "A1:C11")! && sheet.filteredRows == [6])
        sheet.applyStructuralChange(.deleteColumns(at: 1, count: 1))
        #expect(sheet.conditionalFormats.isEmpty)
        #expect(sheet.filter?.criteria[1] != nil && sheet.filter?.criteria[2] == nil)
    }

    @Test func bandingColors() {
        let red = RGBColor(hex: "FF0000")!, white = RGBColor.white, gray = RGBColor(hex: "EEEEEE")!
        let banding = Banding(range: CellRange(a1: "A1:B5")!, headerColor: red, firstColor: white, secondColor: gray, footerColor: red)
        #expect((0...4).map { banding.color(forRow: $0) } == [red, white, gray, white, red])
        #expect(banding.color(forRow: 5) == nil)
    }

    @Test func namedRangeNames() {
        #expect(NamedRange.isValidName("Sales") && NamedRange.isValidName("_total") && NamedRange.isValidName("Q1.Sales"))
        #expect(!NamedRange.isValidName("A1") && !NamedRange.isValidName("ab12") && !NamedRange.isValidName("1st"))
        #expect(!NamedRange.isValidName("TRUE") && !NamedRange.isValidName("R1C2") && !NamedRange.isValidName("my range"))
        let workbook = Workbook(namedRanges: [NamedRange(name: "Sales", reference: "Sheet1!$A$1:$A$9")])
        #expect(workbook.namedRange("sales")?.reference == "Sheet1!$A$1:$A$9")
    }

    @Test func spilledValuesShowWhereThereIsNoContent() {
        var sheet = Sheet(name: "Sheet1")
        sheet.spilledValues = [CellAddress(a1: "A2")!: .number(2)]
        sheet.spillRanges = [CellAddress(a1: "A1")!: CellRange(a1: "A1:A2")!]
        #expect(sheet.value(at: CellAddress(a1: "A2")!) == .number(2))
        #expect(sheet.spillSource(of: CellAddress(a1: "A2")!) == CellAddress(a1: "A1"))
        var bold = CellFormat()
        bold.bold = true
        sheet[1, 0] = Cell(format: bold)
        #expect(sheet.value(at: CellAddress(a1: "A2")!) == .number(2))
        sheet[1, 0] = Cell(value: .text("typed"))
        #expect(sheet.value(at: CellAddress(a1: "A2")!) == .text("typed"))
    }

    @Test func dateSerials() {
        #expect(DateSerial.serial(year: 1899, month: 12, day: 30) == 0)
        #expect(DateSerial.serial(year: 1900, month: 1, day: 1) == 2)
        #expect(DateSerial.serial(year: 2026, month: 11, day: 16) == 46_342)
        #expect(DateSerial.serial(year: 2026, month: 13, day: 1) == DateSerial.serial(year: 2027, month: 1, day: 1))
        #expect(DateSerial.serial(year: 2026, month: 3, day: 0) == DateSerial.serial(year: 2026, month: 2, day: 28))
        let parts = DateSerial.parts(of: 46_342.75)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 16 && parts.hour == 18 && parts.minute == 0)
        #expect(DateSerial.weekday(of: 46_342) == 2) // Monday
        #expect(DateSerial.weekday(of: 0) == 7)
        let moment = DateSerial.date(fromSerial: 46_342.5, timeZone: TimeZone(identifier: "UTC")!)
        #expect(DateSerial.serial(from: moment, timeZone: TimeZone(identifier: "UTC")!) == 46_342.5)
    }

    @Test func sheetNames() {
        var workbook = Workbook()
        #expect(workbook.newSheetName() == "Sheet2")
        workbook.sheets.append(Sheet(name: "Sheet2"))
        #expect(workbook.newSheetName() == "Sheet3")
        #expect(workbook.sheetIndex(named: "sheet2") == 1)
        #expect(workbook.copyName(for: "Sheet1") == "Copy of Sheet1")
        workbook.sheets.append(Sheet(name: "Copy of Sheet1"))
        #expect(workbook.copyName(for: "Sheet1") == "Copy of Sheet1 2")
    }
}
