import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaNamedRangeTests {
    private func book(_ cells: [String: CellInput], data: [String: CellInput] = [:], names: [NamedRange]) -> TestBook {
        var sheets = [Sheet(name: "Sheet1"), Sheet(name: "Data")]
        for (a1, input) in cells { sheets[0][CellAddress(a1: a1)!] = input.cell }
        for (a1, input) in data { sheets[1][CellAddress(a1: a1)!] = input.cell }
        var book = TestBook([("Sheet1", [:])])
        book.workbook = Workbook(sheets: sheets, namedRanges: names)
        book.engine.recalculateAll(&book.workbook, now: book.now)
        return book
    }

    @Test func namesResolveToTheirRanges() {
        let names = [NamedRange(name: "Sales", reference: "Sheet1!$A$1:$A$3"), NamedRange(name: "Rate", reference: "Data!$B$1"),
                     NamedRange(name: "Local", reference: "C1:C2"), NamedRange(name: "Totals.2026", reference: "'Data'!A1:A2")]
        let book = book(["A1": 1, "A2": 2, "A3": 3, "C1": 10, "C2": 20,
                         "E1": "=SUM(Sales)", "E2": "=SUM(sales)*Rate", "E3": "=SUM(Local)", "E4": "=ROWS(SALES)",
                         "E5": "=SUM(Totals.2026)", "E6": "=ISREF(Rate)", "E7": "=INDEX(Sales, 2)", "E8": "=SUM(INDIRECT(\"Sales\"))"],
                        data: ["A1": 5, "A2": 6, "B1": 2], names: names)
        #expect(book["E1"] == .number(6))
        #expect(book["E2"] == .number(12))
        #expect(book["E3"] == .number(30))
        #expect(book["E4"] == .number(3))
        #expect(book["E5"] == .number(11))
        #expect(book["E6"] == .boolean(true))
        #expect(book["E7"] == .number(2))
        #expect(book["E8"] == .number(6))
    }

    @Test func unknownAndBrokenNames() {
        let names = [NamedRange(name: "Gone", reference: "Missing!A1"), NamedRange(name: "Junk", reference: "not a range")]
        let book = book(["A1": "=foo", "A2": "=SUM(Gone)", "A3": "=Junk", "A4": "=IFERROR(foo, 1)"], names: names)
        #expect(book["A1"] == err(.name))
        #expect(message(book["A1"]) == "Unknown range name: 'foo'.")
        #expect(book["A2"] == err(.reference))
        #expect(book["A3"] == err(.reference))
        #expect(book["A4"] == .number(1))
    }

    @Test func formulasUsingNamesFollowTheirCells() {
        var named = book(["A1": 1, "A2": 2, "B1": "=SUM(Items)", "B2": "=B1*Factor"], data: ["C3": 10],
                         names: [NamedRange(name: "Items", reference: "Sheet1!$A$1:$A$5"), NamedRange(name: "Factor", reference: "Data!$C$3")])
        #expect(named["B2"] == .number(30))
        named.set("A4", 7)
        #expect(named["B1"] == .number(10))
        #expect(named["B2"] == .number(100))
        named.set("C3", 2, sheet: 1)
        #expect(named["B2"] == .number(20))
        named.set("C1", "=SUM(Items)+1")
        #expect(named["C1"] == .number(11))
    }

    @Test func editingNamesRecalculates() {
        var named = book(["A1": 1, "A2": 2, "B1": "=SUM(Items)"], names: [NamedRange(name: "Items", reference: "Sheet1!A1")])
        #expect(named["B1"] == .number(1))
        named.workbook.namedRanges[0].reference = "Sheet1!A1:A2"
        named.engine.recalculate(&named.workbook, changed: [SheetCell](), now: named.now)
        #expect(named["B1"] == .number(3))
        named.workbook.namedRanges = []
        named.engine.recalculateAll(&named.workbook, now: named.now)
        #expect(named["B1"] == err(.name))
    }

    @Test func namesAreNotRewritten() {
        #expect(FormulaRewriter.translate("=SUM(Sales)+A1", rows: 1, columns: 0) == "=SUM(Sales)+A2")
        #expect(FormulaReferences.references(in: "=SUM(Sales)+A1").map(\.location) == [12])
    }
}
