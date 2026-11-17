import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormulaLogicalFunctionTests {
    @Test func andOrXorNot() {
        let cells: [String: CellInput] = ["A1": true, "A2": 1, "A3": "text", "B1": false]
        #expect(eval("=AND(TRUE, 1)") == .boolean(true))
        #expect(eval("=AND(TRUE, 0)") == .boolean(false))
        #expect(eval("=AND(A1:A3)", cells) == .boolean(true))
        #expect(eval("=AND(A1:B1)", cells) == .boolean(false))
        #expect(eval("=AND(\"TRUE\", TRUE)") == .boolean(true))
        #expect(eval("=AND(\"x\")") == err(.value))
        #expect(eval("=AND(C1:C2)") == err(.value))
        #expect(eval("=AND(TRUE, 1/0)") == err(.divideByZero))
        #expect(eval("=OR(FALSE, 0, 2)") == .boolean(true))
        #expect(eval("=OR(FALSE, B1)", cells) == .boolean(false))
        #expect(eval("=XOR(TRUE, TRUE, TRUE)") == .boolean(true))
        #expect(eval("=XOR(TRUE, TRUE)") == .boolean(false))
        #expect(eval("=NOT(0)") == .boolean(true))
        #expect(eval("=NOT(\"x\")") == err(.value))
        #expect(eval("=TRUE()") == .boolean(true))
        #expect(eval("=FALSE()") == .boolean(false))
        #expect(eval("=OR({FALSE, TRUE})") == .boolean(true))
    }

    @Test func ifFamily() {
        #expect(eval("=IF(\"TRUE\", 1, 2)") == .number(1))
        #expect(eval("=IF(\"x\", 1, 2)") == err(.value))
        #expect(message(eval("=IF(\"x\", 1, 2)")) == "Function IF parameter 1 expects boolean values. But 'x' is a text and cannot be coerced to a boolean.")
        #expect(eval("=IF(A1, 1, 2)") == .number(2))
        #expect(eval("=IF(FALSE, 1)") == .boolean(false))
        #expect(eval("=IF(1/0, 1, 2)") == err(.divideByZero))
        #expect(eval("=IF(TRUE, 1, 1/0)") == .number(1))
        #expect(eval("=IF(0.5, \"yes\", \"no\")") == .text("yes"))
        #expect(eval("=IFERROR(1/0, \"x\")") == .text("x"))
        #expect(eval("=IFERROR(5, \"x\")") == .number(5))
        #expect(eval("=IFERROR(1/0)") == .empty)
        #expect(eval("=IFNA(NA(), 1)") == .number(1))
        #expect(eval("=IFNA(1/0, 1)") == err(.divideByZero))
        #expect(eval("=SUM(IFNA({1,#N/A,3}, 10))") == .number(14))
        #expect(eval("=IFS(1>2, \"a\", 2>1, \"b\")") == .text("b"))
        #expect(eval("=IFS(FALSE, 1)") == err(.notAvailable))
        #expect(eval("=IFS(TRUE, 1, FALSE)") == err(.notAvailable))
        #expect(eval("=IFS(1/0, 1, TRUE, 2)") == err(.divideByZero))
        #expect(eval("=SUM(IFS({1,2,3}>1, 10, TRUE, 1))") == .number(21))
        #expect(eval("=SWITCH(2, 1, \"a\", 2, \"b\")") == .text("b"))
        #expect(eval("=SWITCH(3, 1, \"a\", \"default\")") == .text("default"))
        #expect(eval("=SWITCH(3, 1, \"a\")") == err(.notAvailable))
        #expect(eval("=SWITCH(\"B\", \"a\", 1, \"b\", 2)") == .number(2))
        #expect(eval("=SWITCH(1, 1, \"a\", 1/0)") == .text("a"))
    }
}

