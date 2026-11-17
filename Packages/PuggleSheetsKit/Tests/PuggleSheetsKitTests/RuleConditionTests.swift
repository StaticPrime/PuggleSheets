import Foundation
import Testing
@testable import PuggleSheetsKit

/// Noon on Monday 2026-11-16 (serial 46342) in the current time zone.
let ruleNow = DateSerial.date(fromSerial: 46342.5, timeZone: .current)

/// A one-sheet workbook with `cells` computed.
func ruleBook(_ cells: [String: CellInput]) -> TestBook {
    TestBook([("Sheet1", cells)], now: ruleNow)
}

struct RuleConditionTests {
    /// Whether the condition holds for `cell` placed at `address` (other cells from `extra`).
    private func holds(_ kind: CellCondition.Kind, _ values: [String] = [], _ cell: CellInput = .empty, at address: String = "A2",
                       origin: String = "A2", extra: [String: CellInput] = [:]) -> Bool {
        var cells = extra
        cells[address] = cell
        let book = ruleBook(cells)
        return RuleEvaluator.test(CellCondition(kind, values), at: CellAddress(a1: address)!, origin: CellAddress(a1: origin)!,
                                  sheetIndex: 0, workbook: book.workbook, now: ruleNow)
    }

    @Test func emptiness() {
        #expect(holds(.isEmpty))
        #expect(holds(.isEmpty, [], "=\"\""))
        #expect(!holds(.isEmpty, [], "x"))
        #expect(!holds(.isEmpty, [], 0))
        #expect(holds(.isNotEmpty, [], 0))
        #expect(!holds(.isNotEmpty))
        #expect(holds(.isNotEmpty, [], .error(.notAvailable)))
    }

    @Test func text() {
        #expect(holds(.textContains, ["ab"], "xABy"))
        #expect(!holds(.textContains, ["ab"], "xy"))
        #expect(holds(.textContains, ["2"], 123))
        #expect(!holds(.textContains, ["a"]))
        #expect(!holds(.textContains, ["a"], .error(.value)))
        #expect(holds(.textDoesNotContain, ["ab"], "xy"))
        #expect(!holds(.textDoesNotContain, ["ab"], "AB"))
        #expect(holds(.textDoesNotContain, ["ab"]))
        #expect(holds(.textStartsWith, ["ab"], "Abc"))
        #expect(!holds(.textStartsWith, ["ab"], "cab"))
        #expect(holds(.textEndsWith, ["ab"], "cAB"))
        #expect(!holds(.textEndsWith, ["ab"], "abc"))
        #expect(holds(.textIsExactly, ["abc"], "ABC"))
        #expect(!holds(.textIsExactly, ["abc"], "abcd"))
        #expect(holds(.textIsExactly, ["5"], 5))
        #expect(holds(.textContains, ["=B2"], "hello", extra: ["B2": "LL"]))
    }

    @Test func emailsAndURLs() {
        for email in ["a.b@example.com", "first+tag@mail.example.co.uk", "x_y@domain.io"] {
            #expect(holds(.textIsValidEmail, [], .value(.text(email))), "\(email)")
        }
        for email in ["a@b", "a b@example.com", "@example.com", "a@example.c", "a@@example.com", "a@-x.com", "plain", "a.@x.com"] {
            #expect(!holds(.textIsValidEmail, [], .value(.text(email))), "\(email)")
        }
        #expect(!holds(.textIsValidEmail, [], 5))
        for url in ["example.com", "https://www.example.com/maps?q=1", "http://localhost:8080", "ftp://10.0.0.1/file",
                    "WWW.Example.ORG#top", "https://user@example.com"] {
            #expect(holds(.textIsValidURL, [], .value(.text(url))), "\(url)")
        }
        for url in ["abc", "http://", "a b.com", "example.c", "http://example.com:99999", "999.1.1.1", ""] {
            #expect(!holds(.textIsValidURL, [], .value(.text(url))), "\(url)")
        }
    }

