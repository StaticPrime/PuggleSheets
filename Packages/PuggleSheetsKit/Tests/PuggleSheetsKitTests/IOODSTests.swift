import Foundation
import Testing
@testable import PuggleSheetsKit

/// Builds OpenDocument packages by hand, laid out like LibreOffice's.
enum IOTestODS {
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"

    static func content(_ body: String, automaticStyles: String = "", fontFaces: String = "") -> String {
        declaration + "<office:document-content \(ODSWriter.namespaces) office:version=\"1.3\"><office:scripts/>"
            + "<office:font-face-decls>\(fontFaces)</office:font-face-decls><office:automatic-styles>\(automaticStyles)</office:automatic-styles>"
            + "<office:body><office:spreadsheet>\(body)</office:spreadsheet></office:body></office:document-content>"
    }

    static func styles(_ styles: String, fontFaces: String = "") -> String {
        declaration + "<office:document-styles \(ODSWriter.namespaces) office:version=\"1.3\"><office:font-face-decls>\(fontFaces)</office:font-face-decls>"
            + "<office:styles>\(styles)</office:styles><office:automatic-styles><style:page-layout style:name=\"Mpm1\"/></office:automatic-styles>"
            + "<office:master-styles><style:master-page style:name=\"Default\" style:page-layout-name=\"Mpm1\"/></office:master-styles></office:document-styles>"
    }

    static func settings(tables: String, active: String) -> String {
        declaration + "<office:document-settings xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" "
            + "xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\" office:version=\"1.3\"><office:settings>"
            + "<config:config-item-set config:name=\"ooo:view-settings\"><config:config-item-map-indexed config:name=\"Views\"><config:config-item-map-entry>"
            + "<config:config-item config:name=\"ViewId\" config:type=\"string\">view1</config:config-item>"
            + "<config:config-item-map-named config:name=\"Tables\">\(tables)</config:config-item-map-named>"
            + "<config:config-item config:name=\"ActiveTable\" config:type=\"string\">\(active)</config:config-item>"
            + "</config:config-item-map-entry></config:config-item-map-indexed></config:config-item-set></office:settings></office:document-settings>"
    }

    static func package(content: String, styles: String? = nil, settings: String? = nil, mimetype: String = ODSWriter.mimetype,
                        manifest: String? = nil, extra: [String: Data] = [:]) throws -> Data {
        var writer = ZipWriter()
        try writer.add("mimetype", Data(mimetype.utf8), compress: false)
        try writer.add("META-INF/manifest.xml", Data((manifest ?? declaration
            + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\">"
            + "<manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"\(mimetype)\"/>"
            + "<manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>").utf8))
        try writer.add("content.xml", Data(content.utf8))
        if let styles { try writer.add("styles.xml", Data(styles.utf8)) }
        if let settings { try writer.add("settings.xml", Data(settings.utf8)) }
        for (path, data) in extra.sorted(by: { $0.key < $1.key }) { try writer.add(path, data) }
        return try writer.finish()
    }

    static func read(_ data: Data) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(data, format: .ods)
    }
}

struct IOODSTests {
    // MARK: - A LibreOffice file

    static let libreOfficeStyles = IOTestODS.styles("""
        <style:default-style style:family="table-cell"><style:paragraph-properties style:tab-stop-distance="0.5in"/>
        <style:text-properties style:font-name="Liberation Sans" fo:font-size="10pt" fo:language="en" fo:country="US"/></style:default-style>
        <number:number-style style:name="N0"><number:number number:min-integer-digits="1"/></number:number-style>
        <style:style style:name="Default" style:family="table-cell"/>
        <style:style style:name="Heading" style:family="table-cell" style:parent-style-name="Default">
        <style:text-properties style:font-name="Georgia" fo:font-size="14pt" fo:font-weight="bold"/></style:style>
        <style:style style:name="Good" style:family="table-cell" style:parent-style-name="Default">
        <style:table-cell-properties fo:background-color="#ccffcc"/><style:text-properties fo:color="#006600"/></style:style>
        <style:style style:name="Bad" style:family="table-cell" style:parent-style-name="Default">
        <style:table-cell-properties fo:background-color="#ffcccc"/><style:text-properties fo:color="#cc0000" fo:font-weight="bold"/></style:style>
        """, fontFaces: """
        <style:font-face style:name="Liberation Sans" svg:font-family="'Liberation Sans'" style:font-family-generic="swiss" style:font-pitch="variable"/>
        <style:font-face style:name="Georgia" svg:font-family="Georgia"/>
        """)

    static let automaticStyles = """
        <style:style style:name="co1" style:family="table-column"><style:table-column-properties fo:break-before="auto" style:column-width="0.889in"/></style:style>
        <style:style style:name="co2" style:family="table-column"><style:table-column-properties fo:break-before="auto" style:column-width="1.5in"/></style:style>
        <style:style style:name="ro1" style:family="table-row"><style:table-row-properties style:row-height="0.178in" fo:break-before="auto" style:use-optimal-row-height="true"/></style:style>
        <style:style style:name="ro2" style:family="table-row"><style:table-row-properties style:row-height="0.5in" fo:break-before="auto" style:use-optimal-row-height="false"/></style:style>
        <style:style style:name="ta1" style:family="table" style:master-page-name="Default"><style:table-properties table:display="true" style:writing-mode="lr-tb" tableooo:tab-color="#ff9900"/></style:style>
        <style:style style:name="ta2" style:family="table" style:master-page-name="Default"><style:table-properties table:display="false" style:writing-mode="lr-tb"/></style:style>
        <number:number-style style:name="N2"><number:number number:decimal-places="2" number:min-decimal-places="2" number:min-integer-digits="1" number:grouping="true"/></number:number-style>
        <number:percentage-style style:name="N3"><number:number number:decimal-places="1" number:min-decimal-places="1" number:min-integer-digits="1"/><number:text>%</number:text></number:percentage-style>
        <number:currency-style style:name="N4P0" style:volatile="true"><number:currency-symbol number:language="en" number:country="US">$</number:currency-symbol><number:number number:decimal-places="2" number:min-decimal-places="2" number:min-integer-digits="1" number:grouping="true"/></number:currency-style>
        <number:currency-style style:name="N4"><style:text-properties fo:color="#ff0000"/><number:text>-</number:text><number:currency-symbol number:language="en" number:country="US">$</number:currency-symbol><number:number number:decimal-places="2" number:min-decimal-places="2" number:min-integer-digits="1" number:grouping="true"/><style:map style:condition="value()&gt;=0" style:apply-style-name="N4P0"/></number:currency-style>
        <number:date-style style:name="N5"><number:month number:style="long"/><number:text>/</number:text><number:day number:style="long"/><number:text>/</number:text><number:year number:style="long"/></number:date-style>
        <number:time-style style:name="N6"><number:hours number:style="long"/><number:text>:</number:text><number:minutes number:style="long"/><number:text>:</number:text><number:seconds number:style="long"/><number:text> </number:text><number:am-pm/></number:time-style>
        <number:time-style style:name="N7" number:truncate-on-overflow="false"><number:hours/><number:text>:</number:text><number:minutes number:style="long"/></number:time-style>
        <number:text-style style:name="N8"><number:text-content/></number:text-style>
        <number:number-style style:name="N9"><number:scientific-number number:decimal-places="3" number:min-integer-digits="1" number:min-exponent-digits="2"/></number:number-style>
        <number:number-style style:name="N10"><number:fraction number:min-integer-digits="0" number:min-numerator-digits="1" number:min-denominator-digits="1"/></number:number-style>
        <number:date-style style:name="N11"><number:day-of-week number:style="long"/><number:text>, </number:text><number:month number:style="long" number:textual="true"/><number:text> </number:text><number:day/><number:text>, </number:text><number:year number:style="long"/></number:date-style>
        <number:date-style style:name="N12"><number:quarter/><number:text> </number:text><number:year/></number:date-style>
        <style:style style:name="ce1" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N2"/>
        <style:style style:name="ce2" style:family="table-cell" style:parent-style-name="Heading"><style:table-cell-properties fo:background-color="#dddddd" fo:border="0.06pt solid #000000" style:text-align-source="fix" style:repeat-content="false"/><style:paragraph-properties fo:text-align="center" fo:margin-left="0in"/><style:text-properties fo:font-style="italic"/></style:style>
        <style:style style:name="ce3" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N4"/>
        <style:style style:name="ce4" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N3"/>
        <style:style style:name="ce5" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N5"/>
        <style:style style:name="ce6" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N6"/>
        <style:style style:name="ce7" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N7"/>
        <style:style style:name="ce8" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N8"/>
        <style:style style:name="ce9" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N9"/>
        <style:style style:name="ce10" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N10"/>
        <style:style style:name="ce11" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N11"/>
        <style:style style:name="ce12" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N12"/>
        <style:style style:name="ce13" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties style:text-align-source="value-type" style:vertical-align="top" fo:wrap-option="wrap"/><style:paragraph-properties fo:text-align="end"/><style:text-properties style:font-name="Liberation Serif" fo:font-size="12pt" fo:color="#0000ff" style:text-underline-style="solid" style:text-underline-width="auto" style:text-underline-color="font-color" style:text-line-through-style="solid"/></style:style>
        <style:style style:name="ce14" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:border-top="1.5pt double #ff0000" fo:border-bottom="2.5pt solid #00ff00" fo:border-left="0.75pt dashed #0000ff" fo:border-right="0.75pt dotted #000000"/></style:style>
        <style:style style:name="T1" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
        """

