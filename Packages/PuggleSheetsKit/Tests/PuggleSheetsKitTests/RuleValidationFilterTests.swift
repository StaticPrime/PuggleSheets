import Foundation
import Testing
@testable import PuggleSheetsKit

struct RuleValidationTests {
    private func valid(_ value: CellValue, _ criterion: DataValidationRule.Criterion, at address: String = "A1",
                       book: TestBook = ruleBook([:])) -> Bool {
        let rule = DataValidationRule(ranges: [CellRange(a1: "A1:A10")!], criterion: criterion)
        return RuleEvaluator.isValid(value, for: rule, at: CellAddress(a1: address)!, sheetIndex: 0, workbook: book.workbook, now: ruleNow)
    }

    @Test func lists() {
        let list = DataValidationRule.Criterion.list(["Apple", "Banana", "10", "$5.00"])
        #expect(valid(.text("apple"), list))
        #expect(valid(.text("BANANA"), list))
        #expect(!valid(.text("Cherry"), list))
        #expect(valid(.number(10), list))
        #expect(valid(.text("10"), list))
        #expect(valid(.number(5), list))
        #expect(!valid(.number(11), list))
        #expect(!valid(.boolean(true), list))
        #expect(valid(.empty, list))
        #expect(valid(.text(""), list))
        #expect(valid(.boolean(true), .list(["true", "false"])))
    }

    @Test func listsFromRanges() {
        let book = ruleBook(["D1": "x", "D2": 2, "D3": true, "D4": "x", "D6": "=SEQUENCE(2, 1, 7)"])
        let fromRange = DataValidationRule.Criterion.listFromRange("Sheet1!$D$1:$D$10")
        #expect(valid(.text("X"), fromRange, book: book))
        #expect(valid(.number(2), fromRange, book: book))
        #expect(valid(.boolean(true), fromRange, book: book))
        #expect(valid(.number(8), fromRange, book: book))
        #expect(!valid(.text("y"), fromRange, book: book))
        let rule = DataValidationRule(ranges: [CellRange(a1: "A1")!], criterion: fromRange)
        #expect(RuleEvaluator.dropdownItems(for: rule, sheetIndex: 0, workbook: book.workbook) == ["x", "2", "TRUE", "7", "8"])
        let unqualified = DataValidationRule(ranges: [CellRange(a1: "A1")!], criterion: .listFromRange("D1:D2"))
        #expect(RuleEvaluator.dropdownItems(for: unqualified, sheetIndex: 0, workbook: book.workbook) == ["x", "2"])
        var named = book
        named.workbook.namedRanges = [NamedRange(name: "Choices", reference: "Sheet1!D1:D3")]
        let byName = DataValidationRule(ranges: [CellRange(a1: "A1")!], criterion: .listFromRange("Choices"))
        #expect(RuleEvaluator.dropdownItems(for: byName, sheetIndex: 0, workbook: named.workbook) == ["x", "2", "TRUE"])
        let typed = DataValidationRule(ranges: [CellRange(a1: "A1")!], criterion: .list(["b", "a"]))
        #expect(RuleEvaluator.dropdownItems(for: typed, sheetIndex: 0, workbook: book.workbook) == ["b", "a"])
    }

    @Test func formattedRangeValuesShowAsTheyLook() {
        var book = ruleBook(["D1": 1234.5])
        var format = CellFormat()
        format.numberFormat = "#,##0.00"
        book.workbook.sheets[0][CellAddress(a1: "D1")!].format = format
        let rule = DataValidationRule(ranges: [CellRange(a1: "A1")!], criterion: .listFromRange("D1"))
        #expect(RuleEvaluator.dropdownItems(for: rule, sheetIndex: 0, workbook: book.workbook) == ["1,234.50"])
        #expect(valid(.text("1,234.50"), .listFromRange("D1"), book: book))
        #expect(valid(.number(1234.5), .listFromRange("D1"), book: book))
    }

    @Test func checkboxes() {
        let plain = DataValidationRule.Criterion.checkbox(checked: nil, unchecked: nil)
        #expect(valid(.boolean(true), plain))
        #expect(valid(.boolean(false), plain))
        #expect(valid(.text("true"), plain))
        #expect(!valid(.number(1), plain))
        #expect(!valid(.text("yes"), plain))
        let custom = DataValidationRule.Criterion.checkbox(checked: "Yes", unchecked: "No")
        #expect(valid(.text("yes"), custom))
        #expect(valid(.text("NO"), custom))
        #expect(!valid(.boolean(true), custom))
        #expect(valid(.number(0), .checkbox(checked: "1", unchecked: "0")))
    }

