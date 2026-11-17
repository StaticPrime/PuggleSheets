import Foundation
import Testing
@testable import PuggleSheetsKit

struct IOXLSXFormulaTests {
    @Test func shiftsRelativeReferences() {
        #expect(XLSXFormula.shifting("A1*2", rows: 1, columns: 0) == "A2*2")
        #expect(XLSXFormula.shifting("A1+B2", rows: 2, columns: 3) == "D3+E4")
        #expect(XLSXFormula.shifting("$A$1+$A1+A$1", rows: 4, columns: 2) == "$A$1+$A5+C$1")
        #expect(XLSXFormula.shifting("SUM(A1:B2)", rows: 1, columns: 1) == "SUM(B2:C3)")
        #expect(XLSXFormula.shifting("SUM($A$1:B2)", rows: 1, columns: 1) == "SUM($A$1:C3)")
        #expect(XLSXFormula.shifting("a1+b1", rows: 1, columns: 0) == "A2+B2")
        #expect(XLSXFormula.shifting("Z1", rows: 0, columns: 1) == "AA1")
        #expect(XLSXFormula.shifting("A1", rows: 0, columns: 0) == "A1")
    }

    @Test func shiftsWholeRowsAndColumns() {
        #expect(XLSXFormula.shifting("SUM(A:A)", rows: 5, columns: 1) == "SUM(B:B)")
        #expect(XLSXFormula.shifting("SUM($A:B)", rows: 0, columns: 2) == "SUM($A:D)")
        #expect(XLSXFormula.shifting("SUM(1:1)", rows: 2, columns: 7) == "SUM(3:3)")
        #expect(XLSXFormula.shifting("SUM($1:2)", rows: 1, columns: 0) == "SUM($1:3)")
    }

    @Test func shiftsSheetQualifiedReferences() {
        #expect(XLSXFormula.shifting("Data!A1+'My Sheet'!B2", rows: 1, columns: 0) == "Data!A2+'My Sheet'!B3")
        #expect(XLSXFormula.shifting("'It''s'!A1:A3", rows: 1, columns: 0) == "'It''s'!A2:A4")
        // Short sheet names that look like cells stay put; so do 3-D sheet spans.
        #expect(XLSXFormula.shifting("A1!B2", rows: 1, columns: 0) == "A1!B3")
        #expect(XLSXFormula.shifting("SUM(S1:S3!A1)", rows: 1, columns: 0) == "SUM(S1:S3!A2)")
        #expect(XLSXFormula.shifting("[1]Sheet1!A1", rows: 1, columns: 0) == "[1]Sheet1!A2")
    }

    @Test func leavesEverythingElseAlone() {
        #expect(XLSXFormula.shifting("\"A1\"&A1", rows: 1, columns: 0) == "\"A1\"&A2")
        #expect(XLSXFormula.shifting("\"say \"\"B2\"\"\"&B2", rows: 1, columns: 0) == "\"say \"\"B2\"\"\"&B3")
        #expect(XLSXFormula.shifting("LOG10(A1)+ATAN2(B1,C1)", rows: 1, columns: 0) == "LOG10(A2)+ATAN2(B2,C2)")
        #expect(XLSXFormula.shifting("Table1[Amount]+T1[[#This Row],[A1]]", rows: 1, columns: 0) == "Table1[Amount]+T1[[#This Row],[A1]]")
        #expect(XLSXFormula.shifting("TRUE+1.5E+3+Rate", rows: 1, columns: 1) == "TRUE+1.5E+3+Rate")
        #expect(XLSXFormula.shifting("STDEV.S(A1:A9)", rows: 1, columns: 0) == "STDEV.S(A2:A10)")
        #expect(XLSXFormula.shifting("A1#", rows: 1, columns: 0) == "A2#")
        #expect(XLSXFormula.shifting("#REF!+A1", rows: 1, columns: 0) == "#REF!+A2")
        #expect(XLSXFormula.shifting("Größe+A1", rows: 1, columns: 0) == "Größe+A2")
    }

    @Test func referencesPushedOffTheSheetBecomeRefErrors() {
        #expect(XLSXFormula.shifting("A1", rows: -1, columns: 0) == "#REF!")
        #expect(XLSXFormula.shifting("SUM(A1:B2)+1", rows: 0, columns: -1) == "SUM(#REF!)+1")
        #expect(XLSXFormula.shifting("XFD1", rows: 0, columns: 1) == "#REF!")
        #expect(XLSXFormula.shifting("A1048576", rows: 1, columns: 0) == "#REF!")
        // Not references at all: beyond Excel's grid.
        #expect(XLSXFormula.shifting("XFE1+ZZZ9", rows: 1, columns: 0) == "XFE1+ZZZ9")
    }

