import Foundation
import Testing
@testable import PuggleSheetsKit

/// OpenFormula and OpenDocument data styles.
struct IOODSFormatTests {
    static func size(_ name: String?) -> (rows: Int, columns: Int) {
        name?.lowercased() == "big" ? (5000, 40) : (1000, 26)
    }

    // MARK: - Formulas

    @Test func readsOpenFormula() {
        #expect(ODSFormula.importing("of:=SUM([.A1:.B2])") == "=SUM(A1:B2)")
        #expect(ODSFormula.importing("of:=[Sheet2.A1]+['My sheet'.$B$2]") == "=Sheet2!A1+'My sheet'!$B$2")
        #expect(ODSFormula.importing("of:=[$Sheet2.$A$1:.$B$3]") == "=Sheet2!$A$1:$B$3")
        #expect(ODSFormula.importing("of:=['My sheet'.A1:'My sheet'.B2]") == "='My sheet'!A1:B2")
        #expect(ODSFormula.importing("of:=['It''s'.A1]") == "='It''s'!A1")
        #expect(ODSFormula.importing("of:=SUM([.A:.A])+SUM([.$1:.$3])") == "=SUM(A:A)+SUM($1:$3)")
        #expect(ODSFormula.importing("of:=IF([.A1]>0;\"a;b\";TRUE())") == "=IF(A1>0,\"a;b\",TRUE)")
        #expect(ODSFormula.importing("of:={1;2|3;4}") == "={1,2;3,4}")
        #expect(ODSFormula.importing("of:=COM.MICROSOFT.CONCAT([.A1];[.B1])") == "=CONCAT(A1,B1)")
        #expect(ODSFormula.importing("of:=[.#REF!]+1") == "=#REF!+1")
        #expect(ODSFormula.importing("of:=['file:///x.ods'#$Sheet1.A1]") == "=#REF!")
        #expect(ODSFormula.importing("of:=[Sheet1.A1:Sheet2.B2]") == "=#REF!")
        // OpenOffice.org 2 and Excel's own syntax.
        #expect(ODSFormula.importing("oooc:=SUM([.A1:.A3];[.B1])") == "=SUM(A1:A3,B1)")
        #expect(ODSFormula.importing("msoxl:=_xlfn.CONCAT(A1,B1)") == "=CONCAT(A1,B1)")
        #expect(ODSFormula.importing("=[.A1]*2") == "=A1*2")
        #expect(ODSFormula.importing("of:=") == nil)
        #expect(ODSFormula.importing("") == nil)
    }

    @Test func writesOpenFormula() {
        #expect(ODSFormula.exporting("=SUM(A1:B2)", size: Self.size) == "of:=SUM([.A1:.B2])")
        #expect(ODSFormula.exporting("=Sheet2!A1+'My sheet'!$B$2:$C$3", size: Self.size) == "of:=[Sheet2.A1]+['My sheet'.$B$2:.$C$3]")
        #expect(ODSFormula.exporting("=IF(A1>0,TRUE,FALSE)", size: Self.size) == "of:=IF([.A1]>0;TRUE();FALSE())")
        #expect(ODSFormula.exporting("={1,2;3,4}", size: Self.size) == "of:={1;2|3;4}")
        #expect(ODSFormula.exporting("=CONCAT(A1,\"x,y\")", size: Self.size) == "of:=COM.MICROSOFT.CONCAT([.A1];\"x,y\")")
        #expect(ODSFormula.exporting("=CEILING(A1,2)-FLOOR(A1,2)", size: Self.size) == "of:=COM.MICROSOFT.CEILING([.A1];2)-COM.MICROSOFT.FLOOR([.A1];2)")
        #expect(ODSFormula.exporting("=SUM(A:A)+SUM(1:2)", size: Self.size) == "of:=SUM([.A:.A])+SUM([.1:.2])")
        #expect(ODSFormula.exporting("=#REF!+A1", size: Self.size) == "of:=#REF!+[.A1]")
        #expect(ODSFormula.exporting("=LOG10(A1)+Rate", size: Self.size) == "of:=LOG10([.A1])+Rate")
        // Open-ended ranges end at their sheet's edge.
        #expect(ODSFormula.exporting("=SUM(A2:A)+SUM(Big!B3:3)", size: Self.size) == "of:=SUM([.A2:.A1000])+SUM([Big.B3:.AN3])")
        #expect(ODSFormula.exporting("=", size: Self.size) == nil)
    }

