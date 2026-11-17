import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaDateFunctionTests {
    @Test func dateConstruction() {
        #expect(eval("=DATE(2026, 11, 16)") == .number(46342))
        #expect(eval("=DATE(2026, 1, 1)") == .number(46023))
        #expect(eval("=DATE(26, 1, 1)") == .number(DateSerial.serial(year: 1926, month: 1, day: 1)))
        #expect(eval("=DATE(1899, 12, 31)") == .number(DateSerial.serial(year: 3799, month: 12, day: 31)))
        #expect(eval("=DATE(2026, 13, 1)") == eval("=DATE(2027, 1, 1)"))
        #expect(eval("=DATE(2026, 3, 0)") == eval("=DATE(2026, 2, 28)"))
        #expect(eval("=DATE(2026, 1, -1)") == eval("=DATE(2025, 12, 30)"))
        #expect(eval("=DATE(2026.9, 1.9, 1.9)") == eval("=DATE(2026, 1, 1)"))
        #expect(eval("=DATE(-1, 1, 1)") == err(.number))
        #expect(eval("=DATE(10000, 1, 1)") == err(.number))
        #expect(eval("=TIME(12, 0, 0)") == .number(0.5))
        #expect(eval("=TIME(25, 0, 0)") == .number(1.0 / 24))
        #expect(eval("=TIME(0, -1, 0)") == err(.number))
        #expect(close(eval("=TIME(1, 30, 30)"), (3600 + 1800 + 30) / 86_400.0))
    }

    @Test func dateParts() {
        let serial = DateSerial.serial(year: 2026, month: 11, day: 16, hour: 18, minute: 30, second: 45)
        let cells: [String: CellInput] = ["A1": .value(.number(serial))]
        #expect(eval("=YEAR(A1)", cells) == .number(2026))
        #expect(eval("=MONTH(A1)", cells) == .number(11))
        #expect(eval("=DAY(A1)", cells) == .number(16))
        #expect(eval("=HOUR(A1)", cells) == .number(18))
        #expect(eval("=MINUTE(A1)", cells) == .number(30))
        #expect(eval("=SECOND(A1)", cells) == .number(45))
        #expect(eval("=WEEKDAY(A1)", cells) == .number(2))
        #expect(eval("=WEEKDAY(A1, 2)", cells) == .number(1))
        #expect(eval("=WEEKDAY(A1, 3)", cells) == .number(0))
        #expect(eval("=WEEKDAY(A1, 11)", cells) == .number(1))
        #expect(eval("=WEEKDAY(A1, 17)", cells) == .number(2))
        #expect(eval("=WEEKDAY(A1, 4)", cells) == err(.number))
        #expect(eval("=YEAR(\"abc\")") == err(.value))
        #expect(eval("=YEAR(0)") == .number(1899))
        #expect(eval("=MONTH(0)") == .number(12))
        #expect(eval("=DAY(0)") == .number(30))
        #expect(eval("=HOUR(0.75)") == .number(18))
    }

    @Test func weekNumbers() {
        // 2026-01-01 is a Thursday; 2026-11-16 a Monday.
        #expect(eval("=WEEKNUM(DATE(2026,1,1))") == .number(1))
        #expect(eval("=WEEKNUM(DATE(2026,1,4))") == .number(2))
        #expect(eval("=WEEKNUM(DATE(2026,1,4), 2)") == .number(1))
        #expect(eval("=WEEKNUM(DATE(2026,1,5), 2)") == .number(2))
        #expect(eval("=WEEKNUM(DATE(2026,12,31))") == .number(53))
        #expect(eval("=WEEKNUM(DATE(2026,1,1), 9)") == err(.number))
        #expect(eval("=ISOWEEKNUM(DATE(2026,1,1))") == .number(1))
        #expect(eval("=ISOWEEKNUM(DATE(2027,1,1))") == .number(53))
        #expect(eval("=ISOWEEKNUM(DATE(2026,11,16))") == .number(47))
        #expect(eval("=WEEKNUM(DATE(2027,1,1), 21)") == .number(53))
    }

    @Test func dateDifferences() {
        #expect(eval("=DAYS(DATE(2026,3,1), DATE(2026,2,1))") == .number(28))
        #expect(eval("=DAYS(DATE(2026,2,1), DATE(2026,3,1))") == .number(-28))
        #expect(eval("=DATEDIF(DATE(2020,2,29), DATE(2026,11,16), \"Y\")") == .number(6))
        #expect(eval("=DATEDIF(DATE(2026,1,31), DATE(2026,3,1), \"M\")") == .number(1))
        #expect(eval("=DATEDIF(DATE(2026,1,15), DATE(2026,11,16), \"M\")") == .number(10))
        #expect(eval("=DATEDIF(DATE(2026,1,15), DATE(2026,11,16), \"d\")") == .number(305))
        #expect(eval("=DATEDIF(DATE(2025,11,20), DATE(2026,11,16), \"YM\")") == .number(11))
        #expect(eval("=DATEDIF(DATE(2026,1,20), DATE(2026,3,16), \"MD\")") == .number(24))
        #expect(eval("=DATEDIF(DATE(2025,3,1), DATE(2026,2,1), \"YD\")") == .number(337))
        #expect(eval("=DATEDIF(DATE(2026,1,2), DATE(2026,1,1), \"D\")") == err(.number))
        #expect(eval("=DATEDIF(1, 2, \"X\")") == err(.number))
        #expect(eval("=EDATE(DATE(2026,1,31), 1)") == eval("=DATE(2026,2,28)"))
        #expect(eval("=EDATE(DATE(2026,3,15), -3)") == eval("=DATE(2025,12,15)"))
        #expect(eval("=EOMONTH(DATE(2026,1,15), 1)") == eval("=DATE(2026,2,28)"))
        #expect(eval("=EOMONTH(DATE(2024,1,15), 1)") == eval("=DATE(2024,2,29)"))
        #expect(eval("=EOMONTH(DATE(2026,1,15), -1)") == eval("=DATE(2025,12,31)"))
        #expect(eval("=EOMONTH(DATE(2026,1,15), 0)") == eval("=DATE(2026,1,31)"))
    }

    @Test func workdays() {
        #expect(eval("=NETWORKDAYS(DATE(2026,11,16), DATE(2026,11,22))") == .number(5))
        #expect(eval("=NETWORKDAYS(DATE(2026,11,16), DATE(2026,11,30))") == .number(11))
        #expect(eval("=NETWORKDAYS(DATE(2026,11,22), DATE(2026,11,16))") == .number(-5))
        #expect(eval("=NETWORKDAYS(DATE(2026,11,21), DATE(2026,11,22))") == .number(0))
        #expect(eval("=NETWORKDAYS(DATE(2026,11,16), DATE(2026,11,22), DATE(2026,11,18))") == .number(4))
        #expect(eval("=NETWORKDAYS(DATE(2026,11,16), DATE(2026,11,22), {46344, 46348})") == .number(4))
        #expect(eval("=WORKDAY(DATE(2026,11,16), 5)") == eval("=DATE(2026,11,23)"))
        #expect(eval("=WORKDAY(DATE(2026,11,20), 1)") == eval("=DATE(2026,11,23)"))
        #expect(eval("=WORKDAY(DATE(2026,11,23), -1)") == eval("=DATE(2026,11,20)"))
        #expect(eval("=WORKDAY(DATE(2026,11,16), 2, DATE(2026,11,17))") == eval("=DATE(2026,11,19)"))
        #expect(eval("=WORKDAY(DATE(2026,11,16), 0)") == eval("=DATE(2026,11,16)"))
    }

    @Test func yearFractions() {
        #expect(close(eval("=YEARFRAC(DATE(2026,1,1), DATE(2026,7,1))"), 0.5))
        #expect(close(eval("=YEARFRAC(DATE(2026,1,1), DATE(2026,7,1), 1)"), 181.0 / 365))
        #expect(close(eval("=YEARFRAC(DATE(2026,1,1), DATE(2026,7,1), 2)"), 181.0 / 360))
        #expect(close(eval("=YEARFRAC(DATE(2026,1,1), DATE(2026,7,1), 3)"), 181.0 / 365))
        #expect(close(eval("=YEARFRAC(DATE(2026,1,31), DATE(2026,3,31), 4)"), 60.0 / 360))
        #expect(close(eval("=YEARFRAC(DATE(2026,1,31), DATE(2026,3,31))"), 60.0 / 360))
        #expect(close(eval("=YEARFRAC(DATE(2026,7,1), DATE(2026,1,1))"), 0.5))
        #expect(close(eval("=YEARFRAC(DATE(2024,1,1), DATE(2026,1,1), 1)"), 731.0 / ((366 + 365 + 365) / 3.0)))
        #expect(close(eval("=YEARFRAC(DATE(2024,3,1), DATE(2025,2,28), 1)"), 364.0 / 365))
        #expect(eval("=YEARFRAC(1, 2, 5)") == err(.number))
    }

    @Test func nowAndToday() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let book = TestBook([("Sheet1", [:])], now: now)
        let serial = DateSerial.serial(from: now, timeZone: .current)
        #expect(close(book.evaluate("=NOW()"), serial))
        #expect(book.evaluate("=TODAY()") == .number(serial.rounded(.down)))
        #expect(book.evaluate("=DATEVALUE(\"abc\")") == err(.value))
        #expect(book.evaluate("=TIMEVALUE(5)") == err(.value))
    }
}