    @Test func exactDates() {
        #expect(holds(.dateIs, ["1/2/2026"], 46024))
        #expect(holds(.dateIs, ["1/2/2026"], 46024.75))
        #expect(!holds(.dateIs, ["1/2/2026"], 46025))
        #expect(!holds(.dateIs, ["1/2/2026"], "x"))
        #expect(!holds(.dateIs, ["1/2/2026"]))
        #expect(holds(.dateIsBefore, ["1/2/2026"], 46023))
        #expect(!holds(.dateIsBefore, ["1/2/2026"], 46024))
        #expect(holds(.dateIsAfter, ["1/2/2026"], 46025))
        #expect(holds(.dateIsOnOrBefore, ["1/2/2026"], 46024))
        #expect(holds(.dateIsOnOrAfter, ["1/2/2026"], 46024))
        #expect(!holds(.dateIsOnOrAfter, ["1/2/2026"], 46023))
        #expect(holds(.dateIsBetween, ["1/1/2026", "1/31/2026"], 46030))
        #expect(holds(.dateIsBetween, ["1/31/2026", "1/1/2026"], 46030))
        #expect(!holds(.dateIsBetween, ["1/1/2026", "1/31/2026"], 46060))
        #expect(holds(.dateIsNotBetween, ["1/1/2026", "1/31/2026"], 46060))
        #expect(!holds(.dateIsNotBetween, ["1/1/2026", "1/31/2026"], 46030))
        #expect(!holds(.dateIsNotBetween, ["1/1/2026", "1/31/2026"], "x"))
        #expect(holds(.dateIsAfter, ["=B2"], 46030, extra: ["B2": "=DATE(2026,1,1)"]))
        #expect(holds(.dateIs, ["1/2/2026"], .value(.text("1/2/2026"))))
    }

    @Test func relativeDates() {
        #expect(holds(.dateIs, ["today"], 46342))
        #expect(holds(.dateIs, ["Tomorrow"], 46343))
        #expect(holds(.dateIs, ["yesterday"], 46341))
        #expect(holds(.dateIs, ["past week"], 46335))
        #expect(holds(.dateIs, ["past week"], 46342))
        #expect(!holds(.dateIs, ["past week"], 46334))
        #expect(!holds(.dateIs, ["past week"], 46343))
        #expect(holds(.dateIs, ["past month"], 46311))
        #expect(!holds(.dateIs, ["past month"], 46310))
        #expect(holds(.dateIs, ["past year"], .value(.number(DateSerial.serial(year: 2025, month: 11, day: 16)))))
        #expect(!holds(.dateIs, ["past year"], .value(.number(DateSerial.serial(year: 2025, month: 11, day: 15)))))
        #expect(holds(.dateIsBefore, ["past week"], 46334))
        #expect(!holds(.dateIsBefore, ["past week"], 46335))
        #expect(holds(.dateIsAfter, ["today"], 46343))
        #expect(holds(.dateIsBetween, ["yesterday", "tomorrow"], 46342))
    }

    @Test func validDates() {
        #expect(holds(.dateIsValid, [], 46024))
        #expect(holds(.dateIsValid, [], .value(.text("1/2/2026"))))
        #expect(!holds(.dateIsValid, [], "hello"))
        #expect(!holds(.dateIsValid, [], .value(.text("12"))))
        #expect(!holds(.dateIsValid, []))
        #expect(!holds(.dateIsValid, [], true))
    }