    @Test func conditions() {
        let book = ruleBook(["B1": 5, "B2": 50])
        #expect(valid(.number(6), .condition(CellCondition(.greaterThan, ["5"]))))
        #expect(!valid(.number(4), .condition(CellCondition(.greaterThan, ["5"]))))
        #expect(!valid(.text("abc"), .condition(CellCondition(.greaterThan, ["5"]))))
        #expect(valid(.empty, .condition(CellCondition(.greaterThan, ["5"]))))
        #expect(valid(.text("me@example.com"), .condition(CellCondition(.textIsValidEmail))))
        #expect(!valid(.text("me@"), .condition(CellCondition(.textIsValidEmail))))
        let custom = DataValidationRule.Criterion.condition(CellCondition(.customFormula, ["=A1>B1"]))
        #expect(valid(.number(10), custom, at: "A1", book: book))
        #expect(!valid(.number(3), custom, at: "A1", book: book))
        #expect(valid(.number(60), custom, at: "A2", book: book))
        #expect(!valid(.number(40), custom, at: "A2", book: book))
        let sum = DataValidationRule.Criterion.condition(CellCondition(.customFormula, ["=SUM($A$1:$A$10)<=100"]))
        #expect(valid(.number(100), sum, at: "A3", book: book))
        #expect(!valid(.number(101), sum, at: "A3", book: book))
        #expect(valid(.text("1/15/2026"), .condition(CellCondition(.dateIsBetween, ["1/1/2026", "1/31/2026"]))))
        #expect(valid(.number(46030), .condition(CellCondition(.dateIsValid))))
        #expect(!valid(.text("soon"), .condition(CellCondition(.dateIsValid))))
    }

    @Test func messages() {
        func message(_ criterion: DataValidationRule.Criterion, help: String? = nil) -> String {
            RuleEvaluator.invalidMessage(for: DataValidationRule(ranges: [], criterion: criterion, helpText: help))
        }
        #expect(message(.list(["a"])) == "Input must be an item on the specified list.")
        #expect(message(.listFromRange("A1:A3")) == "Input must be an item on the specified list.")
        #expect(message(.condition(CellCondition(.greaterThan, ["5"]))) == "Input must be a number greater than 5.")
        #expect(message(.condition(CellCondition(.isBetween, ["1", "10"]))) == "Input must be a number between 1 and 10.")
        #expect(message(.condition(CellCondition(.textIsValidEmail))) == "Input must be a valid email address.")
        #expect(message(.condition(CellCondition(.dateIsAfter, ["1/1/2026"]))) == "Input must be a date after 1/1/2026.")
        #expect(message(.condition(CellCondition(.textContains, ["x"]))) == "Input must be text containing \"x\".")
        #expect(message(.condition(CellCondition(.dateIs, ["past week"]))) == "Input must be a date in the past week.")
        #expect(message(.condition(CellCondition(.dateIsBefore, ["today"]))) == "Input must be a date before today.")
        #expect(message(.condition(CellCondition(.isNotBetween, ["1", "10"]))) == "Input must be a number not between 1 and 10.")
        #expect(message(.condition(CellCondition(.textIsValidURL))) == "Input must be a valid URL.")
        #expect(message(.condition(CellCondition(.customFormula, ["=A1>1"]))) == "Input must satisfy the specified formula.")
        #expect(message(.checkbox(checked: nil, unchecked: nil)) == "Input must be either TRUE or FALSE.")
        #expect(message(.checkbox(checked: "Yes", unchecked: "No")) == "Input must be either \"Yes\" or \"No\".")
        #expect(message(.list(["a"]), help: "Pick a fruit.") == "Pick a fruit.")
        #expect(message(.list(["a"]), help: "  ") == "Input must be an item on the specified list.")
        for kind in CellCondition.Kind.allCases {
            #expect(message(.condition(CellCondition(kind, ["1", "2"]))).hasPrefix("Input must"), "\(kind)")
        }
    }
}