struct FormulaFinancialFunctionTests {
    @Test func annuities() {
        #expect(close(eval("=PMT(0.05/12, 360, 200000)"), -1073.6432460242797))
        #expect(close(eval("=PMT(0.05/12, 360, 200000, 0, 1)"), -1069.1882947959632))
        #expect(close(eval("=PMT(0, 10, 1000)"), -100))
        #expect(close(eval("=FV(0.05, 10, -100)"), 1257.789253554884))
        #expect(close(eval("=FV(0, 10, -100, -1000)"), 2000))
        #expect(close(eval("=PV(0.05, 10, -100)"), 772.1734929184818))
        #expect(close(eval("=PV(0, 10, -100)"), 1000))
        #expect(close(eval("=NPER(0.05/12, -1073.6432460242797, 200000)"), 360, tolerance: 1e-7))
        #expect(close(eval("=NPER(0, -100, 1000)"), 10))
        #expect(eval("=NPER(0.1, 100, -1000)") == err(.number))
        #expect(close(eval("=RATE(360, -1073.6432460242797, 200000)*12"), 0.05, tolerance: 1e-7))
        #expect(close(eval("=RATE(10, -100, 1000)"), 0, tolerance: 1e-9))
    }

    @Test func cashFlows() {
        #expect(close(eval("=NPV(0.1, -1000, 300, 400, 500)"), -1000 / 1.1 + 300 / 1.21 + 400 / 1.331 + 500 / 1.4641))
        #expect(eval("=NPV(0.1, {300, 400}, \"x\")") == err(.value))
        #expect(close(eval("=NPV(0.1, A1:A3)", ["A1": 300, "A2": "x", "A3": 400]), 300 / 1.1 + 400 / 1.21))
        #expect(close(eval("=IRR({-1000, 300, 400, 500})"), 0.08896339469335, tolerance: 1e-8))
        #expect(close(eval("=IRR(A1:A4)", ["A1": -1000, "A2": 300, "A3": 400, "A4": 500]), 0.08896339469335, tolerance: 1e-8))
        #expect(eval("=IRR({100, 200})") == err(.number))
    }
}