    @Test func formulasRoundTrip() {
        for formula in ["=SUM(A1:B2)*'My sheet'!C3", "=IF(AND(A1>0,B1<>\"x\"),TEXTJOIN(\",\",TRUE,A1:A9),\"no\")", "={1,2;3,4}",
                        "=SUM(A:A,1:3)", "=XLOOKUP(A1,B:B,C:C)", "=CEILING(A1,0.5)+FLOOR.MATH(A2)", "=Sheet2!$A$1&\"; text with ; and |\"", "=-A1%^2"] {
            #expect(ODSFormula.importing(ODSFormula.exporting(formula, size: Self.size) ?? "") == formula, "\(formula)")
        }
    }

    @Test func addresses() {
        #expect(ODSFormula.parseAddress("$Sheet1.$A$1:.$D$20")?.text == "Sheet1!$A$1:$D$20")
        #expect(ODSFormula.parseAddress("'Q1 2026'.B2")?.text == "'Q1 2026'!B2")
        #expect(ODSFormula.parseAddress(".A1")?.range == CellRange(a1: "A1"))
        #expect(ODSFormula.parseAddress("Sheet1.A1:Sheet2.B2") == nil)
        let list = ODSFormula.parseAddressList("Sales.A1:Sales.A10 'My sheet'.C3")
        #expect(list.map(\.sheet) == ["Sales", "My sheet"])
        #expect(list.map(\.range) == [CellRange(a1: "A1:A10")!, CellRange(a1: "C3")!])
        #expect(ODSFormula.address(sheet: "Sales", range: CellRange(a1: "B2:C9")!) == "Sales.B2:Sales.C9")
        #expect(ODSFormula.address(sheet: "My sheet", range: CellRange(a1: "A1")!, absolute: true) == "$'My sheet'.$A$1")
        #expect(ODSFormula.address(fromReference: "'Q1 2026'!$A$1:$A$50", defaultSheet: "Sheet1") == "$'Q1 2026'.$A$1:.$A$50")
        #expect(ODSFormula.address(fromReference: "B2", defaultSheet: "Sheet1") == "$Sheet1.B2")
        #expect(ODSFormula.address(fromReference: "A1+1", defaultSheet: "Sheet1") == nil)
    }

    // MARK: - Data styles

    /// A pattern written as a data style and read back.
    static func roundTrip(_ pattern: String) -> String? {
        var xml = XMLWriter(fragmentCapacity: 256)
        guard ODSNumberStyles.write(pattern: pattern, name: "N1", into: &xml) else { return "unwritable" }
        let document = "<office:automatic-styles \(ODSWriter.namespaces)>" + String(decoding: xml.bytes, as: UTF8.self) + "</office:automatic-styles>"
        guard let root = try? XMLTree.parse(Data(document.utf8)) else { return "malformed" }
        var styles: [String: XNode] = [:]
        for child in root.children { if let name = child["name"] { styles[name] = child } }
        guard let main = styles["N1"] else { return "missing" }
        return ODSNumberStyles.pattern(of: main, styles: styles)
    }

