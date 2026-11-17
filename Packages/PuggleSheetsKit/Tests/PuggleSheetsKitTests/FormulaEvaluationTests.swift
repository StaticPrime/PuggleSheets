import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaEvaluationTests {
    @Test func emptyReferences() {
        #expect(eval("=A1") == .empty)
        #expect(eval("=A1+0") == .number(0))
        #expect(eval("=A1&\"\"") == .text(""))
        #expect(eval("=-A1") == .number(0))
        #expect(eval("=A1=0") == .boolean(true))
        #expect(eval("=A1=\"\"") == .boolean(true))
        #expect(eval("=A1=FALSE") == .boolean(true))
        #expect(eval("=A1=A2") == .boolean(true))
        #expect(eval("=A1<1") == .boolean(true))
        #expect(eval("=A1<\"a\"") == .boolean(true))
    }

    @Test func arithmeticCoercion() {
        let cells: [String: CellInput] = ["A1": "3", "A2": true, "A3": "abc", "A4": " 4 "]
        #expect(eval("=A1*2", cells) == .number(6))
        #expect(eval("=A2+1", cells) == .number(2))
        #expect(eval("=A3*2", cells) == err(.value))
        #expect(message(eval("=A3*2", cells))
            == "Function MULTIPLY parameter 1 expects number values. But 'abc' is a text and cannot be coerced to a number.")
        #expect(message(eval("=2+A3", cells))
            == "Function ADD parameter 2 expects number values. But 'abc' is a text and cannot be coerced to a number.")
        #expect(message(eval("=-A3", cells))
            == "Function UMINUS parameter 1 expects number values. But 'abc' is a text and cannot be coerced to a number.")
        #expect(eval("=A4+1", cells) == .number(5))
        #expect(eval("=\"\"+1") == .number(1))
        #expect(eval("=TRUE+TRUE") == .number(2))
        #expect(eval("=\"2\"^\"3\"") == .number(8))
    }

    @Test func concatenation() {
        #expect(eval("=1&2") == .text("12"))
        #expect(eval("=TRUE&\"x\"") == .text("TRUEx"))
        #expect(eval("=1.5&\"\"") == .text("1.5"))
        #expect(eval("=A1&\"x\"") == .text("x"))
        #expect(eval("=-3&\"\"") == .text("-3"))
    }

    @Test func comparisons() {
        #expect(eval("=1<\"a\"") == .boolean(true))
        #expect(eval("=\"z\"<TRUE") == .boolean(true))
        #expect(eval("=99999<FALSE") == .boolean(true))
        #expect(eval("=\"abc\"=\"ABC\"") == .boolean(true))
        #expect(eval("=\"a\"<\"B\"") == .boolean(true))
        #expect(eval("=\"b\">\"A\"") == .boolean(true))
        #expect(eval("=1=\"1\"") == .boolean(false))
        #expect(eval("=TRUE=1") == .boolean(false))
        #expect(eval("=2<>3") == .boolean(true))
        #expect(eval("=2>=2") == .boolean(true))
        #expect(eval("=2<=1") == .boolean(false))
        #expect(eval("=\"\"<\"a\"") == .boolean(true))
        #expect(eval("=FALSE<TRUE") == .boolean(true))
        #expect(eval("=0.1+0.2=0.3") == .boolean(true))
        #expect(eval("=0.1+0.2>0.3") == .boolean(false))
        #expect(eval("=1.000001=1") == .boolean(false))
        #expect(eval("=COUNTIF({0.3}, 0.1+0.2)") == .number(1))
        #expect(eval("=MATCH(0.1+0.2, {0.1,0.3}, 0)") == .number(2))
        #expect(eval("=VLOOKUP(0.3, {0.1,\"a\";0.30000000000000004,\"b\"}, 2, FALSE)") == .text("b"))
    }

    @Test func errorsPropagateLeftToRight() {
        #expect(eval("=1/0+NA()") == err(.divideByZero))
        #expect(eval("=NA()+1/0") == err(.notAvailable))
        #expect(eval("=#REF!&\"x\"") == err(.reference))
        #expect(eval("=(1/0)=1") == err(.divideByZero))
        #expect(message(eval("=1/0")) == "Function DIVIDE parameter 2 cannot be zero.")
        #expect(eval("=SUM(1, 1/0, NA())") == err(.divideByZero))
        #expect(eval("=A1+1", ["A1": .error(.name)]) == err(.name))
    }

    @Test func numberErrors() {
        #expect(eval("=SQRT(-1)") == err(.number))
        #expect(eval("=(-8)^(1/3)") == err(.number))
        #expect(eval("=10^400") == err(.number))
        #expect(eval("=0^-1") == err(.divideByZero))
        #expect(eval("=0^0") == .number(1))
        #expect(eval("=1E308*10") == err(.number))
    }

    @Test func elementWiseArrays() {
        let cells: [String: CellInput] = ["A1": 1, "A2": 2, "A3": 3, "B1": 4, "B2": 5, "B3": 6]
        #expect(eval("=SUMPRODUCT(A1:A3*B1:B3)", cells) == .number(32))
        #expect(eval("=SUMPRODUCT(A1:A3,B1:B3)", cells) == .number(32))
        #expect(eval("=SUM(A1:A3*2)", cells) == .number(12))
        #expect(eval("=SUM(IF(A1:A3>1, B1:B3, 0))", cells) == .number(11))
        #expect(eval("=SUM(IF(A1:A3>1, B1:B3))", cells) == .number(11))
        #expect(eval("=SUM((A1:A3>1)*1)", cells) == .number(2))
        #expect(eval("=ARRAYFORMULA(A1:A3*10)", cells) == .number(10))
        #expect(eval("=INDEX(A1:A3+B1:B3, 3)", cells) == .number(9))
        #expect(eval("=SUM(ROW(A1:A3)*COLUMN(A1:C1))", cells) == .number(36))
        #expect(eval("=INDEX({1,2}+{1;2;3}, 3, 2)") == .number(5))
        #expect(eval("=INDEX({1,2,3}+{1,2}, 1, 3)") == err(.notAvailable))
        #expect(eval("=SUM(LEN({\"a\",\"bb\",\"ccc\"}))") == .number(6))
        #expect(eval("=A1:A3", cells) == .number(1))
        #expect(eval("=SUM(-A1:A3)", cells) == .number(-6))
        #expect(close(eval("=SUM(A1:A3%)", cells), 0.06))
        #expect(eval("=CONCATENATE(A1:A3&\"x\")", cells) == .text("1x2x3x"))
        #expect(eval("=SUM(IFERROR(1/(A1:A3-2), 100))", cells) == .number(100))
        #expect(eval("=COUNT(IFERROR(1/(A1:A3-2), \"bad\"))", cells) == .number(2))
        #expect(eval("=SUM(N(A1:A3))", cells) == .number(6))
    }

    @Test func implicitTopLeftAndSingleCells() {
        let cells: [String: CellInput] = ["A1": "x", "A2": 2]
        #expect(eval("=A1:A2", cells) == .text("x"))
        #expect(eval("={5}+1") == .number(6))
        #expect(eval("=ABS(A2:A2)", cells) == .number(2))
    }

    @Test func hugeArgumentsAreErrorsNotCrashes() {
        #expect(eval("=YEAR(1E+300)") == err(.number))
        #expect(eval("=WEEKDAY(-1E+300)") == err(.number))
        #expect(eval("=DATEDIF(0, 1E+300, \"D\")") == err(.number))
        #expect(eval("=NETWORKDAYS(0, 1E+300)") == err(.number))
        #expect(eval("=WORKDAY(1E+300, 1)") == err(.number))
        #expect(eval("=EDATE(1E+300, 1)") == err(.number))
        #expect(eval("=YEARFRAC(0, 1E+300)") == err(.number))
        #expect(eval("=REPT(\"ab\", 1E+14)") == err(.value))
        #expect(eval("=SEQUENCE(1E+9, 1E+9)") == err(.value))
        #expect(eval("=CHOOSE(1E+300, 1)") == err(.value))
        #expect(eval("=COMBIN(1E+14, 5E+13)") == err(.number))
        #expect(eval("=ROUND(1, 1E+14)") == .number(1))
        #expect(eval("=LEFT(\"abc\", 1E+14)") == .text("abc"))
        #expect(eval("=INDIRECT(\"R[9999999999999]C1\", FALSE)") == err(.reference))
        #expect(eval("=ADDRESS(1E+14, 1E+14)") != err(.parse))
        #expect(eval("=ROUND(1E+300, -2)") == .number(1E+300))
        #expect(eval("=SUM(1E+308, 1E+308)") == err(.number))
    }

    @Test func nestingLimit() {
        let nested = "=" + String(repeating: "(", count: 90) + "1" + String(repeating: ")", count: 90)
        #expect(eval(nested) == .number(1))
        let tooDeep = "=" + String(repeating: "(", count: 150) + "1" + String(repeating: ")", count: 150)
        #expect(eval(tooDeep) == err(.parse))
        let functions = "=" + String(repeating: "ABS(", count: 60) + "-1" + String(repeating: ")", count: 60)
        #expect(eval(functions) == .number(1))
        #expect(eval("=" + String(repeating: "-", count: 300) + "1") == err(.parse))
    }

    @Test func standaloneEvaluationUsesStoredValues() {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .number(42), formula: "=6*7")
        let workbook = Workbook(sheets: [sheet])
        #expect(FormulaEngine.evaluate("=A1+1", inSheet: 0, at: CellAddress(row: 5, column: 5), workbook: workbook) == .number(43))
        #expect(FormulaEngine.evaluate("=ROW()", inSheet: 0, at: CellAddress(row: 5, column: 5), workbook: workbook) == .number(6))
        #expect(FormulaEngine.evaluate("=1", inSheet: 3, at: CellAddress(row: 0, column: 0), workbook: workbook) == err(.reference))
    }
}