struct FormulaInfoFunctionTests {
    @Test func isFunctions() {
        let cells: [String: CellInput] = ["B1": "=\"\"", "B2": 3, "B3": "x"]
        #expect(eval("=ISBLANK(A1)") == .boolean(true))
        #expect(eval("=ISBLANK(\"\")") == .boolean(false))
        #expect(eval("=ISBLANK(B1)", cells) == .boolean(false))
        #expect(eval("=ISBLANK(C1)", ["C1": "=D1"]) == .boolean(false))
        #expect(eval("=ISBLANK(D1)", ["C1": "=D1"]) == .boolean(true))
        #expect(eval("=ISERR(NA())") == .boolean(false))
        #expect(eval("=ISERR(1/0)") == .boolean(true))
        #expect(eval("=ISERROR(NA())") == .boolean(true))
        #expect(eval("=ISERROR(1)") == .boolean(false))
        #expect(eval("=ISNA(NA())") == .boolean(true))
        #expect(eval("=ISNA(1)") == .boolean(false))
        #expect(eval("=ISEVEN(2.5)") == .boolean(true))
        #expect(eval("=ISEVEN(0)") == .boolean(true))
        #expect(eval("=ISODD(-3)") == .boolean(true))
        #expect(eval("=ISEVEN(\"x\")") == err(.value))
        #expect(eval("=ISLOGICAL(TRUE)") == .boolean(true))
        #expect(eval("=ISLOGICAL(1)") == .boolean(false))
        #expect(eval("=ISNUMBER(1)") == .boolean(true))
        #expect(eval("=ISNUMBER(\"1\")") == .boolean(false))
        #expect(eval("=ISTEXT(\"a\")") == .boolean(true))
        #expect(eval("=ISTEXT(1)") == .boolean(false))
        #expect(eval("=ISNONTEXT(A1)") == .boolean(true))
        #expect(eval("=ISNONTEXT(\"\")") == .boolean(false))
        #expect(eval("=ISREF(A1)") == .boolean(true))
        #expect(eval("=ISREF(A1:B2)") == .boolean(true))
        #expect(eval("=ISREF(\"A1\")") == .boolean(false))
        #expect(eval("=ISREF(INDIRECT(\"A1\"))") == .boolean(true))
        #expect(eval("=SUM(ISNUMBER(B1:B3)*1)", cells) == .number(1))
    }

    @Test func valuesAndTypes() {
        #expect(eval("=N(5)") == .number(5))
        #expect(eval("=N(TRUE)") == .number(1))
        #expect(eval("=N(\"x\")") == .number(0))
        #expect(eval("=N(NA())") == err(.notAvailable))
        #expect(eval("=NA()") == err(.notAvailable))
        #expect(eval("=TYPE(1)") == .number(1))
        #expect(eval("=TYPE(A1)") == .number(1))
        #expect(eval("=TYPE(\"a\")") == .number(2))
        #expect(eval("=TYPE(TRUE)") == .number(4))
        #expect(eval("=TYPE(NA())") == .number(16))
        #expect(eval("=TYPE({1,2})") == .number(64))
        #expect(eval("=TYPE(A1:A2)") == .number(64))
        #expect(eval("=ERROR.TYPE(1/0)") == .number(2))
        #expect(eval("=ERROR.TYPE(NA())") == .number(7))
        #expect(eval("=ERROR.TYPE(#NULL!)") == .number(1))
        #expect(eval("=ERROR.TYPE(#ERROR!)") == .number(8))
        #expect(eval("=ERROR.TYPE(1)") == err(.notAvailable))
    }
}

struct FormulaTextFunctionTests {
    @Test func charactersAndCodes() {
        #expect(eval("=CHAR(65)") == .text("A"))
        #expect(eval("=CHAR(0)") == err(.number))
        #expect(eval("=UNICHAR(9731)") == .text("☃"))
        #expect(eval("=CODE(\"A\")") == .number(65))
        #expect(eval("=CODE(\"\")") == err(.value))
        #expect(eval("=UNICODE(\"☃x\")") == .number(9731))
        #expect(eval("=CLEAN(\"a\"&CHAR(10)&\"b\"&CHAR(7))") == .text("ab"))
        #expect(eval("=LEN(\"abc\")") == .number(3))
        #expect(eval("=LEN(123)") == .number(3))
        #expect(eval("=LEN(\"😀\")") == .number(2))
        #expect(eval("=LEN(A1)") == .number(0))
    }

