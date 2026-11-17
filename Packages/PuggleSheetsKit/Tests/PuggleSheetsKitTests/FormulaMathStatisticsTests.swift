import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaMathFunctionTests {
    @Test func basicMath() {
        #expect(eval("=ABS(-3)") == .number(3))
        #expect(eval("=ABS(\"-2\")") == .number(2))
        #expect(eval("=ABS(\"x\")") == err(.value))
        #expect(message(eval("=ABS(\"x\")")) == "Function ABS parameter 1 expects number values. But 'x' is a text and cannot be coerced to a number.")
        #expect(eval("=SIGN(-2)") == .number(-1))
        #expect(eval("=SIGN(0)") == .number(0))
        #expect(eval("=INT(-2.5)") == .number(-3))
        #expect(eval("=INT(2.5)") == .number(2))
        #expect(eval("=TRUNC(-2.5)") == .number(-2))
        #expect(eval("=TRUNC(3.14159, 2)") == .number(3.14))
        #expect(eval("=MOD(10, 3)") == .number(1))
        #expect(eval("=MOD(-10, 3)") == .number(2))
        #expect(eval("=MOD(10, -3)") == .number(-2))
        #expect(eval("=MOD(5.5, 2)") == .number(1.5))
        #expect(eval("=MOD(1, 0)") == err(.divideByZero))
        #expect(eval("=QUOTIENT(7, 2)") == .number(3))
        #expect(eval("=QUOTIENT(-7, 2)") == .number(-3))
        #expect(eval("=QUOTIENT(1, 0)") == err(.divideByZero))
        #expect(eval("=POWER(2, 10)") == .number(1024))
        #expect(eval("=POWER(0, -1)") == err(.divideByZero))
        #expect(eval("=SQRT(16)") == .number(4))
        #expect(eval("=SQRT(-4)") == err(.number))
        #expect(eval("=EXP(0)") == .number(1))
        #expect(eval("=LN(1)") == .number(0))
        #expect(eval("=LN(0)") == err(.number))
        #expect(close(eval("=LOG(8, 2)"), 3))
        #expect(eval("=LOG(100)") == .number(2))
        #expect(eval("=LOG(10, 1)") == err(.divideByZero))
        #expect(eval("=LOG(0)") == err(.number))
        #expect(eval("=LOG10(0.001)") == .number(-3))
        #expect(eval("=PI()") == .number(.pi))
        #expect(eval("=DEGREES(PI())") == .number(180))
        #expect(close(eval("=RADIANS(180)"), .pi))
    }

    @Test func trigonometry() {
        #expect(close(eval("=SIN(PI()/2)"), 1))
        #expect(close(eval("=COS(0)"), 1))
        #expect(close(eval("=TAN(PI()/4)"), 1))
        #expect(close(eval("=ASIN(1)"), .pi / 2))
        #expect(close(eval("=ACOS(0)"), .pi / 2))
        #expect(eval("=ACOS(2)") == err(.number))
        #expect(eval("=ASIN(-1.5)") == err(.number))
        #expect(close(eval("=ATAN(1)"), .pi / 4))
        #expect(close(eval("=ATAN2(-1, 0)"), .pi))
        #expect(close(eval("=ATAN2(1, 2)"), atan2(2, 1)))
        #expect(eval("=ATAN2(0, 0)") == err(.divideByZero))
        #expect(close(eval("=SINH(1)"), sinh(1)))
        #expect(close(eval("=COSH(1)"), cosh(1)))
        #expect(close(eval("=TANH(1)"), tanh(1)))
        #expect(close(eval("=ASINH(1)"), asinh(1)))
        #expect(eval("=ACOSH(1)") == .number(0))
        #expect(eval("=ACOSH(0.5)") == err(.number))
        #expect(close(eval("=ATANH(0.5)"), atanh(0.5)))
        #expect(eval("=ATANH(1)") == err(.number))
    }

    @Test func rounding() {
        #expect(eval("=ROUND(2.5)") == .number(3))
        #expect(eval("=ROUND(-2.5)") == .number(-3))
        #expect(eval("=ROUND(2.675, 2)") == .number(2.68))
        #expect(eval("=ROUND(1.005, 2)") == .number(1.01))
        #expect(eval("=ROUND(1234.5678, -2)") == .number(1200))
        #expect(eval("=ROUND(1234.5678, 1)") == .number(1234.6))
        #expect(eval("=ROUNDUP(2.1)") == .number(3))
        #expect(eval("=ROUNDUP(-2.1)") == .number(-3))
        #expect(eval("=ROUNDUP(1.234, 2)") == .number(1.24))
        #expect(eval("=ROUNDDOWN(2.9)") == .number(2))
        #expect(eval("=ROUNDDOWN(-2.9)") == .number(-2))
        #expect(eval("=ROUNDDOWN(1234, -2)") == .number(1200))
        #expect(eval("=ROUND(\"x\")") == err(.value))
        #expect(eval("=CEILING(2.1)") == .number(3))
        #expect(eval("=CEILING(2.1, 0.5)") == .number(2.5))
        #expect(eval("=CEILING(-2.1, 1)") == .number(-2))
        #expect(eval("=CEILING(-2.1, -1)") == .number(-3))
        #expect(eval("=CEILING(2.1, -1)") == err(.number))
        #expect(eval("=CEILING(0.3, 0.1)") == .number(0.3))
        #expect(eval("=FLOOR(2.9)") == .number(2))
        #expect(eval("=FLOOR(-2.1, 1)") == .number(-3))
        #expect(eval("=FLOOR(-2.1, -1)") == .number(-2))
        #expect(eval("=FLOOR(7, 0)") == err(.divideByZero))
        #expect(eval("=CEILING.MATH(-2.5)") == .number(-2))
        #expect(eval("=CEILING.MATH(-2.5, 1, 1)") == .number(-3))
        #expect(eval("=CEILING.MATH(6.3, 5)") == .number(10))
        #expect(eval("=FLOOR.MATH(-2.5)") == .number(-3))
        #expect(eval("=FLOOR.MATH(-2.5, 1, 1)") == .number(-2))
        #expect(eval("=FLOOR.MATH(6.7, 5)") == .number(5))
        #expect(eval("=MROUND(10, 3)") == .number(9))
        #expect(eval("=MROUND(-10, -3)") == .number(-9))
        #expect(eval("=MROUND(1.3, 0.2)") == .number(1.4))
        #expect(eval("=MROUND(5, -2)") == err(.number))
        #expect(eval("=EVEN(1.5)") == .number(2))
        #expect(eval("=EVEN(3)") == .number(4))
        #expect(eval("=EVEN(-1)") == .number(-2))
        #expect(eval("=EVEN(0)") == .number(0))
        #expect(eval("=ODD(1.5)") == .number(3))
        #expect(eval("=ODD(2)") == .number(3))
        #expect(eval("=ODD(-1)") == .number(-1))
        #expect(eval("=ODD(0)") == .number(1))
    }

    @Test func combinatorics() {
        #expect(eval("=FACT(5)") == .number(120))
        #expect(eval("=FACT(0)") == .number(1))
        #expect(eval("=FACT(5.9)") == .number(120))
        #expect(eval("=FACT(-1)") == err(.number))
        #expect(eval("=COMBIN(5, 2)") == .number(10))
        #expect(eval("=COMBIN(5, 0)") == .number(1))
        #expect(eval("=COMBIN(50, 25)") == .number(126_410_606_437_752))
        #expect(eval("=COMBIN(2, 5)") == err(.number))
        #expect(eval("=GCD(12, 18)") == .number(6))
        #expect(eval("=GCD(12, 18, 8)") == .number(2))
        #expect(eval("=GCD(0, 5)") == .number(5))
        #expect(eval("=GCD({12, 18})") == .number(6))
        #expect(eval("=GCD(-1, 2)") == err(.number))
        #expect(eval("=LCM(4, 6)") == .number(12))
        #expect(eval("=LCM(4, 6, 10)") == .number(60))
        #expect(eval("=LCM(0, 3)") == .number(0))
    }

    @Test func sums() {
        let cells: [String: CellInput] = ["A1": 1, "A2": "2", "A3": true, "A4": 4, "B1": 2, "B2": 3, "B3": 4, "B4": 5]
        #expect(eval("=SUM(A1:A4)", cells) == .number(5))
        #expect(eval("=SUM(A1:A4, \"2\", TRUE)", cells) == .number(8))
        #expect(eval("=SUM(A2)", cells) == .number(0))
        #expect(eval("=SUM(\"x\")") == err(.value))
        #expect(eval("=SUM(C1:C10)") == .number(0))
        #expect(eval("=SUM(1/0, NA())") == err(.divideByZero))
        #expect(eval("=PRODUCT(A1:A4)", cells) == .number(4))
        #expect(eval("=PRODUCT(2, 3, \"4\")") == .number(24))
        #expect(eval("=PRODUCT(C1:C3)") == .number(0))
        #expect(eval("=SUMSQ(1, 2, 3)") == .number(14))
        #expect(eval("=SUMSQ(A1:A4)", cells) == .number(17))
        #expect(eval("=SUMPRODUCT(A1:A4, B1:B4)", cells) == .number(22))
        #expect(eval("=SUMPRODUCT(A1:A2, B1:B3)", cells) == err(.value))
        #expect(eval("=SUMPRODUCT({1,2,3})") == .number(6))
        #expect(eval("=SUMPRODUCT({1,2}, {3,#N/A})") == err(.notAvailable))
    }

    @Test func conditionalSums() {
        let cells: [String: CellInput] = ["A1": 1, "A2": 5, "A3": 10, "A4": "x", "B1": 10, "B2": 20, "B3": 30, "B4": 40]
        #expect(eval("=SUMIF(A1:A4, \">4\")", cells) == .number(15))
        #expect(eval("=SUMIF(A1:A4, \">4\", B1:B4)", cells) == .number(50))
        #expect(eval("=SUMIF(A1:A4, \"x\", B1:B4)", cells) == .number(40))
        #expect(eval("=SUMIF(A1:A4, \"<>x\", B1:B4)", cells) == .number(60))
        #expect(eval("=SUMIF(A1:A4, 5, B1)", cells) == .number(20))
        #expect(eval("=SUMIF(A1:A4, \">\"&A2, B1:B4)", cells) == .number(30))
        #expect(eval("=SUMIF(A1:A4, \">100\")", cells) == .number(0))
        #expect(eval("=SUMIFS(B1:B4, A1:A4, \">=1\", A1:A4, \"<10\")", cells) == .number(30))
        #expect(eval("=SUMIFS(B1:B4, A1:A4, \"<>5\", B1:B4, \">15\")", cells) == .number(70))
        #expect(eval("=SUMIFS(B1:B4, A1:A3, \">=1\")", cells) == err(.value))
    }

    @Test func randomNumbers() {
        for _ in 0..<20 {
            let random = num(eval("=RAND()")) ?? -1
            #expect(random >= 0 && random < 1)
            let integer = num(eval("=RANDBETWEEN(1, 3)")) ?? 0
            #expect([1, 2, 3].contains(integer))
        }
        #expect(eval("=RANDBETWEEN(2.5, 3.5)") == .number(3))
        #expect(eval("=RANDBETWEEN(1.5, 1.7)") == err(.number))
    }
}