    static let fontFaces = """
        <style:font-face style:name="Liberation Sans" svg:font-family="'Liberation Sans'" style:font-family-generic="swiss"/>
        <style:font-face style:name="Liberation Serif" svg:font-family="'Liberation Serif'" style:font-family-generic="roman"/>
        <style:font-face style:name="Georgia" svg:font-family="Georgia"/>
        """

    static func float(_ value: String, style: String? = nil, extra: String = "") -> String {
        let styleAttribute = style.map { " table:style-name=\"\($0)\"" } ?? ""
        return "<table:table-cell\(styleAttribute) office:value-type=\"float\" office:value=\"\(value)\" calcext:value-type=\"float\"\(extra)><text:p>\(value)</text:p></table:table-cell>"
    }

    static func text(_ value: String, style: String? = nil, extra: String = "") -> String {
        let styleAttribute = style.map { " table:style-name=\"\($0)\"" } ?? ""
        return "<table:table-cell\(styleAttribute) office:value-type=\"string\" calcext:value-type=\"string\"\(extra)><text:p>\(value)</text:p></table:table-cell>"
    }

    static let body = """
        <table:calculation-settings table:automatic-find-labels="false" table:use-regular-expressions="false" table:use-wildcards="true"/>
        <table:content-validations>
        <table:content-validation table:name="val1" table:condition="of:cell-content-is-in-list(&quot;Low&quot;;&quot;Medium&quot;;&quot;High&quot;)" table:allow-empty-cell="true" table:base-cell-address="Sales.D2" table:display-list="unsorted">
        <table:help-message table:title="" table:display="true"><text:p>Pick a priority</text:p></table:help-message>
        <table:error-message table:message-type="stop" table:title="" table:display="true"/></table:content-validation>
        <table:content-validation table:name="val2" table:condition="of:cell-content-is-decimal-number() and cell-content-is-between(0,100)" table:allow-empty-cell="true" table:base-cell-address="Sales.B2">
        <table:error-message table:message-type="warning" table:display="true"/></table:content-validation>
        </table:content-validations>
        <table:table table:name="Sales" table:style-name="ta1">
        <table:shapes><draw:frame draw:z-index="0" svg:width="2in" svg:height="1in"><draw:image xlink:href="Pictures/logo.png"/></draw:frame>
        <draw:frame draw:z-index="1" svg:width="4in" svg:height="3in"><draw:object xlink:href="./Object 1"/></draw:frame></table:shapes>
        <table:table-column table:style-name="co2" table:default-cell-style-name="Default"/>
        <table:table-column table:style-name="co1" table:number-columns-repeated="3" table:default-cell-style-name="Default"/>
        <table:table-column table:style-name="co1" table:visibility="collapse" table:default-cell-style-name="ce1"/>
        <table:table-column table:style-name="co1" table:number-columns-repeated="1019" table:default-cell-style-name="Default"/>
        <table:table-row table:style-name="ro2">\(text("Product", style: "ce2"))\(text("Units", style: "ce2"))\(text("Price", style: "ce2"))\(text("Priority", style: "ce2"))\(text("secret"))<table:table-cell table:number-columns-repeated="1019"/></table:table-row>
        <table:table-row table:style-name="ro1">\(text("Widget"))\(float("12", style: "ce1", extra: " table:content-validation-name=\"val2\""))<table:table-cell table:style-name="ce3" office:value-type="currency" office:currency="USD" office:value="4.5" calcext:value-type="currency"><text:p>$4.50</text:p></table:table-cell>\(text("High", extra: " table:content-validation-name=\"val1\""))\(float("3"))<table:table-cell table:number-columns-repeated="1019"/></table:table-row>
        <table:table-row table:style-name="ro1"><table:table-cell office:value-type="string" calcext:value-type="string"><office:annotation><dc:creator>Ann</dc:creator><text:p>Check this</text:p></office:annotation><text:p>Gadget</text:p></table:table-cell>\(float("7", style: "ce1", extra: " table:content-validation-name=\"val2\""))<table:table-cell table:style-name="ce3" office:value-type="currency" office:currency="USD" office:value="-2.25" calcext:value-type="currency"><text:p>-$2.25</text:p></table:table-cell>\(text("Low", extra: " table:content-validation-name=\"val1\""))<table:table-cell table:number-columns-repeated="1020"/></table:table-row>
        <table:table-row table:style-name="ro1"><table:table-cell office:value-type="string" calcext:value-type="string"><text:p>Doo<text:span text:style-name="T1">hickey</text:span><text:s text:c="2"/>x<text:tab/>y</text:p><text:p>line   two
          wrapped</text:p></table:table-cell><table:table-cell table:style-name="ce1" table:formula="of:=SUM([.B2:.B3])" office:value-type="float" office:value="19" calcext:value-type="float"><text:p>19.00</text:p></table:table-cell><table:table-cell table:style-name="ce3" table:formula="of:=[.C2]*['Hidden Notes'.B1]" office:value-type="float" office:value="9" calcext:value-type="float"><text:p>$9.00</text:p></table:table-cell>\(text("Medium", extra: " table:content-validation-name=\"val1\""))<table:table-cell table:number-columns-repeated="1020"/></table:table-row>
        <table:table-row table:style-name="ro1"><table:table-cell table:number-columns-spanned="2" table:number-rows-spanned="1" office:value-type="string" calcext:value-type="string"><text:p>Merged</text:p></table:table-cell><table:covered-table-cell/><table:table-cell table:style-name="ce4" office:value-type="percentage" office:value="0.125" calcext:value-type="percentage"><text:p>12.5%</text:p></table:table-cell><table:table-cell table:style-name="ce5" office:value-type="date" office:date-value="2026-11-16" calcext:value-type="date"><text:p>11/16/2026</text:p></table:table-cell><table:table-cell table:number-columns-repeated="1020"/></table:table-row>
        <table:table-row table:style-name="ro1"><table:table-cell table:style-name="ce6" office:value-type="time" office:time-value="PT13H45M00S" calcext:value-type="time"><text:p>01:45:00 PM</text:p></table:table-cell><table:table-cell office:value-type="boolean" office:boolean-value="true" calcext:value-type="boolean"><text:p>TRUE</text:p></table:table-cell><table:table-cell table:formula="of:=1/0" office:value-type="string" office:string-value="" calcext:value-type="error"><text:p>#DIV/0!</text:p></table:table-cell>\(text("High", extra: " table:content-validation-name=\"val1\""))<table:table-cell table:number-columns-repeated="1020"/></table:table-row>
        <table:table-row table:style-name="ro1" table:number-rows-repeated="3"><table:table-cell office:value-type="float" office:value="0" calcext:value-type="float" table:number-columns-repeated="2"><text:p>0</text:p></table:table-cell><table:table-cell table:number-columns-repeated="1022"/></table:table-row>
        <table:table-row table:style-name="ro1"><table:table-cell table:style-name="ce7" office:value-type="time" office:time-value="PT36H00M00S" calcext:value-type="time"><text:p>36:00</text:p></table:table-cell>\(float("1.25", style: "ce10"))\(float("12345.678", style: "ce9"))<table:table-cell table:style-name="ce11" office:value-type="date" office:date-value="2026-01-02" calcext:value-type="date"><text:p>Friday, January 2, 2026</text:p></table:table-cell><table:table-cell/>\(float("1", style: "ce12"))\(text("@text", style: "ce8"))<table:table-cell table:formula="oooc:=SUM([.A7:.A9])" office:value-type="float" office:value="0" calcext:value-type="float"><text:p>0</text:p></table:table-cell><table:table-cell table:number-columns-repeated="1016"/></table:table-row>
        <table:table-row table:style-name="ro1"><table:table-cell table:formula="of:=TRANSPOSE([.A7:.A9])" table:number-matrix-columns-spanned="3" table:number-matrix-rows-spanned="1" office:value-type="float" office:value="0" calcext:value-type="float"><text:p>0</text:p></table:table-cell>\(float("0"))\(float("0"))<table:table-cell table:formula="of:=COM.MICROSOFT.TEXTJOIN(&quot;;&quot;;TRUE();[.A2:.A3])" office:value-type="string" office:string-value="Widget;Gadget" calcext:value-type="string"><text:p>Widget;Gadget</text:p></table:table-cell>\(text("styled", style: "ce13"))\(text("borders", style: "ce14"))<table:table-cell table:number-columns-repeated="1018"/></table:table-row>
        <table:table-row table:style-name="ro1" table:visibility="collapse">\(text("hidden row"))<table:table-cell table:number-columns-repeated="1023"/></table:table-row>
        <table:table-row table:style-name="ro1" table:visibility="filter">\(text("filtered"))<table:table-cell table:number-columns-repeated="1023"/></table:table-row>
        <table:table-row table:style-name="ro1" table:number-rows-repeated="1048563"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>
        <calcext:conditional-formats>
        <calcext:conditional-format calcext:target-range-address="Sales.B2:Sales.B6"><calcext:condition calcext:apply-style-name="Good" calcext:value="&gt;10" calcext:base-cell-address="Sales.B2"/><calcext:condition calcext:apply-style-name="Bad" calcext:value="between(0,5)" calcext:base-cell-address="Sales.B2"/></calcext:conditional-format>
        <calcext:conditional-format calcext:target-range-address="Sales.C2:Sales.C6"><calcext:color-scale><calcext:color-scale-entry calcext:value="0" calcext:type="minimum" calcext:color="#f8696b"/><calcext:color-scale-entry calcext:value="50" calcext:type="percentile" calcext:color="#ffeb84"/><calcext:color-scale-entry calcext:value="0" calcext:type="maximum" calcext:color="#63be7b"/></calcext:color-scale></calcext:conditional-format>
        <calcext:conditional-format calcext:target-range-address="Sales.A2:Sales.A6"><calcext:data-bar calcext:max-length="100"><calcext:formatting-entry calcext:value="0" calcext:type="auto-minimum"/><calcext:formatting-entry calcext:value="0" calcext:type="auto-maximum"/></calcext:data-bar></calcext:conditional-format>
        <calcext:conditional-format calcext:target-range-address="Sales.D2:Sales.D6"><calcext:date-is calcext:date="today" calcext:style="Bad"/><calcext:date-is calcext:date="last-7-days" calcext:style="Good"/><calcext:date-is calcext:date="this-month" calcext:style="Good"/></calcext:conditional-format>
        <calcext:conditional-format calcext:target-range-address="Sales.A2:Sales.D6"><calcext:condition calcext:apply-style-name="Good" calcext:value="formula-is(ISEVEN(ROW([.A2])))" calcext:base-cell-address="Sales.A2"/></calcext:conditional-format>
        <calcext:conditional-format calcext:target-range-address="Sales.A2:Sales.A6"><calcext:condition calcext:apply-style-name="Good" calcext:value="begins-with(&quot;G&quot;)" calcext:base-cell-address="Sales.A2"/></calcext:conditional-format>
        </calcext:conditional-formats>
        </table:table>
        <table:table table:name="Hidden Notes" table:style-name="ta2" table:protected="true">
        <table:table-column table:style-name="co1" table:number-columns-repeated="2" table:default-cell-style-name="Default"/>
        <table:table-row table:style-name="ro1">\(text("note"))\(float("2"))</table:table-row>
        </table:table>
        <table:named-expressions>
        <table:named-range table:name="Products" table:base-cell-address="$Sales.$A$1" table:cell-range-address="$Sales.$A$2:.$A$6"/>
        <table:named-expression table:name="Rate" table:base-cell-address="$Sales.$A$1" table:expression="of:=0.07"/>
        </table:named-expressions>
        <table:database-ranges>
        <table:database-range table:name="__Anonymous_Sheet_DB__0" table:target-range-address="Sales.A1:Sales.D6" table:display-filter-buttons="true">
        <table:filter><table:filter-condition table:field-number="3" table:value="High" table:operator="="><table:filter-set-item table:value="High"/><table:filter-set-item table:value="medium"/></table:filter-condition></table:filter>
        </table:database-range>
        </table:database-ranges>
        """

