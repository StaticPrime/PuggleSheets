import Foundation
import Testing
@testable import PuggleSheetsKit

// MARK: Helpers

/// What a pivot cell shows, compactly: numbers as formulas print them, blanks as "".
func pivotText(_ value: CellValue) -> String {
    switch value {
    case .empty: ""
    case .number(let number): NumberText.general(number)
    case .text(let text): text
    case .boolean(let boolean): boolean ? "TRUE" : "FALSE"
    case .error(let error): error.code
    }
}

func pivotGrid(_ output: PivotOutput) -> [[String]] {
    output.values.map { $0.map(pivotText) }
}

/// Roles as letters: h(eader), l(abel), v(alue), t(otal), g(rand total), e(mpty).
func pivotRoles(_ output: PivotOutput) -> [String] {
    output.roles.map { row in
        String(row.map { role -> Character in
            switch role {
            case .header: "h"
            case .rowLabel: "l"
            case .value: "v"
            case .total: "t"
            case .grandTotal: "g"
            case .empty: "e"
            }
        })
    }
}

/// A sheet holding `rows` from `origin` down ("=…" strings become formulas).
func pivotSheet(_ rows: [[CellInput]], name: String = "Data", origin: String = "A1",
                rowCount: Int = Sheet.defaultRowCount, columnCount: Int = Sheet.defaultColumnCount) -> Sheet {
    var sheet = Sheet(name: name, rowCount: rowCount, columnCount: columnCount)
    let start = CellAddress(a1: origin)!
    for (r, row) in rows.enumerated() {
        for (c, input) in row.enumerated() where !(input.cell.value == .empty && input.cell.formula == nil) {
            sheet[start.row + r, start.column + c] = input.cell
        }
    }
    return sheet
}

/// The sales table used by most pivot tests, at A1:E6.
let salesRows: [[CellInput]] = [
    ["Region", "Rep", "Product", "Sales", "Units"],
    ["East", "Alice", "Apple", 10, 1],
    ["East", "Bob", "Banana", 20, 2],
    ["West", "Carol", "Apple", 5, 3],
    ["East", "Alice", "Banana", 7, 4],
    ["West", "Dan", "Cherry", 1, 5],
]

/// A pivot table on the sales data, anchored at H1 of the same sheet.
func salesPivot(rows: [PivotGroup] = [], columns: [PivotGroup] = [], values: [PivotValue] = [], filters: [PivotFilter] = [],
                valuesInRows: Bool = false, source: String = "A1:E6") -> PivotTable {
    PivotTable(anchor: CellAddress(a1: "H1")!, source: source, rows: rows, columns: columns, values: values, filters: filters,
               valuesInRows: valuesInRows)
}

func pivotOutput(_ pivot: PivotTable, _ sheets: [Sheet], sheet: Int = 0, namedRanges: [NamedRange] = []) -> PivotOutput {
    var workbook = Workbook(sheets: sheets, namedRanges: namedRanges)
    FormulaEngine().recalculateAll(&workbook)
    return PivotEngine.output(for: pivot, sheetIndex: sheet, workbook: workbook)
}

func salesOutput(_ pivot: PivotTable) -> PivotOutput {
    pivotOutput(pivot, [pivotSheet(salesRows)])
}

// MARK: Tests

