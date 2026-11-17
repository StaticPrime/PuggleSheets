import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaParserTests {
    @Test func operatorPrecedence() {
        #expect(eval("=1+2*3") == .number(7))
        #expect(eval("=(1+2)*3") == .number(9))
        #expect(eval("=2^3^2") == .number(64))
        #expect(eval("=-2^2") == .number(4))
        #expect(eval("=2^-1") == .number(0.5))
        #expect(eval("=10-2-3") == .number(5))
        #expect(eval("=12/3/2") == .number(2))
        #expect(eval("=1+2&3") == .text("33"))
        #expect(eval("=\"a\"&1+1") == .text("a2"))
        #expect(eval("=1+1=2") == .boolean(true))
        #expect(eval("=1<2=TRUE") == .boolean(true))
        #expect(eval("=2&3=\"23\"") == .boolean(true))
        #expect(eval("=--3") == .number(3))
        #expect(eval("=+3") == .number(3))
        #expect(eval("=-(1+2)*2") == .number(-6))
    }

    @Test func percentOperator() {
        #expect(eval("=50%") == .number(0.5))
        #expect(eval("=2*50%") == .number(1))
        #expect(eval("=-50%") == .number(-0.5))
        #expect(eval("=200%%") == .number(0.02))
        #expect(eval("=A1%", ["A1": 25]) == .number(0.25))
    }

    @Test func numberLiterals() {
        #expect(eval("=1.5") == .number(1.5))
        #expect(eval("=.5") == .number(0.5))
        #expect(eval("=1e3") == .number(1000))
        #expect(eval("=1E-3") == .number(0.001))
        #expect(eval("=2.5e+2") == .number(250))
        #expect(eval("=007") == .number(7))
    }

    @Test func stringBooleanAndErrorLiterals() {
        #expect(eval("=\"a \"\"quoted\"\" word\"") == .text("a \"quoted\" word"))
        #expect(eval("=\"\"") == .text(""))
        #expect(eval("=\"héllo 😀\"") == .text("héllo 😀"))
        #expect(eval("=TRUE") == .boolean(true))
        #expect(eval("=false") == .boolean(false))
        #expect(eval("=TRUE()") == .boolean(true))
        for code in ["#N/A", "#DIV/0!", "#REF!", "#VALUE!", "#NAME?", "#NUM!", "#NULL!", "#ERROR!"] {
            #expect(eval("=" + code) == .error(CellError(code: code)!), "\(code)")
        }
        #expect(eval("=#n/a") == err(.notAvailable))
        #expect(eval("=ISNA(#N/A)") == .boolean(true))
    }

    @Test func arrayLiterals() {
        #expect(eval("=SUM({1,2;3,4})") == .number(10))
        #expect(eval("=ROWS({1,2;3,4})") == .number(2))
        #expect(eval("=COLUMNS({1,2,3})") == .number(3))
        #expect(eval("={1,2;3,4}") == .number(1))
        #expect(eval("=INDEX({1,2;3,4},2,1)") == .number(3))
        #expect(eval("=INDEX({\"a\",TRUE;#N/A,-1},2,2)") == .number(-1))
        #expect(eval("={1,2;3}") == err(.value))
        #expect(eval("=SUM({1,2}*{3,4})") == .number(11))
        #expect(eval("=ROWS({A1:A3,B1:B3})") == .number(3))
        #expect(eval("=COLUMNS({A1:A3,B1:B3})") == .number(2))
        #expect(eval("=ROWS({1;2;A1:A3})") == .number(5))
    }

    @Test func whitespaceAndCase() {
        #expect(eval("= 1 +  2 ") == .number(3))
        #expect(eval("=sum( 1 , 2 )") == .number(3))
        #expect(eval("=Sum(a1:A2)", ["A1": 1, "A2": 2]) == .number(3))
        #expect(eval("=\n1\n+\t2") == .number(3))
    }

    @Test func references() {
        let cells: [String: CellInput] = ["A1": 1, "B2": 5, "C3": 10, "A2": 2, "A3": 3]
        #expect(eval("=$A$1+A$1+$A1", cells) == .number(3))
        #expect(eval("=SUM(C3:A1)", cells) == .number(21))
        #expect(eval("=SUM(A:A)", cells) == .number(6))
        #expect(eval("=SUM(A:C)", cells) == .number(21))
        #expect(eval("=SUM($A:$C)", cells) == .number(21))
        #expect(eval("=SUM(2:2)", cells) == .number(7))
        #expect(eval("=SUM(1:3)", cells) == .number(21))
        #expect(eval("=SUM($1:$3)", cells) == .number(21))
        #expect(eval("=SUM(A2:A)", cells) == .number(5))
        #expect(eval("=SUM($A$2:$A)", cells) == .number(5))
        #expect(eval("=SUM(A2:2)", cells) == .number(7))
        #expect(eval("=SUM(A1:B2:C3)", cells) == .number(21))
    }

    @Test func sheetQualifiedReferences() {
        let book = TestBook([("Sheet1", ["A1": 1]), ("My Sheet", ["A1": 10, "B2": 20]), ("It's", ["A1": 100])])
        #expect(book.evaluate("=Sheet1!A1+'My Sheet'!A1") == .number(11))
        #expect(book.evaluate("=SUM('My Sheet'!A1:B2)") == .number(30))
        #expect(book.evaluate("='It''s'!A1") == .number(100))
        #expect(book.evaluate("=sheet1!a1") == .number(1))
        #expect(book.evaluate("=SUM('my sheet'!A:A)") == .number(10))
        #expect(book.evaluate("=Missing!A1") == err(.reference))
        #expect(message(book.evaluate("=Missing!A1")) == "Unresolved sheet name 'Missing'.")
    }

    @Test func functionNamesThatLookLikeCells() {
        #expect(eval("=LOG10(100)") == .number(2))
        #expect(close(eval("=ATAN2(1,1)"), .pi / 4))
        #expect(eval("=log10(1000)") == .number(3))
    }

    @Test func parseErrors() {
        for formula in ["=", "=1+", "=(1", "=1)", "=SUM(1", "=\"abc", "=1 2", "=*2", "={}", "={1,}", "=A1:", "=@A1",
                        "=Sheet1!", "='abc", "=1..2", "=SUM(1;2)", "=A1 B1", "=#FOO", "=1:A", "='My Sheet'"] {
            let value = eval(formula)
            #expect(value == err(.parse), "\(formula)")
            #expect(message(value) == "Formula parse error.", "\(formula)")
        }
    }

    @Test func unknownNamesAndFunctions() {
        #expect(eval("=FOO(1)") == err(.name))
        #expect(message(eval("=FOO(1)")) == "Unknown function: 'FOO'.")
        #expect(eval("=foo") == err(.name))
        #expect(message(eval("=foo")) == "Unknown range name: 'foo'.")
        #expect(eval("=ABCD1") == err(.name))
        #expect(eval("=IFERROR(FOO(), 2)") == .number(2))
        #expect(eval("=IF(FALSE, FOO(), 2)") == .number(2))
    }

    @Test func emptyArguments() {
        #expect(eval("=IF(TRUE,,1)") == .empty)
        #expect(eval("=IF(FALSE,1,)") == .empty)
        #expect(eval("=SUM(1,,2)") == .number(3))
        #expect(eval("=CONCATENATE(\"a\",,\"b\")") == .text("ab"))
        #expect(eval("=ROUND(2.5,)") == .number(3))
    }

    @Test func outOfGridReferences() {
        #expect(eval("=A1001") == err(.reference))
        #expect(eval("=AA1") == err(.reference))
        #expect(eval("=SUM(A1:A2000)") == err(.reference))
    }

    @Test func argumentCounts() {
        #expect(eval("=SUM()") == err(.notAvailable))
        #expect(message(eval("=SUM()")) == "Wrong number of arguments to SUM. Expected at least 1 arguments, but got 0 arguments.")
        #expect(message(eval("=ABS(1,2)")) == "Wrong number of arguments to ABS. Expected 1 arguments, but got 2 arguments.")
        #expect(message(eval("=ROUND()")) == "Wrong number of arguments to ROUND. Expected between 1 and 2 arguments, but got 0 arguments.")
        #expect(eval("=PI(1)") == err(.notAvailable))
        #expect(eval("=SUMIFS(A1:A2, B1:B2)") == err(.notAvailable))
    }

    @Test func excelFunctionPrefixes() {
        #expect(eval("=_xlfn.XLOOKUP(2,{1;2},{\"a\";\"b\"})") == .text("b"))
    }

    @Test func functionNamesAreListedSorted() {
        let names = FormulaEngine.functionNames
        #expect(names == names.sorted())
        for name in ["SUM", "VLOOKUP", "CEILING.MATH", "STDEV.S", "ARRAYFORMULA", "XLOOKUP", "NETWORKDAYS", "IRR"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(names.count >= 190)
    }

    @Test func functionHelpCoversEveryFunction() {
        let info = FormulaEngine.functionInfo
        #expect(info.map(\.name) == FormulaEngine.functionNames)
        #expect(FormulaEngine.functionInfo(named: "sum")?.syntax == "SUM(value1, [value2, ...])")
        #expect(FormulaEngine.functionInfo(named: "VLOOKUP")?.category == "Lookup")
        #expect(FormulaEngine.functionInfo(named: "PI")?.syntax == "PI()")
        #expect(info.allSatisfy { !$0.summary.isEmpty && !$0.category.isEmpty })
    }

    @Test func parsedFormulaDependenciesAndVolatility() {
        let parsed = ParsedFormula("=SUM(A1:B2)+ROW(C3)+Sheet2!D4")
        #expect(parsed.dependencies.map(\.reference.partsText) == ["A1:B2", "D4"])
        #expect(ParsedFormula("=SUMIF(A1:A5, 1, B1)").dependencies.map { $0.shapedLike?.partsText } == [nil, "A1:A5"])
        #expect(!parsed.isVolatile)
        #expect(ParsedFormula("=NOW()").isVolatile)
        #expect(ParsedFormula("=1+RAND()").isVolatile)
        #expect(ParsedFormula("=INDIRECT(\"A1\")").isVolatile)
        #expect(ParsedFormula("=SUM(OFFSET(A1,1,1))").isVolatile)
        #expect(ParsedFormula("=SUM(A1:INDEX(B:B,3))").isVolatile)
        #expect(ParsedFormula("=OFFSET(A1,1,0)").dependencies.isEmpty)
    }
}