    @Test func joining() {
        let cells: [String: CellInput] = ["A1": "a", "A2": 1, "B1": true, "B2": "", "A3": "c"]
        #expect(eval("=CONCAT(\"a\", 1)") == .text("a1"))
        #expect(eval("=CONCAT(\"a\", \"b\", \"c\")") == err(.notAvailable))
        #expect(eval("=CONCATENATE(\"a\", 1, TRUE)") == .text("a1TRUE"))
        #expect(eval("=CONCATENATE(A1:B2)", cells) == .text("aTRUE1"))
        #expect(eval("=JOIN(\"-\", {1,2,3})") == .text("1-2-3"))
        #expect(eval("=JOIN(\", \", A1:A3, \"x\")", cells) == .text("a, 1, c, x"))
        #expect(eval("=TEXTJOIN(\"-\", TRUE, \"a\", \"\", \"b\")") == .text("a-b"))
        #expect(eval("=TEXTJOIN(\"-\", FALSE, \"a\", \"\", \"b\")") == .text("a--b"))
        #expect(eval("=TEXTJOIN(\", \", TRUE, A1:A4)", cells) == .text("a, 1, c"))
        #expect(eval("=TEXTJOIN({\"-\",\"+\"}, TRUE, 1, 2, 3, 4)") == .text("1-2+3-4"))
        #expect(eval("=CONCATENATE(\"a\", 1/0)") == err(.divideByZero))
    }

    @Test func comparingAndSearching() {
        #expect(eval("=EXACT(\"a\", \"A\")") == .boolean(false))
        #expect(eval("=EXACT(\"a\", \"a\")") == .boolean(true))
        #expect(eval("=EXACT(1, \"1\")") == .boolean(true))
        #expect(eval("=FIND(\"b\", \"abcb\")") == .number(2))
        #expect(eval("=FIND(\"b\", \"abcb\", 3)") == .number(4))
        #expect(eval("=FIND(\"B\", \"abc\")") == err(.value))
        #expect(eval("=FIND(\"\", \"abc\")") == .number(1))
        #expect(eval("=FIND(\"a\", \"abc\", 0)") == err(.value))
        #expect(eval("=SEARCH(\"B\", \"abc\")") == .number(2))
        #expect(eval("=SEARCH(\"x\", \"abc\")") == err(.value))
        #expect(eval("=FIND(\"c\", \"😀c\")") == .number(3))
    }

    @Test func slicing() {
        #expect(eval("=LEFT(\"abc\", 2)") == .text("ab"))
        #expect(eval("=LEFT(\"abc\")") == .text("a"))
        #expect(eval("=LEFT(\"abc\", 10)") == .text("abc"))
        #expect(eval("=LEFT(\"abc\", -1)") == err(.value))
        #expect(eval("=RIGHT(\"abc\", 2)") == .text("bc"))
        #expect(eval("=RIGHT(\"abc\", 5)") == .text("abc"))
        #expect(eval("=MID(\"abcdef\", 2, 3)") == .text("bcd"))
        #expect(eval("=MID(\"abc\", 5, 1)") == .text(""))
        #expect(eval("=MID(\"abc\", 0, 1)") == err(.value))
        #expect(eval("=REPLACE(\"abcdef\", 2, 3, \"X\")") == .text("aXef"))
        #expect(eval("=REPLACE(\"abc\", 10, 1, \"X\")") == .text("abcX"))
        #expect(eval("=REPT(\"ab\", 3)") == .text("ababab"))
        #expect(eval("=REPT(\"a\", 0)") == .text(""))
        #expect(eval("=REPT(\"a\", -1)") == err(.value))
        #expect(eval("=LEFT(123, 2)") == .text("12"))
    }