struct PivotEngineTests {
    @Test func rowGroupWithOneValue() {
        let output = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(output) == [["Region", "SUM of Sales"], ["East", "37"], ["West", "6"], ["Grand Total", "43"]])
        #expect(pivotRoles(output) == ["hh", "lv", "lv", "gg"])
        #expect(output.rowCount == 4 && output.columnCount == 2)
        #expect(output.numberFormats.allSatisfy { $0.allSatisfy { $0 == nil } })
    }

    @Test func rowAndColumnGroups() {
        let output = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], columns: [PivotGroup(sourceColumn: 2)],
                                            values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(output) == [
            ["SUM of Sales", "Product", "", "", ""],
            ["Region", "Apple", "Banana", "Cherry", "Grand Total"],
            ["East", "10", "27", "", "37"],
            ["West", "5", "", "1", "6"],
            ["Grand Total", "15", "27", "1", "43"],
        ])
        #expect(pivotRoles(output) == ["hhhhh", "hhhhg", "lvvvg", "lvvvg", "ggggg"])
    }

    @Test func nestedGroupsWithSubtotalsAndSeveralValues() {
        let output = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 1)],
                                            columns: [PivotGroup(sourceColumn: 2)],
                                            values: [PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 4, summary: .countA)]))
        #expect(pivotGrid(output) == [
            ["", "", "Product", "Values", "", "", "", "", "", ""],
            ["", "", "Apple", "", "Banana", "", "Cherry", "", "Grand Total", ""],
            ["Region", "Rep", "SUM of Sales", "COUNTA of Units", "SUM of Sales", "COUNTA of Units", "SUM of Sales",
             "COUNTA of Units", "SUM of Sales", "COUNTA of Units"],
            ["East", "Alice", "10", "1", "7", "1", "", "", "17", "2"],
            ["", "Bob", "", "", "20", "1", "", "", "20", "1"],
            ["East Total", "", "10", "1", "27", "2", "", "", "37", "3"],
            ["West", "Carol", "5", "1", "", "", "", "", "5", "1"],
            ["", "Dan", "", "", "", "", "1", "1", "1", "1"],
            ["West Total", "", "5", "1", "", "", "1", "1", "6", "2"],
            ["Grand Total", "", "15", "2", "27", "2", "1", "1", "43", "5"],
        ])
        #expect(pivotRoles(output) == ["hhhhhhhhhh", "hhhhhhhhgg", "hhhhhhhhgg", "llvvvvvvgg", "llvvvvvvgg", "ttttttttgg",
                                       "llvvvvvvgg", "llvvvvvvgg", "ttttttttgg", "gggggggggg"])
    }

    @Test func nestedColumnGroupsGetSubtotalColumns() {
        let output = salesOutput(salesPivot(columns: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 2)],
                                            values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(output) == [
            ["SUM of Sales", "Region", "Product", "", "", "", "", ""],
            ["", "East", "", "East Total", "West", "", "West Total", "Grand Total"],
            ["", "Apple", "Banana", "", "Apple", "Cherry", "", ""],
            ["", "10", "27", "37", "5", "1", "6", "43"],
        ])
        #expect(pivotRoles(output) == ["hhhhhhhh", "hhhthhtg", "hhhthhtg", "lvvtvvtg"])
    }

    @Test func valuesStackedInRows() {
        let output = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)],
                                            values: [PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 4, summary: .average)],
                                            valuesInRows: true))
        #expect(pivotGrid(output) == [
            ["Region", "Values", ""],
            ["East", "SUM of Sales", "37"],
            ["", "AVERAGE of Units", NumberText.general(7.0 / 3)],
            ["West", "SUM of Sales", "6"],
            ["", "AVERAGE of Units", "4"],
            ["Grand Total", "SUM of Sales", "43"],
            ["", "AVERAGE of Units", "3"],
        ])
        #expect(pivotRoles(output) == ["hhh", "llv", "llv", "llv", "llv", "ggg", "ggg"])
    }

    @Test func valuesOnlyGiveOneHeaderRowAndOneValueRow() {
        let output = salesOutput(salesPivot(values: [PivotValue(sourceColumn: 3), PivotValue(sourceColumn: 4, summary: .max)]))
        #expect(pivotGrid(output) == [["SUM of Sales", "MAX of Units"], ["43", "5"]])
        #expect(pivotRoles(output) == ["hh", "vv"])
        let single = salesOutput(salesPivot(values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(single) == [["SUM of Sales"], ["43"]])
    }

    @Test func rowsWithoutValuesShowLabelsOnly() {
        let output = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 1)]))
        #expect(pivotGrid(output) == [
            ["Region", "Rep"], ["East", "Alice"], ["", "Bob"], ["East Total", ""], ["West", "Carol"], ["", "Dan"],
            ["West Total", ""], ["Grand Total", ""],
        ])
        let columnsOnly = salesOutput(salesPivot(columns: [PivotGroup(sourceColumn: 0)]))
        #expect(pivotGrid(columnsOnly) == [["", "Region", "", ""], ["", "East", "West", "Grand Total"]])
    }

    @Test func nothingConfiguredOrBadSourceGivesNothing() {
        #expect(salesOutput(salesPivot()) == PivotOutput())
        #expect(salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], source: "Nowhere!A1:B5")) == PivotOutput())
        #expect(salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], source: "not a range")) == PivotOutput())
        #expect(salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], source: "MissingName")) == PivotOutput())
        let workbook = Workbook(sheets: [pivotSheet(salesRows)])
        #expect(PivotEngine.sourceError("Nowhere!A1:B5", workbook: workbook).message == "Unresolved sheet name 'Nowhere'.")
        #expect(PivotEngine.sourceError("bad", workbook: workbook).message == "Unable to parse range: bad")
    }

    @Test func headerOnlySourceStillShowsHeadings() {
        let output = pivotOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], values: [PivotValue(sourceColumn: 3)], source: "A1:E1"),
                                 [pivotSheet(salesRows)])
        #expect(pivotGrid(output) == [["Region", "SUM of Sales"], ["Grand Total", ""]])
    }

    /// Every summary agrees with the function of the same name over the group's values.
    @Test(arguments: PivotValue.Summary.allCases) func summariesMatchTheirFunctions(summary: PivotValue.Summary) {
        let rows: [[CellInput]] = [
            ["Group", "Value"], ["a", 1], ["a", 2], ["a", "x"], ["a", true], ["a", .empty], ["a", 2], ["b", 3], ["c", "y"],
        ]
        var workbook = Workbook(sheets: [pivotSheet(rows)])
        FormulaEngine().recalculateAll(&workbook)
        let pivot = PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B9", rows: [PivotGroup(sourceColumn: 0)],
                               values: [PivotValue(sourceColumn: 1, summary: summary)])
        let output = PivotEngine.output(for: pivot, sheetIndex: 0, workbook: workbook)
        func function(_ range: String) -> CellValue {
            FormulaEngine.evaluate("=\(summary.rawValue)(\(range))", inSheet: 0, at: CellAddress(a1: "Z1")!, workbook: workbook)
        }
        let expected = [function("B2:B7"), function("B8"), function("B9"), function("B2:B9")]
        for (index, value) in expected.enumerated() {
            let cell = output.values[index + 1][1]
            #expect(cell == value, "\(summary) row \(index): \(cell) vs \(value)")
            #expect(cell.errorValue?.message == value.errorValue?.message)
            if case .number(let x) = cell, case .number(let y) = value { #expect(x == y) }
        }
    }

    @Test func errorsPassThroughExceptForCounts() {
        let rows: [[CellInput]] = [["Group", "Value"], ["a", 1], ["a", .error(.notAvailable)], ["a", 2]]
        func value(_ summary: PivotValue.Summary) -> CellValue {
            let output = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B4", rows: [PivotGroup(sourceColumn: 0)],
                                                values: [PivotValue(sourceColumn: 1, summary: summary)]), [pivotSheet(rows)])
            return output.values[1][1]
        }
        #expect(value(.sum) == err(.notAvailable))
        #expect(value(.max) == err(.notAvailable))
        #expect(value(.countUnique) == err(.notAvailable))
        #expect(value(.countA) == .number(3))
        #expect(value(.count) == .number(2))
    }

    @Test func percentagesOfRowColumnAndGrandTotal() {
        func output(_ showAs: PivotValue.ShowAs) -> PivotOutput {
            salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], columns: [PivotGroup(sourceColumn: 2)],
                                   values: [PivotValue(sourceColumn: 3, showAs: showAs)]))
        }
        let row = output(.percentOfRow)
        #expect(close(row.values[2][1], 10.0 / 37) && close(row.values[2][2], 27.0 / 37) && row.values[2][4] == .number(1))
        #expect(close(row.values[4][1], 15.0 / 43) && row.values[4][4] == .number(1))
        #expect(row.values[3][2] == .empty)
        #expect(row.numberFormats[2][1] == "0.00%" && row.numberFormats[4][4] == "0.00%")
        #expect(row.numberFormats[2][0] == nil && row.numberFormats[1][1] == nil)
        let column = output(.percentOfColumn)
        #expect(close(column.values[2][1], 10.0 / 15) && close(column.values[3][1], 5.0 / 15) && column.values[4][1] == .number(1))
        #expect(close(column.values[2][4], 37.0 / 43))
        let total = output(.percentOfGrandTotal)
        #expect(close(total.values[2][1], 10.0 / 43) && close(total.values[3][3], 1.0 / 43) && total.values[4][4] == .number(1))

        let zero = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B3", rows: [PivotGroup(sourceColumn: 0)],
                                          values: [PivotValue(sourceColumn: 1, showAs: .percentOfRow)]),
                               [pivotSheet([["Group", "Value"], ["a", 0], ["b", 2]])])
        #expect(zero.values[1][1] == err(.divideByZero))
        #expect(zero.values[2][1] == .number(1))
    }

    @Test func labelsSortByTypeThenValue() {
        let labels: [CellInput] = [3, "banana", "Apple", true, false, .empty, 1, .error(.notAvailable), "apple"]
        let rows: [[CellInput]] = [["Label", "Value"]] + labels.map { [$0, 1] }
        func order(ascending: Bool) -> [String] {
            let output = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B10",
                                                rows: [PivotGroup(sourceColumn: 0, ascending: ascending, showsTotals: false)],
                                                values: [PivotValue(sourceColumn: 1)]), [pivotSheet(rows)])
            return output.values.dropFirst().map { pivotText($0[0]) }
        }
        #expect(order(ascending: true) == ["", "1", "3", "Apple", "apple", "banana", "FALSE", "TRUE", "#N/A"])
        #expect(order(ascending: false) == ["#N/A", "TRUE", "FALSE", "banana", "apple", "Apple", "3", "1", ""])
    }

    @Test func groupsSortByAValue() {
        func reps(_ summary: PivotValue.Summary, ascending: Bool) -> [String] {
            let output = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 1, ascending: ascending, sortByValue: 0)],
                                                values: [PivotValue(sourceColumn: 3, summary: summary)]))
            return output.values.dropFirst().map { pivotText($0[0]) }
        }
        #expect(reps(.sum, ascending: false) == ["Bob", "Alice", "Carol", "Dan", "Grand Total"])
        #expect(reps(.sum, ascending: true) == ["Dan", "Carol", "Alice", "Bob", "Grand Total"])
        // Ties go by label.
        #expect(reps(.countA, ascending: true) == ["Bob", "Carol", "Dan", "Alice", "Grand Total"])
        #expect(reps(.countA, ascending: false) == ["Alice", "Dan", "Carol", "Bob", "Grand Total"])
        // Column groups sort by their totals over all rows.
        let output = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)],
                                            columns: [PivotGroup(sourceColumn: 2, ascending: false, sortByValue: 0)],
                                            values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(output)[1] == ["Region", "Banana", "Apple", "Cherry", "Grand Total"])
        // An index past the values falls back to labels.
        let fallback = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 1, sortByValue: 5)], values: [PivotValue(sourceColumn: 3)]))
        #expect(fallback.values.dropFirst().map { pivotText($0[0]) } == ["Alice", "Bob", "Carol", "Dan", "Grand Total"])
    }

    @Test func totalsCanBeTurnedOff() {
        let rows = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0, showsTotals: false), PivotGroup(sourceColumn: 1)],
                                          values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(rows) == [["Region", "Rep", "SUM of Sales"], ["East", "Alice", "17"], ["", "Bob", "20"],
                                    ["West", "Carol", "5"], ["", "Dan", "1"]])
        let inner = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 1, showsTotals: false)],
                                           values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(inner).map { $0[0] } == ["Region", "East", "", "East Total", "West", "", "West Total", "Grand Total"])
        let columns = salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], columns: [PivotGroup(sourceColumn: 2, showsTotals: false)],
                                             values: [PivotValue(sourceColumn: 3)]))
        #expect(pivotGrid(columns)[1] == ["Region", "Apple", "Banana", "Cherry"])
        #expect(pivotGrid(columns).last == ["Grand Total", "15", "27", "1"])
    }

    @Test func headingsAndValueNames() {
        var rows = salesRows
        rows[0][2] = .empty
        let output = pivotOutput(salesPivot(rows: [PivotGroup(sourceColumn: 2)],
                                            values: [PivotValue(sourceColumn: 3, name: "Revenue"), PivotValue(sourceColumn: 2, summary: .countA)]),
                                 [pivotSheet(rows)])
        #expect(pivotGrid(output)[0] == ["Column C", "Revenue", "COUNTA of Column C"])

        let shifted = Workbook(sheets: [pivotSheet(rows, origin: "B3")])
        let pivot = PivotTable(anchor: CellAddress(a1: "J1")!, source: "B3:F8")
        #expect(PivotEngine.sourceHeaders(for: pivot, sheetIndex: 0, workbook: shifted) == ["Region", "Rep", "Column D", "Sales", "Units"])
        #expect(PivotEngine.sourceHeaders(for: PivotTable(anchor: CellAddress(row: 0, column: 0), source: "Gone!A1:B2"),
                                          sheetIndex: 0, workbook: shifted).isEmpty)
    }

    @Test func numberFormatsComeFromTheSource() {
        var sheet = pivotSheet([["When", "Amount"], [46000, 1.5], [46000, 2], [46001, 4]])
        sheet[CellAddress(a1: "A2")!].format.numberFormat = "M/d/yyyy"
        sheet[CellAddress(a1: "A4")!].format.numberFormat = "yyyy-mm-dd"
        sheet[CellAddress(a1: "B2")!].format.numberFormat = "$#,##0.00"
        func output(_ summary: PivotValue.Summary) -> PivotOutput {
            pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B4", rows: [PivotGroup(sourceColumn: 0)],
                                   values: [PivotValue(sourceColumn: 1, summary: summary)]), [sheet])
        }
        let sum = output(.sum)
        #expect(sum.numberFormats[1] == ["M/d/yyyy", "$#,##0.00"])
        #expect(sum.numberFormats[2] == ["yyyy-mm-dd", "$#,##0.00"])
        #expect(sum.numberFormats[3] == [nil, "$#,##0.00"])
        for summary in [PivotValue.Summary.average, .max, .min, .median, .product] { #expect(output(summary).numberFormats[1][1] == "$#,##0.00") }
        for summary in [PivotValue.Summary.countA, .count, .countUnique, .variance] { #expect(output(summary).numberFormats[1][1] == nil) }

        // Subtotal labels show the label as formatted.
        let nested = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B4",
                                            rows: [PivotGroup(sourceColumn: 0), PivotGroup(sourceColumn: 1)],
                                            values: [PivotValue(sourceColumn: 1)]), [sheet])
        #expect(pivotGrid(nested).map { $0[0] }.contains("12/9/2025 Total"))
    }

    @Test func filtersWorkLikeSheetFilters() {
        func regions(_ filters: [PivotFilter]) -> [[String]] {
            pivotGrid(salesOutput(salesPivot(rows: [PivotGroup(sourceColumn: 0)], values: [PivotValue(sourceColumn: 3)], filters: filters)))
        }
        #expect(regions([PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["West"]))])
                == [["Region", "SUM of Sales"], ["East", "37"], ["Grand Total", "37"]])
        #expect(regions([PivotFilter(sourceColumn: 3, criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["6"])))])
                == [["Region", "SUM of Sales"], ["East", "37"], ["Grand Total", "37"]])
        // Custom formulas count relative references from the source's first data row.
        #expect(regions([PivotFilter(sourceColumn: 0, criterion: FilterCriterion(condition: CellCondition(.customFormula, ["=$E2>=3"])))])
                == [["Region", "SUM of Sales"], ["East", "7"], ["West", "6"], ["Grand Total", "13"]])
        // Every filter applies.
        #expect(regions([PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["West"])),
                         PivotFilter(sourceColumn: 1, criterion: FilterCriterion(hiddenValues: ["Bob"]))])
                == [["Region", "SUM of Sales"], ["East", "17"], ["Grand Total", "17"]])
        // Filters on columns outside the source are ignored; empty criteria do nothing.
        #expect(regions([PivotFilter(sourceColumn: 9, criterion: FilterCriterion(hiddenValues: ["East"])),
                         PivotFilter(sourceColumn: 0)]).count == 4)

        // Hidden values match shown text: formatted numbers and "" for blanks.
        var sheet = pivotSheet([["Group", "Value"], ["a", 10], ["a", 20], [.empty, 5], ["b", .empty]])
        sheet[CellAddress(a1: "B2")!].format.numberFormat = "$0"
        let output = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B5", rows: [PivotGroup(sourceColumn: 0)],
                                            values: [PivotValue(sourceColumn: 1, summary: .countA)],
                                            filters: [PivotFilter(sourceColumn: 1, criterion: FilterCriterion(hiddenValues: ["$10", ""]))]),
                                 [sheet])
        #expect(pivotGrid(output) == [["Group", "COUNTA of Value"], ["", "1"], ["a", "1"], ["Grand Total", "2"]])
    }

    @Test func emptyRowsAreSkippedButBlankLabelsGroup() {
        let rows: [[CellInput]] = [["Group", "Value"], ["a", 1], [.empty, .empty], [.empty, 4], ["a", 2], [.empty, .empty]]
        let output = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B6", rows: [PivotGroup(sourceColumn: 0)],
                                            values: [PivotValue(sourceColumn: 1, summary: .countA), PivotValue(sourceColumn: 0, summary: .countA)]),
                                 [pivotSheet(rows)])
        #expect(pivotGrid(output) == [["Group", "COUNTA of Value", "COUNTA of Group"], ["", "1", "0"], ["a", "2", "2"], ["Grand Total", "3", "2"]])
        // Whole-column sources work the same way.
        let columns = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A:B", rows: [PivotGroup(sourceColumn: 0)],
                                             values: [PivotValue(sourceColumn: 1)]), [pivotSheet(rows)])
        #expect(pivotGrid(columns) == [["Group", "SUM of Value"], ["", "4"], ["a", "3"], ["Grand Total", "7"]])
    }

    @Test func textLabelsDifferingInCaseAreSeparateGroups() {
        let output = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B4", rows: [PivotGroup(sourceColumn: 0)],
                                            values: [PivotValue(sourceColumn: 1)]),
                                 [pivotSheet([["Fruit", "Count"], ["apple", 1], ["Apple", 2], ["apple", 4]])])
        #expect(pivotGrid(output) == [["Fruit", "SUM of Count"], ["Apple", "2"], ["apple", "5"], ["Grand Total", "7"]])
    }

    @Test func spilledAndFormulaValuesInTheSourceCount() {
        let rows: [[CellInput]] = [["N", "Double"], ["=SEQUENCE(3)", "=A2*2"], [.empty, "=A3*2"], [.empty, "=A4*2"]]
        let output = pivotOutput(PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B4", rows: [PivotGroup(sourceColumn: 0)],
                                            values: [PivotValue(sourceColumn: 1)]), [pivotSheet(rows)])
        #expect(pivotGrid(output) == [["N", "SUM of Double"], ["1", "2"], ["2", "4"], ["3", "6"], ["Grand Total", "12"]])
    }

    @Test func sourcesOnOtherSheetsAndNamedRanges() {
        let data = pivotSheet(salesRows)
        let pivot = PivotTable(anchor: CellAddress(a1: "A1")!, source: "'Data'!A1:E6", rows: [PivotGroup(sourceColumn: 0)],
                               values: [PivotValue(sourceColumn: 4)])
        let output = pivotOutput(pivot, [Sheet(name: "Report"), data])
        #expect(pivotGrid(output) == [["Region", "SUM of Units"], ["East", "7"], ["West", "8"], ["Grand Total", "15"]])
        var named = pivot
        named.source = "Sales"
        #expect(pivotOutput(named, [data, Sheet(name: "Report")], sheet: 1,
                            namedRanges: [NamedRange(name: "Sales", reference: "Data!$A$1:$E$6")]) == output)
    }

    @Test func sourceValuesForFilterLists() {
        let rows: [[CellInput]] = [["Group", "Value"], ["b", 1], [.empty, 2], ["a", 3], ["b", 4], [10, 5], [2, 6], [.empty, .empty]]
        let workbook = Workbook(sheets: [pivotSheet(rows)])
        let pivot = PivotTable(anchor: CellAddress(a1: "E1")!, source: "A1:B8",
                               filters: [PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["a"]))])
        let values = PivotEngine.sourceValues(column: 0, for: pivot, sheetIndex: 0, workbook: workbook)
        #expect(values.map(\.value) == ["", "2", "10", "a", "b"])
        #expect(values.map(\.count) == [1, 1, 1, 1, 2])
        #expect(PivotEngine.sourceValues(column: 5, for: pivot, sheetIndex: 0, workbook: workbook).isEmpty)
    }
}
