import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaHyperlinkTests {
    private func links(_ book: TestBook) -> [String: String] {
        Dictionary(uniqueKeysWithValues: book.workbook.sheets[0].formulaLinks.map { ($0.key.a1, $0.value) })
    }

    @Test func hyperlinkShowsItsLabel() {
        #expect(eval("=HYPERLINK(\"https://example.com\", \"Example\")") == .text("Example"))
        #expect(eval("=HYPERLINK(\"https://example.com\")") == .text("https://example.com"))
        // An empty cell as the label shows the URL; "" shows nothing.
        #expect(eval("=HYPERLINK(\"example.com\", A1)") == .text("example.com"))
        #expect(eval("=HYPERLINK(\"example.com\", \"\")") == .text(""))
        // Labels keep their type.
        #expect(eval("=HYPERLINK(\"example.com\", 5)+1") == .number(6))
        #expect(eval("=HYPERLINK(123)") == .text("123"))
        #expect(eval("=HYPERLINK(1/0, \"x\")") == err(.divideByZero))
        #expect(eval("=HYPERLINK(\"a.com\", NA())") == err(.notAvailable))
        #expect(message(eval("=HYPERLINK()")) == "Wrong number of arguments to HYPERLINK. Expected between 1 and 2 arguments, but got 0 arguments.")
        #expect(FormulaEngine.functionInfo(named: "hyperlink")?.category == "Web")
        #expect(FormulaEngine.functionInfo(named: "HYPERLINK")?.syntax == "HYPERLINK(url, [link_label])")
    }

    @Test func linkTargets() {
        #expect(FunctionTable.hyperlinkTarget("https://example.com/a?b=1") == "https://example.com/a?b=1")
        #expect(FunctionTable.hyperlinkTarget(" example.com ") == "http://example.com")
        #expect(FunctionTable.hyperlinkTarget("www.example.com:8080/x") == "http://www.example.com:8080/x")
        #expect(FunctionTable.hyperlinkTarget("MAILTO:someone@example.com") == "MAILTO:someone@example.com")
        #expect(FunctionTable.hyperlinkTarget("ftp://files.example.com") == "ftp://files.example.com")
        #expect(FunctionTable.hyperlinkTarget("javascript:alert(1)") == nil)
        #expect(FunctionTable.hyperlinkTarget("file:///etc/hosts") == nil)
        #expect(FunctionTable.hyperlinkTarget("#gid=0&range=A1") == "#gid=0&range=A1")
        #expect(FunctionTable.hyperlinkTarget("  ") == nil)
    }

    @Test func formulaCellsRecordTheirLinks() {
        let book = TestBook([
            "A1": "=HYPERLINK(\"https://example.com/a\", \"A\")",
            "A2": "=HYPERLINK(\"example.com\")",
            "A3": "=IF(B1>0, HYPERLINK(\"https://b.com\", \"B\"), \"none\")",
            "A4": "=IFERROR(HYPERLINK(\"https://c.com\", 1/0), HYPERLINK(\"https://d.com\", \"D\"))",
            "A5": "=CHOOSE(2, \"x\", HYPERLINK(\"https://e.com\", \"E\"))",
            "A6": "=HYPERLINK(\"https://f.com\", \"F\") & \"!\"",
            "A7": "=A1",
            "A8": "=HYPERLINK(\"javascript:alert(1)\", \"bad\")",
            "A9": "=HYPERLINK(\"#gid=0\", \"First sheet\")",
            "A10": "=IFS(FALSE, 1, TRUE, HYPERLINK(\"https://g.com\"))",
            "A11": "=SWITCH(2, 1, \"one\", 2, HYPERLINK(\"https://h.com\", \"two\"))",
            "A12": "=IFNA(HYPERLINK(\"https://i.com\", \"I\"), \"x\")",
            "A13": "=HYPERLINK(\"https://j.com\", 1/0)",
            "A14": "=HYPERLINK(\"\", \"empty\")",
            "A15": "=HYPERLINK({\"https://k.com\", \"https://l.com\"})",
            "A16": "=IF(HYPERLINK(\"https://m.com\", TRUE), \"yes\")",
            "A17": "=IFERROR(HYPERLINK(\"https://n.com\", \"N\"), \"x\")",
            "B1": 1,
        ])
        #expect(links(book) == [
            "A1": "https://example.com/a", "A2": "http://example.com", "A3": "https://b.com", "A4": "https://d.com",
            "A5": "https://e.com", "A9": "#gid=0", "A10": "https://g.com", "A11": "https://h.com", "A12": "https://i.com",
            "A17": "https://n.com",
        ])
        #expect(book["A3"] == .text("B") && book["A16"] == .text("yes"))
        #expect(book.workbook.sheets[0].link(at: CellAddress(a1: "A1")!) == "https://example.com/a")
        #expect(book.workbook.sheets[0].link(at: CellAddress(a1: "A6")!) == nil)
    }

    @Test func linksFollowRecalculation() {
        var book = TestBook(["A1": "=IF(B1>0, HYPERLINK(C1, \"go\"), \"none\")", "B1": 1, "C1": "https://b.com"])
        #expect(links(book) == ["A1": "https://b.com"])
        book.set("B1", 0)
        #expect(links(book).isEmpty)
        book.set("B1", 2)
        #expect(links(book) == ["A1": "https://b.com"])
        book.set("C1", "c.com")
        #expect(links(book) == ["A1": "http://c.com"])
        book.set("A1", 5)
        #expect(links(book).isEmpty)
        book.set("A1", "=HYPERLINK(\"x.com\")")
        #expect(links(book) == ["A1": "http://x.com"])
        book.set("A1", .empty)
        #expect(links(book).isEmpty)

        book.set("A2", "=HYPERLINK(\"y.com\")")
        book.workbook.sheets[0].formulaLinks[CellAddress(a1: "Z9")!] = "stale"
        book.engine.recalculateAll(&book.workbook, now: book.now)
        #expect(links(book) == ["A2": "http://y.com"])
    }

    @Test func linksThroughDynamicReferencesStayCurrent() {
        var book = TestBook(["A1": "=IF(INDIRECT(\"B1\")>0, HYPERLINK(\"https://b.com\"), \"\")", "B1": 1])
        #expect(links(book) == ["A1": "https://b.com"])
        book.set("B1", -1)
        #expect(links(book).isEmpty)
    }
}