    @Test func caseAndSpacing() {
        #expect(eval("=LOWER(\"ABC\")") == .text("abc"))
        #expect(eval("=UPPER(\"abc\")") == .text("ABC"))
        #expect(eval("=PROPER(\"hello wORLD 2nd o'neil\")") == .text("Hello World 2Nd O'Neil"))
        #expect(eval("=TRIM(\"  a   b  \")") == .text("a b"))
        #expect(eval("=SUBSTITUTE(\"aaa\", \"a\", \"b\")") == .text("bbb"))
        #expect(eval("=SUBSTITUTE(\"aaa\", \"a\", \"b\", 2)") == .text("aba"))
        #expect(eval("=SUBSTITUTE(\"aaa\", \"a\", \"b\", 5)") == .text("aaa"))
        #expect(eval("=SUBSTITUTE(\"abc\", \"\", \"x\")") == .text("abc"))
        #expect(eval("=SUBSTITUTE(\"Abc\", \"a\", \"x\")") == .text("Abc"))
        #expect(eval("=T(\"a\")") == .text("a"))
        #expect(eval("=T(1)") == .text(""))
        #expect(eval("=FIXED(1234.567)") == .text("1,234.57"))
        #expect(eval("=FIXED(1234.567, 1, TRUE)") == .text("1234.6"))
        #expect(eval("=FIXED(-1234.5, 0)") == .text("-1,235"))
        #expect(eval("=FIXED(1234.567, -2)") == .text("1,200"))
        #expect(eval("=FIXED(1234567.891, 2)") == .text("1,234,567.89"))
    }

    @Test func regularExpressions() {
        #expect(eval("=REGEXEXTRACT(\"abc123\", \"[0-9]+\")") == .text("123"))
        #expect(eval("=REGEXEXTRACT(\"key=value\", \"=(.*)\")") == .text("value"))
        #expect(eval("=REGEXEXTRACT(\"a1b2\", \"([a-z])([0-9])\")") == .text("a"))
        #expect(eval("=COLUMNS(REGEXEXTRACT(\"a1b2\", \"([a-z])([0-9])\"))") == .number(2))
        #expect(eval("=REGEXEXTRACT(\"abc\", \"x\")") == err(.notAvailable))
        #expect(eval("=REGEXMATCH(\"abc\", \"^a\")") == .boolean(true))
        #expect(eval("=REGEXMATCH(\"abc\", \"^b\")") == .boolean(false))
        #expect(eval("=REGEXMATCH(123, \"1\")") == err(.value))
        #expect(eval("=REGEXMATCH(\"a\", \"(\")") == err(.reference))
        #expect(eval("=REGEXREPLACE(\"a1b2\", \"[0-9]\", \"#\")") == .text("a#b#"))
        #expect(eval("=REGEXREPLACE(\"John Smith\", \"(\\w+) (\\w+)\", \"$2 $1\")") == .text("Smith John"))
    }

    @Test func splitting() {
        #expect(eval("=SPLIT(\"a,b,,c\", \",\")") == .text("a"))
        #expect(eval("=COLUMNS(SPLIT(\"a,b,,c\", \",\"))") == .number(3))
        #expect(eval("=COLUMNS(SPLIT(\"a,b,,c\", \",\", TRUE, FALSE))") == .number(4))
        #expect(eval("=INDEX(SPLIT(\"1-2\", \"-\"), 1, 2)") == .number(2))
        #expect(eval("=COLUMNS(SPLIT(\"a-b_c\", \"-_\"))") == .number(3))
        #expect(eval("=SPLIT(\"a-b_c\", \"-_\", FALSE)") == .text("a-b_c"))
        #expect(eval("=INDEX(SPLIT(\"a--b\", \"--\", FALSE), 1, 2)") == .text("b"))
        #expect(eval("=SPLIT(\"abc\", \"\")") == err(.value))
    }