struct RuleFilterTests {
    private let cells: [String: CellInput] = [
        "A1": "Name", "B1": "Score", "C1": "Joined",
        "A2": "Ann", "B2": 80, "C2": 46340,
        "A3": "Bob", "B3": 45, "C3": 46000,
        "A4": "Cy", "B4": 50, "C4": 46342,
        "A5": "Bob", "B5": 95, "C5": 46100,
        "A6": "Di", "C6": 46341,
        "A7": "Ed", "B7": 70,
    ]

    private func book(_ criteria: [Int: FilterCriterion]) -> TestBook {
        var book = ruleBook(cells)
        book.workbook.sheets[0].filter = SheetFilter(range: CellRange(a1: "A1:C7")!, criteria: criteria)
        return book
    }

    private func hidden(_ criteria: [Int: FilterCriterion]) -> [Int] {
        RuleEvaluator.filteredRows(sheetIndex: 0, workbook: book(criteria).workbook, now: ruleNow).sorted()
    }

    @Test func conditionsHideRows() {
        #expect(hidden([1: FilterCriterion(condition: CellCondition(.greaterThan, ["50"]))]) == [2, 3, 5])
        #expect(hidden([1: FilterCriterion(condition: CellCondition(.isEmpty))]) == [1, 2, 3, 4, 6])
        #expect(hidden([2: FilterCriterion(condition: CellCondition(.dateIs, ["past week"]))]) == [2, 4, 6])
        #expect(hidden([1: FilterCriterion(condition: CellCondition(.customFormula, ["=B2>A2"]))]) == [1, 2, 3, 4, 5, 6])
        #expect(hidden([1: FilterCriterion(condition: CellCondition(.customFormula, ["=B2>=B$2"]))]) == [2, 3, 5, 6])
        #expect(hidden([:]).isEmpty)
    }