    @Test func importingStripsExcelPrefixes() {
        #expect(XLSXFormula.importing("SUM(A1:A3)") == "=SUM(A1:A3)")
        #expect(XLSXFormula.importing("_xlfn.CONCAT(A1,B1)") == "=CONCAT(A1,B1)")
        #expect(XLSXFormula.importing("_xlfn._xlws.FILTER(A1:A9,B1:B9>0)") == "=FILTER(A1:A9,B1:B9>0)")
        #expect(XLSXFormula.importing("_xlws.SORT(A1:A3)") == "=SORT(A1:A3)")
        #expect(XLSXFormula.importing("_xlfn.LET(_xlpm.x,1,_xlpm.x+1)") == "=LET(x,1,x+1)")
        #expect(XLSXFormula.importing("_xludf.SPLIT(A1,\",\")") == "=SPLIT(A1,\",\")")
        // Text that only looks like a prefix stays.
        #expect(XLSXFormula.importing("\"_xlfn.CONCAT\"&my_name") == "=\"_xlfn.CONCAT\"&my_name")
    }

    @Test func exportingAddsPrefixesForNewerFunctions() {
        #expect(XLSXFormula.exporting("=SUM(A1:A3)") == "SUM(A1:A3)")
        #expect(XLSXFormula.exporting("=CONCAT(A1, TEXTJOIN(\",\", TRUE, B1:B3))") == "_xlfn.CONCAT(A1, _xlfn.TEXTJOIN(\",\", TRUE, B1:B3))")
        #expect(XLSXFormula.exporting("=filter(A1:A9, B1:B9 > 0)") == "_xlfn._xlws.filter(A1:A9, B1:B9 > 0)")
        #expect(XLSXFormula.exporting("=SORT(UNIQUE(A:A))") == "_xlfn._xlws.SORT(_xlfn.UNIQUE(A:A))")
        #expect(XLSXFormula.exporting("=IFS(A1>1,\"CONCAT(\",TRUE,STDEV.S(B:B))") == "_xlfn.IFS(A1>1,\"CONCAT(\",TRUE,_xlfn.STDEV.S(B:B))")
        #expect(XLSXFormula.exporting("=XLOOKUP(A1,B:B,C:C)+IFNA(D1,0)+DAYS(E1,F1)") == "_xlfn.XLOOKUP(A1,B:B,C:C)+_xlfn.IFNA(D1,0)+_xlfn.DAYS(E1,F1)")
        // Other functions, and names that merely match, aren't prefixed.
        #expect(XLSXFormula.exporting("=ARRAYFORMULA(SPLIT(A1,\" \"))+COUNTUNIQUE(B:B)") == "ARRAYFORMULA(SPLIT(A1,\" \"))+COUNTUNIQUE(B:B)")
        #expect(XLSXFormula.exporting("=Sheet1!CONCAT") == "Sheet1!CONCAT")
        #expect(XLSXFormula.exporting("=") == nil)
        #expect(XLSXFormula.exporting("=  ") == nil)
    }

    @Test func exportingClosesOpenEndedRanges() {
        let sizes: (String?) -> (rows: Int, columns: Int) = { name in
            switch name?.lowercased() {
            case nil: (1000, 26)
            case "big data": (5000, 40)
            default: (200, 10)
            }
        }
        #expect(XLSXFormula.exporting("=SUM(A2:A)", size: sizes) == "SUM(A2:A1000)")
        #expect(XLSXFormula.exporting("=SUM($B$3:$C)", size: sizes) == "SUM($B$3:$C1000)")
        #expect(XLSXFormula.exporting("=SUM('Big Data'!A2:A)+SUM(Other!B5:5)", size: sizes) == "SUM('Big Data'!A2:A5000)+SUM(Other!B5:J5)")
        #expect(XLSXFormula.exporting("=COUNTA(B2:2)", size: sizes) == "COUNTA(B2:Z2)")
        // Whole columns and rows are fine as they are; so are complete ranges and text.
        #expect(XLSXFormula.exporting("=SUM(A:A)+SUM(1:1)+SUM(A1:B2)&\"A2:A\"", size: sizes) == "SUM(A:A)+SUM(1:1)+SUM(A1:B2)&\"A2:A\"")
        // A range starting below the sheet's last row still ends at its start.
        #expect(XLSXFormula.exporting("=SUM(A1500:A)", size: sizes) == "SUM(A1500:A1500)")
        #expect(XLSXFormulaToken.unquoted("'It''s'") == "It's")
    }

