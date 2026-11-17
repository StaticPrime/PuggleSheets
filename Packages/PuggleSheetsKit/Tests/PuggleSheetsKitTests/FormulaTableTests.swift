import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaTableTests {
    private static let cells: [String: CellInput] = [
        "A1": "Region", "B1": "Amount", "C1": "Units",
        "A2": "East", "B2": 10, "C2": 1,
        "A3": "West", "B3": 20, "C3": 2,
        "A4": "East", "B4": 30, "C4": 3,
    ]

    /// A sheet with the table "Sales" over A1:C4 and `formulas`, recalculated.
    private func book(_ formulas: [String: CellInput] = [:]) -> TestBook {
        var book = TestBook(Self.cells.merging(formulas) { $1 })
        book.workbook.sheets[0].tables = [SheetTable(name: "Sales", range: CellRange(a1: "A1:C4")!)]
        book.engine.recalculateAll(&book.workbook, now: book.now)
        return book
    }

    private func value(_ formula: String) -> CellValue {
        book(["Z1": .formula(formula)])["Z1"]
    }

    @Test func structuredReferences() {
        #expect(value("=SUM(Sales[Amount])") == .number(60))
        #expect(value("=SUM(sales[AMOUNT])") == .number(60))
        #expect(value("=SUM(Sales[[Amount]])") == .number(60))
        #expect(value("=ROWS(Sales)") == .number(4))
        #expect(value("=ROWS(Sales[#ALL])") == .number(4))
        #expect(value("=ROWS(Sales[#DATA])") == .number(3))
        #expect(value("=ROWS(Sales[#HEADERS])*10+COLUMNS(Sales[#headers])") == .number(13))
        #expect(value("=Sales[[#HEADERS],[Units]]") == .text("Units"))
        #expect(value("=ROWS(Sales[[#ALL],[Amount]])") == .number(4))
        #expect(value("=SUM(Sales[[Amount]:[Units]])") == .number(66))
        #expect(value("=SUMIF(Sales[Region], \"East\", Sales[Amount])") == .number(40))
        #expect(value("=COUNTA(Sales[Region])") == .number(3))
        #expect(value("=SUM(Nope[Amount])") == err(.name))
        #expect(message(value("=SUM(Sales[Price])")) == "Column 'Price' doesn't exist in table 'Sales'.")
        #expect(value("=Sales[[Amount]") == .error(FormulaErrors.parse))
        #expect(value("=Sales[]") == .error(FormulaErrors.parse))
        #expect(value("=Sales[#Totals]") == .error(FormulaErrors.parse))
    }

    @Test func referencesFollowTheTable() {
        var book = book(["E1": "=SUM(Sales[Amount])", "E2": "=Sales[[#HEADERS],[Amount]]", "E3": "=ROWS(Sales)"])
        book.set("B3", 25)
        #expect(book["E1"] == .number(65))
        // Header edits find the column again.
        book.set("B1", "Revenue")
        #expect(book["E1"] == err(.reference))
        book.set("C1", "Amount")
        #expect(book["E1"] == .number(6))
        #expect(book["E2"] == .text("Amount"))
        book.set("C2", 100)
        #expect(book["E1"] == .number(105))
        // A resized table is noticed on the next recalculation.
        book.workbook.sheets[0][CellAddress(a1: "C5")!] = Cell(value: .number(1000))
        book.workbook.sheets[0].tables[0].range = CellRange(a1: "A1:C5")!
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book["E1"] == .number(1105))
        #expect(book["E3"] == .number(5))
        book.workbook.sheets[0].tables = []
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book["E1"] == err(.name) && book["E3"] == err(.name))
        book.workbook.sheets[0].tables = [SheetTable(name: "SALES", range: CellRange(a1: "A1:C3")!)]
        book.engine.recalculate(&book.workbook, changed: [], now: book.now)
        #expect(book["E1"] == .number(102))
    }

    @Test func renamingTablesAndColumns() {
        #expect(FormulaRewriter.renameTable("=SUM(Sales[Amount])+ROWS(sales)+Sales!A1+SALESX(1)", from: "SALES", to: "Revenue")
                == "=SUM(Revenue[Amount])+ROWS(Revenue)+Sales!A1+SALESX(1)")
        #expect(FormulaRewriter.renameTable("=Other[Amount]", from: "Sales", to: "Revenue") == "=Other[Amount]")
        let formula = "=SUM(Sales[Amount])+Sales[[#HEADERS],[amount]]+SUM(Sales[[Amount]:[Units]])+Other[Amount]+Sales[Units]"
        #expect(FormulaRewriter.renameTableColumn(formula, table: "sales", from: "AMOUNT", to: "Revenue")
                == "=SUM(Sales[Revenue])+Sales[[#HEADERS],[Revenue]]+SUM(Sales[[Revenue]:[Units]])+Other[Amount]+Sales[Units]")
    }

    @Test func referencesPanelIncludesTables() {
        let workbook = book().workbook
        let references = FormulaReferences.references(in: "=SUM(Sales[Amount])+A1+ROWS(Sales)+Nope[X]", workbook: workbook)
        #expect(references.count == 3)
        #expect(references[0].table == "Sales" && references[0].range(rowCount: 1000, columnCount: 26) == CellRange(a1: "B2:B4"))
        #expect(references[0].location == 5 && references[0].length == 13 && references[0].sheet == "Sheet1")
        #expect(references[1].table == nil && references[1].rows == 0...0)
        #expect(references[2].table == "Sales" && references[2].range(rowCount: 1000, columnCount: 26) == CellRange(a1: "A1:C4"))
        #expect(FormulaReferences.references(in: "=SUM(Sales[Amount])").isEmpty)
    }
}