struct FormulaStatisticalFunctionTests {
    let data: [String: CellInput] = ["A1": 2, "A2": 4, "A3": 4, "A4": 4, "A5": 5, "A6": 5, "A7": 7, "A8": 9,
                                     "B1": "text", "B2": true, "B3": 3]

    @Test func averagesAndCounts() {
        #expect(eval("=AVERAGE(A1:A8)", data) == .number(5))
        #expect(eval("=AVERAGE(B1:B3)", data) == .number(3))
        #expect(eval("=AVERAGEA(B1:B3)", data) == .number(4.0 / 3.0))
        #expect(eval("=AVERAGE(C1:C3)") == err(.divideByZero))
        #expect(message(eval("=AVERAGE(C1:C3)")) == "Evaluation of function AVERAGE caused a divide by zero error.")
        #expect(eval("=AVERAGE(1, \"3\")") == .number(2))
        #expect(eval("=COUNT(A1:B8)", data) == .number(9))
        #expect(eval("=COUNT(1, \"2\", TRUE, \"x\")") == .number(1))
        #expect(eval("=COUNT(A1, 1/0)", data) == .number(1))
        #expect(eval("=COUNTA(A1:B8)", data) == .number(11))
        #expect(eval("=COUNTA(1, \"\", TRUE)") == .number(3))
        #expect(eval("=COUNTA(C1:C9)") == .number(0))
        #expect(eval("=COUNTBLANK(A1:B8)", data) == .number(5))
        #expect(eval("=COUNTBLANK(C1:C2)", ["C1": "=\"\""]) == .number(2))
        #expect(eval("=COUNTUNIQUE(A1:A8)", data) == .number(5))
        #expect(eval("=COUNTUNIQUE(\"a\", \"A\", 1, \"1\", C1)") == .number(4))
    }