    @Test func conversions() {
        #expect(eval("=VALUE(\"12\")") == .number(12))
        #expect(eval("=VALUE(\" 12 \")") == .number(12))
        #expect(eval("=VALUE(\"abc\")") == err(.value))
        #expect(message(eval("=VALUE(\"abc\")")) == "VALUE parameter 'abc' cannot be parsed to number.")
        #expect(eval("=VALUE(5)") == .number(5))
        #expect(eval("=ISTEXT(TEXT(1, \"0\"))") == .boolean(true))
        #expect(eval("=TEXT(\"abc\", \"0\")") == .text("abc"))
    }
}

struct FormulaCriteriaTests {
    let cells: [String: CellInput] = ["A1": 1, "A2": 5, "A3": "5", "A4": "apple", "A5": "Apple pie", "A6": true,
                                      "A7": "=\"\"", "A8": "a*b", "A9": .error(.notAvailable), "A10": 46023]

    @Test func numericCriteria() {
        #expect(eval("=COUNTIF(A1:A10, \">4\")", cells) == .number(2))
        #expect(eval("=COUNTIF(A1:A10, \"5\")", cells) == .number(2))
        #expect(eval("=COUNTIF(A1:A10, 5)", cells) == .number(2))
        #expect(eval("=COUNTIF(A1:A10, \"=5\")", cells) == .number(2))
        #expect(eval("=COUNTIF(A1:A10, \"<>5\")", cells) == .number(8))
        #expect(eval("=COUNTIF(A1:A10, \">=46023\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"<1\")", cells) == .number(0))
    }

    @Test func textCriteria() {
        #expect(eval("=COUNTIF(A1:A10, \"=apple\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"APPLE\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"apple*\")", cells) == .number(2))
        #expect(eval("=COUNTIF(A1:A10, \"*PIE\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"?pple\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"a~*b\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"a*b\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"*\")", cells) == .number(5))
        #expect(eval("=COUNTIF(A1:A10, \"<>apple\")", cells) == .number(9))
        #expect(eval("=COUNTIF(A1:A10, \">=apple\")", cells) == .number(2))
    }

    @Test func blankBooleanAndErrorCriteria() {
        #expect(eval("=COUNTIF(A1:A12, \"\")", cells) == .number(3))
        #expect(eval("=COUNTIF(A1:A12, \"=\")", cells) == .number(3))
        #expect(eval("=COUNTIF(A1:A12, \"<>\")", cells) == .number(9))
        #expect(eval("=COUNTIF(A1:A10, TRUE)", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"true\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, \"#N/A\")", cells) == .number(1))
        #expect(eval("=COUNTIF(A1:A10, 1/0)", cells) == err(.divideByZero))
        #expect(eval("=COUNTIF(A1:A12, B1)", cells) == .number(3))
    }

    @Test func criterionMatching() throws {
        let atLeastFive = try Criterion(.text(">=5"))
        #expect(atLeastFive.matches(.number(5)))
        #expect(!atLeastFive.matches(.number(4.9)))
        #expect(!atLeastFive.matches(.text("6")))
        #expect(!atLeastFive.matchesBlank)
        let notX = try Criterion(.text("<>x"))
        #expect(notX.matches(.empty))
        #expect(notX.matches(.number(1)))
        #expect(!notX.matches(.text("X")))
        let wildcard = try Criterion(.text("a?c*"))
        #expect(wildcard.matches(.text("ABCdef")))
        #expect(!wildcard.matches(.text("ac")))
        #expect(WildcardPattern("*a*b*").matches("xxaYYbzz"))
        #expect(!WildcardPattern("*a*b").matches("xxaYYbzz"))
        #expect(WildcardPattern("~?").matches("?"))
        #expect(!WildcardPattern("~?").matches("a"))
        #expect(WildcardPattern("Straße").matches("STRASSE") == false)
        #expect(WildcardPattern("ÉTÉ").matches("été"))
    }
}
