import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaRewriterTests {
    private func adjust(_ formula: String, _ change: StructuralChange, sheet: String = "Sheet1",
                        formulaSheet: String = "Sheet1") -> String {
        FormulaRewriter.adjust(formula, for: change, inSheet: sheet, formulaSheet: formulaSheet)
    }

    private func move(_ formula: String, rows: Int = 2, columns: Int = 2, to destination: String = "Sheet1",
                      formulaSheet: String = "Sheet1") -> String {
        FormulaRewriter.move(formula, range: CellRange(a1: "A1:B2")!, inSheet: "Sheet1", rows: rows, columns: columns,
                             toSheet: destination, formulaSheet: formulaSheet)
    }

    @Test func translateShiftsRelativeParts() {
        #expect(FormulaRewriter.translate("=A1+$A$1+A$1+$A1", rows: 2, columns: 1) == "=B3+$A$1+B$1+$A3")
        #expect(FormulaRewriter.translate("=SUM(A1:B2)", rows: 1, columns: 0) == "=SUM(A2:B3)")
        #expect(FormulaRewriter.translate("=SUM(B2:A1)", rows: 1, columns: 0) == "=SUM(B3:A2)")
        #expect(FormulaRewriter.translate("=SUM(A:B)", rows: 5, columns: 1) == "=SUM(B:C)")
        #expect(FormulaRewriter.translate("=SUM(1:2)", rows: 5, columns: 1) == "=SUM(6:7)")
        #expect(FormulaRewriter.translate("=SUM($A:B)", rows: 0, columns: 2) == "=SUM($A:D)")
        #expect(FormulaRewriter.translate("=SUM($1:2)", rows: 3, columns: 0) == "=SUM($1:5)")
        #expect(FormulaRewriter.translate("=Sheet2!A1*'My Sheet'!B2", rows: 1, columns: 1) == "=Sheet2!B2*'My Sheet'!C3")
        #expect(FormulaRewriter.translate("=A2:A", rows: 1, columns: 0) == "=A3:A")
        #expect(FormulaRewriter.translate("=A1", rows: -1, columns: 0) == "=#REF!")
        #expect(FormulaRewriter.translate("=SUM(A1:B2, C3)", rows: 0, columns: -1) == "=SUM(#REF!, B3)")
        #expect(FormulaRewriter.translate("=Sheet2!A1", rows: -1, columns: 0) == "=#REF!")
        #expect(FormulaRewriter.translate("=$A$1", rows: -5, columns: -5) == "=$A$1")
        #expect(FormulaRewriter.translate("=LOG10(A1)", rows: 1, columns: 0) == "=LOG10(A2)")
        #expect(FormulaRewriter.translate("=A1", rows: 0, columns: 0) == "=A1")
        #expect(FormulaRewriter.translate("plain text A1", rows: 1, columns: 1) == "plain text A1")
        #expect(FormulaRewriter.translate("=SUM(A1", rows: 1, columns: 0) == "=SUM(A2")
    }

    @Test func translateKeepsOtherText() {
        #expect(FormulaRewriter.translate("=sum( a1 ,  \"A1\" )", rows: 1, columns: 0) == "=sum( A2 ,  \"A1\" )")
        #expect(FormulaRewriter.translate("=IF( a1 > 0 , \"A1:B2\" , sum( B1 : B3 ) )  ", rows: 1, columns: 0)
            == "=IF( A2 > 0 , \"A1:B2\" , sum( B2:B4 ) )  ")
        #expect(FormulaRewriter.translate("=\"😀\"&A1&TRUE", rows: 1, columns: 0) == "=\"😀\"&A2&TRUE")
        #expect(FormulaRewriter.translate("=A1 + foo + #REF!", rows: 1, columns: 0) == "=A2 + foo + #REF!")
    }

    @Test func adjustForInsertedRows() {
        let change = StructuralChange.insertRows(at: 2, count: 2)
        #expect(adjust("=A1+A3+$A$5", change) == "=A1+A5+$A$7")
        #expect(adjust("=SUM(A1:A3)", change) == "=SUM(A1:A5)")
        #expect(adjust("=SUM(A3:A4)", change) == "=SUM(A5:A6)")
        #expect(adjust("=SUM(A1:A2)", change) == "=SUM(A1:A2)")
        #expect(adjust("=SUM(A3:A1)", change) == "=SUM(A1:A5)")
        #expect(adjust("=SUM(A:A)", change) == "=SUM(A:A)")
        #expect(adjust("=SUM(3:4)", change) == "=SUM(5:6)")
        #expect(adjust("=SUM(1:3)", change) == "=SUM(1:5)")
        #expect(adjust("=SUM(A2:A)", change) == "=SUM(A2:A)")
        #expect(adjust("=SUM(A3:A)", change) == "=SUM(A5:A)")
        #expect(adjust("=Other!A3+A3", change) == "=Other!A3+A5")
        #expect(adjust("=Sheet1!A3+A3", change, formulaSheet: "Other") == "=Sheet1!A5+A3")
        #expect(adjust("='sheet1'!a3", change, formulaSheet: "Other") == "='sheet1'!A5")
        #expect(adjust("=a1+a2", change) == "=a1+a2")
    }

    @Test func adjustForDeletedRows() {
        let change = StructuralChange.deleteRows(at: 2, count: 2)
        #expect(adjust("=A1+A3+A5", change) == "=A1+#REF!+A3")
        #expect(adjust("=SUM(A1:A5)", change) == "=SUM(A1:A3)")
        #expect(adjust("=SUM(A3:A4)", change) == "=SUM(#REF!)")
        #expect(adjust("=SUM(A4:A6)", change) == "=SUM(A3:A4)")
        #expect(adjust("=SUM(A2:A3)", change) == "=SUM(A2:A2)")
        #expect(adjust("=SUM(3:4)", change) == "=SUM(#REF!)")
        #expect(adjust("=SUM(2:6)", change) == "=SUM(2:4)")
        #expect(adjust("=SUM(A:B)", change) == "=SUM(A:B)")
        #expect(adjust("=SUM($A$1:$A$10)", change) == "=SUM($A$1:$A$8)")
        #expect(adjust("=SUM(A4:A)", change) == "=SUM(A3:A)")
        #expect(adjust("=SUM(A3:A)", change) == "=SUM(A3:A)")
    }

    @Test func adjustForColumns() {
        let insert = StructuralChange.insertColumns(at: 1, count: 1)
        #expect(adjust("=A1+B1+$C$1", insert) == "=A1+C1+$D$1")
        #expect(adjust("=SUM(A1:C1)", insert) == "=SUM(A1:D1)")
        #expect(adjust("=SUM(B:C)", insert) == "=SUM(C:D)")
        #expect(adjust("=SUM($A:$B)", insert) == "=SUM($A:$C)")
        #expect(adjust("=SUM(1:1)", insert) == "=SUM(1:1)")
        #expect(adjust("=SUM(B2:2)", insert) == "=SUM(C2:2)")
        let delete = StructuralChange.deleteColumns(at: 1, count: 1)
        #expect(adjust("=A1+B1+C1", delete) == "=A1+#REF!+B1")
        #expect(adjust("=SUM(A:C)", delete) == "=SUM(A:B)")
        #expect(adjust("=SUM(B:B)", delete) == "=SUM(#REF!)")
        #expect(adjust("=SUM(B1:B5)", delete) == "=SUM(#REF!)")
        #expect(adjust("=Sheet2!B1", delete) == "=Sheet2!B1")
        #expect(adjust("=Sheet2!C1", delete, sheet: "Sheet2") == "=Sheet2!B1")
    }

    @Test func insertingCellsShiftsReferencesInsideTheBand() {
        let down = StructuralChange.insertCells(CellRange(a1: "B2:C3")!, shiftDown: true)
        #expect(adjust("=B2+B1+D2+$B$2", down) == "=B4+B1+D2+$B$4")
        #expect(adjust("=SUM(B2:C5)", down) == "=SUM(B4:C7)")
        #expect(adjust("=SUM(B1:B3)", down) == "=SUM(B1:B5)")
        #expect(adjust("=SUM(A2:C2)", down) == "=SUM(A2:C2)")
        #expect(adjust("=SUM(B:B)+SUM(2:3)", down) == "=SUM(B:B)+SUM(2:3)")
        #expect(adjust("=SUM(B2:B)", down) == "=SUM(B4:B)")
        #expect(adjust("=Other!B2", down) == "=Other!B2")
        let right = StructuralChange.insertCells(CellRange(a1: "B2:C3")!, shiftDown: false)
        #expect(adjust("=B2+B4+C3", right) == "=D2+B4+E3")
        #expect(adjust("=SUM(A2:B3)", right) == "=SUM(A2:D3)")
        #expect(adjust("=SUM(A1:B3)", right) == "=SUM(A1:B3)")
        #expect(adjust("=SUM(2:3)+SUM(B:B)", right) == "=SUM(2:3)+SUM(B:B)")
        #expect(adjust("=SUM(B2:2)", right) == "=SUM(D2:2)")
    }

    @Test func deletingCellsShiftsReferencesInsideTheBand() {
        let up = StructuralChange.deleteCells(CellRange(a1: "B2:C3")!, shiftUp: true)
        #expect(adjust("=B2+B4+D4+C5", up) == "=#REF!+B2+D4+C3")
        #expect(adjust("=SUM(B2:C3)", up) == "=SUM(#REF!)")
        #expect(adjust("=SUM(B1:C5)", up) == "=SUM(B1:C3)")
        #expect(adjust("=SUM(B3:C6)", up) == "=SUM(B2:C4)")
        #expect(adjust("=SUM(A1:D5)", up) == "=SUM(A1:D5)")
        let left = StructuralChange.deleteCells(CellRange(a1: "B2:C3")!, shiftUp: false)
        #expect(adjust("=D2+B3+D5", left) == "=B2+#REF!+D5")
        #expect(adjust("=SUM(A2:E2)", left) == "=SUM(A2:C2)")
        #expect(adjust("=SUM(A1:E2)", left) == "=SUM(A1:E2)")
    }

    @Test func cellShiftsAgreeWithStructuralChangeMapping() {
        var random = SeededGenerator(state: 77)
        for _ in 0..<500 {
            let top = Int.random(in: 0..<6, using: &random), left = Int.random(in: 0..<6, using: &random)
            let band = CellRange(rows: top...(top + Int.random(in: 0..<3, using: &random)),
                                 columns: left...(left + Int.random(in: 0..<3, using: &random)))
            let change: StructuralChange = switch Int.random(in: 0..<4, using: &random) {
            case 0: .insertCells(band, shiftDown: true)
            case 1: .insertCells(band, shiftDown: false)
            case 2: .deleteCells(band, shiftUp: true)
            default: .deleteCells(band, shiftUp: false)
            }
            let a = CellAddress(row: Int.random(in: 0..<10, using: &random), column: Int.random(in: 0..<10, using: &random))
            let b = CellAddress(row: Int.random(in: 0..<10, using: &random), column: Int.random(in: 0..<10, using: &random))
            let expectedCell = change.map(a).map { "=" + $0.a1 } ?? "=#REF!"
            #expect(adjust("=" + a.a1, change) == expectedCell, "\(change) \(a.a1)")
            let range = CellRange(a, b)
            let expectedRange = change.map(range).map { "=" + $0.start.a1 + ":" + $0.end.a1 } ?? "=#REF!"
            #expect(adjust("=" + range.start.a1 + ":" + range.end.a1, change) == expectedRange, "\(change) \(range.a1)")
        }
    }

    @Test func moveRelocatesReferencesInsideTheRange() {
        #expect(move("=A1+B2+C3") == "=C3+D4+C3")
        #expect(move("=SUM(A1:B2)+SUM(A1:C3)") == "=SUM(C3:D4)+SUM(A1:C3)")
        #expect(move("=$A$1+A$2") == "=$C$3+C$4")
        #expect(move("=A1", to: "Data") == "=Data!C3")
        #expect(move("=A1", to: "My Data") == "='My Data'!C3")
        #expect(move("=Sheet1!A1", formulaSheet: "Other") == "=Sheet1!C3")
        #expect(move("=Sheet1!A1", to: "Other", formulaSheet: "Other") == "=C3")
        #expect(move("=Sheet1!A1", to: "Data", formulaSheet: "Other") == "=Data!C3")
        #expect(move("=Other!A1") == "=Other!A1")
        #expect(move("=A1", rows: -2, columns: 0) == "=#REF!")
        #expect(move("=SUM(A:A)") == "=SUM(A:A)")
        #expect(move("=SUM(A1:A)") == "=SUM(A1:A)")
        #expect(move("=A1", rows: 0, columns: 0) == "=A1")
    }

    @Test func renameAndRemoveSheets() {
        #expect(FormulaRewriter.renameSheet("=Sheet1!A1+sheet1!B2+A1", from: "Sheet1", to: "Data") == "=Data!A1+Data!B2+A1")
        #expect(FormulaRewriter.renameSheet("=Sheet1!A1", from: "Sheet1", to: "My Data") == "='My Data'!A1")
        #expect(FormulaRewriter.renameSheet("='My Data'!A1:B2", from: "my data", to: "It's") == "='It''s'!A1:B2")
        #expect(FormulaRewriter.renameSheet("=Sheet1!A1", from: "Sheet1", to: "2024") == "='2024'!A1")
        #expect(FormulaRewriter.renameSheet("=Sheet1!A1", from: "Sheet1", to: "A1") == "='A1'!A1")
        #expect(FormulaRewriter.renameSheet("=Sheet1!a1:b$2", from: "Sheet1", to: "Data") == "=Data!a1:b$2")
        #expect(FormulaRewriter.renameSheet("=INDIRECT(\"Sheet1!A1\")", from: "Sheet1", to: "Data") == "=INDIRECT(\"Sheet1!A1\")")
        #expect(FormulaRewriter.renameSheet("=Sheet10!A1", from: "Sheet1", to: "Data") == "=Sheet10!A1")
        #expect(FormulaRewriter.removeSheet("=Sheet2!A1+A1+SUM(Sheet2!A:A)", named: "sheet2") == "=#REF!+A1+SUM(#REF!)")
        #expect(FormulaRewriter.removeSheet("=Sheet3!A1", named: "Sheet2") == "=Sheet3!A1")
    }

    @Test func sheetNameQuoting() {
        #expect(FormulaRewriter.quotedSheetName("Sales") == "Sales")
        #expect(FormulaRewriter.quotedSheetName("Sales_2024") == "Sales_2024")
        #expect(FormulaRewriter.quotedSheetName("Q1 Sales") == "'Q1 Sales'")
        #expect(FormulaRewriter.quotedSheetName("It's") == "'It''s'")
        #expect(FormulaRewriter.quotedSheetName("2024") == "'2024'")
        #expect(FormulaRewriter.quotedSheetName("AB12") == "'AB12'")
        #expect(FormulaRewriter.quotedSheetName("R1C1") == "'R1C1'")
        #expect(FormulaRewriter.quotedSheetName("TRUE") == "'TRUE'")
        #expect(FormulaRewriter.quotedSheetName("Données") == "'Données'")
        #expect(FormulaRewriter.quotedSheetName("a-b") == "'a-b'")
    }

    @Test func rewrittenFormulasStillEvaluate() {
        let book = TestBook([("Sheet1", ["A1": 1, "A2": 2]), ("It's", ["A1": 5])])
        let renamed = FormulaRewriter.renameSheet("=Sheet1!A1+Sheet1!A2", from: "Sheet1", to: "It's")
        #expect(book.evaluate(renamed) == .number(5))
    }

    @Test func referencePositions() {
        let references = FormulaReferences.references(in: "=SUM(A1:B2, 'My Sheet'!C3) + D:D + 2:3 + A2:A")
        #expect(references.count == 5)
        guard references.count == 5 else { return }
        #expect(references[0] == FormulaReference(location: 5, length: 5, sheet: nil, rows: 0...1, columns: 0...1))
        #expect(references[1] == FormulaReference(location: 12, length: 13, sheet: "My Sheet", rows: 2...2, columns: 2...2))
        #expect(references[2] == FormulaReference(location: 29, length: 3, sheet: nil, rows: nil, columns: 3...3))
        #expect(references[3] == FormulaReference(location: 35, length: 3, sheet: nil, rows: 1...2, columns: nil))
        #expect(references[4] == FormulaReference(location: 41, length: 4, sheet: nil, rows: 1...FormulaReference.openEnd,
                                                  columns: 0...0))
        #expect(references[2].range(rowCount: 1000, columnCount: 26) == CellRange(a1: "D1:D1000"))
        #expect(references[4].range(rowCount: 1000, columnCount: 26) == CellRange(a1: "A2:A1000"))
        #expect(FormulaReferences.references(in: "=\"😀\"&a1").map(\.location) == [6])
        #expect(FormulaReferences.references(in: "=SUM(A1:").map(\.length) == [2])
        #expect(FormulaReferences.references(in: "=SUM(B3:A1)").first?.rows == 0...2)
        #expect(FormulaReferences.references(in: "=\"A1\"&LOG10(2)").isEmpty)
        #expect(FormulaReferences.references(in: "A1").isEmpty)
        #expect(FormulaReferences.references(in: "=Sheet1!A1:B2").first?.sheet == "Sheet1")
    }
}
