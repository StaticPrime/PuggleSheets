import Foundation
import Testing
@testable import PuggleSheetsKit

/// Charts in Excel files: DrawingML chart parts with series referencing cells.
struct IOXLSXChartTests {
    static let red = RGBColor(hex: "CC0000")!
    static let teal = RGBColor(hex: "008080")!

    /// Month, Sales, Costs, Profit for six months.
    static func dataSheet(name: String = "Data") -> Sheet {
        var sheet = Sheet(name: name)
        let header = ["Month", "Sales", "Costs", "Profit"]
        for (column, text) in header.enumerated() { sheet[0, column] = Cell(value: .text(text)) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
        for (offset, month) in months.enumerated() {
            let row = offset + 1
            sheet[row, 0] = Cell(value: .text(month))
            sheet[row, 1] = Cell(value: .number(Double(100 + offset * 10)), format: IOTest.format { $0.numberFormat = "#,##0" })
            sheet[row, 2] = Cell(value: .number(Double(60 + offset * 3)))
            sheet[row, 3] = Cell(value: .number(Double(40 + offset * 7)), formula: "=B\(row + 1)-C\(row + 1)")
        }
        return sheet
    }

    static func chartObject(_ spec: ChartSpec, at cell: String = "F2") -> SheetObject {
        SheetObject(anchor: ObjectAnchor(cell: CellAddress(a1: cell)!, offsetX: 4, offsetY: 2, width: 480, height: 300), content: .chart(spec),
                    title: "Chart", altDescription: "A chart of sales")
    }

    /// A workbook with `spec` charted on the data sheet, written and read back.
    static func roundTrip(_ spec: ChartSpec, sheets extra: [Sheet] = [], configure: (inout Sheet) -> Void = { _ in }) throws
        -> (spec: ChartSpec?, file: SpreadsheetFile) {
        var sheet = dataSheet()
        configure(&sheet)
        sheet.objects = [chartObject(spec)]
        let file = try IOXLSXObjectTests.roundTrip(Workbook(sheets: [sheet] + extra))
        return (file.workbook.sheets[0].objects.first?.chart, file)
    }

    static func chartXML(_ spec: ChartSpec, sheets extra: [Sheet] = [], configure: (inout Sheet) -> Void = { _ in }) throws -> String {
        var sheet = dataSheet()
        configure(&sheet)
        sheet.objects = [chartObject(spec)]
        return try IOXLSXObjectTests.part("xl/charts/chart1.xml", of: Workbook(sheets: [sheet] + extra))
    }

    // MARK: - Kinds

    @Test func everyKindRoundTrips() throws {
        for kind in ChartSpec.Kind.allCases {
            var spec = ChartSpec(kind: kind, ranges: ["A1:D7"], title: "Sales by month", horizontalAxisTitle: "Month", verticalAxisTitle: "Dollars")
            if kind == .pie || kind == .donut {
                spec.horizontalAxisTitle = ""
                spec.verticalAxisTitle = ""
            }
            if kind == .donut { spec.ranges = ["A1:B7"] }
            if kind == .combo { spec.series = [ChartSeriesStyle(), ChartSeriesStyle(type: .area), ChartSeriesStyle(usesRightAxis: true)] }
            let (read, file) = try Self.roundTrip(spec)
            #expect(file.warnings.isEmpty, "\(kind)")
            #expect(read == spec, "\(kind)")
        }
    }

    @Test func kindsAsExcelDrawsThem() throws {
        func xml(_ kind: ChartSpec.Kind) throws -> String { try Self.chartXML(ChartSpec(kind: kind, ranges: ["A1:D7"])) }
        #expect(try xml(.column).contains("<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>"))
        #expect(!(try xml(.column)).contains("<c:overlap"))
        #expect(try xml(.stackedBar).contains("<c:barDir val=\"bar\"/><c:grouping val=\"stacked\"/>"))
        #expect(try xml(.stackedBar).contains("<c:gapWidth val=\"150\"/><c:overlap val=\"100\"/>"))
        #expect(try xml(.percentColumn).contains("<c:grouping val=\"percentStacked\"/>"))
        #expect(try xml(.percentColumn).contains("<c:numFmt formatCode=\"0%\" sourceLinked=\"0\"/>"))
        #expect(try xml(.smoothLine).contains("<c:smooth val=\"1\"/>"))
        #expect(try xml(.line).contains("<c:marker><c:symbol val=\"none\"/></c:marker>"))
        #expect(try xml(.stackedArea).contains("<c:areaChart><c:grouping val=\"stacked\"/>"))
        #expect(try xml(.pie).contains("<c:pieChart><c:varyColors val=\"1\"/>"))
        #expect(!(try xml(.pie)).contains("<c:catAx>"))
        #expect(try xml(.scatter).contains("<c:scatterChart><c:scatterStyle val=\"lineMarker\"/>"))
        #expect(try xml(.scatter).contains("<c:xVal>"))
        #expect(try xml(.scatter).contains("<c:valAx><c:axId val=\"1001\"/>"))
        var donut = ChartSpec(kind: .donut, ranges: ["A1:D7"], pieHole: 0.35)
        donut.pieSliceLabel = .value
        let donutXML = try Self.chartXML(donut)
        #expect(donutXML.contains("<c:holeSize val=\"35\"/>"))
        #expect(donutXML.contains("<c:showVal val=\"1\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/><c:showPercent val=\"0\"/>"))
        // A doughnut shows its first series only; Excel would draw the others as rings.
        #expect(donutXML.components(separatedBy: "<c:ser>").count == 2)
        // Slices take the default palette's colors in turn.
        #expect(donutXML.contains("<c:dPt><c:idx val=\"1\"/><c:bubble3D val=\"0\"/><c:spPr><a:solidFill><a:srgbClr val=\"EA4335\"/>"))
    }

    @Test func comboChartsShareAxesAndUseASecondOne() throws {
        let spec = ChartSpec(kind: .combo, ranges: ["A1:D7"],
                             series: [ChartSeriesStyle(), ChartSeriesStyle(type: .line), ChartSeriesStyle(type: .column, usesRightAxis: true)])
        let xml = try Self.chartXML(spec)
        // Columns first, on the left axis; then the line; then columns against the right axis.
        let bar = try #require(xml.range(of: "<c:barChart>")), line = try #require(xml.range(of: "<c:lineChart>"))
        #expect(bar.lowerBound < line.lowerBound)
        #expect(xml.components(separatedBy: "<c:barChart>").count == 3)
        #expect(xml.contains("<c:axId val=\"1003\"/><c:axId val=\"1004\"/></c:barChart>"))
        #expect(xml.contains("<c:valAx><c:axId val=\"1004\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"r\"/>"))
        #expect(xml.contains("<c:crossAx val=\"1003\"/><c:crosses val=\"max\"/>"))
        #expect(xml.contains("<c:catAx><c:axId val=\"1003\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"1\"/>"))
        let (read, file) = try Self.roundTrip(spec)
        #expect(file.warnings.isEmpty)
        // The second series' line is the default for combo charts.
        #expect(read?.series == [ChartSeriesStyle(), ChartSeriesStyle(), ChartSeriesStyle(type: .column, usesRightAxis: true)])
        // A line chart with one series on the right axis stays a line chart.
        let lines = ChartSpec(kind: .line, ranges: ["A1:C7"], series: [ChartSeriesStyle(), ChartSeriesStyle(usesRightAxis: true)])
        #expect(try Self.roundTrip(lines).spec == lines)
    }

    // MARK: - Data layout

    @Test func seriesReferenceTheirCells() throws {
        var sheet = Self.dataSheet(name: "Q1 data")
        sheet.objects = [Self.chartObject(ChartSpec(kind: .column, ranges: ["A1:C7"]))]
        let xml = try IOXLSXObjectTests.part("xl/charts/chart1.xml", of: Workbook(sheets: [sheet]))
        #expect(xml.contains("<c:tx><c:strRef><c:f>'Q1 data'!$B$1</c:f><c:strCache><c:ptCount val=\"1\"/><c:pt idx=\"0\"><c:v>Sales</c:v></c:pt>"))
        #expect(xml.contains("<c:cat><c:strRef><c:f>'Q1 data'!$A$2:$A$7</c:f><c:strCache><c:ptCount val=\"6\"/><c:pt idx=\"0\"><c:v>Jan</c:v></c:pt>"))
        #expect(xml.contains("<c:val><c:numRef><c:f>'Q1 data'!$B$2:$B$7</c:f><c:numCache><c:formatCode>#,##0</c:formatCode><c:ptCount val=\"6\"/>"
            + "<c:pt idx=\"0\"><c:v>100</c:v></c:pt><c:pt idx=\"1\"><c:v>110</c:v></c:pt>"))
        #expect(xml.contains("<c:f>'Q1 data'!$C$2:$C$7</c:f>"))
        // Excel draws visible cells only, as the chart's rules do.
        #expect(xml.contains("<c:plotVisOnly val=\"1\"/>"))
        // Series take the default palette.
        #expect(xml.contains("<c:spPr><a:solidFill><a:srgbClr val=\"4285F4\"/></a:solidFill></c:spPr>"))
        #expect(xml.contains("<a:srgbClr val=\"EA4335\"/>"))
    }

    @Test func layoutOptionsRoundTrip() throws {
        var other = Self.dataSheet(name: "Other data")
        other[0, 0] = Cell(value: .text("Quarter"))
        let specs: [ChartSpec] = [
            ChartSpec(kind: .column, ranges: ["A1:D7"], switchRowsAndColumns: true),
            ChartSpec(kind: .line, ranges: ["B2:D7"], firstRowIsHeader: false, firstColumnIsLabels: false),
            ChartSpec(kind: .column, ranges: ["A1:A7", "C1:D7"]),
            ChartSpec(kind: .bar, ranges: ["B1:C7"], firstColumnIsLabels: false),
            ChartSpec(kind: .column, ranges: ["'Other data'!A1:C4"]),
            ChartSpec(kind: .scatter, ranges: ["B1:C7"]),
            ChartSpec(kind: .pie, ranges: ["A1:B7"], switchRowsAndColumns: false),
            ChartSpec(kind: .column, ranges: ["A1:D3"], firstRowIsHeader: true, firstColumnIsLabels: false, switchRowsAndColumns: true),
        ]
        for spec in specs {
            let (read, file) = try Self.roundTrip(spec, sheets: [other])
            #expect(file.warnings.isEmpty, "\(spec.ranges)")
            #expect(read == spec, "\(spec.ranges) \(spec.switchRowsAndColumns)")
        }
    }

    @Test func hiddenColumnsAreSkippedAndBridged() throws {
        // Column C is hidden: the chart shows Sales and Profit, as series 0 and 1.
        let spec = ChartSpec(kind: .column, ranges: ["A1:D7"], series: [ChartSeriesStyle(color: Self.red), ChartSeriesStyle(color: Self.teal)])
        let xml = try Self.chartXML(spec) { $0.hiddenColumns = [2] }
        #expect(!xml.contains("$C$2:$C$7"))
        #expect(xml.contains("<c:f>Data!$D$2:$D$7</c:f>"))
        let (read, _) = try Self.roundTrip(spec) { $0.hiddenColumns = [2] }
        #expect(read == spec)
        // Hidden rows stay in the references; Excel leaves them out when drawing.
        let rows = try Self.chartXML(ChartSpec(ranges: ["A1:B7"])) { $0.hiddenRows = [3] }
        #expect(rows.contains("<c:f>Data!$B$2:$B$7</c:f>"))
    }

    @Test func namedAndOpenRangesBecomeReferences() throws {
        var sheet = Self.dataSheet()
        sheet.objects = [Self.chartObject(ChartSpec(ranges: ["Sales"])), Self.chartObject(ChartSpec(ranges: ["A1:B"]), at: "F20")]
        let workbook = Workbook(sheets: [sheet], namedRanges: [NamedRange(name: "Sales", reference: "Data!$A$1:$B$7")])
        let file = try IOXLSXObjectTests.roundTrip(workbook)
        #expect(file.workbook.sheets[0].objects.map { $0.chart?.ranges } == [["A1:B7"], ["A1:B1000"]])
    }

    // MARK: - Styles and options

    @Test func stylesAndOptionsRoundTrip() throws {
        var spec = ChartSpec(kind: .line, ranges: ["A1:D7"], title: "Revenue", subtitle: "First half", horizontalAxisTitle: "Month",
                             verticalAxisTitle: "USD", legend: .bottom, backgroundColor: RGBColor(hex: "FFF2CC"), fontFamily: "Georgia",
                             verticalMinimum: 0, verticalMaximum: 250.5, logScale: true, showsGridlines: false, showsDataLabels: true)
        spec.series = [ChartSeriesStyle(color: Self.red, lineWidth: 4, pointSize: 8, showsDataLabels: false),
                       ChartSeriesStyle(lineWidth: 1.5, pointSize: 0),
                       ChartSeriesStyle(color: Self.teal, showsDataLabels: true)]
        let (read, file) = try Self.roundTrip(spec)
        #expect(file.warnings.isEmpty)
        var expected = spec
        // No points is a line's default.
        expected.series[1].pointSize = nil
        #expect(read == expected)
        let xml = try Self.chartXML(spec)
        #expect(xml.contains("<a:p><a:pPr><a:defRPr sz=\"1400\" b=\"0\"/></a:pPr><a:r><a:rPr lang=\"en-US\" sz=\"1400\" b=\"0\"/><a:t>Revenue</a:t></a:r></a:p>"
            + "<a:p><a:pPr><a:defRPr sz=\"1100\" b=\"0\"/></a:pPr><a:r><a:rPr lang=\"en-US\" sz=\"1100\" b=\"0\"/><a:t>First half</a:t></a:r></a:p>"))
        #expect(xml.contains("<c:scaling><c:logBase val=\"10\"/><c:orientation val=\"minMax\"/><c:max val=\"250.5\"/><c:min val=\"0\"/></c:scaling>"))
        #expect(xml.contains("<c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/></c:legend>"))
        #expect(xml.contains("<a:ln w=\"38100\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"CC0000\"/>"))
        #expect(xml.contains("<c:marker><c:symbol val=\"circle\"/><c:size val=\"6\"/>"))
        #expect(xml.contains("<c:spPr><a:solidFill><a:srgbClr val=\"FFF2CC\"/></a:solidFill><a:ln><a:noFill/></a:ln></c:spPr>"))
        #expect(xml.contains("<a:latin typeface=\"Georgia\"/>"))
        #expect(!xml.contains("<c:majorGridlines/>"))

        for legend in ChartSpec.LegendPosition.allCases {
            let spec = ChartSpec(ranges: ["A1:B7"], legend: legend)
            // Right is where the automatic legend goes.
            #expect(try Self.roundTrip(spec).spec?.legend == (legend == .right ? .auto : legend), "\(legend)")
        }
        for label in ChartSpec.PieLabel.allCases {
            let spec = ChartSpec(kind: .pie, ranges: ["A1:B7"], pieSliceLabel: label)
            #expect(try Self.roundTrip(spec).spec?.pieSliceLabel == label, "\(label)")
        }
        // A subtitle alone keeps an empty first line.
        let subtitle = ChartSpec(ranges: ["A1:B7"], subtitle: "Only a subtitle")
        #expect(try Self.roundTrip(subtitle).spec == subtitle)
    }

    @Test func untitledChartsStayUntitled() throws {
        let xml = try Self.chartXML(ChartSpec(ranges: ["A1:B7"]))
        #expect(xml.contains("<c:chart><c:autoTitleDeleted val=\"1\"/><c:plotArea>"))
        #expect(xml.contains("<c:roundedCorners val=\"0\"/>"))
    }

    @Test func anchorsAndAltTextRoundTrip() throws {
        let (_, file) = try Self.roundTrip(ChartSpec(ranges: ["A1:B7"]))
        let object = try #require(file.workbook.sheets[0].objects.first)
        #expect(object.anchor == ObjectAnchor(cell: CellAddress(a1: "F2")!, offsetX: 4, offsetY: 2, width: 480, height: 300))
        #expect(object.title == "Chart" && object.altDescription == "A chart of sales")
        var sheet = Self.dataSheet()
        sheet.objects = [Self.chartObject(ChartSpec(ranges: ["A1:B7"]))]
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
        let drawing = try #require(try IOTestPackage.part("xl/drawings/drawing1.xml", of: data))
        #expect(drawing.contains("<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"2\" name=\"Chart 1\" descr=\"A chart of sales\" title=\"Chart\"/>"))
        #expect(drawing.contains("<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"><c:chart r:id=\"rId1\"/></a:graphicData>"))
        let types = try #require(try IOTestPackage.part("[Content_Types].xml", of: data))
        #expect(types.contains("<Override PartName=\"/xl/charts/chart1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>"))
    }

    // MARK: - Charts from Excel

    /// A worksheet with a chart drawn the way Excel 2016 writes it.
    static func excelPackage(chart: String, chartRelationships: [(id: String, type: String, target: String)]? = nil,
                             sheetBody: String? = nil) throws -> Data {
        let rows = (1...7).map { row -> String in
            row == 1 ? "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Month</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Sales</t></is></c>"
                + "<c r=\"C1\" t=\"inlineStr\"><is><t>Costs</t></is></c></row>"
                : "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"inlineStr\"><is><t>M\(row - 1)</t></is></c><c r=\"B\(row)\"><v>\(row * 10)</v></c>"
                    + "<c r=\"C\(row)\"><v>\(row * 4)</v></c></row>"
        }.joined()
        let drawing = IOTestPackage.declaration
            + "<xdr:wsDr xmlns:xdr=\"\(XLSXNamespace.spreadsheetDrawing)\" xmlns:a=\"\(XLSXNamespace.drawingMain)\">"
            + "<xdr:twoCellAnchor editAs=\"oneCell\"><xdr:from><xdr:col>4</xdr:col><xdr:colOff>304800</xdr:colOff><xdr:row>1</xdr:row>"
            + "<xdr:rowOff>9525</xdr:rowOff></xdr:from><xdr:to><xdr:col>11</xdr:col><xdr:colOff>609600</xdr:colOff><xdr:row>16</xdr:row>"
            + "<xdr:rowOff>85725</xdr:rowOff></xdr:to><xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"2\" name=\"Chart 1\"/>"
            + "<xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic>"
            + "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"><c:chart xmlns:c=\"\(XLSXNamespace.chart)\" "
            + "xmlns:r=\"\(IOTestPackage.relationshipNamespace)\" r:id=\"rId1\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/>"
            + "</xdr:twoCellAnchor></xdr:wsDr>"
        var parts = [
            "xl/drawings/drawing1.xml": drawing,
            "xl/drawings/_rels/drawing1.xml.rels": IOTestPackage.relationships([("rId1", "chart", "../charts/chart1.xml")]),
            "xl/charts/chart1.xml": IOTestPackage.declaration + "<c:chartSpace xmlns:c=\"\(XLSXNamespace.chart)\" xmlns:a=\"\(XLSXNamespace.drawingMain)\" "
                + "xmlns:r=\"\(IOTestPackage.relationshipNamespace)\">\(chart)</c:chartSpace>",
        ]
        if let chartRelationships { parts["xl/charts/_rels/chart1.xml.rels"] = IOTestPackage.relationships(chartRelationships) }
        return try IOTestPackage.xlsx(sheets: [
            IOTestPackage.SheetPart("Sheet 1", sheetBody ?? "<sheetData>\(rows)</sheetData><drawing r:id=\"rId1\"/>",
                                    relationships: [("drawing", "../drawings/drawing1.xml")]),
        ], parts: parts)
    }

    static func excelSeries(_ index: Int, column: String, color: String) -> String {
        "<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/><c:tx><c:strRef><c:f>'Sheet 1'!$\(column)$1</c:f><c:strCache><c:ptCount val=\"1\"/>"
            + "<c:pt idx=\"0\"><c:v>S</c:v></c:pt></c:strCache></c:strRef></c:tx><c:spPr>\(color)</c:spPr><c:invertIfNegative val=\"0\"/>"
            + "<c:cat><c:strRef><c:f>'Sheet 1'!$A$2:$A$7</c:f></c:strRef></c:cat><c:val><c:numRef><c:f>'Sheet 1'!$\(column)$2:$\(column)$7</c:f>"
            + "<c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"6\"/></c:numCache></c:numRef></c:val></c:ser>"
    }

    static let excelAxes = "<c:catAx><c:axId val=\"510726544\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/>"
        + "<c:axPos val=\"b\"/><c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>Months</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title>"
        + "<c:crossAx val=\"510728184\"/><c:crosses val=\"autoZero\"/></c:catAx>"
        + "<c:valAx><c:axId val=\"510728184\"/><c:scaling><c:orientation val=\"minMax\"/><c:max val=\"100\"/></c:scaling><c:delete val=\"0\"/>"
        + "<c:axPos val=\"l\"/><c:majorGridlines><c:spPr><a:ln w=\"9525\"/></c:spPr></c:majorGridlines><c:crossAx val=\"510726544\"/>"
        + "<c:crosses val=\"autoZero\"/><c:crossBetween val=\"between\"/></c:valAx>"

    @Test func excelChartsAreRead() throws {
        let chart = "<c:roundedCorners val=\"0\"/><c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Sales </a:t></a:r>"
            + "<a:r><a:t>2026</a:t></a:r></a:p><a:p><a:r><a:t>by month</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title>"
            + "<c:autoTitleDeleted val=\"0\"/><c:plotArea><c:layout/><c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/>"
            + "<c:varyColors val=\"0\"/>"
            + Self.excelSeries(0, column: "B", color: "<a:solidFill><a:schemeClr val=\"accent1\"/></a:solidFill>")
            + Self.excelSeries(1, column: "C", color: "<a:solidFill><a:schemeClr val=\"accent2\"><a:lumMod val=\"75000\"/></a:schemeClr></a:solidFill>")
            + "<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"0\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/>"
            + "<c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls><c:gapWidth val=\"219\"/><c:overlap val=\"-27\"/>"
            + "<c:axId val=\"510726544\"/><c:axId val=\"510728184\"/></c:barChart>" + Self.excelAxes + "</c:plotArea>"
            + "<c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/></c:legend><c:plotVisOnly val=\"1\"/></c:chart>"
            + "<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:pPr></a:p></c:txPr>"
        let file = try IOTestPackage.read(try Self.excelPackage(chart: chart))
        #expect(file.warnings.isEmpty)
        let object = try #require(file.workbook.sheets[0].objects.first)
        // 64-pixel columns and 21-pixel rows (the file's defaults): E2 + (32, 1); to L17 + (64, 9).
        #expect(object.anchor == ObjectAnchor(cell: CellAddress(a1: "E2")!, offsetX: 32, offsetY: 1, width: 480, height: 323))
        let spec = try #require(object.chart)
        #expect(spec.kind == .column)
        #expect(spec.ranges == ["A1:C7"])
        #expect(spec.firstRowIsHeader && spec.firstColumnIsLabels && !spec.switchRowsAndColumns)
        #expect(spec.title == "Sales 2026" && spec.subtitle == "by month")
        #expect(spec.horizontalAxisTitle == "Months" && spec.verticalAxisTitle == "")
        #expect(spec.legend == .bottom)
        #expect(spec.verticalMaximum == 100 && spec.verticalMinimum == nil)
        #expect(spec.showsGridlines && !spec.showsDataLabels)
        #expect(spec.fontFamily == nil)
        // Office theme colors: accent1, and accent2 at 75% lightness.
        #expect(spec.series.map(\.color) == [RGBColor(hex: "4472C4"), RGBColor(hex: "C55A11")])
    }

    @Test func excelLineChartsWithASecondAxis() throws {
        let lineSeries = { (index: Int, column: String) in
            "<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/><c:tx><c:strRef><c:f>'Sheet 1'!$\(column)$1</c:f></c:strRef></c:tx>"
                + "<c:spPr><a:ln w=\"28575\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></a:ln></c:spPr>"
                + "<c:marker><c:symbol val=\"circle\"/><c:size val=\"5\"/></c:marker>"
                + "<c:cat><c:strRef><c:f>'Sheet 1'!$A$2:$A$7</c:f></c:strRef></c:cat><c:val><c:numRef><c:f>'Sheet 1'!$\(column)$2:$\(column)$7</c:f>"
                + "</c:numRef></c:val><c:smooth val=\"0\"/></c:ser>"
        }
        let chart = "<c:chart><c:autoTitleDeleted val=\"1\"/><c:plotArea><c:layout/>"
            + "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>" + lineSeries(0, "B")
            + "<c:marker val=\"1\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:lineChart>"
            + "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>" + lineSeries(1, "C")
            + "<c:marker val=\"1\"/><c:axId val=\"3\"/><c:axId val=\"4\"/></c:lineChart>"
            + "<c:catAx><c:axId val=\"1\"/><c:scaling/><c:delete val=\"0\"/><c:axPos val=\"b\"/><c:crossAx val=\"2\"/></c:catAx>"
            + "<c:valAx><c:axId val=\"2\"/><c:scaling/><c:delete val=\"0\"/><c:axPos val=\"l\"/><c:crossAx val=\"1\"/></c:valAx>"
            + "<c:catAx><c:axId val=\"3\"/><c:scaling/><c:delete val=\"1\"/><c:axPos val=\"b\"/><c:crossAx val=\"4\"/></c:catAx>"
            + "<c:valAx><c:axId val=\"4\"/><c:scaling/><c:delete val=\"0\"/><c:axPos val=\"r\"/><c:crossAx val=\"3\"/><c:crosses val=\"max\"/></c:valAx>"
            + "</c:plotArea></c:chart>"
        let file = try IOTestPackage.read(try Self.excelPackage(chart: chart))
        #expect(file.warnings.isEmpty)
        let spec = try #require(file.workbook.sheets[0].objects.first?.chart)
        #expect(spec.kind == .line && spec.ranges == ["A1:C7"] && spec.legend == .none && spec.title.isEmpty)
        let red = RGBColor(hex: "FF0000")
        #expect(spec.series == [ChartSeriesStyle(color: red, lineWidth: 3, pointSize: 7),
                                ChartSeriesStyle(color: red, lineWidth: 3, pointSize: 7, usesRightAxis: true)])
        #expect(!spec.showsGridlines)
    }

    @Test func excelChartsPuggleSheetsCannotKeep() throws {
        // Values typed into the chart reference no cells: nothing to keep.
        let literal = "<c:chart><c:plotArea><c:layout/><c:barChart><c:barDir val=\"col\"/><c:ser><c:idx val=\"0\"/><c:order val=\"0\"/>"
            + "<c:val><c:numLit><c:ptCount val=\"2\"/><c:pt idx=\"0\"><c:v>1</c:v></c:pt></c:numLit></c:val></c:ser>"
            + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart></c:plotArea></c:chart>"
        var file = try IOTestPackage.read(try Self.excelPackage(chart: literal))
        #expect(file.warnings == [.charts])
        #expect(file.workbook.sheets[0].objects.isEmpty)
        // A radar chart becomes the closest kind, a line chart, with a warning.
        let radar = "<c:chart><c:plotArea><c:layout/><c:radarChart><c:radarStyle val=\"marker\"/>"
            + Self.excelSeries(0, column: "B", color: "").replacingOccurrences(of: "<c:invertIfNegative val=\"0\"/>", with: "")
            + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:radarChart></c:plotArea></c:chart>"
        file = try IOTestPackage.read(try Self.excelPackage(chart: radar))
        #expect(file.warnings == [.charts])
        #expect(file.workbook.sheets[0].objects.first?.chart?.kind == .line)
        // Surface charts have no counterpart.
        let surface = "<c:chart><c:plotArea><c:layout/><c:surfaceChart>" + Self.excelSeries(0, column: "B", color: "")
            + "</c:surfaceChart></c:plotArea></c:chart>"
        file = try IOTestPackage.read(try Self.excelPackage(chart: surface))
        #expect(file.warnings == [.charts])
        #expect(file.workbook.sheets[0].objects.isEmpty)
        // Series named by typed text lose their names.
        let literalName = Self.excelSeries(0, column: "B", color: "")
            .replacingOccurrences(of: "<c:tx><c:strRef><c:f>'Sheet 1'!$B$1</c:f><c:strCache><c:ptCount val=\"1\"/><c:pt idx=\"0\"><c:v>S</c:v></c:pt></c:strCache></c:strRef></c:tx>",
                                  with: "<c:tx><c:v>Typed name</c:v></c:tx>")
        let named = "<c:chart><c:plotArea><c:layout/><c:barChart><c:barDir val=\"col\"/>\(literalName)<c:axId val=\"1\"/><c:axId val=\"2\"/>"
            + "</c:barChart></c:plotArea></c:chart>"
        file = try IOTestPackage.read(try Self.excelPackage(chart: named))
        #expect(file.warnings == [.charts])
        let spec = try #require(file.workbook.sheets[0].objects.first?.chart)
        #expect(spec.ranges == ["A2:B7"] && !spec.firstRowIsHeader && spec.firstColumnIsLabels)
    }

    @Test func damagedChartsOnlyWarn() throws {
        var random = IOTestRandom(seed: 7)
        var sheet = Self.dataSheet()
        var spec = ChartSpec(kind: .combo, ranges: ["A1:D7"], title: "T", series: [ChartSeriesStyle(color: Self.red, usesRightAxis: true)])
        spec.verticalMaximum = 9
        sheet.objects = [Self.chartObject(spec)]
        let chart = try IOXLSXObjectTests.part("xl/charts/chart1.xml", of: Workbook(sheets: [sheet]))
        let scalars = Array(chart.unicodeScalars)
        for _ in 0..<150 {
            var damaged = scalars
            for _ in 0..<(1 + Int(random.next() % 3)) {
                let position = Int(random.next() % UInt64(damaged.count))
                damaged.removeSubrange(position..<min(damaged.count, position + Int(random.next() % 60)))
            }
            let text = String(String.UnicodeScalarView(damaged))
            let body = text.components(separatedBy: "xmlns:r=\"\(XLSXNamespace.relationships)\">").last ?? text
            let file = try IOTestPackage.read(try Self.excelPackage(chart: body.replacingOccurrences(of: "</c:chartSpace>", with: "")))
            #expect(file.workbook.sheets[0][0, 0].value == .text("Month"))
        }
    }
}
