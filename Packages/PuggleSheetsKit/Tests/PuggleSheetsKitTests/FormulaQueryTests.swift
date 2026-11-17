import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaQueryTests {
    private static func date(_ year: Int, _ month: Int, _ day: Int) -> CellInput { .value(.number(DateSerial.serial(year: year, month: month, day: day))) }

    private static let staff: [String: CellInput] = [
        "A1": "Name", "B1": "Dept", "C1": "Salary", "D1": "Hired", "E1": "Senior",
        "A2": "John", "B2": "Eng", "C2": 1000, "D2": date(2020, 1, 15), "E2": true,
        "A3": "Dave", "B3": "Eng", "C3": 500, "D3": date(2021, 3, 10), "E3": false,
        "A4": "Sally", "B4": "Eng", "C4": 600, "D4": date(2019, 7, 1), "E4": true,
        "A5": "Ben", "B5": "Sales", "C5": 400, "D5": date(2022, 2, 28), "E5": false,
        "A6": "Dana", "B6": "Sales", "C6": 350, "D6": date(2020, 11, 11), "E6": false,
        "A7": "Mike", "B7": "Marketing", "C7": 800, "D7": date(2018, 5, 5), "E7": true,
    ]

    /// QUERY's spilled result as text rows.
    private func query(_ query: String, data: String = "A1:E7", headers: String = "") -> [[String]] {
        let formula = "=QUERY(\(data), \"\(query.replacingOccurrences(of: "\"", with: "\"\""))\"\(headers.isEmpty ? "" : ", " + headers))"
        return spilled(formula, Self.staff, at: "H1").map { $0.map(pivotText) }
    }

    private func error(_ query: String, data: String = "A1:E7") -> String? {
        let book = TestBook(Self.staff.merging(["H1": .formula("=QUERY(\(data), \"\(query)\")")]) { $1 })
        return message(book["H1"])
    }

    @Test func selectWhereOrder() {
        #expect(query("select A, C where C > 500 order by C desc") == [["Name", "Salary"], ["John", "1000"], ["Mike", "800"], ["Sally", "600"]])
        #expect(query("select A order by C limit 2 offset 1") == [["Name"], ["Ben"], ["Dave"]])
        #expect(query("select A, B order by B desc, C") == [["Name", "Dept"], ["Dana", "Sales"], ["Ben", "Sales"], ["Mike", "Marketing"],
                                                            ["Dave", "Eng"], ["Sally", "Eng"], ["John", "Eng"]])
        #expect(query("select `A`, C*2 where C < 400") == [["Name", "C*2"], ["Dana", "700"]])
        #expect(query("where B = 'Marketing'") == [["Name", "Dept", "Salary", "Hired", "Senior"], ["Mike", "Marketing", "800", "43225", "TRUE"]])
        #expect(query("select * where A = 'Ben'").count == 2)
        #expect(query("select A where not E and C >= 400") == [["Name"], ["Dave"], ["Ben"]])
        #expect(query("select A where C is null") == [["Name"]])
        #expect(query("select A where B != 'Eng' and (C < 380 or C > 700)") == [["Name"], ["Dana"], ["Mike"]])
    }

    @Test func textTestsAndDates() {
        #expect(query("select A where A contains 'a'") == [["Name"], ["Dave"], ["Sally"], ["Dana"]])
        #expect(query("select A where A starts with 'D'") == [["Name"], ["Dave"], ["Dana"]])
        #expect(query("select A where A ends with 'e'") == [["Name"], ["Dave"], ["Mike"]])
        #expect(query("select A where A matches '.*an.*'") == [["Name"], ["Dana"]])
        #expect(query("select A where A like '_a%'") == [["Name"], ["Dave"], ["Sally"], ["Dana"]])
        #expect(query("select A where D > date '2020-06-01'") == [["Name"], ["Dave"], ["Ben"], ["Dana"]])
        #expect(query("select A, year(D), month(D) where E = true") == [["Name", "year(D)", "month(D)"], ["John", "2020", "0"],
                                                                       ["Sally", "2019", "6"], ["Mike", "2018", "4"]])
        #expect(query("select upper(A) where D < datetime '2019-01-01 00:00:00'") == [["upper(A)"], ["MIKE"]])
        #expect(query("select A, C format C '$#,##0.00'")[1] == ["John", "$1,000.00"])
    }

    @Test func groupPivotAndLabels() {
        #expect(query("select B, sum(C) group by B") == [["Dept", "sum Salary"], ["Eng", "2100"], ["Marketing", "800"], ["Sales", "750"]])
        #expect(query("select B, count(A), avg(C) group by B order by count(A) desc label count(A) 'People'")
                == [["Dept", "People", "avg Salary"], ["Eng", "3", "700"], ["Sales", "2", "375"], ["Marketing", "1", "800"]])
        #expect(query("select B, sum(C) group by B pivot E") == [["Dept", "FALSE", "TRUE"], ["Eng", "500", "1600"], ["Marketing", "", "800"],
                                                                 ["Sales", "750", ""]])
        #expect(query("select sum(C) pivot B") == [["Eng", "Marketing", "Sales"], ["2100", "800", "750"]])
        #expect(query("select sum(C), max(C) pivot B")[0] == ["Eng sum Salary", "Eng max Salary", "Marketing sum Salary", "Marketing max Salary",
                                                             "Sales sum Salary", "Sales max Salary"])
        #expect(query("select count(A), min(A), max(D)") == [["count Name", "min Name", "max Hired"], ["6", "Ben", "44620"]])
        #expect(query("select B, sum(C) where C > 450 group by B label B 'Team', sum(C) 'Total'") == [["Team", "Total"], ["Eng", "2100"], ["Marketing", "800"]])
    }

    @Test func headersAndArrays() {
        #expect(query("select A", data: "A2:E7", headers: "0") == [["John"], ["Dave"], ["Sally"], ["Ben"], ["Dana"], ["Mike"]])
        #expect(query("select A limit 1", headers: "1") == [["Name"], ["John"]])
        #expect(query("select A limit 1", headers: "2") == [["Name John"], ["Dave"]])
        // All-text data has no guessed header row.
        #expect(query("select A limit 2", data: "A1:B7") == [["Name"], ["John"]])
        #expect(query("select Col2 where Col1 >= 2", data: "{1,\"a\";2,\"b\";3,\"c\"}") == [["b"], ["c"]])
        // Values of a column's minority type count as null.
        #expect(query("select Col1 where Col1 > 1", data: "{\"n\";1;2;\"x\";3}") == [["n"], ["2"], ["3"]])
        #expect(query("select B, sum(C) group by B", data: "A2:E7", headers: "0") == [["", "sum C"], ["Eng", "2100"], ["Marketing", "800"],
                                                                                     ["Sales", "750"]])
    }

    @Test func errors() {
        let prefix = "Unable to parse query string for Function QUERY parameter 2: "
        #expect(error("select Z") == prefix + "NO_COLUMN: Z")
        #expect(error("select A, sum(C)") == prefix + "ADD_COL_TO_GROUP_BY_OR_AGG: A")
        #expect(error("select sum(A)") == prefix + "AVG_SUM_ONLY_NUMERIC")
        #expect(error("selec A") == prefix + "PARSE_ERROR: Encountered \"selec\" at line 1, column 1.")
        #expect(error("select A where") == prefix + "PARSE_ERROR: Encountered \"<EOF>\" at line 1, column 15.")
        #expect(error("select A where sum(C) > 1") == prefix + "CANNOT_USE_AGGREGATION_IN_WHERE")
        #expect(error("select A where D > date '2020-13-01'")?.hasPrefix(prefix + "PARSE_ERROR: Invalid date literal") == true)
        let book = TestBook(Self.staff.merging(["H1": "=QUERY(A2:E7, \"select A where C > 5000\", 0)"]) { $1 })
        #expect(message(book["H1"]) == "Query completed with an empty output.")
        #expect(TestBook(Self.staff.merging(["H1": "=QUERY(A1:E7, \"select A\", -2)"]) { $1 })["H1"] == err(.value))
    }

    @Test func resultsSpillAndRecalculate() {
        var book = TestBook(Self.staff.merging(["H1": "=QUERY(A1:E7, \"select B, sum(C) group by B\")"]) { $1 })
        #expect(book.workbook.sheets[0].spillRanges[CellAddress(a1: "H1")!] == CellRange(a1: "H1:I4"))
        book.set("C7", 900)
        #expect(book.workbook.sheets[0].value(at: CellAddress(a1: "I3")!) == .number(900))
        book.set("B5", "Support")
        #expect(book.workbook.sheets[0].spillRanges[CellAddress(a1: "H1")!] == CellRange(a1: "H1:I5"))
    }

    @Test func queriesOverManyRowsAreFast() {
        var sheet = Sheet(name: "Data", rowCount: 100_001, columnCount: 6)
        for (column, title) in ["Region", "Rep", "Product", "Sales", "Units"].enumerated() { sheet[0, column] = Cell(value: .text(title)) }
        var random = SeededGenerator(state: 99)
        let regions = ["North", "South", "East", "West", "Central"]
        for row in 1...100_000 {
            sheet[row, 0] = Cell(value: .text(regions[Int.random(in: 0..<5, using: &random)]))
            sheet[row, 1] = Cell(value: .text("Rep \(Int.random(in: 1...40, using: &random))"))
            sheet[row, 2] = Cell(value: .text("P\(Int.random(in: 1...12, using: &random))"))
            sheet[row, 3] = Cell(value: .number(Double(Int.random(in: 1...10_000, using: &random)) / 100))
            sheet[row, 4] = Cell(value: .number(Double(Int.random(in: 1...20, using: &random))))
        }
        var report = Sheet(name: "Report", rowCount: 100, columnCount: 10)
        report[0, 0] = Cell(formula: "=QUERY(Data!A1:E100001, \"select A, sum(D), count(B) where E > 5 group by A order by sum(D) desc\")")
        var workbook = Workbook(sheets: [sheet, report])
        let clock = ContinuousClock()
        var fastest = Duration.seconds(100)
        for _ in 0..<3 {
            var copy = workbook
            fastest = min(fastest, clock.measure { FormulaEngine().recalculateAll(&copy) })
            workbook = copy
        }
        #expect(workbook.sheets[1].spillRanges[CellAddress(row: 0, column: 0)] == CellRange(a1: "A1:C6"))
        #expect(workbook.sheets[1].value(at: CellAddress(row: 0, column: 1)) == .text("sum Sales"))
        print("QUERY over 100,000 rows: \(fastest) (fastest of 3)")
        #if DEBUG
        let scale = 15.0
        #else
        let scale = 1.0
        #endif
        #expect(fastest < .milliseconds(150 * scale))
    }
}