    @Test func numbers() {
        #expect(holds(.greaterThan, ["5"], 6))
        #expect(!holds(.greaterThan, ["5"], 5))
        #expect(holds(.greaterThan, ["5"], "10"))
        #expect(!holds(.greaterThan, ["5"], "abc"))
        #expect(!holds(.greaterThan, ["5"]))
        #expect(holds(.lessThan, ["5"]))
        #expect(holds(.lessThan, ["5"], 4))
        #expect(holds(.greaterThanOrEqual, ["5"], 5))
        #expect(holds(.lessThanOrEqual, ["5"], 5))
        #expect(holds(.isEqual, ["5"], 5))
        #expect(holds(.isEqual, ["5"], "5"))
        #expect(holds(.isEqual, ["0.3"], "=0.1+0.2"))
        #expect(holds(.isEqual, ["0"]))
        #expect(holds(.isEqual, ["apple"], "Apple"))
        #expect(holds(.isNotEqual, ["5"], 4))
        #expect(holds(.isNotEqual, ["5"], "abc"))
        #expect(!holds(.isNotEqual, ["5"], 5))
        #expect(!holds(.isNotEqual, ["5"], .error(.divideByZero)))
        #expect(holds(.greaterThan, ["1,000"], 1500))
        #expect(holds(.lessThan, ["50%"], 0.25))
        #expect(holds(.greaterThan, ["0"], true))
    }

    @Test func ranges() {
        #expect(holds(.isBetween, ["1", "10"], 5))
        #expect(holds(.isBetween, ["1", "10"], 1))
        #expect(holds(.isBetween, ["1", "10"], 10))
        #expect(!holds(.isBetween, ["1", "10"], 11))
        #expect(holds(.isBetween, ["10", "1"], 5))
        #expect(!holds(.isBetween, ["1", "10"], "abc"))
        #expect(holds(.isNotBetween, ["1", "10"], 11))
        #expect(!holds(.isNotBetween, ["1", "10"], 5))
        #expect(!holds(.isNotBetween, ["1", "10"], "abc"))
        #expect(!holds(.isBetween, ["1"], 5))
    }

    @Test func relativeFormulas() {
        let cells: [String: CellInput] = ["A1": 10, "A2": 3, "A3": 7, "B1": 5, "B2": 5, "B3": 5]
        let book = ruleBook(cells)
        func holds(_ condition: CellCondition, _ address: String) -> Bool {
            RuleEvaluator.test(condition, at: CellAddress(a1: address)!, origin: CellAddress(a1: "A1")!, sheetIndex: 0,
                               workbook: book.workbook, now: ruleNow)
        }
        let greaterThanB = CellCondition(.greaterThan, ["=B1"])
        #expect(holds(greaterThanB, "A1"))
        #expect(!holds(greaterThanB, "A2"))
        #expect(holds(greaterThanB, "A3"))
        let custom = CellCondition(.customFormula, ["=A1>B1"])
        #expect(holds(custom, "A1"))
        #expect(!holds(custom, "A2"))
        let absolute = CellCondition(.customFormula, ["=$A1>6"])
        #expect(holds(absolute, "B1"))
        #expect(!holds(absolute, "B2"))
        #expect(holds(absolute, "B3"))
        #expect(holds(CellCondition(.customFormula, ["=ROW()=2"]), "C2"))
        #expect(holds(CellCondition(.customFormula, ["=A1"]), "A1"))
        #expect(!holds(CellCondition(.customFormula, ["=A1-10"]), "A1"))
        #expect(!holds(CellCondition(.customFormula, ["=\"TRUE\""]), "A1"))
        #expect(!holds(CellCondition(.customFormula, ["=1/0"]), "A1"))
        #expect(!holds(CellCondition(.customFormula, ["=A0"]), "A1"))
        #expect(holds(CellCondition(.customFormula, ["A1>5"]), "A1"))
    }

    @Test func spilledValuesCount() {
        let book = ruleBook(["A1": "=SEQUENCE(3)"])
        #expect(RuleEvaluator.test(CellCondition(.isEqual, ["3"]), at: CellAddress(a1: "A3")!, origin: CellAddress(a1: "A1")!,
                                   sheetIndex: 0, workbook: book.workbook, now: ruleNow))
        #expect(!RuleEvaluator.test(CellCondition(.isEmpty), at: CellAddress(a1: "A2")!, origin: CellAddress(a1: "A1")!,
                                    sheetIndex: 0, workbook: book.workbook, now: ruleNow))
    }
}