    @Test func extremes() {
        #expect(eval("=MAX(A1:A8)", data) == .number(9))
        #expect(eval("=MIN(A1:A8)", data) == .number(2))
        #expect(eval("=MAX(B1:B3)", data) == .number(3))
        #expect(eval("=MAXA(B1:B3)", data) == .number(3))
        #expect(eval("=MINA(B1:B3)", data) == .number(0))
        #expect(eval("=MAX(C1:C5)") == .number(0))
        #expect(eval("=MAX(-1, \"-5\")") == .number(-1))
        #expect(eval("=MIN(A1:A8, -3)", data) == .number(-3))
        #expect(eval("=LARGE(A1:A8, 2)", data) == .number(7))
        #expect(eval("=SMALL(A1:A8, 3)", data) == .number(4))
        #expect(eval("=LARGE(A1:A8, 9)", data) == err(.number))
        #expect(eval("=SMALL(A1:A8, 0)", data) == err(.number))
        #expect(eval("=MEDIAN(A1:A8)", data) == .number(4.5))
        #expect(eval("=MEDIAN(1, 2, 3)") == .number(2))
        #expect(eval("=MEDIAN(C1:C2)") == err(.number))
        #expect(eval("=MODE(A1:A8)", data) == .number(4))
        #expect(eval("=MODE(1, 2, 2, 1)") == .number(1))
        #expect(eval("=MODE.SNGL(1, 2, 3)") == err(.notAvailable))
    }