struct FormulaArrayFunctionTests {
    let cells: [String: CellInput] = ["A1": 3, "A2": 1, "A3": 2, "A4": 1, "B1": "c", "B2": "a", "B3": "b", "B4": "a"]

    @Test func filter() {
        #expect(eval("=SUM(FILTER(A1:A4, A1:A4>1))", cells) == .number(5))
        #expect(eval("=FILTER(B1:B4, A1:A4=2)", cells) == .text("b"))
        #expect(eval("=ROWS(FILTER(A1:B4, B1:B4=\"a\"))", cells) == .number(2))
        #expect(eval("=SUM(FILTER(A1:A4, A1:A4>1, B1:B4<>\"c\"))", cells) == .number(2))
        #expect(eval("=SUM(FILTER({1,2,3}, {TRUE,FALSE,TRUE}))") == .number(4))
        #expect(eval("=FILTER(A1:A4, A1:A4>5)", cells) == err(.notAvailable))
        #expect(message(eval("=FILTER(A1:A4, A1:A4>5)", cells)) == "No matches are found in FILTER evaluation.")
        #expect(eval("=FILTER(A1:A4, A1:A3>1)", cells) == err(.value))
    }

    @Test func sort() {
        #expect(eval("=SORT(A1:A4)", cells) == .number(1))
        #expect(eval("=INDEX(SORT(A1:A4), 4)", cells) == .number(3))
        #expect(eval("=INDEX(SORT(A1:A4, 1, FALSE), 1)", cells) == .number(3))
        #expect(eval("=INDEX(SORT(A1:B4, 2, TRUE), 1, 1)", cells) == .number(1))
        #expect(eval("=JOIN(\",\", SORT(B1:B4))", cells) == .text("a,a,b,c"))
        #expect(eval("=JOIN(\",\", INDEX(SORT(A1:B4, 2, TRUE, 1, FALSE), 0, 1))", cells) == .text("1,1,2,3"))
        #expect(eval("=JOIN(\",\", SORT({3;\"b\";TRUE;1;\"A\"}))") == .text("1,3,A,b,TRUE"))
        #expect(eval("=JOIN(\",\", SORT(A1:A6))", cells) == .text("1,1,2,3,,"))
        #expect(eval("=JOIN(\",\", INDEX(SORT(A1:B4, B1:B4, FALSE), 0, 2))", cells) == .text("c,b,a,a"))
        #expect(eval("=SORT(A1:A4, 3, TRUE)", cells) == err(.value))
    }