    static let settings = IOTestODS.settings(tables: """
        <config:config-item-map-entry config:name="Sales">
        <config:config-item config:name="HorizontalSplitMode" config:type="short">2</config:config-item>
        <config:config-item config:name="VerticalSplitMode" config:type="short">2</config:config-item>
        <config:config-item config:name="HorizontalSplitPosition" config:type="int">1</config:config-item>
        <config:config-item config:name="VerticalSplitPosition" config:type="int">1</config:config-item>
        <config:config-item config:name="ShowGrid" config:type="boolean">false</config:config-item></config:config-item-map-entry>
        <config:config-item-map-entry config:name="Hidden Notes">
        <config:config-item config:name="TabColor" config:type="int">255</config:config-item>
        <config:config-item config:name="ShowGrid" config:type="boolean">true</config:config-item></config:config-item-map-entry>
        """, active: "Hidden Notes")

    static func libreOfficeFile() throws -> SpreadsheetFile {
        try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(body, automaticStyles: automaticStyles, fontFaces: fontFaces),
                                                 styles: libreOfficeStyles, settings: settings))
    }

    @Test func libreOfficeValues() throws {
        let file = try Self.libreOfficeFile()
        #expect(file.workbook.sheets.map(\.name) == ["Sales", "Hidden Notes"])
        #expect(file.activeSheet == 1)
        let sheet = file.workbook.sheets[0]
        #expect(sheet[0, 0].value == .text("Product"))
        #expect(sheet[0, 4].value == .text("secret"))
        #expect(sheet[1, 1].value == .number(12))
        #expect(sheet[1, 2].value == .number(4.5))
        #expect(sheet[2, 0].value == .text("Gadget"))
        #expect(sheet[2, 2].value == .number(-2.25))
        #expect(sheet[3, 0].value == .text("Doohickey  x\ty\nline two wrapped"))
        #expect(sheet[4, 0].value == .text("Merged"))
        #expect(sheet[4, 2].value == .number(0.125))
        #expect(sheet[4, 3].value == .number(46_342))
        #expect(sheet[5, 0].value == .number(DateSerial.time(hour: 13, minute: 45, second: 0)))
        #expect(sheet[5, 1].value == .boolean(true))
        for row in 6...8 {
            #expect(sheet[row, 0].value == .number(0) && sheet[row, 1].value == .number(0))
        }
        #expect(sheet.cells[CellAddress(row: 6, column: 2)] == nil)
        #expect(sheet[9, 0].value == .number(1.5))
        #expect(sheet[9, 3].value == .number(46_024))
        #expect(sheet[9, 6].value == .text("@text"))
        #expect(sheet[11, 0].value == .text("hidden row"))
        #expect(file.workbook.sheets[1][0, 1].value == .number(2))
    }

    @Test func libreOfficeFormulas() throws {
        let sheet = try Self.libreOfficeFile().workbook.sheets[0]
        #expect(sheet[3, 1].formula == "=SUM(B2:B3)" && sheet[3, 1].value == .number(19))
        #expect(sheet[3, 2].formula == "=C2*'Hidden Notes'!B1" && sheet[3, 2].value == .number(9))
        #expect(sheet[5, 2].formula == "=1/0" && sheet[5, 2].value == .error(CellError(.divideByZero)))
        #expect(sheet[9, 7].formula == "=SUM(A7:A9)")
        #expect(sheet[10, 3] == Cell(value: .text("Widget;Gadget"), formula: "=TEXTJOIN(\";\",TRUE,A2:A3)"))
        // A matrix formula keeps its first result; the formula fills in the rest again.
        #expect(sheet[10, 0] == Cell(value: .number(0), formula: "=TRANSPOSE(A7:A9)"))
        #expect(sheet.cells[CellAddress(row: 10, column: 1)] == nil && sheet.cells[CellAddress(row: 10, column: 2)] == nil)
    }

    @Test func libreOfficeStylesAndNumberStyles() throws {
        let sheet = try Self.libreOfficeFile().workbook.sheets[0]
        let thin = BorderLine(style: .thin, color: .black)
        #expect(sheet[0, 0].format == IOTest.format {
            $0.fontFamily = "Georgia"
            $0.fontSize = 14
            $0.bold = true
            $0.italic = true
            $0.fillColor = RGBColor(hex: "DDDDDD")
            $0.horizontalAlignment = .center
            $0.borders = CellBorders(top: thin, left: thin, bottom: thin, right: thin)
        })
        // Liberation Sans 10, LibreOffice's default, is Arial 10.
        #expect(sheet[1, 0].format.isDefault)
        #expect(sheet[1, 1].format == IOTest.format { $0.numberFormat = "#,##0.00" })
        // A column's default style applies to its cells without one.
        #expect(sheet[0, 4].format.numberFormat == "#,##0.00")
        #expect(sheet[1, 4].format.numberFormat == "#,##0.00")
        #expect(sheet[1, 2].format.numberFormat == "\"$\"#,##0.00;[Red]-\"$\"#,##0.00")
        #expect(sheet[4, 2].format.numberFormat == "0.0%")
        #expect(sheet[4, 3].format.numberFormat == "MM/dd/yyyy")
        #expect(sheet[5, 0].format.numberFormat == "hh:mm:ss AM/PM")
        #expect(sheet[9, 0].format.numberFormat == "[h]:mm")
        #expect(sheet[9, 1].format.numberFormat == "# ?/?")
        #expect(sheet[9, 2].format.numberFormat == "0.000E+00")
        #expect(sheet[9, 3].format.numberFormat == "dddd, MMMM d, yyyy")
        #expect(sheet[9, 5].format.isDefault)
        #expect(sheet[9, 6].format.numberFormat == "@")
        #expect(sheet[10, 4].format == IOTest.format {
            $0.fontFamily = "Times New Roman"
            $0.fontSize = 12
            $0.underline = true
            $0.strikethrough = true
            $0.textColor = RGBColor(hex: "0000FF")
            $0.verticalAlignment = .top
            $0.wrap = .wrap
        })
        #expect(sheet[10, 5].format.borders == CellBorders(top: BorderLine(style: .double, color: RGBColor(hex: "FF0000")!),
                                                           left: BorderLine(style: .dashed, color: RGBColor(hex: "0000FF")!),
                                                           bottom: BorderLine(style: .thick, color: RGBColor(hex: "00FF00")!),
                                                           right: BorderLine(style: .dotted, color: .black)))
    }

    @Test func libreOfficeLayout() throws {
        let file = try Self.libreOfficeFile()
        let sheet = file.workbook.sheets[0]
        // A million repeated empty rows and a thousand columns don't make the grid bigger.
        #expect(sheet.rowCount == 1000)
        #expect(sheet.columnCount == 26)
        #expect(sheet.defaultColumnWidth == 85)
        #expect(sheet.columnWidths == [0: 144])
        #expect(sheet.hiddenColumns == [4])
        #expect(sheet.defaultRowHeight == 17)
        #expect(sheet.rowHeights == [0: 48])
        #expect(sheet.hiddenRows == [11])
        #expect(sheet.filteredRows == [12])
        #expect(sheet.merges == [CellRange(a1: "A5:B5")!])
        #expect(sheet.frozenRows == 1 && sheet.frozenColumns == 1)
        #expect(!sheet.showsGridlines)
        #expect(sheet.tabColor == RGBColor(hex: "FF9900"))
        let notes = file.workbook.sheets[1]
        #expect(notes.showsGridlines)
        #expect(notes.tabColor == RGBColor(hex: "0000FF"))
    }

    @Test func libreOfficeRules() throws {
        let file = try Self.libreOfficeFile()
        let sheet = file.workbook.sheets[0]
        #expect(sheet.validations.count == 2)
        #expect(sheet.validations[0].ranges == [CellRange(a1: "D2:D4")!, CellRange(a1: "D6")!])
        #expect(sheet.validations[0].criterion == .list(["Low", "Medium", "High"]))
        #expect(sheet.validations[0].rejectsInvalid && sheet.validations[0].showsDropdown)
        #expect(sheet.validations[0].helpText == "Pick a priority")
        #expect(sheet.validations[1].ranges == [CellRange(a1: "B2:B3")!])
        #expect(sheet.validations[1].criterion == .condition(CellCondition(.isBetween, ["0", "100"])))
        #expect(!sheet.validations[1].rejectsInvalid)

        let good = ConditionalFormat(textColor: RGBColor(hex: "006600"), fillColor: RGBColor(hex: "CCFFCC"))
        let bad = ConditionalFormat(bold: true, textColor: RGBColor(hex: "CC0000"), fillColor: RGBColor(hex: "FFCCCC"))
        #expect(sheet.conditionalFormats.map(\.style) == [
            .condition(CellCondition(.greaterThan, ["10"]), good),
            .condition(CellCondition(.isBetween, ["0", "5"]), bad),
            .colorScale(ColorScale(minimum: .init(kind: .minimum, color: RGBColor(hex: "F8696B")!),
                                   midpoint: .init(kind: .percentile, value: "50", color: RGBColor(hex: "FFEB84")!),
                                   maximum: .init(kind: .maximum, color: RGBColor(hex: "63BE7B")!))),
            .condition(CellCondition(.dateIs, ["today"]), bad),
            .condition(CellCondition(.dateIs, ["past week"]), good),
            .condition(CellCondition(.customFormula, ["=ISEVEN(ROW(A2))"]), good),
            .condition(CellCondition(.textStartsWith, ["G"]), good),
        ])
        #expect(sheet.conditionalFormats[0].ranges == [CellRange(a1: "B2:B6")!])

        #expect(sheet.filter == SheetFilter(range: CellRange(a1: "A1:D6")!, criteria: [3: FilterCriterion(hiddenValues: ["Low", "11/16/2026"])]))
        #expect(file.workbook.namedRanges == [NamedRange(name: "Products", reference: "Sales!$A$2:$A$6")])
    }

    @Test func libreOfficeWarnings() throws {
        let file = try Self.libreOfficeFile()
        #expect(file.warnings == [.richText, .images, .charts, .conditionalFormatting, .namedRanges, .hiddenSheets])
        // The annotation is a note; the protected table refuses edits everywhere.
        #expect(file.workbook.sheets[0][2, 0].note == "Check this")
        #expect(file.workbook.sheets[1].protections.map(\.scope) == [.sheet(except: [])])
        #expect(file.workbook.sheets[1].protections.allSatisfy { !$0.warningOnly })
    }

    // MARK: - Round trips

    @Test func roundTripKeepsEverything() throws {
        let workbook = IOXLSXWriteTests.everythingWorkbook()
        let data = try SpreadsheetIO.write(workbook, activeSheet: 1, format: .ods)
        let file = try SpreadsheetIO.read(data, format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.activeSheet == 1)
        #expect(file.workbook.sheets.map(\.name) == workbook.sheets.map(\.name))
        for (original, copy) in zip(workbook.sheets, file.workbook.sheets) {
            #expect(copy.cells.count == original.cells.count, "\(original.name)")
            for (address, cell) in original.cells {
                #expect(copy[address] == cell, "\(original.name)!\(address)")
            }
            #expect(copy.columnWidths == original.columnWidths, "\(original.name)")
            #expect(copy.rowHeights == original.rowHeights, "\(original.name)")
            #expect(copy.hiddenRows == original.hiddenRows, "\(original.name)")
            #expect(copy.hiddenColumns == original.hiddenColumns, "\(original.name)")
            #expect(copy.merges == original.merges, "\(original.name)")
            #expect(copy.frozenRows == original.frozenRows && copy.frozenColumns == original.frozenColumns, "\(original.name)")
            #expect(copy.tabColor == original.tabColor, "\(original.name)")
            #expect(copy.showsGridlines == original.showsGridlines, "\(original.name)")
            #expect(copy.defaultColumnWidth == original.defaultColumnWidth, "\(original.name)")
            #expect(copy.defaultRowHeight == original.defaultRowHeight, "\(original.name)")
        }
        // The grid comes back as it was written, grown to hold everything.
        #expect(file.workbook.sheets[0].rowCount == 2001 && file.workbook.sheets[0].columnCount == 28)
        #expect(file.workbook.sheets[1].rowCount == 1000 && file.workbook.sheets[1].columnCount == 26)
    }

    @Test func gridSizeRoundTrips() throws {
        var sheet = Sheet(name: "Wide", rowCount: 2500, columnCount: 40)
        sheet[0, 0] = Cell(value: .number(1))
        let read = try IOXLSXRulesTests.roundTrip(Workbook(sheets: [sheet]), format: .ods).workbook.sheets[0]
        #expect(read.rowCount == 2500 && read.columnCount == 40)
    }

    @Test func rulesRoundTrip() throws {
        var lists = Sheet(name: "Lists")
        lists[0, 0] = Cell(value: .text("x"))
        let names = [NamedRange(name: "TaxRate", reference: "Sales!$B$1"), NamedRange(name: "Fruits", reference: "'Q1 2026'!$A$1:$A$50"),
                     NamedRange(name: "Quantities", reference: "Sales!$B:$B"), NamedRange(name: "first_row", reference: "Sales!$1:$1")]
        var validation = IOXLSXRulesTests.validationSheet()
        validation.conditionalFormats = IOXLSXRulesTests.formattingSheet().conditionalFormats
        let filtered = IOXLSXRulesTests.filteredSheet()
        var quarter = IOXLSXRulesTests.filteredSheet()
        quarter.name = "Q1 2026"
        quarter.filter = nil
        let workbook = Workbook(sheets: [validation, lists, quarter, { var sheet = filtered; sheet.name = "Filtered"; return sheet }()],
                                namedRanges: names)
        let file = try IOXLSXRulesTests.roundTrip(workbook, format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.namedRanges == names)

        let rules = file.workbook.sheets[0].validations
        let original = validation.validations
        #expect(rules.count == original.count)
        // Checkboxes go out as a TRUE,FALSE list and come back as checkboxes.
        for index in [0, 1, 2, 3, 4, 5, 6, 7, 8] {
            #expect(rules[index].ranges == original[index].ranges, "\(index)")
            #expect(rules[index].criterion == original[index].criterion, "\(index)")
            #expect(rules[index].rejectsInvalid == original[index].rejectsInvalid, "\(index)")
            #expect(rules[index].helpText == original[index].helpText, "\(index)")
            #expect(rules[index].showsDropdown == original[index].showsDropdown, "\(index)")
        }
        #expect(rules[9].criterion == .condition(CellCondition(.customFormula, ["=ISNUMBER(SEARCH(\"abc\",L2))"])))
        #expect(rules[10].criterion == .condition(CellCondition(.customFormula, ["=M2=\"abc\""])))

        let formats = file.workbook.sheets[0].conditionalFormats
        let originalFormats = validation.conditionalFormats
        #expect(formats.count == originalFormats.count)
        for index in originalFormats.indices where ![7, 8, originalFormats.count - 1].contains(index) {
            #expect(formats[index].ranges == originalFormats[index].ranges, "\(index)")
            #expect(formats[index].style == originalFormats[index].style, "\(index)")
        }
        // LibreOffice has no "is empty" condition; those come back as formulas.
        #expect(formats[7].style == .condition(CellCondition(.customFormula, ["=LEN(C2)=0"]), ConditionalFormat(fillColor: IOXLSXRulesTests.red)))
        #expect(formats[8].style == .condition(CellCondition(.customFormula, ["=LEN(C2)>0"]), ConditionalFormat(fillColor: IOXLSXRulesTests.green)))
        // Nor a "past month" period that matches ours.
        #expect(formats.last?.style == .condition(CellCondition(.customFormula, ["=AND(INT(E2)>=EDATE(TODAY(),-1),INT(E2)<=TODAY())"]),
                                                  ConditionalFormat(bold: true, textColor: IOXLSXRulesTests.red)))
        let content = try #require(try Self.part("content.xml", of: try SpreadsheetIO.write(workbook, activeSheet: 0, format: .ods)))
        #expect(content.contains("<calcext:date-is calcext:date=\"last-7-days\" calcext:style=\"PuggleSheets_Conditional_1\"/>"))
        // LibreOffice expects a comma between the bounds of "between".
        #expect(content.contains("table:condition=\"of:cell-content-is-decimal-number() and cell-content-is-between(1,100)\""))
        #expect(content.contains("calcext:value=\"between(1,3)\""))

        let filter = file.workbook.sheets[3]
        #expect(filter.filter == filtered.filter)
        #expect(filter.filteredRows == [2, 4, 5])
        #expect(filter.hiddenRows == [10])
    }

    @Test func customFilterConditionsRoundTrip() throws {
        let conditions: [CellCondition] = [
            CellCondition(.isEmpty), CellCondition(.isNotEmpty), CellCondition(.textContains, ["an"]), CellCondition(.textDoesNotContain, ["x"]),
            CellCondition(.textStartsWith, ["A"]), CellCondition(.textEndsWith, ["s"]), CellCondition(.textIsExactly, ["Kiwis"]),
            CellCondition(.isEqual, ["7"]), CellCondition(.isNotEqual, ["7"]), CellCondition(.lessThanOrEqual, ["7"]),
            CellCondition(.isBetween, ["2", "9"]), CellCondition(.isNotBetween, ["2", "9"]),
        ]
        for condition in conditions {
            var sheet = IOXLSXRulesTests.salesSheet()
            sheet.filter = SheetFilter(range: CellRange(a1: "A1:C6")!, criteria: [1: FilterCriterion(condition: condition)])
            let file = try IOXLSXRulesTests.roundTrip(Workbook(sheets: [sheet]), format: .ods)
            #expect(file.warnings.isEmpty, "\(condition)")
            #expect(file.workbook.sheets[0].filter?.criteria[1]?.condition == condition, "\(condition)")
        }
        // "Not between" beside other criteria, and conditions OpenDocument filters can't hold, are left out.
        var sheet = IOXLSXRulesTests.salesSheet()
        sheet.filter = SheetFilter(range: CellRange(a1: "A1:C6")!, criteria: [
            0: FilterCriterion(condition: CellCondition(.customFormula, ["=A2<>\"\""])),
            1: FilterCriterion(condition: CellCondition(.isNotBetween, ["2", "9"])),
            2: FilterCriterion(condition: CellCondition(.greaterThan, ["1"])),
        ])
        let read = try IOXLSXRulesTests.roundTrip(Workbook(sheets: [sheet]), format: .ods).workbook.sheets[0]
        #expect(read.filter?.criteria == [2: FilterCriterion(condition: CellCondition(.greaterThan, ["1"]))])
    }

    @Test func readsFilterOperators() throws {
        // LibreOffice's operator names, the OpenDocument standard's, and LibreOffice's way of writing "empty".
        let cases: [(op: String, value: String, type: String?, expected: CellCondition)] = [
            ("begins-with", "A", nil, CellCondition(.textStartsWith, ["A"])), ("begins", "A", "text", CellCondition(.textStartsWith, ["A"])),
            ("ends-with", "s", nil, CellCondition(.textEndsWith, ["s"])), ("ends", "s", nil, CellCondition(.textEndsWith, ["s"])),
            ("contains", "pp", nil, CellCondition(.textContains, ["pp"])), ("does-not-contain", "x", nil, CellCondition(.textDoesNotContain, ["x"])),
            ("!contains", "x", nil, CellCondition(.textDoesNotContain, ["x"])), ("empty", "66", "number", CellCondition(.isEmpty)),
            ("!empty", "67", "number", CellCondition(.isNotEmpty)), ("!=", "", nil, CellCondition(.isNotEmpty)),
            ("=", "Apples", nil, CellCondition(.textIsExactly, ["Apples"])), ("&lt;=", "7", "number", CellCondition(.lessThanOrEqual, ["7"])),
        ]
        for item in cases {
            let type = item.type.map { " table:data-type=\"\($0)\"" } ?? ""
            let content = IOTestODS.content("""
                <table:table table:name="Data"><table:table-row>\(Self.text("Name"))\(Self.text("Count"))</table:table-row>
                <table:table-row>\(Self.text("Apples"))\(Self.float("7"))</table:table-row></table:table>
                <table:database-ranges><table:database-range table:name="__Anonymous_Sheet_DB__0" table:target-range-address="Data.A1:Data.B2" table:display-filter-buttons="true">
                <table:filter><table:filter-condition table:field-number="1" table:value="\(item.value)" table:operator="\(item.op)"\(type)/></table:filter>
                </table:database-range></table:database-ranges>
                """)
            let file = try IOTestODS.read(try IOTestODS.package(content: content))
            #expect(file.workbook.sheets[0].filter?.criteria[1]?.condition == item.expected, "\(item.op)")
            #expect(file.warnings.isEmpty, "\(item.op)")
        }
        // Operators PuggleSheets has no condition for keep the warning.
        let content = IOTestODS.content("""
            <table:table table:name="Data"><table:table-row>\(Self.text("Name"))</table:table-row></table:table>
            <table:database-ranges><table:database-range table:target-range-address="Data.A1:Data.A5" table:display-filter-buttons="true">
            <table:filter><table:filter-condition table:field-number="0" table:value="3" table:operator="top values" table:data-type="number"/></table:filter>
            </table:database-range></table:database-ranges>
            """)
        #expect(try IOTestODS.read(try IOTestODS.package(content: content)).warnings == [.filters])
    }

    @Test func bandingAndSpills() throws {
        var sheet = IOXLSXRulesTests.spillingSheet()
        sheet.bandings = [Banding(range: CellRange(a1: "D1:E3")!, headerColor: nil, firstColor: IOXLSXRulesTests.yellow, secondColor: .white)]
        let read = try IOXLSXRulesTests.roundTrip(Workbook(sheets: [sheet]), format: .ods).workbook.sheets[0]
        #expect(read[0, 0] == Cell(value: .number(1), formula: "=SEQUENCE(3,2)"))
        #expect(read[1, 1] == Cell(format: IOTest.format { $0.bold = true }))
        #expect(read.cells[CellAddress(row: 2, column: 1)] == nil)
        #expect(read[0, 3].format.fillColor == IOXLSXRulesTests.yellow && read[1, 4].format.fillColor == .white)
        let content = try #require(try IOODSTests.part("content.xml", of: try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .ods)))
        #expect(content.contains("table:formula=\"of:=COM.MICROSOFT.SEQUENCE(3;2)\" table:number-matrix-columns-spanned=\"2\" table:number-matrix-rows-spanned=\"3\""))
    }

    @Test func textSpacingRoundTrips() throws {
        var sheet = Sheet(name: "Text")
        let texts = ["  two leading", "trailing  ", "a  b   c", "tab\there", " ", "line 1\n  line 2", "plain"]
        for (row, text) in texts.enumerated() { sheet[row, 0] = Cell(value: .text(text)) }
        let read = try IOXLSXRulesTests.roundTrip(Workbook(sheets: [sheet]), format: .ods).workbook.sheets[0]
        for (row, text) in texts.enumerated() { #expect(read[row, 0].value == .text(text), "\(text)") }
    }

    // MARK: - Package

    static func part(_ path: String, of data: Data) throws -> String? {
        try ZipReader(data: data).read(path).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func packageLayout() throws {
        var workbook = Workbook(sheets: [IOXLSXRulesTests.formattingSheet(), IOXLSXRulesTests.filteredSheet()],
                                namedRanges: [NamedRange(name: "TaxRate", reference: "Sales!$B$1")])
        workbook.sheets[0].validations = IOXLSXRulesTests.validationSheet().validations
        workbook.sheets[1].name = "Filtered"
        let data = try SpreadsheetIO.write(workbook, activeSheet: 1, format: .ods)
        let zip = try ZipReader(data: data)
        #expect(zip.entries.map(\.path) == ["mimetype", "META-INF/manifest.xml", "content.xml", "styles.xml", "meta.xml", "settings.xml"])
        #expect(zip.entries.first?.method == 0)
        // "mimetype" sits right after the first local header, readable without unzipping.
        #expect(data.subdata(in: 30..<38) == Data("mimetype".utf8))
        #expect(data.subdata(in: 38..<(38 + 46)) == Data(ODSWriter.mimetype.utf8))
        for entry in zip.entries where entry.path.hasSuffix(".xml") {
            #expect(IOTestPackage.isWellFormed(try zip.read(entry)), "\(entry.path)")
        }
        let content = try #require(try Self.part("content.xml", of: data))
        let order = ["<office:font-face-decls>", "<office:automatic-styles>", "<table:calculation-settings", "<table:content-validations>",
                     "<table:table ", "<calcext:conditional-formats>", "<table:named-expressions>", "<table:database-ranges>"]
        let positions = order.compactMap { content.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted())
        let styles = try #require(try Self.part("styles.xml", of: data))
        #expect(styles.contains("<style:style style:name=\"PuggleSheets_Conditional_1\" style:family=\"table-cell\" style:parent-style-name=\"Default\"><style:text-properties fo:font-weight=\"bold\" fo:color=\"#cc0000\"/></style:style>"))
        let settings = try #require(try Self.part("settings.xml", of: data))
        #expect(settings.contains("<config:config-item config:name=\"ActiveTable\" config:type=\"string\">Filtered</config:config-item>"))
        let manifest = try #require(try Self.part("META-INF/manifest.xml", of: data))
        #expect(manifest.contains("manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\""))
    }

    // MARK: - Files that can't be read

    static func unreadableMessage(_ data: Data) -> String? {
        do {
            _ = try IOTestODS.read(data)
            return nil
        } catch SpreadsheetIOError.unreadable(let message) {
            return message
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test func refusesWhatItCannotRead() throws {
        #expect(Self.unreadableMessage(Data()) == ODSMessages.notASpreadsheet)
        #expect(Self.unreadableMessage(Data("a,b".utf8)) == ODSMessages.notASpreadsheet)
        let text = try IOTestODS.package(content: IOTestODS.content(""), mimetype: "application/vnd.oasis.opendocument.text")
        #expect(Self.unreadableMessage(text) == ODSMessages.otherDocument)
        let encrypted = try IOTestODS.package(content: "not xml at all", manifest: IOTestODS.declaration
            + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"><manifest:encryption-data manifest:checksum-type=\"SHA1/1K\"/></manifest:file-entry></manifest:manifest>")
        #expect(Self.unreadableMessage(encrypted) == ODSMessages.encrypted)
        #expect(Self.unreadableMessage(try IOTestODS.package(content: "<office:document-content><unclosed>")) == ODSMessages.damaged)
        let xlsx = try SpreadsheetIO.write(Workbook(), activeSheet: 0, format: .xlsx)
        #expect(Self.unreadableMessage(xlsx) == ODSMessages.notASpreadsheet)
    }

    @Test func survivesDamage() throws {
        let content = IOTestODS.content(Self.body, automaticStyles: Self.automaticStyles, fontFaces: Self.fontFaces)
        let fragments = ["<table:table-cell table:number-columns-repeated=\"999999999\">", "</table:table-row>", "<text:p>",
                         "table:number-rows-repeated=\"2147483647\"", "<table:table-cell table:number-columns-spanned=\"99999\" office:value-type=\"float\" office:value=\"1\"/>",
                         "office:value-type=\"date\" office:date-value=\"-0001-99-99\"", "office:time-value=\"PTxH\"", "<calcext:condition calcext:value=\"between(\"/>",
                         "table:formula=\"of:=[[[\"", "<table:table table:name=\"\">", "<text:s text:c=\"-5\"/>", "&amp;", "<number:map/>"]
        var random = IOTestRandom(seed: 314)
        var readable = 0
        for iteration in 0..<300 {
            var scalars = Array(content.unicodeScalars)
            for _ in 0..<(1 + Int(random.next() % 4)) {
                let position = Int(random.next() % UInt64(scalars.count + 1))
                switch random.next() % 3 {
                case 0:
                    scalars.removeSubrange(position..<min(scalars.count, position + Int(random.next() % 40)))
                case 1:
                    scalars.insert(contentsOf: fragments[Int(random.next() % UInt64(fragments.count))].unicodeScalars, at: position)
                default:
                    let end = min(scalars.count, position + Int(random.next() % 80))
                    scalars.insert(contentsOf: scalars[position..<end], at: position)
                }
            }
            var data = try IOTestODS.package(content: String(String.UnicodeScalarView(scalars)), styles: Self.libreOfficeStyles, settings: Self.settings)
            if iteration % 5 == 0 {
                for _ in 0..<3 { data[Int(random.next() % UInt64(data.count))] = UInt8(truncatingIfNeeded: random.next()) }
            }
            do {
                let file = try IOTestODS.read(data)
                readable += 1
                #expect(!file.workbook.sheets.isEmpty)
                #expect(file.workbook.sheets.indices.contains(file.activeSheet))
            } catch let error as SpreadsheetIOError {
                #expect(!(error.errorDescription ?? "").isEmpty)
            }
        }
        #expect(readable > 0)
    }

    @Test func hugeRepeatsStayCheap() throws {
        // Formatting repeated over whole rows and columns is kept only inside the grid.
        let content = IOTestODS.content("""
            <table:table table:name="Big"><table:table-column table:number-columns-repeated="16384"/>
            <table:table-row table:number-rows-repeated="1048576"><table:table-cell table:style-name="ce1" table:number-columns-repeated="16384"/></table:table-row>
            </table:table>
            """, automaticStyles: "<style:style style:name=\"ce1\" style:family=\"table-cell\"><style:table-cell-properties fo:background-color=\"#ffff00\"/></style:style>")
        let clock = ContinuousClock()
        var file: SpreadsheetFile?
        let duration = try clock.measure { file = try IOTestODS.read(try IOTestODS.package(content: content)) }
        let sheet = try #require(file?.workbook.sheets.first)
        #expect(sheet.rowCount == 1000 && sheet.columnCount == 26)
        #expect(sheet.cells.count == 26_000)
        #expect(sheet[999, 25].format.fillColor == RGBColor(hex: "FFFF00"))
        #expect(duration < .seconds(30))
        // Content repeated beyond any sensible size is refused instead of filling memory.
        let tooBig = IOTestODS.content("""
            <table:table table:name="Big"><table:table-row table:number-rows-repeated="1048576"><table:table-cell office:value-type="float" office:value="1" table:number-columns-repeated="16384"/></table:table-row></table:table>
            """)
        #expect(Self.unreadableMessage(try IOTestODS.package(content: tooBig)) == ODSMessages.tooLarge)
    }

    @Test func readsGroupedAndHeaderRowsAndColumns() throws {
        // Print titles and outline groups wrap rows and columns; the cells inside count as usual.
        let content = IOTestODS.content("""
            <table:table table:name="Groups">
            <table:table-header-columns><table:table-column table:style-name="co1"/></table:table-header-columns>
            <table:table-column-group table:display="false"><table:table-column table:style-name="co1" table:visibility="collapse"/></table:table-column-group>
            <table:table-columns><table:table-column table:number-columns-repeated="2"/></table:table-columns>
            <table:table-header-rows><table:table-row>\(Self.text("Title"))\(Self.text("Hidden column"))\(Self.text("C"))</table:table-row></table:table-header-rows>
            <table:table-row-group><table:table-row>\(Self.float("1"))</table:table-row>
            <table:table-row-group table:display="false"><table:table-row table:visibility="collapse">\(Self.float("2"))</table:table-row></table:table-row-group>
            </table:table-row-group>
            <table:table-rows><table:table-row><table:covered-table-cell table:number-columns-repeated="2"/>\(Self.float("3"))</table:table-row></table:table-rows>
            </table:table>
            """, automaticStyles: "<style:style style:name=\"co1\" style:family=\"table-column\"><style:table-column-properties style:column-width=\"1in\"/></style:style>")
        let sheet = try #require(try IOTestODS.read(try IOTestODS.package(content: content)).workbook.sheets.first)
        #expect(sheet[0, 0].value == .text("Title") && sheet[0, 1].value == .text("Hidden column") && sheet[0, 2].value == .text("C"))
        #expect(sheet[1, 0].value == .number(1))
        #expect(sheet[2, 0].value == .number(2))
        #expect(sheet[3, 2].value == .number(3))
        // Rows and columns hidden because their group is collapsed belong to the group.
        #expect(sheet.hiddenRows.isEmpty && sheet.rowGroups == [OutlineGroup(range: 1...2), OutlineGroup(range: 2...2, isCollapsed: true)])
        #expect(sheet.hiddenColumns.isEmpty && sheet.columnGroups == [OutlineGroup(range: 1...1, isCollapsed: true)])
        #expect(sheet.isRowHidden(2) && sheet.isColumnHidden(1) && !sheet.isRowHidden(1))
        // Columns without a width have the standard one.
        #expect([0, 1, 2, 3, 4].map(sheet.columnWidth) == [96, 96, 100, 100, 96])
    }

    @Test func sizesWithoutStylesAreStandard() throws {
        // Only the first column and row have sizes, as some generators write; the rest keep the standard sizes.
        // A row height without use-optimal-row-height="false" is one LibreOffice recalculates to fit, as here.
        let content = IOTestODS.content("""
            <table:table table:name="Sizes"><table:table-column table:style-name="wide"/><table:table-column table:number-columns-repeated="5"/>
            <table:table-row table:style-name="tall">\(Self.text("Header"))</table:table-row><table:table-row>\(Self.float("1"))</table:table-row>
            <table:table-row>\(Self.float("2"))</table:table-row>
            <table:table-row table:style-name="fits">\(Self.float("3"))</table:table-row></table:table>
            """, automaticStyles: """
            <style:style style:name="wide" style:family="table-column"><style:table-column-properties style:column-width="5.292cm"/></style:style>
            <style:style style:name="tall" style:family="table-row"><style:table-row-properties style:row-height="36pt" style:use-optimal-row-height="false"/></style:style>
            <style:style style:name="fits" style:family="table-row"><style:table-row-properties style:row-height="72pt"/></style:style>
            """)
        let sheet = try #require(try IOTestODS.read(try IOTestODS.package(content: content)).workbook.sheets.first)
        #expect(sheet.defaultColumnWidth == Sheet.standardColumnWidth && sheet.columnWidths == [0: 200])
        #expect(sheet.defaultRowHeight == Sheet.standardRowHeight && sheet.rowHeights == [0: 48])
    }

    @Test func minimalFilesRead() throws {
        // No styles, settings or columns; a cell without a value type is text.
        let content = IOTestODS.content("<table:table table:name=\"Only\"><table:table-row><table:table-cell><text:p>bare</text:p></table:table-cell></table:table-row></table:table>")
        let file = try IOTestODS.read(try IOTestODS.package(content: content))
        #expect(file.workbook.sheets.map(\.name) == ["Only"])
        #expect(file.workbook.sheets[0][0, 0].value == .text("bare"))
        // No tables at all: one empty sheet.
        let empty = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content("")))
        #expect(empty.workbook.sheets.count == 1)
    }
}