    @Test func valuesHideRows() {
        #expect(hidden([0: FilterCriterion(hiddenValues: ["Bob"])]) == [2, 4])
        #expect(hidden([1: FilterCriterion(hiddenValues: [""])]) == [5])
        #expect(hidden([0: FilterCriterion(hiddenValues: ["Name"])]).isEmpty)
        #expect(hidden([0: FilterCriterion(hiddenValues: ["bob"])]).isEmpty)
        #expect(hidden([0: FilterCriterion(hiddenValues: ["Ann"]), 1: FilterCriterion(condition: CellCondition(.lessThan, ["60"]))])
            == [1, 4, 6])
    }

    @Test func shownTextMatchesFormats() {
        var formatted = book([1: FilterCriterion(hiddenValues: ["80.0"])])
        var format = CellFormat()
        format.numberFormat = "0.0"
        formatted.workbook.sheets[0][CellAddress(a1: "B2")!].format = format
        #expect(RuleEvaluator.filteredRows(sheetIndex: 0, workbook: formatted.workbook, now: ruleNow) == [1])
    }

    @Test func filterValuesListsWhatOtherColumnsLeave() {
        let workbook = book([1: FilterCriterion(condition: CellCondition(.greaterThan, ["50"]))]).workbook
        let names = RuleEvaluator.filterValues(column: 0, sheetIndex: 0, workbook: workbook)
        #expect(names.map(\.value) == ["Ann", "Bob", "Ed"])
        #expect(names.map(\.count) == [1, 1, 1])
        let scores = RuleEvaluator.filterValues(column: 1, sheetIndex: 0, workbook: workbook)
        #expect(scores.map(\.value) == ["", "45", "50", "70", "80", "95"])
        let all = RuleEvaluator.filterValues(column: 0, sheetIndex: 0, workbook: book([:]).workbook)
        #expect(all.map(\.value) == ["Ann", "Bob", "Cy", "Di", "Ed"])
        #expect(all.first { $0.value == "Bob" }?.count == 2)
        #expect(RuleEvaluator.filterValues(column: 5, sheetIndex: 0, workbook: workbook).isEmpty)
    }

    @Test func filterViewsUseTheirOwnCriteria() {
        // A filter view leaves the sheet's own filter alone: here the sheet has none.
        let workbook = ruleBook(cells).workbook
        let view = FilterView(name: "Top scores", range: CellRange(a1: "A1:C7")!,
                              criteria: [1: FilterCriterion(condition: CellCondition(.greaterThan, ["50"]))])
        #expect(RuleEvaluator.filteredRows(for: view.asFilter, sheetIndex: 0, workbook: workbook, now: ruleNow).sorted() == [2, 3, 5])
        #expect(RuleEvaluator.filteredRows(sheetIndex: 0, workbook: workbook, now: ruleNow).isEmpty)
        #expect(RuleEvaluator.filteredRows(for: view.asFilter, sheetIndex: 3, workbook: workbook).isEmpty)

        let names = RuleEvaluator.filterValues(column: 0, filter: view.asFilter, sheetIndex: 0, workbook: workbook)
        #expect(names.map(\.value) == ["Ann", "Bob", "Ed"])
        let all = RuleEvaluator.filterValues(column: 0, range: view.range, sheetIndex: 0, workbook: workbook)
        #expect(all.map(\.value) == ["Ann", "Bob", "Cy", "Di", "Ed"])
        #expect(all.map(\.count) == [1, 2, 1, 1, 1])
        let scores = RuleEvaluator.filterValues(column: 1, range: CellRange(a1: "A1:C4")!, sheetIndex: 0, workbook: workbook)
        #expect(scores.map(\.value) == ["45", "50", "80"])
        #expect(RuleEvaluator.filterValues(column: 4, range: view.range, sheetIndex: 0, workbook: workbook).isEmpty)
        #expect(RuleEvaluator.filterValues(column: 0, range: CellRange(a1: "A1:C1")!, sheetIndex: 0, workbook: workbook).isEmpty)
    }

    @Test func tablesAndSlicersHideRowsToo() {
        var workbook = ruleBook(cells).workbook
        workbook.sheets.append(Sheet(name: "Controls"))
        // The table hides Bob; a slicer on another sheet keeps scores over 60.
        workbook.sheets[0].tables = [SheetTable(name: "People", range: CellRange(a1: "A1:C7")!,
                                                criteria: [0: FilterCriterion(hiddenValues: ["Bob"])])]
        let slicer = SlicerSpec(range: "Sheet1!A1:C7", column: 1, criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["60"])))
        workbook.sheets[1].objects = [SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 0, column: 0), width: 200, height: 100),
                                                  content: .slicer(slicer))]
        #expect(RuleEvaluator.filteredRows(sheetIndex: 0, workbook: workbook, now: ruleNow).sorted() == [2, 3, 4, 5])
        #expect(RuleEvaluator.filteredRows(sheetIndex: 1, workbook: workbook, now: ruleNow).isEmpty)
        // The slicer's list leaves out rows the table hides, not those it hides itself.
        let scores = RuleEvaluator.filterValues(forSlicer: slicer, onSheet: 1, workbook: workbook, now: ruleNow)
        #expect(scores.map(\.value) == ["", "50", "70", "80"])
        // With the sheet's own filter too; a slicer on the same sheet with an unqualified range.
        workbook.sheets[0].filter = SheetFilter(range: CellRange(a1: "A1:C7")!, criteria: [0: FilterCriterion(hiddenValues: ["Ed"])])
        let names = SlicerSpec(range: "A1:C7", column: 0, criterion: FilterCriterion(hiddenValues: ["Ann"]))
        workbook.sheets[0].objects = [SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 0, column: 5), width: 200, height: 100),
                                                  content: .slicer(names))]
        #expect(RuleEvaluator.filteredRows(sheetIndex: 0, workbook: workbook, now: ruleNow).sorted() == [1, 2, 3, 4, 5, 6])
        #expect(RuleEvaluator.filterValues(forSlicer: names, onSheet: 0, workbook: workbook, now: ruleNow).map(\.value) == ["Ann"])
        // Bad references and columns give nothing.
        #expect(RuleEvaluator.filterValues(forSlicer: SlicerSpec(range: "Nowhere!A1:B2"), onSheet: 0, workbook: workbook).isEmpty)
        #expect(RuleEvaluator.filterValues(forSlicer: SlicerSpec(range: "A1:C7", column: 5), onSheet: 0, workbook: workbook).isEmpty)
        // Slicers over a table by name.
        workbook.sheets[0].filter = nil
        workbook.sheets[0].objects = []
        workbook.sheets[0].tables[0].criteria = [:]
        workbook.sheets[1].objects[0].content = .slicer(SlicerSpec(range: "People", column: 0, criterion: FilterCriterion(hiddenValues: ["Cy", "Di"])))
        #expect(RuleEvaluator.filteredRows(sheetIndex: 0, workbook: workbook, now: ruleNow).sorted() == [3, 5])
    }
}