    @Test func dataStylesRoundTrip() {
        let patterns = ["0", "0.0", "#,##0", "#,##0.00", "0%", "0.00%", "0.00E+00", "0.000E+00", "\"$\"#,##0.00", "\"$\"#,##0",
                        "M/d/yyyy", "MM/dd/yyyy", "h:mm:ss AM/PM", "M/d/yyyy H:mm:ss", "H:mm", "mm:ss", "[h]:mm:ss", "@",
                        "#,##0.00;(#,##0.00)", "#,##0.00;[Red]-#,##0.00", "0;-0;\"zero\"", "dddd, MMMM d, yyyy", "MMM d", "# ?/?",
                        "?/?", "#,##0.0,", "H:mm:ss.00", "0.00 \"km\"", "#,##0.00 \"€\""]
        for pattern in patterns {
            #expect(Self.roundTrip(pattern) == pattern, "\(pattern)")
        }
        // Equivalent spellings come back in the module's own: 24-hour hours as "H", literals quoted.
        #expect(Self.roundTrip("h:mm") == "H:mm")
        #expect(Self.roundTrip("0.00\" km\"") == "0.00 \"km\"")
        #expect(Self.roundTrip(NumberFormatPresets.number.pattern!) == "#,##0.00")
        // Accounting's fill and padding have no OpenDocument form; the currency survives.
        let accounting = Self.roundTrip(NumberFormatPresets.accounting.pattern!)
        #expect(accounting?.contains("\"$\"") == true && accounting?.contains("#,##0.00") == true)
        #expect(Self.roundTrip("not;a;valid;pattern;at all") == "unwritable")
    }

    @Test func readsLibreOfficeDataStyles() throws {
        let document = """
            <office:automatic-styles \(ODSWriter.namespaces)>
            <number:number-style style:name="N0"><number:number number:min-integer-digits="1"/></number:number-style>
            <number:number-style style:name="N1"><number:number number:min-integer-digits="1"/><number:text> units</number:text></number:number-style>
            <number:date-style style:name="N2"><number:quarter/><number:text> </number:text><number:year/></number:date-style>
            <number:boolean-style style:name="N3"><number:boolean/></number:boolean-style>
            <number:number-style style:name="N4"><number:number number:decimal-places="2" number:min-integer-digits="0"/></number:number-style>
            <number:number-style style:name="N5P0" style:volatile="true"><number:number number:decimal-places="1" number:min-decimal-places="1" number:min-integer-digits="1"/></number:number-style>
            <number:number-style style:name="N5P1" style:volatile="true"><style:text-properties fo:color="#0000ff"/><number:text>(</number:text><number:number number:decimal-places="1" number:min-decimal-places="1" number:min-integer-digits="1"/><number:text>)</number:text></number:number-style>
            <number:number-style style:name="N5"><number:text>nil</number:text><style:map style:condition="value()&gt;0" style:apply-style-name="N5P0"/><style:map style:condition="value()&lt;0" style:apply-style-name="N5P1"/></number:number-style>
            <number:number-style style:name="N6"><number:number number:decimal-places="0" number:min-integer-digits="7"><number:embedded-text number:position="4">-</number:embedded-text></number:number></number:number-style>
            <number:time-style style:name="N7"><number:hours number:style="long"/><number:text>:</number:text><number:minutes number:style="long"/><number:text>:</number:text><number:seconds number:style="long" number:decimal-places="2"/></number:time-style>
            <number:number-style style:name="N8"><number:number number:decimal-places="3" number:min-decimal-places="1" number:min-integer-digits="1" number:grouping="true"/></number:number-style>
            </office:automatic-styles>
            """
        let root = try XMLTree.parse(Data(document.utf8))
        var styles: [String: XNode] = [:]
        for child in root.children { if let name = child["name"] { styles[name] = child } }
        func pattern(_ name: String) -> String? { ODSNumberStyles.pattern(of: styles[name]!, styles: styles) }
        #expect(pattern("N0") == nil)
        #expect(pattern("N1") == "General \"units\"")
        #expect(pattern("N2") == nil)
        #expect(pattern("N3") == nil)
        #expect(pattern("N4") == "#.00")
        #expect(pattern("N5") == "0.0;[Blue](0.0);\"nil\"")
        #expect(pattern("N6") == nil)
        #expect(pattern("N7") == "HH:mm:ss.00")
        #expect(pattern("N8") == "#,##0.0##")
    }
}