    @Test func unique() {
        #expect(eval("=JOIN(\",\", UNIQUE(A1:A4))", cells) == .text("3,1,2"))
        #expect(eval("=JOIN(\",\", UNIQUE(B1:B4))", cells) == .text("c,a,b"))
        #expect(eval("=JOIN(\",\", UNIQUE({\"a\";\"A\";\"a\"}))") == .text("a,A"))
        #expect(eval("=JOIN(\",\", UNIQUE(A1:A4, FALSE, TRUE))", cells) == .text("3,2"))
        #expect(eval("=COLUMNS(UNIQUE({1,1,2}, TRUE))") == .number(2))
        #expect(eval("=ROWS(UNIQUE(A1:B4))", cells) == .number(3))
        #expect(eval("=UNIQUE({1;1}, FALSE, TRUE)") == err(.notAvailable))
    }

    @Test func sequenceAndTranspose() {
        #expect(eval("=SUM(SEQUENCE(4))") == .number(10))
        #expect(eval("=SUM(SEQUENCE(2, 3))") == .number(21))
        #expect(eval("=INDEX(SEQUENCE(2, 3, 10, 5), 2, 1)") == .number(25))
        #expect(eval("=COLUMNS(SEQUENCE(2, 3))") == .number(3))
        #expect(eval("=SEQUENCE(1)") == .number(1))
        #expect(eval("=SEQUENCE(0)") == err(.value))
        #expect(eval("=ROWS(TRANSPOSE(A1:B4))", cells) == .number(2))
        #expect(eval("=INDEX(TRANSPOSE(A1:B4), 2, 3)", cells) == .text("b"))
        #expect(eval("=ARRAYFORMULA(SUM(A1:A4*2))", cells) == .number(14))
        #expect(eval("=SUM(ARRAYFORMULA(A1:A4+{10;20;30;40}))", cells) == .number(107))
    }
}
