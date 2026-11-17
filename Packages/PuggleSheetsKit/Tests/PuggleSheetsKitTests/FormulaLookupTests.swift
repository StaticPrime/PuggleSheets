import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaLookupTests {
    let table: [String: CellInput] = [
        "A1": 1, "B1": "one", "C1": 10,
        "A2": 2, "B2": "two", "C2": 20,
        "A3": 3, "B3": "three", "C3": 30,
        "A4": 5, "B4": "five", "C4": 50,
        "E1": "apple", "F1": 1, "E2": "Banana", "F2": 2, "E3": "cherry", "F3": 3,
    ]

    @Test func vlookup() {
        #expect(eval("=VLOOKUP(2, A1:C4, 2, FALSE)", table) == .text("two"))
        #expect(eval("=VLOOKUP(4, A1:C4, 3)", table) == .number(30))
        #expect(eval("=VLOOKUP(4, A1:C4, 3, TRUE)", table) == .number(30))
        #expect(eval("=VLOOKUP(9, A:C, 2)", table) == .text("five"))
        #expect(eval("=VLOOKUP(0, A1:C4, 2)", table) == err(.notAvailable))
        #expect(eval("=VLOOKUP(4, A1:C4, 2, FALSE)", table) == err(.notAvailable))
        #expect(message(eval("=VLOOKUP(4, A1:C4, 2, FALSE)", table)) == "Did not find value '4' in VLOOKUP evaluation.")
        #expect(eval("=VLOOKUP(\"BANANA\", E1:F3, 2, FALSE)", table) == .number(2))
        #expect(eval("=VLOOKUP(\"ch*\", E1:F3, 2, FALSE)", table) == .number(3))
        #expect(eval("=VLOOKUP(\"?pple\", E1:F3, 2, FALSE)", table) == .number(1))
        #expect(eval("=VLOOKUP(\"b\", E1:F3, 2)", table) == .number(1))
        #expect(eval("=VLOOKUP(2, A1:C4, 4, FALSE)", table) == err(.reference))
        #expect(eval("=VLOOKUP(2, A1:C4, 0, FALSE)", table) == err(.value))
        #expect(eval("=VLOOKUP(\"2\", A1:C4, 2, FALSE)", table) == err(.notAvailable))
        #expect(eval("=SUM(VLOOKUP({1;3}, A1:C4, 3, FALSE))", table) == .number(40))
        #expect(eval("=VLOOKUP(NA(), A1:C4, 2, FALSE)", table) == err(.notAvailable))
    }

    @Test func hlookup() {
        let cells: [String: CellInput] = ["A1": 1, "B1": 2, "C1": 3, "A2": "a", "B2": "b", "C2": "c"]
        #expect(eval("=HLOOKUP(2, A1:C2, 2, FALSE)", cells) == .text("b"))
        #expect(eval("=HLOOKUP(2.5, A1:C2, 2)", cells) == .text("b"))
        #expect(eval("=HLOOKUP(2, A1:C2, 3, FALSE)", cells) == err(.reference))
        #expect(eval("=HLOOKUP(7, A1:C2, 2, FALSE)", cells) == err(.notAvailable))
    }

    @Test func match() {
        #expect(eval("=MATCH(3, A1:A4, 0)", table) == .number(3))
        #expect(eval("=MATCH(4, A1:A4)", table) == .number(3))
        #expect(eval("=MATCH(4, A1:A4, 1)", table) == .number(3))
        #expect(eval("=MATCH(\"b*\", E1:E3, 0)", table) == .number(2))
        #expect(eval("=MATCH(\"two\", B1:B4, 0)", table) == .number(2))
        #expect(eval("=MATCH(4, {9,7,5,3,1}, -1)") == .number(3))
        #expect(eval("=MATCH(10, {9,7,5}, -1)") == err(.notAvailable))
        #expect(eval("=MATCH(1, A1:C4, 0)", table) == err(.notAvailable))
        #expect(eval("=MATCH(\"x\", {\"a\",\"x\"}, 0)") == .number(2))
        #expect(eval("=MATCH(0, A1:A4)", table) == err(.notAvailable))
        #expect(message(eval("=MATCH(0, A1:A4)", table)) == "Did not find value '0' in MATCH evaluation.")
    }

    @Test func indexRowsAndColumns() {
        #expect(eval("=INDEX(A1:C4, 2, 3)", table) == .number(20))
        #expect(eval("=INDEX(A1:C4, 0, 3)", table) == .number(10))
        #expect(eval("=SUM(INDEX(A1:C4, 0, 3))", table) == .number(110))
        #expect(eval("=SUM(INDEX(A1:C4, 2, 0))", table) == .number(22))
        #expect(eval("=INDEX(A1:C4, 5, 1)", table) == err(.reference))
        #expect(message(eval("=INDEX(A1:E1, 3)")) == "Function INDEX parameter 2 value is 3. Valid values are between 0 and 1 inclusive.")
        #expect(eval("=INDEX(A1:C4, -1, 1)", table) == err(.value))
        #expect(eval("=INDEX(A1:A4, 3)", table) == .number(3))
        #expect(eval("=ROW(INDEX(A1:C4, 3, 2))", table) == .number(3))
        #expect(eval("=INDEX({1,2;3,4}, 2)") == .number(3))
        #expect(eval("=INDEX({1,2;3,4}, 2, 2)") == .number(4))
        #expect(eval("=SUM(A1:INDEX(A1:A4, 3))", table) == .number(6))
        #expect(eval("=ROW(B5)") == .number(5))
        #expect(eval("=COLUMN(C2)") == .number(3))
        #expect(eval("=ROW()", at: "D7") == .number(7))
        #expect(eval("=COLUMN()", at: "D7") == .number(4))
        #expect(eval("=ROWS(A1:C4)") == .number(4))
        #expect(eval("=COLUMNS(A1:C4)") == .number(3))
        #expect(eval("=ROWS(A:A)") == .number(1000))
        #expect(eval("=COLUMNS(1:1)") == .number(26))
        #expect(eval("=ROWS(5)") == .number(1))
        #expect(eval("=ROW(\"A1\")") == err(.value))
        #expect(eval("=SUM(ROW(A1:A3))") == .number(6))
        #expect(eval("=SUM(COLUMN(A1:C1))") == .number(6))
    }

    @Test func xlookupAndXmatch() {
        #expect(eval("=XLOOKUP(3, A1:A4, B1:B4)", table) == .text("three"))
        #expect(eval("=XLOOKUP(4, A1:A4, B1:B4)", table) == err(.notAvailable))
        #expect(eval("=XLOOKUP(4, A1:A4, B1:B4, \"none\")", table) == .text("none"))
        #expect(eval("=XLOOKUP(4, A1:A4, B1:B4, , 1)", table) == .text("five"))
        #expect(eval("=XLOOKUP(4, A1:A4, B1:B4, , -1)", table) == .text("three"))
        #expect(eval("=XLOOKUP(\"b*\", E1:E3, F1:F3, , 2)", table) == .number(2))
        #expect(eval("=XLOOKUP(\"b*\", E1:E3, F1:F3)", table) == err(.notAvailable))
        #expect(eval("=XLOOKUP(2, {1,2,2,3}, {\"a\",\"b\",\"c\",\"d\"}, , 0, -1)") == .text("c"))
        #expect(eval("=XLOOKUP(4, A1:A4, B1:B4, , -1, 2)", table) == .text("three"))
        #expect(eval("=XLOOKUP(4, A1:A4, B1:B4, , 1, 2)", table) == .text("five"))
        #expect(eval("=XLOOKUP(3, A1:A4, B1:B4, , 0, 2)", table) == .text("three"))
        #expect(eval("=XLOOKUP(3, A1:A4, A1:C4)", table) == .number(3))
        #expect(eval("=COLUMNS(XLOOKUP(3, A1:A4, A1:C4))", table) == .number(3))
        #expect(eval("=XLOOKUP(3, A1:A4, B1:B3)", table) == err(.value))
        #expect(eval("=XLOOKUP(1, A1:A4, B1:B4, , 3)", table) == err(.value))
        #expect(eval("=XLOOKUP(\"c\", {\"a\",\"b\",\"c\"}, {1,2,3})") == .number(3))
        #expect(eval("=XMATCH(5, A1:A4)", table) == .number(4))
        #expect(eval("=XMATCH(4, A1:A4, 1)", table) == .number(4))
        #expect(eval("=XMATCH(4, A1:A4, -1)", table) == .number(3))
        #expect(eval("=XMATCH(\"cherry\", E1:E3)", table) == .number(3))
        #expect(eval("=XMATCH(3, {5,4,3,2,1}, 0, -2)") == .number(3))
        #expect(eval("=XMATCH(9, A1:A4)", table) == err(.notAvailable))
    }

    @Test func lookupAndChoose() {
        #expect(eval("=LOOKUP(4, A1:A4, B1:B4)", table) == .text("three"))
        #expect(eval("=LOOKUP(3, A1:C4)", table) == .number(30))
        #expect(eval("=LOOKUP(2, {1,2,3;\"a\",\"b\",\"c\"})") == .text("b"))
        #expect(eval("=LOOKUP(0, A1:A4, B1:B4)", table) == err(.notAvailable))
        #expect(eval("=CHOOSE(2, \"a\", \"b\", \"c\")") == .text("b"))
        #expect(eval("=CHOOSE(2.9, \"a\", \"b\", \"c\")") == .text("b"))
        #expect(eval("=CHOOSE(4, \"a\", \"b\", \"c\")") == err(.value))
        #expect(eval("=CHOOSE(1, \"a\", 1/0)") == .text("a"))
        #expect(eval("=SUM(CHOOSE(2, A1:A4, C1:C4))", table) == .number(110))
        #expect(eval("=SUM(CHOOSE({1,2}, 1, 10))") == .number(11))
    }

    @Test func indirectAndOffset() {
        let book = TestBook([("Sheet1", ["A1": 1, "A2": 2, "B1": 3, "B2": 4, "C1": "A2"]), ("Other Sheet", ["A1": 100])])
        #expect(book.evaluate("=INDIRECT(\"A2\")") == .number(2))
        #expect(book.evaluate("=INDIRECT(C1)") == .number(2))
        #expect(book.evaluate("=SUM(INDIRECT(\"A1:B2\"))") == .number(10))
        #expect(book.evaluate("=SUM(INDIRECT(\"A:A\"))") == .number(3))
        #expect(book.evaluate("=INDIRECT(\"'Other Sheet'!A1\")") == .number(100))
        #expect(book.evaluate("=INDIRECT(\"Other Sheet!A1\")") == .number(100))
        #expect(book.evaluate("=INDIRECT(\"R2C2\", FALSE)") == .number(4))
        #expect(book.evaluate("=INDIRECT(\"R[-99]C[-25]\", FALSE)", at: "Z100") == .number(1))
        #expect(book.evaluate("=SUM(INDIRECT(\"R1C1:R2C2\", FALSE))") == .number(10))
        #expect(book.evaluate("=INDIRECT(\"nonsense!!\")") == err(.reference))
        #expect(book.evaluate("=INDIRECT(\"Nope!A1\")") == err(.reference))
        #expect(book.evaluate("=INDIRECT(\"A1001\")") == err(.reference))
        #expect(book.evaluate("=OFFSET(A1, 1, 1)") == .number(4))
        #expect(book.evaluate("=SUM(OFFSET(A1, 0, 0, 2, 2))") == .number(10))
        #expect(book.evaluate("=ROWS(OFFSET(A1, 0, 0, 3))") == .number(3))
        #expect(book.evaluate("=SUM(OFFSET(A1:B2, 0, 1))") == .number(7))
        #expect(book.evaluate("=OFFSET(A1, -1, 0)") == err(.reference))
        #expect(book.evaluate("=OFFSET(A1, 0, 0, 0)") == err(.reference))
        #expect(book.evaluate("=OFFSET(5, 1, 1)") == err(.value))
    }

    @Test func address() {
        #expect(eval("=ADDRESS(1, 1)") == .text("$A$1"))
        #expect(eval("=ADDRESS(2, 28, 2)") == .text("AB$2"))
        #expect(eval("=ADDRESS(2, 3, 3)") == .text("$C2"))
        #expect(eval("=ADDRESS(2, 3, 4)") == .text("C2"))
        #expect(eval("=ADDRESS(2, 3, 1, FALSE)") == .text("R2C3"))
        #expect(eval("=ADDRESS(2, 3, 4, FALSE)") == .text("R[2]C[3]"))
        #expect(eval("=ADDRESS(1, 1, 1, TRUE, \"My Sheet\")") == .text("'My Sheet'!$A$1"))
        #expect(eval("=ADDRESS(1, 1, 1, TRUE, \"Sheet2\")") == .text("Sheet2!$A$1"))
        #expect(eval("=ADDRESS(0, 1)") == err(.value))
        #expect(eval("=ADDRESS(1, 1, 5)") == err(.value))
        #expect(eval("=INDIRECT(ADDRESS(2, 1))", ["A2": 7]) == .number(7))
    }
}