    @Test func percentilesAndRanks() {
        #expect(eval("=PERCENTILE(A1:A8, 0.5)", data) == .number(4.5))
        #expect(eval("=PERCENTILE.INC({1,2,3,4}, 0.25)") == .number(1.75))
        #expect(eval("=PERCENTILE({1,2,3,4}, 1.5)") == err(.number))
        #expect(eval("=QUARTILE({1,2,3,4,5,6,7,8}, 1)") == .number(2.75))
        #expect(eval("=QUARTILE.INC({1,2,3,4,5,6,7,8}, 4)") == .number(8))
        #expect(eval("=QUARTILE({1,2}, 5)") == err(.number))
        #expect(eval("=RANK(5, A1:A8)", data) == .number(3))
        #expect(eval("=RANK.EQ(4, A1:A8, 1)", data) == .number(2))
        #expect(eval("=RANK.AVG(4, A1:A8)", data) == .number(6))
        #expect(eval("=RANK(6, A1:A8)", data) == err(.notAvailable))
    }

    @Test func deviation() {
        #expect(close(eval("=STDEV(A1:A8)", data), 2.138089935299395))
        #expect(close(eval("=STDEV.S(A1:A8)", data), 2.138089935299395))
        #expect(eval("=STDEVP(A1:A8)", data) == .number(2))
        #expect(eval("=STDEV.P(A1:A8)", data) == .number(2))
        #expect(close(eval("=VAR(A1:A8)", data), 32.0 / 7))
        #expect(close(eval("=VAR.S(A1:A8)", data), 32.0 / 7))
        #expect(eval("=VARP(A1:A8)", data) == .number(4))
        #expect(eval("=VAR.P(A1:A8)", data) == .number(4))
        #expect(eval("=STDEV(1)") == err(.divideByZero))
        #expect(eval("=VARP(5)") == .number(0))
    }

    @Test func regression() {
        let cells: [String: CellInput] = ["A1": 1, "A2": 2, "A3": 3, "A4": 4, "B1": 2, "B2": 4, "B3": 5, "B4": 8, "B5": "x"]
        #expect(close(eval("=SLOPE(B1:B4, A1:A4)", cells), 1.9))
        #expect(close(eval("=INTERCEPT(B1:B4, A1:A4)", cells), 0))
        #expect(close(eval("=CORREL(A1:A4, B1:B4)", cells), 0.9811557810392123))
        #expect(eval("=SLOPE(B1:B5, A1:A4)", cells) == err(.notAvailable))
        #expect(eval("=SLOPE({1,1}, {2,2})") == err(.divideByZero))
        #expect(close(eval("=SLOPE(B1:B5, A1:A5)", cells), 1.9))
    }

    @Test func conditionalAggregates() {
        let cells: [String: CellInput] = ["A1": "apple", "A2": "banana", "A3": "apple", "A4": "cherry",
                                          "B1": 10, "B2": 20, "B3": 30, "B4": 40]
        #expect(eval("=AVERAGEIF(A1:A4, \"apple\", B1:B4)", cells) == .number(20))
        #expect(eval("=AVERAGEIF(B1:B4, \">15\")", cells) == .number(30))
        #expect(eval("=AVERAGEIF(A1:A4, \"kiwi\", B1:B4)", cells) == err(.divideByZero))
        #expect(eval("=AVERAGEIFS(B1:B4, A1:A4, \"a*\", B1:B4, \">10\")", cells) == .number(30))
        #expect(eval("=COUNTIF(A1:A4, \"apple\")", cells) == .number(2))
        #expect(eval("=COUNTIFS(A1:A4, \"apple\", B1:B4, \">10\")", cells) == .number(1))
        #expect(eval("=COUNTIFS(A1:A4, \"apple\", B1:B3, \">10\")", cells) == err(.value))
        #expect(eval("=MAXIFS(B1:B4, A1:A4, \"apple\")", cells) == .number(30))
        #expect(eval("=MINIFS(B1:B4, A1:A4, \"<>apple\")", cells) == .number(20))
        #expect(eval("=MAXIFS(B1:B4, A1:A4, \"kiwi\")", cells) == .number(0))
    }
}