    @Test func tokenizerKeepsEveryCharacter() {
        for formula in ["=SUM(A1:B2)*'My Sheet'!C3&\"text \"\"quoted\"\"\"", "=Table1[[#This Row],[Amount]]+[1]Ext!A1", "=Größe×2 + 1.5E+3", "='unterminated", "=\"open"] {
            #expect(XLSXFormulaToken.tokenize(formula).map(\.text).joined() == formula)
        }
    }

    @Test func prefixesRoundTrip() {
        for formula in ["=CONCAT(A1,B1)", "=FILTER(A1:A9,B1:B9>0)", "=SUM(A1:A3)*RANK.EQ(B1,B:B)", "=\"_xlfn.\"&SEQUENCE(3)"] {
            #expect(XLSXFormula.importing(XLSXFormula.exporting(formula) ?? "") == formula)
        }
    }

    // MARK: - Lambda functions and Excel 365's newer functions

    @Test func lambdaFunctionsGetPrefixesAndParameterNames() {
        #expect(XLSXFormula.exporting("=LET(x, 1, y, 2, x+y)") == "_xlfn.LET(_xlpm.x, 1, _xlpm.y, 2, _xlpm.x+_xlpm.y)")
        #expect(XLSXFormula.exporting("=LAMBDA(a, b, a*b)(2, 3)") == "_xlfn.LAMBDA(_xlpm.a, _xlpm.b, _xlpm.a*_xlpm.b)(2, 3)")
        #expect(XLSXFormula.exporting("=MAP(A1:A3, LAMBDA(v, v*2))") == "_xlfn.MAP(A1:A3, _xlfn.LAMBDA(_xlpm.v, _xlpm.v*2))")
        #expect(XLSXFormula.exporting("=REDUCE(0, A1:A3, LAMBDA(total, v, total+v))")
            == "_xlfn.REDUCE(0, A1:A3, _xlfn.LAMBDA(_xlpm.total, _xlpm.v, _xlpm.total+_xlpm.v))")
        #expect(XLSXFormula.exporting("=SCAN(0,A1:A3,LAMBDA(a,v,a+v))") == "_xlfn.SCAN(0,A1:A3,_xlfn.LAMBDA(_xlpm.a,_xlpm.v,_xlpm.a+_xlpm.v))")
        #expect(XLSXFormula.exporting("=BYROW(A1:C3,LAMBDA(r,SUM(r)))+BYCOL(A1:C3,LAMBDA(c,MAX(c)))")
            == "_xlfn.BYROW(A1:C3,_xlfn.LAMBDA(_xlpm.r,SUM(_xlpm.r)))+_xlfn.BYCOL(A1:C3,_xlfn.LAMBDA(_xlpm.c,MAX(_xlpm.c)))")
        #expect(XLSXFormula.exporting("=MAKEARRAY(2,3,LAMBDA(r,c,r*c))") == "_xlfn.MAKEARRAY(2,3,_xlfn.LAMBDA(_xlpm.r,_xlpm.c,_xlpm.r*_xlpm.c))")
        #expect(XLSXFormula.exporting("=LAMBDA(x,y,IF(ISOMITTED(y),x,x+y))(1)")
            == "_xlfn.LAMBDA(_xlpm.x,_xlpm.y,IF(_xlfn.ISOMITTED(_xlpm.y),_xlpm.x,_xlpm.x+_xlpm.y))(1)")
        // Only inside their own call; sheet names, strings and the function names themselves stay.
        #expect(XLSXFormula.exporting("=LET(x, 1, x)+x") == "_xlfn.LET(_xlpm.x, 1, _xlpm.x)+x")
        #expect(XLSXFormula.exporting("=LET(x, x!A1, \"x\"&x)") == "_xlfn.LET(_xlpm.x, x!A1, \"x\"&_xlpm.x)")
        #expect(XLSXFormula.exporting("=LET(rate, 0.1, total, SUM(A1:A9), total*(1+rate))")
            == "_xlfn.LET(_xlpm.rate, 0.1, _xlpm.total, SUM(A1:A9), _xlpm.total*(1+_xlpm.rate))")
        // A LET value that is a calculation isn't a name.
        #expect(XLSXFormula.exporting("=LET(x, {1,2}, y, x*2, SUM(y))") == "_xlfn.LET(_xlpm.x, {1,2}, _xlpm.y, _xlpm.x*2, SUM(_xlpm.y))")
    }

    @Test func newerFunctionsGetPrefixes() {
        #expect(XLSXFormula.exporting("=XLOOKUP(A1,B:B,C:C)&TEXTJOIN(\",\",TRUE,UNIQUE(SORT(FILTER(D:D,E:E>0))))")
            == "_xlfn.XLOOKUP(A1,B:B,C:C)&_xlfn.TEXTJOIN(\",\",TRUE,_xlfn.UNIQUE(_xlfn._xlws.SORT(_xlfn._xlws.FILTER(D:D,E:E>0))))")
        #expect(XLSXFormula.exporting("=SEQUENCE(3)+XMATCH(1,A:A)+SUM(SORTBY(A1:A3,B1:B3))+ROWS(VSTACK(A1,B1))")
            == "_xlfn.SEQUENCE(3)+_xlfn.XMATCH(1,A:A)+SUM(_xlfn.SORTBY(A1:A3,B1:B3))+ROWS(_xlfn.VSTACK(A1,B1))")
        #expect(XLSXFormula.exporting("=TEXTSPLIT(A1,\" \")&TEXTBEFORE(A1,\"-\")&REGEXEXTRACT(A1,\"[0-9]+\")&ENCODEURL(A2)")
            == "_xlfn.TEXTSPLIT(A1,\" \")&_xlfn.TEXTBEFORE(A1,\"-\")&_xlfn.REGEXEXTRACT(A1,\"[0-9]+\")&_xlfn.ENCODEURL(A2)")
        // Functions without an Excel equivalent, and GETPIVOTDATA (which Excel has with
        // other arguments), are written as they are.
        for formula in ["QUERY(A1:C9,\"select A where B > 1\",1)", "SPARKLINE(A1:A9,{\"charttype\",\"bar\"})", "SORTN(A1:B9,2,0,2,FALSE)",
                        "GETPIVOTDATA(\"SUM of Sales\",A1,\"Region\",\"East\")"] {
            #expect(XLSXFormula.exporting("=" + formula) == formula)
            #expect(XLSXFormula.importing(formula) == "=" + formula)
        }
    }

    @Test func importingStripsLambdaPrefixes() {
        #expect(XLSXFormula.importing("_xlfn.LET(_xlpm.x,1,_xlpm.y,2,_xlpm.x+_xlpm.y)") == "=LET(x,1,y,2,x+y)")
        #expect(XLSXFormula.importing("_xlfn.MAP(A1:A3,_xlfn.LAMBDA(_xlpm.v,_xlpm.v*2))") == "=MAP(A1:A3,LAMBDA(v,v*2))")
        #expect(XLSXFormula.importing("_xlfn.MAKEARRAY(2,2,_xlfn.LAMBDA(_xlpm.r,_xlpm.c,_xlpm.r+_xlpm.c))") == "=MAKEARRAY(2,2,LAMBDA(r,c,r+c))")
        #expect(XLSXFormula.importing("_xlfn.LAMBDA(_xlpm.x,_xlpm.y,IF(_xlfn.ISOMITTED(_xlpm.y),_xlpm.x,_xlpm.y))(1)")
            == "=LAMBDA(x,y,IF(ISOMITTED(y),x,y))(1)")
        for formula in ["=LET(x, 1, y, x*2, LAMBDA(a, b, a+b)(x, y))", "=REDUCE(0, A1:A3, LAMBDA(acc, v, acc+v))",
                        "=BYROW(A1:B2, LAMBDA(row, SUM(row)))&BYCOL(A1:B2, LAMBDA(col, SUM(col)))", "=SCAN(1, A1:A3, LAMBDA(a, b, a*b))"] {
            #expect(XLSXFormula.importing(XLSXFormula.exporting(formula) ?? "") == formula)
        }
    }

    // MARK: - Table references

    @Test func tableReferencesTakeExcelsForms() {
        let tables: Set<String> = ["orders", "table1"]
        #expect(XLSXFormula.exporting("=SUM(Orders[#ALL])+SUM(Orders[#DATA])+COUNTA(Orders[#HEADERS])", tableNames: tables)
            == "SUM(Orders[#All])+SUM(Orders[#Data])+COUNTA(Orders[#Headers])")
        #expect(XLSXFormula.exporting("=Orders[[#HEADERS],[Sales]]&SUM(Orders[[Sales]:[Tax]])&SUM(Orders[Sales])", tableNames: tables)
            == "Orders[[#Headers],[Sales]]&SUM(Orders[[Sales]:[Tax]])&SUM(Orders[Sales])")
        #expect(XLSXFormula.exporting("=orders[#all]", tableNames: tables) == "orders[#All]")
        // A bare name is the whole table here and only the data rows in Excel.
        #expect(XLSXFormula.exporting("=ROWS(Orders)+ROWS(table1)+COUNTA(Other)", tableNames: tables) == "ROWS(Orders[#All])+ROWS(table1[#All])+COUNTA(Other)")
        #expect(XLSXFormula.exporting("=ROWS(Orders)") == "ROWS(Orders)")
        // Not table names: sheet names, functions, text, other sheets' names, LET names.
        #expect(XLSXFormula.exporting("=Orders!A1+'Orders'!B2+Data!Orders+\"Orders\"", tableNames: tables) == "Orders!A1+'Orders'!B2+Data!Orders+\"Orders\"")
        #expect(XLSXFormula.exporting("=LET(Orders, 2, Orders*3)", tableNames: tables) == "_xlfn.LET(_xlpm.Orders, 2, _xlpm.Orders*3)")
        // "@" is written out as Excel's files have it; keywords inside column names stay.
        #expect(XLSXFormula.exporting("=Orders[@Sales]*Orders[@[Unit Price]]+COUNTA(Orders[@])", tableNames: tables)
            == "Orders[[#This Row],[Sales]]*Orders[[#This Row],[Unit Price]]+COUNTA(Orders[#This Row])")
        #expect(XLSXFormula.exporting("=SUM(Orders[#Datapoints])+SUM(Orders[[#totals],[Sales]])") == "SUM(Orders[#Datapoints])+SUM(Orders[[#Totals],[Sales]])")
    }

    @Test func excelTableReferencesAreRead() {
        #expect(XLSXFormula.importing("SUM(Orders[#All])+SUM(Orders[#Data])+COUNTA(Orders[#Headers])")
            == "=SUM(Orders[#ALL])+SUM(Orders[#DATA])+COUNTA(Orders[#HEADERS])")
        #expect(XLSXFormula.importing("Orders[[#Headers],[Sales]]&SUM(Orders[[Sales]:[Tax]])") == "=Orders[[#HEADERS],[Sales]]&SUM(Orders[[Sales]:[Tax]])")
        #expect(XLSXFormula.importing("SUM(Orders[[#Headers],[#Data],[Sales]])") == "=SUM(Orders[[#HEADERS],[#DATA],[Sales]])")
        // Excel's empty brackets are the data rows.
        #expect(XLSXFormula.importing("SUM(Orders[])") == "=SUM(Orders[#DATA])")
        // What PuggleSheets can't calculate yet stays as Excel wrote it.
        #expect(XLSXFormula.importing("Orders[[#This Row],[Sales]]*2+SUM(Orders[[#Totals],[Tax]])")
            == "=Orders[[#This Row],[Sales]]*2+SUM(Orders[[#Totals],[Tax]])")
        #expect(XLSXFormula.importing("Orders[@Sales]") == "=Orders[@Sales]")
        // Bare names mean the data rows in Excel.
        let tables: Set<String> = ["orders"]
        #expect(XLSXFormula.qualifyingTableNames("=SUM(Orders)+ROWS(orders)", tableNames: tables) == "=SUM(Orders[#DATA])+ROWS(orders[#DATA])")
        #expect(XLSXFormula.qualifyingTableNames("=Orders[Sales]+Orders!A1+Data!Orders+\"Orders\"+ORDERS(1)", tableNames: tables)
            == "=Orders[Sales]+Orders!A1+Data!Orders+\"Orders\"+ORDERS(1)")
        #expect(XLSXFormula.qualifyingTableNames("=LET(Orders,1,Orders+1)", tableNames: tables) == "=LET(Orders,1,Orders+1)")
        #expect(XLSXFormula.qualifyingTableNames("=SUM(Sales)", tableNames: tables) == "=SUM(Sales)")
    }

    @Test func tableReferencesRoundTrip() {
        let tables: Set<String> = ["orders"]
        for formula in ["=SUM(Orders[#ALL])+COUNTA(Orders[#HEADERS])+SUM(Orders[#DATA])", "=Orders[[#HEADERS],[Sales]]",
                        "=SUM(Orders[[Sales]:[Tax]])*Orders[Sales]", "=Orders[[#This Row],[Sales]]+SUM(Orders[[#Totals],[Sales]])"] {
            #expect(XLSXFormula.importing(XLSXFormula.exporting(formula, tableNames: tables) ?? "") == formula)
        }
        // A bare name comes back spelled out, meaning the same.
        let written = XLSXFormula.exporting("=ROWS(Orders)", tableNames: tables) ?? ""
        #expect(XLSXFormula.qualifyingTableNames(XLSXFormula.importing(written), tableNames: tables) == "=ROWS(Orders[#ALL])")
    }
}
