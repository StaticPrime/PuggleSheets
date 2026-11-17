import Foundation
import Testing
@testable import PuggleSheetsKit

/// Phase 3 in OpenDocument files: links, images, charts, pivot tables (DataPilot) and filter views.
struct IOODSObjectsTests {
    static func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    static func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    /// PNG header bytes (enough for `ImageData(data:)`) for an image of the given size.
    static func png(width: Int, height: Int, seed: UInt8 = 0) -> ImageData {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
        bytes += [UInt8(width >> 24 & 0xFF), UInt8(width >> 16 & 0xFF), UInt8(width >> 8 & 0xFF), UInt8(width & 0xFF)]
        bytes += [UInt8(height >> 24 & 0xFF), UInt8(height >> 16 & 0xFF), UInt8(height >> 8 & 0xFF), UInt8(height & 0xFF)]
        bytes += [8, 6, 0, 0, 0, seed, 1, 2, 3]
        return ImageData(data: Data(bytes))!
    }

    /// Regions and quarters: a header row, a labels column and three series.
    static func dataSheet(name: String = "Data") -> Sheet {
        var sheet = Sheet(name: name)
        let rows: [[CellValue]] = [
            [.text("Region"), .text("Q1"), .text("Q2"), .text("Q3")],
            [.text("North"), .number(10), .number(12), .number(9)],
            [.text("South"), .number(7), .number(8), .number(11)],
            [.text("East"), .number(4), .number(6), .number(5)],
            [.text("West"), .number(9), .number(3), .number(8)],
        ]
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() { sheet[row, column] = Cell(value: value) }
        }
        return sheet
    }

    static func write(_ workbook: Workbook) throws -> Data {
        try SpreadsheetIO.write(workbook, activeSheet: 0, format: .ods)
    }

    static func roundTrip(_ workbook: Workbook) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(try write(workbook), format: .ods)
    }

    static func part(_ path: String, of data: Data) throws -> String? {
        try ZipReader(data: data).read(path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The package without PuggleSheets' own settings, as LibreOffice would save it.
    static func withoutPuggleSettings(_ data: Data) throws -> Data {
        let zip = try ZipReader(data: data)
        var writer = ZipWriter()
        for entry in zip.entries {
            var part = try zip.read(entry)
            if entry.path == "settings.xml" {
                var text = String(decoding: part, as: UTF8.self)
                if let start = text.range(of: "<config:config-item-set config:name=\"\(ODSPuggleSettings.setName)\">"),
                   let end = text.range(of: "</config:config-item-set>", range: start.upperBound..<text.endIndex) {
                    text.removeSubrange(start.lowerBound..<end.upperBound)
                }
                part = Data(text.utf8)
            }
            try writer.add(entry.path, part, compress: entry.path != "mimetype")
        }
        return try writer.finish()
    }

    // MARK: - Links

    @Test func linksRoundTrip() throws {
        let data = Self.dataSheet()
        var links = Sheet(name: "Q1 2026")
        links[0, 0] = Cell(value: .text("Docs"), link: "https://example.com/docs?a=1&b=2")
        links[1, 0] = Cell(value: .number(42), link: "mailto:me@example.com")
        links[2, 0] = Cell(value: .text("Line 1\nLine 2"), link: "https://example.com")
        links[3, 0] = Cell(value: .text("Go to data"), link: LinkTarget.sheet(data.id, Self.range("B2:C3")).link)
        links[4, 0] = Cell(value: .text("Here"), link: LinkTarget.sheet(links.id, Self.range("D7")).link)
        links[5, 0] = Cell(value: .text("Data sheet"), link: LinkTarget.sheet(data.id, nil).link)
        links[6, 0] = Cell(value: .text("Totals"), link: LinkTarget.namedRange("Totals").link)
        links[7, 0] = Cell(link: "https://example.com/empty")
        links[8, 0] = Cell(value: .text("Bold link"), format: IOTest.format { $0.bold = true }, link: "https://example.com/bold")
        let workbook = Workbook(sheets: [data, links], namedRanges: [NamedRange(name: "Totals", reference: "Data!$B$2:$D$5")])
        let package = try Self.write(workbook)
        let content = try #require(try Self.part("content.xml", of: package))
        #expect(content.contains("<text:p><text:a xlink:href=\"https://example.com/docs?a=1&amp;b=2\" xlink:type=\"simple\">Docs</text:a></text:p>"))
        #expect(content.contains("<text:a xlink:href=\"#Data.B2:C3\" xlink:type=\"simple\">Go to data</text:a>"))
        #expect(content.contains("<text:a xlink:href=\"#'Q1 2026'.D7\" xlink:type=\"simple\">Here</text:a>"))
        #expect(content.contains("<text:a xlink:href=\"#Data\" xlink:type=\"simple\">Data sheet</text:a>"))
        #expect(content.contains("<text:a xlink:href=\"#Totals\" xlink:type=\"simple\">Totals</text:a>"))
        #expect(content.contains("<text:p><text:a xlink:href=\"https://example.com\" xlink:type=\"simple\">Line 1</text:a></text:p><text:p><text:a xlink:href=\"https://example.com\" xlink:type=\"simple\">Line 2</text:a></text:p>"))

        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[1]
        let readData = file.workbook.sheets[0]
        #expect(read[0, 0] == links[0, 0])
        #expect(read[1, 0] == links[1, 0])
        #expect(read[2, 0] == links[2, 0])
        #expect(read[3, 0].link == LinkTarget.sheet(readData.id, Self.range("B2:C3")).link)
        #expect(read[4, 0].link == LinkTarget.sheet(read.id, Self.range("D7")).link)
        #expect(read[5, 0].link == LinkTarget.sheet(readData.id, nil).link)
        #expect(read[6, 0] == links[6, 0])
        #expect(read[7, 0] == links[7, 0])
        #expect(read[8, 0] == links[8, 0])
    }

    @Test func readsLibreOfficeLinks() throws {
        func cell(_ text: String) -> String {
            "<table:table-cell office:value-type=\"string\" calcext:value-type=\"string\"><text:p>\(text)</text:p></table:table-cell>"
        }
        func link(_ href: String, _ text: String) -> String { cell("<text:a xlink:href=\"\(href)\" xlink:type=\"simple\">\(text)</text:a>") }
        let body = """
            <table:table table:name="Sheet1">
            <table:table-row>\(link("#Sheet2.A1", "a"))</table:table-row>
            <table:table-row>\(link("#$'My sheet'.$B$2:$C$3", "b"))</table:table-row>
            <table:table-row>\(link("#Totals", "c"))</table:table-row>
            <table:table-row>\(link("#My sheet", "d"))</table:table-row>
            <table:table-row>\(link("#Sheet2!B5", "e"))</table:table-row>
            <table:table-row>\(link("#My%20sheet.A1", "f"))</table:table-row>
            <table:table-row>\(link("#.C3", "g"))</table:table-row>
            <table:table-row>\(link("https://example.com", "<text:span text:style-name=\"T1\">styled</text:span> link"))</table:table-row>
            </table:table>
            <table:table table:name="Sheet2"><table:table-row>\(cell("x"))</table:table-row></table:table>
            <table:table table:name="My sheet"><table:table-row>\(cell("y"))</table:table-row></table:table>
            <table:named-expressions><table:named-range table:name="Totals" table:base-cell-address="$Sheet1.$A$1" table:cell-range-address="$Sheet2.$A$1:.$A$9"/></table:named-expressions>
            """
        let file = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(body)))
        let sheets = file.workbook.sheets
        let sheet = sheets[0]
        #expect(sheet[0, 0] == Cell(value: .text("a"), link: LinkTarget.sheet(sheets[1].id, Self.range("A1")).link))
        #expect(sheet[1, 0].link == LinkTarget.sheet(sheets[2].id, Self.range("B2:C3")).link)
        #expect(sheet[2, 0].link == LinkTarget.namedRange("Totals").link)
        #expect(sheet[3, 0].link == LinkTarget.sheet(sheets[2].id, nil).link)
        #expect(sheet[4, 0].link == LinkTarget.sheet(sheets[1].id, Self.range("B5")).link)
        #expect(sheet[5, 0].link == LinkTarget.sheet(sheets[2].id, Self.range("A1")).link)
        #expect(sheet[6, 0].link == LinkTarget.sheet(sheets[0].id, Self.range("C3")).link)
        #expect(sheet[7, 0] == Cell(value: .text("styled link"), link: "https://example.com"))
        #expect(file.warnings == [.richText])

        // Several links, or a link around part of the text: the first link takes the whole cell.
        let partial = """
            <table:table table:name="Sheet1">
            <table:table-row>\(cell("See <text:a xlink:href=\"https://a.example\">here</text:a>"))</table:table-row>
            <table:table-row>\(cell("<text:a xlink:href=\"https://a.example\">one</text:a> <text:a xlink:href=\"https://b.example\">two</text:a>"))</table:table-row>
            </table:table>
            """
        let partialFile = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(partial)))
        #expect(partialFile.workbook.sheets[0][0, 0] == Cell(value: .text("See here"), link: "https://a.example"))
        #expect(partialFile.workbook.sheets[0][1, 0] == Cell(value: .text("one two"), link: "https://a.example"))
        #expect(partialFile.warnings == [.hyperlinks])

        // A mark naming nothing can't be kept.
        let broken = "<table:table table:name=\"Sheet1\"><table:table-row>\(link("#Nowhere", "lost"))</table:table-row></table:table>"
        let brokenFile = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(broken)))
        #expect(brokenFile.workbook.sheets[0][0, 0] == Cell(value: .text("lost")))
        #expect(brokenFile.warnings == [.hyperlinks])
    }

    @Test func hyperlinkFormulasRoundTrip() throws {
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .text("Docs"), formula: "=HYPERLINK(\"https://example.com/a;b\",\"Docs\")")
        sheet[1, 0] = Cell(value: .text("B1"), formula: "=HYPERLINK(\"#gid=0\",A1)")
        let package = try Self.write(Workbook(sheets: [sheet]))
        let content = try #require(try Self.part("content.xml", of: package))
        #expect(content.contains("table:formula=\"of:=HYPERLINK(&quot;https://example.com/a;b&quot;;&quot;Docs&quot;)\""))
        let read = try SpreadsheetIO.read(package, format: .ods).workbook.sheets[0]
        #expect(read[0, 0] == sheet[0, 0])
        #expect(read[1, 0] == sheet[1, 0])
        #expect(ODSFormula.importing("of:=HYPERLINK(\"https://x.example\";\"X\")") == "=HYPERLINK(\"https://x.example\",\"X\")")
    }

    // MARK: - Images

    @Test func floatingImagesRoundTrip() throws {
        var sheet = Sheet(name: "Pictures")
        sheet.columnWidths = [1: 150]
        sheet.rowHeights = [2: 40]
        sheet.hiddenColumns = [3]
        let logo = Self.png(width: 300, height: 200)
        let photo = Self.png(width: 64, height: 64, seed: 9)
        sheet.objects = [
            SheetObject(anchor: ObjectAnchor(cell: Self.address("B3"), offsetX: 12, offsetY: 4, width: 300, height: 200), content: .image(logo),
                        title: "Logo", altDescription: "The company logo"),
            SheetObject(anchor: ObjectAnchor(cell: Self.address("A1"), width: 64, height: 64), content: .image(photo)),
            SheetObject(anchor: ObjectAnchor(cell: Self.address("E10"), offsetX: 1, offsetY: 2, width: 30, height: 20), content: .image(logo)),
        ]
        let package = try Self.write(Workbook(sheets: [sheet]))
        let archive = try ZipReader(data: package)
        // One file per distinct picture.
        #expect(archive.entries.map(\.path).filter { $0.hasPrefix("Pictures/") } == ["Pictures/image1.png", "Pictures/image2.png"])
        let manifest = try #require(try Self.part("META-INF/manifest.xml", of: package))
        #expect(manifest.contains("<manifest:file-entry manifest:full-path=\"Pictures/image1.png\" manifest:media-type=\"image/png\"/>"))
        let content = try #require(try Self.part("content.xml", of: package))
        // B3 starts 100 pixels across and 42 down; the logo ends 12 + 300 pixels further, 62 pixels into D (hidden, but
        // counted at its width), and 4 + 200 down, 17 pixels into row 11.
        #expect(content.contains("<draw:frame draw:z-index=\"0\" draw:name=\"Image 1\" draw:style-name=\"gr1\" svg:width=\"225pt\" svg:height=\"150pt\" svg:x=\"9pt\" svg:y=\"3pt\" table:end-cell-address=\"Pictures.D11\" table:end-x=\"46.5pt\" table:end-y=\"12.75pt\"><draw:image xlink:href=\"Pictures/image1.png\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\" draw:mime-type=\"image/png\"/><svg:title>Logo</svg:title><svg:desc>The company logo</svg:desc></draw:frame>"))
        #expect(content.contains("<style:style style:name=\"gr1\" style:family=\"graphic\"><style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\"/></style:style>"))

        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[0]
        #expect(read.objects.count == 3)
        for (original, copy) in zip(sheet.objects, read.objects) {
            #expect(copy.anchor == original.anchor)
            #expect(copy.content == original.content)
            #expect(copy.title == original.title && copy.altDescription == original.altDescription)
        }
    }

    @Test func inCellImagesRoundTrip() throws {
        var sheet = Sheet(name: "Cells")
        sheet.columnWidths = [0: 120]
        sheet.rowHeights = [0: 60]
        let wide = Self.png(width: 400, height: 100)
        sheet[0, 0] = Cell(image: CellImage(image: wide, altText: "A banner"))
        sheet[2, 1] = Cell(format: IOTest.format { $0.fillColor = RGBColor(hex: "FFEEDD") }, image: CellImage(image: Self.png(width: 10, height: 30)))
        sheet.merges = [Self.range("C5:D6")]
        sheet[4, 2] = Cell(image: CellImage(image: Self.png(width: 50, height: 50)))
        sheet.objects = [SheetObject(anchor: ObjectAnchor(cell: Self.address("A1"), width: 40, height: 40), content: .image(wide))]
        let package = try Self.write(Workbook(sheets: [sheet]))
        let content = try #require(try Self.part("content.xml", of: package))
        // Fitted inside A1 (120 × 60): 240 × 60 → 120 × 30 pixels, centered.
        #expect(content.contains("<table:table-cell><draw:frame draw:z-index=\"0\" draw:name=\"PuggleSheets in-cell image 1\" draw:style-name=\"gr1\" svg:width=\"90pt\" svg:height=\"22.5pt\" svg:x=\"0pt\" svg:y=\"11.25pt\" table:end-cell-address=\"Cells.B1\" table:end-x=\"0pt\" table:end-y=\"33.75pt\"><draw:image xlink:href=\"Pictures/image1.png\""))
        #expect(content.contains("<svg:desc>A banner</svg:desc>"))
        // The merged block C5:D6 is 200 × 42 pixels: the square image fits as 42 × 42.
        #expect(content.contains("draw:name=\"PuggleSheets in-cell image 3\" draw:style-name=\"gr1\" svg:width=\"31.5pt\" svg:height=\"31.5pt\" svg:x=\"59.25pt\" svg:y=\"0pt\""))

        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[0]
        #expect(read[0, 0] == sheet[0, 0])
        #expect(read[2, 1] == sheet[2, 1])
        #expect(read[4, 2] == sheet[4, 2])
        #expect(read.objects.count == 1 && read.objects[0].content == .image(wide))
    }

    @Test func readsImagesFromOtherApps() throws {
        let png = Self.png(width: 20, height: 10)
        let base64 = png.data.base64EncodedString()
        // Page-anchored pictures sit where they're drawn: hidden column B takes no room. A picture in a cell whose offset
        // passes the cell's edge belongs to a later cell.
        let body = """
            <table:table table:name="Sheet1">
            <table:shapes>
            <draw:frame draw:z-index="2" draw:name="Picture 1" svg:width="0.5in" svg:height="0.25in" svg:x="2.5in" svg:y="0.5in"><draw:image xlink:href="Pictures/pic.png"><text:p/></draw:image><svg:title>Pic</svg:title></draw:frame>
            <draw:frame draw:z-index="1" svg:width="1in" svg:height="1in" svg:x="0in" svg:y="0in"><draw:image><office:binary-data>\(base64)</office:binary-data></draw:image></draw:frame>
            <draw:frame draw:z-index="3" svg:width="1in" svg:height="1in" svg:x="0in" svg:y="0in"><draw:image xlink:href="Pictures/vector.svg" draw:mime-type="image/svg+xml"/></draw:frame>
            <draw:frame draw:z-index="4" svg:width="1in" svg:height="1in" svg:x="0in" svg:y="0in"><draw:text-box><text:p>Note</text:p></draw:text-box></draw:frame>
            <draw:custom-shape draw:z-index="5" svg:width="1in" svg:height="1in" svg:x="0in" svg:y="0in"/>
            </table:shapes>
            <table:table-column table:style-name="co1"/><table:table-column table:style-name="co1" table:visibility="collapse"/><table:table-column table:style-name="co1" table:number-columns-repeated="3"/>
            <table:table-row><table:table-cell/><table:table-cell><draw:frame draw:z-index="0" svg:width="0.25in" svg:height="0.25in" svg:x="1.25in" svg:y="0.0625in" table:end-cell-address="Sheet1.D2" table:end-x="0.5in" table:end-y="0.25in"><draw:image xlink:href="./Pictures/pic.png"/><svg:desc>In a cell</svg:desc></draw:frame></table:table-cell></table:table-row>
            </table:table>
            """
        let automatic = "<style:style style:name=\"co1\" style:family=\"table-column\"><style:table-column-properties style:column-width=\"1in\"/></style:style>"
        let package = try IOTestODS.package(content: IOTestODS.content(body, automaticStyles: automatic),
                                            extra: ["Pictures/pic.png": png.data, "Pictures/vector.svg": Data("<svg/>".utf8)])
        let file = try IOTestODS.read(package)
        #expect(file.warnings == [.images])
        let objects = file.workbook.sheets[0].objects
        #expect(objects.count == 3)
        // Back to front by z-index.
        #expect(objects.map(\.anchor) == [
            ObjectAnchor(cell: Self.address("C1"), offsetX: 24, offsetY: 6, width: 24, height: 24),
            ObjectAnchor(cell: Self.address("A1"), width: 96, height: 96),
            ObjectAnchor(cell: Self.address("D3"), offsetX: 48, offsetY: 6, width: 48, height: 24),
        ])
        #expect(objects[0].altDescription == "In a cell")
        #expect(objects[2].title == "Pic")
        #expect(objects.allSatisfy { $0.content == .image(png) })
    }

    // MARK: - Charts

    /// A chart of the data sheet with every option set.
    static func chart(_ kind: ChartSpec.Kind, ranges: [String] = ["Data!A1:D5"]) -> ChartSpec {
        var spec = ChartSpec(kind: kind, ranges: ranges, title: "Sales", subtitle: "By region", horizontalAxisTitle: "Region",
                             verticalAxisTitle: "Units", legend: .bottom)
        spec.backgroundColor = RGBColor(hex: "FFF8E1")
        spec.fontFamily = "Georgia"
        spec.showsGridlines = false
        switch kind {
        case .pie, .donut:
            spec.series = [ChartSeriesStyle(), ChartSeriesStyle(color: RGBColor(hex: "123456"))]
            spec.pieSliceLabel = .value
            spec.pieHole = 0.4
            spec.legend = .right
        case .line, .smoothLine:
            spec.series = [ChartSeriesStyle(color: RGBColor(hex: "AA0000"), lineWidth: 4, pointSize: 6), ChartSeriesStyle(showsDataLabels: true)]
            spec.verticalMinimum = 0
            spec.verticalMaximum = 20
            spec.logScale = true
        case .scatter:
            spec.series = [ChartSeriesStyle(pointSize: 10), ChartSeriesStyle(color: RGBColor(hex: "00AA00"), usesRightAxis: true)]
            spec.showsDataLabels = true
            spec.legend = .none
        case .combo:
            spec.series = [ChartSeriesStyle(), ChartSeriesStyle(type: .area, lineWidth: 1, usesRightAxis: true), ChartSeriesStyle(type: .column)]
            spec.aggregation = .average
            spec.legend = .inside
        case .area, .stackedArea, .percentArea:
            spec.series = [ChartSeriesStyle(lineWidth: 3), ChartSeriesStyle(color: RGBColor(hex: "0000AA"))]
            spec.legend = .top
        default:
            spec.series = [ChartSeriesStyle(color: RGBColor(hex: "880088"), showsDataLabels: true), ChartSeriesStyle(), ChartSeriesStyle(usesRightAxis: true)]
            spec.showsGridlines = true
            spec.legend = .left
        }
        return spec
    }

    static func chartWorkbook(_ specs: [ChartSpec], data: Sheet = Self.dataSheet()) -> Workbook {
        var report = Sheet(name: "Report")
        report.objects = specs.enumerated().map { index, spec in
            SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: index * 20, column: 1), offsetX: 3, offsetY: 2, width: 480, height: 300),
                        content: .chart(spec), title: "Chart \(index + 1)", altDescription: "About chart \(index + 1)")
        }
        return Workbook(sheets: [data, report])
    }

    @Test func chartsRoundTrip() throws {
        let specs = ChartSpec.Kind.allCases.map { Self.chart($0) }
        let workbook = Self.chartWorkbook(specs)
        let file = try Self.roundTrip(workbook)
        #expect(file.warnings.isEmpty)
        let objects = file.workbook.sheets[1].objects
        #expect(objects.count == specs.count)
        for (original, copy) in zip(workbook.sheets[1].objects, objects) {
            #expect(copy.anchor == original.anchor)
            #expect(copy.title == original.title && copy.altDescription == original.altDescription)
            #expect(copy.chart == original.chart, "\(original.chart!.kind)")
        }
    }

    @Test func chartsReadWithoutPuggleSettings() throws {
        // As LibreOffice saves it: the ranges are rebuilt from the series; only the aggregation and "auto" legend are lost.
        var specs = ChartSpec.Kind.allCases.map { Self.chart($0) }
        specs.append(ChartSpec(kind: .column, ranges: ["Data!B1:D5", "Data!A1:A5"], firstColumnIsLabels: false, switchRowsAndColumns: true))
        let workbook = Self.chartWorkbook(specs)
        let file = try SpreadsheetIO.read(try Self.withoutPuggleSettings(try Self.write(workbook)), format: .ods)
        #expect(file.warnings.isEmpty)
        for (original, copy) in zip(specs, file.workbook.sheets[1].objects.map { $0.chart! }) {
            var expected = original
            expected.aggregation = nil
            if expected.legend == .right { expected.legend = .auto }
            // Settings a kind doesn't use aren't in the file.
            if expected.kind == .pie || expected.kind == .donut {
                expected.horizontalAxisTitle = ""
                expected.verticalAxisTitle = ""
            }
            if expected.kind != .donut { expected.pieHole = 0.5 }
            #expect(copy == expected, "\(original.kind)")
        }
    }

    @Test func chartLayoutsReadWithoutPuggleSettings() throws {
        let specs = [
            ChartSpec(kind: .column, ranges: ["Data!A1:D5"], firstRowIsHeader: false),
            ChartSpec(kind: .line, ranges: ["Data!B1:D5"], firstColumnIsLabels: false),
            ChartSpec(kind: .column, ranges: ["Data!A1:A5", "Data!C1:D5"]),
            ChartSpec(kind: .bar, ranges: ["Data!A2:C5"], firstRowIsHeader: false, switchRowsAndColumns: true),
            ChartSpec(kind: .scatter, ranges: ["Data!B1:C5"]),
            ChartSpec(kind: .area, ranges: ["Data!A1:B5"], firstRowIsHeader: false, firstColumnIsLabels: false),
        ]
        let file = try SpreadsheetIO.read(try Self.withoutPuggleSettings(try Self.write(Self.chartWorkbook(specs))), format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[1].objects.map { $0.chart! } == specs)
    }

    @Test func chartRangesAsTyped() throws {
        var report = Sheet(name: "Report")
        report[0, 0] = Cell(value: .text("Own"))
        report[1, 0] = Cell(value: .number(3))
        let specs = [ChartSpec(ranges: ["Sales"]), ChartSpec(ranges: ["A1:A2"], firstColumnIsLabels: false), ChartSpec(ranges: ["Gone!A1:B2"])]
        report.objects = specs.map { SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 5, column: 2), width: 300, height: 200), content: .chart($0)) }
        let workbook = Workbook(sheets: [Self.dataSheet(), report], namedRanges: [NamedRange(name: "Sales", reference: "Data!$A$1:$D$5")])
        let package = try Self.write(workbook)
        let own = try #require(try Self.part("Object 2/content.xml", of: package))
        #expect(own.contains("chart:values-cell-range-address=\"Report.A2:Report.A2\" chart:label-cell-address=\"Report.A1:Report.A1\""))
        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[1].objects.map { $0.chart! } == specs)
        // As LibreOffice saves it: the named range becomes its cells, and a chart of nothing is left out.
        let saved = try SpreadsheetIO.read(try Self.withoutPuggleSettings(package), format: .ods)
        #expect(saved.warnings == [.charts])
        #expect(saved.workbook.sheets[1].objects.map { $0.chart!.ranges } == [["Data!A1:D5"], ["A1:A2"]])
    }

    @Test func chartLayout() throws {
        var data = Self.dataSheet()
        data.hiddenRows = [2]
        data.hiddenColumns = [2]
        let workbook = Workbook(sheets: [data, Sheet(name: "Report")])
        // Hidden rows stay inside a series' block (LibreOffice leaves them out itself); hidden columns are no series.
        let layout = try #require(ODSChartLayout(spec: ChartSpec(ranges: ["Data!A1:D5"]), sheetIndex: 1, workbook: workbook))
        #expect(layout.series.map(\.blocks) == [[ODSSheetRange(sheet: 0, range: Self.range("B2:B5"))], [ODSSheetRange(sheet: 0, range: Self.range("D2:D5"))]])
        #expect(layout.series.map { $0.name?.address } == [Self.address("B1"), Self.address("D1")])
        #expect(layout.series[0].cells.map(\.address) == [Self.address("B2"), Self.address("B4"), Self.address("B5")])
        #expect(layout.labelBlocks == [ODSSheetRange(sheet: 0, range: Self.range("A2:A5"))])

        // Switched: series run along rows, named by column A, labelled by row 1; ranges side by side.
        let switched = ChartSpec(ranges: ["Data!A1:B5", "Data!D1:D5"], switchRowsAndColumns: true)
        let rows = try #require(ODSChartLayout(spec: switched, sheetIndex: 1, workbook: workbook))
        #expect(rows.series.count == 3)
        #expect(rows.series[0].blocks == [ODSSheetRange(sheet: 0, range: Self.range("B2")), ODSSheetRange(sheet: 0, range: Self.range("D2"))])
        #expect(rows.series[0].name?.address == Self.address("A2"))
        #expect(rows.labelBlocks == [ODSSheetRange(sheet: 0, range: Self.range("B1")), ODSSheetRange(sheet: 0, range: Self.range("D1"))])

        let package = try Self.write(Self.chartWorkbook([switched]))
        let chart = try #require(try Self.part("Object 1/content.xml", of: package))
        #expect(chart.contains("table:cell-range-address=\"Data.A1:Data.B5 Data.D1:Data.D5\" chart:data-source-has-labels=\"both\""))
        #expect(chart.contains("chart:series-source=\"rows\""))
        #expect(chart.contains("chart:values-cell-range-address=\"Data.B2:Data.B2 Data.D2:Data.D2\" chart:label-cell-address=\"Data.A2:Data.A2\" chart:class=\"chart:bar\">"))
    }

    @Test func chartsOfWholeColumns() throws {
        // Whole columns of a tall sheet: the blocks reach the sheet's end, the local table stops at the data.
        var data = Self.dataSheet()
        data.rowCount = 1_000_000
        let spec = ChartSpec(kind: .line, ranges: ["Data!A:C"])
        let workbook = Workbook(sheets: [data, Sheet(name: "Report")])
        let clock = ContinuousClock()
        var package = Data()
        let duration = try clock.measure { package = try Self.write(Self.chartWorkbook([spec], data: data)) }
        #expect(duration < .seconds(10))
        let chart = try #require(try Self.part("Object 1/content.xml", of: package))
        #expect(chart.contains("chart:values-cell-range-address=\"Data.B2:Data.B1000000\" chart:label-cell-address=\"Data.B1:Data.B1\""))
        #expect(chart.contains("<chart:categories table:cell-range-address=\"Data.A2:Data.A1000000\"/>"))
        #expect(chart.components(separatedBy: "<table:table-row>").count == 6)
        let layout = try #require(ODSChartLayout(spec: spec, sheetIndex: 1, workbook: workbook))
        #expect(layout.series.map(\.cells.count) == [4, 4])
        let file = try SpreadsheetIO.read(try Self.withoutPuggleSettings(package), format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[1].objects.first?.chart?.ranges == ["Data!A1:C1000000"])
    }

    @Test func chartObjectParts() throws {
        let package = try Self.write(Self.chartWorkbook([Self.chart(.column), Self.chart(.pie)]))
        let zip = try ZipReader(data: package)
        let paths = zip.entries.map(\.path)
        for part in ["Object 1/content.xml", "Object 1/styles.xml", "Object 1/meta.xml", "Object 2/content.xml"] { #expect(paths.contains(part)) }
        let manifest = try #require(try Self.part("META-INF/manifest.xml", of: package))
        #expect(manifest.contains("<manifest:file-entry manifest:full-path=\"Object 1/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.chart\"/>"))
        #expect(manifest.contains("<manifest:file-entry manifest:full-path=\"Object 2/content.xml\" manifest:media-type=\"text/xml\"/>"))
        let content = try #require(try Self.part("content.xml", of: package))
        #expect(content.contains("<draw:object draw:notify-on-update-of-ranges=\"Data.A1:Data.D5\" xlink:href=\"./Object 1\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>"))
        let column = try #require(try Self.part("Object 1/content.xml", of: package))
        #expect(column.contains("chart:class=\"chart:bar\""))
        #expect(column.contains("<chart:categories table:cell-range-address=\"Data.A2:Data.A5\"/>"))
        #expect(column.contains("chart:values-cell-range-address=\"Data.B2:Data.B5\" chart:label-cell-address=\"Data.B1:Data.B1\""))
        #expect(column.contains("chart:attached-axis=\"secondary-y\""))
        #expect(column.contains("<chart:legend chart:legend-position=\"start\""))
        // The local table holds the values.
        #expect(column.contains("<table:table table:name=\"local-table\">"))
        #expect(column.contains("<table:table-cell office:value-type=\"string\"><text:p>North</text:p></table:table-cell><table:table-cell office:value-type=\"float\" office:value=\"10\"><text:p>10</text:p></table:table-cell>"))
        let pie = try #require(try Self.part("Object 2/content.xml", of: package))
        // A pie shows its first series, each slice colored from the default palette unless set.
        #expect(pie.components(separatedBy: "<chart:series ").count == 2)
        #expect(pie.components(separatedBy: "<chart:data-point ").count == 5)
        #expect(pie.contains("draw:fill-color=\"#123456\""))
        #expect(pie.contains("draw:fill-color=\"#fbbc04\""))
        #expect(pie.contains("chart:data-label-number=\"value\""))
    }

    @Test func readsLibreOfficeCharts() throws {
        // A LibreOffice combined chart: series in rows, in their own order, one on a secondary axis.
        let combined = """
            <chart:chart svg:width="16cm" svg:height="9cm" xlink:href=".." xlink:type="simple" chart:class="chart:bar" chart:style-name="ch1">
            <chart:title chart:style-name="ch2"><text:p>It is a Maintitle</text:p></chart:title>
            <chart:legend chart:legend-position="bottom" style:legend-expansion="high"/>
            <chart:plot-area chart:style-name="ch3" table:cell-range-address="Sheet1.B1:Sheet1.E4 Sheet1.A5:Sheet1.E5 Sheet1.A2:Sheet1.A4" chart:data-source-has-labels="both">
            <chart:axis chart:dimension="x" chart:name="primary-x"><chart:categories table:cell-range-address="Sheet1.B1:Sheet1.E1"/></chart:axis>
            <chart:axis chart:dimension="y" chart:name="primary-y" chart:style-name="ch5"><chart:grid chart:class="major"/></chart:axis>
            <chart:axis chart:dimension="y" chart:name="secondary-y"/>
            <chart:series chart:attached-axis="secondary-y" chart:style-name="ch8" chart:values-cell-range-address="Sheet1.B5:Sheet1.E5" chart:label-cell-address="Sheet1.A5:Sheet1.A5" chart:class="chart:bar"><chart:data-point chart:repeated="4"/></chart:series>
            <chart:series chart:attached-axis="primary-y" chart:style-name="ch9" chart:values-cell-range-address="Sheet1.B2:Sheet1.E2" chart:label-cell-address="Sheet1.A2:Sheet1.A2" chart:class="chart:line"/>
            <chart:series chart:attached-axis="primary-y" chart:style-name="ch10" chart:values-cell-range-address="Sheet1.B3:Sheet1.E3" chart:label-cell-address="Sheet1.A3:Sheet1.A3" chart:class="chart:line"/>
            <chart:wall/></chart:plot-area></chart:chart>
            """
        let combinedStyles = """
            <style:style style:name="ch1" style:family="chart"><style:graphic-properties draw:stroke="none"/></style:style>
            <style:style style:name="ch2" style:family="chart"><style:text-properties fo:font-family="Arial" fo:font-size="13pt"/></style:style>
            <style:style style:name="ch3" style:family="chart"><style:chart-properties chart:include-hidden-cells="false" chart:series-source="rows"/></style:style>
            <style:style style:name="ch5" style:family="chart"><style:chart-properties chart:minimum="-5" chart:logarithmic="false"/></style:style>
            <style:style style:name="ch8" style:family="chart"><style:graphic-properties draw:fill-color="#579d1c"/></style:style>
            <style:style style:name="ch9" style:family="chart"><style:chart-properties chart:symbol-type="none"/><style:graphic-properties svg:stroke-color="#004586" draw:fill-color="#004586"/></style:style>
            <style:style style:name="ch10" style:family="chart"><style:chart-properties chart:symbol-type="named-symbol" chart:symbol-name="square" chart:symbol-width="0.25cm" chart:symbol-height="0.25cm"/><style:graphic-properties svg:stroke-width="0.08cm" svg:stroke-color="#ff420e" draw:fill-color="#ff420e"/></style:style>
            """
        // A scatter chart: x values in the first series' domain.
        let scatter = """
            <chart:chart svg:width="16cm" svg:height="9cm" xlink:href=".." xlink:type="simple" chart:class="chart:scatter">
            <chart:plot-area chart:style-name="sc" table:cell-range-address="Sheet1.A2:Sheet1.B4 Sheet1.B1:Sheet1.B1" chart:data-source-has-labels="row">
            <chart:axis chart:dimension="x" chart:name="primary-x"/><chart:axis chart:dimension="y" chart:name="primary-y"/>
            <chart:series chart:values-cell-range-address="Sheet1.B2:Sheet1.B4" chart:label-cell-address="Sheet1.B1:Sheet1.B1" chart:class="chart:scatter"><chart:domain table:cell-range-address="Sheet1.A2:Sheet1.A4"/></chart:series>
            </chart:plot-area></chart:chart>
            """
        // A pie of a selection with labels in the first column only, its slices colored.
        let pie = """
            <chart:chart svg:width="16cm" svg:height="9cm" xlink:href=".." xlink:type="simple" chart:class="chart:circle">
            <chart:legend chart:legend-position="end" loext:overlay="true"/>
            <chart:plot-area table:cell-range-address="Sheet1.A2:Sheet1.B4" chart:data-source-has-labels="column">
            <chart:axis chart:dimension="x" chart:name="primary-x"><chart:categories table:cell-range-address="Sheet1.A2:Sheet1.A4"/></chart:axis>
            <chart:series chart:style-name="pie" chart:values-cell-range-address="Sheet1.B2:Sheet1.B4" chart:class="chart:circle"><chart:data-point chart:style-name="p1"/><chart:data-point chart:style-name="p2" chart:repeated="2"/></chart:series>
            </chart:plot-area></chart:chart>
            """
        let pieStyles = """
            <style:style style:name="pie" style:family="chart"><style:chart-properties chart:data-label-number="percentage"/></style:style>
            <style:style style:name="p1" style:family="chart"><style:graphic-properties draw:fill-color="#004586"/></style:style>
            <style:style style:name="p2" style:family="chart"><style:graphic-properties draw:fill-color="#ea4335"/></style:style>
            """
        // A chart with its own data (pasted from Writer) isn't linked to cells.
        let own = """
            <chart:chart xlink:href="." chart:class="chart:bar"><chart:plot-area><chart:series chart:values-cell-range-address="local-table.B2:.B4"/></chart:plot-area></chart:chart>
            """
        func object(_ chart: String, styles: String = "") -> Data {
            Data((IOTestODS.declaration + "<office:document-content \(ODSChartWriter.namespaces) office:version=\"1.2\">"
                + "<office:automatic-styles>\(styles)</office:automatic-styles><office:body><office:chart>\(chart)</office:chart></office:body></office:document-content>").utf8)
        }
        var rows = ""
        let values = [["", "2004", "2005", "2007", "2008"], ["a", "5", "7", "3", "1"], ["b", "3", "-2", "4", "0"], ["c", "1", "5", "5", "1"], ["d", "6", "1", "-5", "7"]]
        for row in values {
            rows += "<table:table-row>" + row.map { text in
                Double(text) != nil ? IOODSTests.float(text) : (text.isEmpty ? "<table:table-cell/>" : IOODSTests.text(text))
            }.joined() + "</table:table-row>"
        }
        func frame(_ object: String) -> String {
            "<draw:frame draw:z-index=\"0\" svg:width=\"16cm\" svg:height=\"9cm\" svg:x=\"1mm\" svg:y=\"28.87mm\"><draw:object xlink:href=\"./\(object)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/><draw:image xlink:href=\"./ObjectReplacements/\(object)\"/></draw:frame>"
        }
        let body = "<table:table table:name=\"Sheet1\"><table:shapes>\(frame("Object 1"))\(frame("Object 2"))\(frame("Object 3"))\(frame("Object 4"))</table:shapes>\(rows)</table:table>"
        let package = try IOTestODS.package(content: IOTestODS.content(body), extra: [
            "Object 1/content.xml": object(combined, styles: combinedStyles), "Object 2/content.xml": object(scatter),
            "Object 3/content.xml": object(pie, styles: pieStyles), "Object 4/content.xml": object(own),
        ])
        let file = try IOTestODS.read(package)
        // The combined chart's series order can't be laid out by rows of a range; the chart with its own data is left out.
        #expect(file.warnings == [.charts])
        let charts = file.workbook.sheets[0].objects.compactMap(\.chart)
        #expect(charts.count == 3)

        let combo = charts[0]
        #expect(combo.kind == .combo)
        #expect(combo.title == "It is a Maintitle" && combo.fontFamily == "Arial")
        #expect(combo.legend == .bottom)
        #expect(combo.switchRowsAndColumns && combo.firstRowIsHeader && combo.firstColumnIsLabels)
        #expect(combo.verticalMinimum == -5 && combo.showsGridlines)
        #expect(combo.series.count == 3)
        #expect(combo.series[0] == ChartSeriesStyle(color: RGBColor(hex: "579D1C"), usesRightAxis: true))
        #expect(combo.series[1] == ChartSeriesStyle(color: RGBColor(hex: "004586")))
        #expect(combo.series[2] == ChartSeriesStyle(color: RGBColor(hex: "FF420E"), lineWidth: 3, pointSize: 9.5))

        let xy = charts[1]
        #expect(xy.kind == .scatter)
        #expect(xy.ranges == ["A1:B4"] && xy.firstRowIsHeader && xy.firstColumnIsLabels && !xy.switchRowsAndColumns)
        #expect(xy.legend == .none)

        let circle = charts[2]
        #expect(circle.kind == .pie)
        #expect(circle.ranges == ["A2:B4"] && !circle.firstRowIsHeader && circle.firstColumnIsLabels)
        #expect(circle.legend == .inside)
        #expect(circle.pieSliceLabel == .percentage)
        #expect(circle.series == [ChartSeriesStyle(color: RGBColor(hex: "004586")), ChartSeriesStyle(), ChartSeriesStyle(color: RGBColor(hex: "EA4335"))])
    }

    // MARK: - Pivot tables

    static func pivotWorkbook() -> Workbook {
        var data = Self.dataSheet()
        data[5, 0] = Cell(value: .text("North"))
        data[5, 1] = Cell(value: .number(2))
        data[5, 2] = Cell(value: .text("n/a"))
        data[5, 3] = Cell(value: .number(1))
        var report = Sheet(name: "Report")
        report[0, 4] = Cell(value: .text("Notes"))
        let pivot = PivotTable(anchor: Self.address("A2"), source: "Data!A1:D6",
                               rows: [PivotGroup(sourceColumn: 0, ascending: false, showsTotals: true, sortByValue: 1)],
                               columns: [PivotGroup(sourceColumn: 3, showsTotals: false)],
                               values: [PivotValue(sourceColumn: 1, summary: .sum), PivotValue(sourceColumn: 2, summary: .count, showAs: .percentOfColumn, name: "Numbers in Q2"),
                                        PivotValue(sourceColumn: 2, summary: .countA)],
                               filters: [PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["West"])),
                                         PivotFilter(sourceColumn: 1, criterion: FilterCriterion(condition: CellCondition(.greaterThan, ["3"]))),
                                         PivotFilter(sourceColumn: 2, criterion: FilterCriterion(hiddenValues: ["n/a"]))],
                               valuesInRows: true)
        report.pivotTables = [pivot]
        report.spillRanges = [pivot.anchor: Self.range("A2:C4")]
        report.spilledValues = [Self.address("A2"): .text("Region"), Self.address("B2"): .text("SUM of Q1"),
                                Self.address("A3"): .text("North"), Self.address("B3"): .number(12)]
        return Workbook(sheets: [data, report])
    }

    @Test func pivotTablesRoundTrip() throws {
        let workbook = Self.pivotWorkbook()
        let package = try Self.write(workbook)
        let content = try #require(try Self.part("content.xml", of: package))
        #expect(content.contains("<table:data-pilot-table table:name=\"Pivot table 1\" table:target-range-address=\"Report.A2:Report.C4\" table:grand-total=\"column\" table:show-filter-button=\"false\">"))
        #expect(content.contains("<table:source-cell-range table:cell-range-address=\"Data.A1:Data.D6\"><table:filter><table:filter-condition table:field-number=\"1\" table:value=\"3\" table:operator=\"&gt;\" table:data-type=\"number\"/></table:filter></table:source-cell-range>"))
        // COUNT counts numbers ("countnums"); COUNTA counts everything ("count").
        #expect(content.contains("table:source-field-name=\"Q2\" tableooo:display-name=\"Numbers in Q2\" table:orientation=\"data\" table:used-hierarchy=\"0\" table:function=\"countnums\"><table:data-pilot-field-reference table:field-name=\"Q2\" table:member-type=\"named\" table:member-name=\"\" table:type=\"column-percentage\"/>"))
        #expect(content.contains("table:source-field-name=\"Q2\" table:orientation=\"data\" table:used-hierarchy=\"0\" table:function=\"count\">"))
        #expect(content.contains("<table:data-pilot-field table:source-field-name=\"\" table:is-data-layout-field=\"true\" table:orientation=\"row\""))
        #expect(content.contains("<table:data-pilot-member table:name=\"West\" table:display=\"false\" table:show-details=\"true\"/>"))
        #expect(content.contains("<table:data-pilot-sort-info table:data-field=\"Q2\" table:sort-mode=\"data\" table:order=\"descending\"/>"))
        #expect(content.contains("table:orientation=\"page\" table:selected-page=\"12\" loext:ignore-selected-page=\"true\""))
        // The results are written as values, so LibreOffice shows them before refreshing.
        #expect(content.contains("<text:p>SUM of Q1</text:p>"))

        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let report = file.workbook.sheets[1]
        #expect(report.pivotTables == workbook.sheets[1].pivotTables)
        // The engine recomputes the results: the target range is cleared, the rest of the sheet kept.
        #expect(report.cells(in: Self.range("A2:C4")).isEmpty)
        #expect(report[0, 4].value == .text("Notes"))
    }

    @Test func pivotTablesReadWithoutPuggleSettings() throws {
        let workbook = Self.pivotWorkbook()
        let file = try SpreadsheetIO.read(try Self.withoutPuggleSettings(try Self.write(workbook)), format: .ods)
        #expect(file.warnings.isEmpty)
        let pivot = try #require(file.workbook.sheets[1].pivotTables.first)
        let original = workbook.sheets[1].pivotTables[0]
        #expect(pivot.anchor == original.anchor && pivot.source == original.source)
        #expect(pivot.rows == original.rows && pivot.columns == original.columns)
        #expect(pivot.values == original.values)
        #expect(pivot.valuesInRows)
        #expect(Set(pivot.filters.map(\.sourceColumn)) == [0, 1, 2])
        #expect(pivot.filters.first { $0.sourceColumn == 0 }?.criterion == FilterCriterion(hiddenValues: ["West"]))
        #expect(pivot.filters.first { $0.sourceColumn == 1 }?.criterion == FilterCriterion(condition: CellCondition(.greaterThan, ["3"])))
        #expect(pivot.filters.first { $0.sourceColumn == 2 }?.criterion == FilterCriterion(hiddenValues: ["n/a"]))

        // COUNTUNIQUE has no DataPilot function: LibreOffice counts instead.
        var unique = workbook
        unique.sheets[1].pivotTables[0].values = [PivotValue(sourceColumn: 0, summary: .countUnique)]
        let counted = try SpreadsheetIO.read(try Self.withoutPuggleSettings(try Self.write(unique)), format: .ods)
        #expect(counted.workbook.sheets[1].pivotTables.first?.values == [PivotValue(sourceColumn: 0, summary: .countA)])
        #expect(try Self.roundTrip(unique).workbook.sheets[1].pivotTables.first?.values == [PivotValue(sourceColumn: 0, summary: .countUnique)])
    }

    @Test func readsLibreOfficeDataPilot() throws {
        // Laid out like LibreOffice 5.4's: a data layout field, members, display names, no grand totals, a page field.
        var rows = "<table:table-row>\(IOODSTests.text("Group Segment"))\(IOODSTests.text("Expenses"))\(IOODSTests.text("Revenue"))\(IOODSTests.text(""))</table:table-row>"
        for (index, segment) in ["Big", "Medium", "Small", "Big"].enumerated() {
            rows += "<table:table-row>\(IOODSTests.text(segment))\(IOODSTests.float(String(index * 10 + 5)))\(IOODSTests.float(String(index * 20 + 7)))\(IOODSTests.text("x"))</table:table-row>"
        }
        let body = """
            <table:table table:name="Sheet 1">\(rows)</table:table>
            <table:table table:name="Sheet Pivot Table"><table:table-row>\(IOODSTests.text("old result"))\(IOODSTests.text("kept"))</table:table-row></table:table>
            <table:data-pilot-tables>
            <table:data-pilot-table table:name="DataPilot1" table:application-data="" table:target-range-address="'Sheet Pivot Table'.A1:'Sheet Pivot Table'.A3" table:buttons="'Sheet Pivot Table'.A2" table:grand-total="none" table:show-filter-button="false" table:drill-down-on-double-click="false">
            <table:source-cell-range table:cell-range-address="'Sheet 1'.A1:'Sheet 1'.D5"/>
            <table:data-pilot-field table:source-field-name="" table:is-data-layout-field="true" table:orientation="column" table:used-hierarchy="-1" table:function="auto"><table:data-pilot-level table:show-empty="true" calcext:repeat-item-labels="false"/></table:data-pilot-field>
            <table:data-pilot-field table:source-field-name="Group Segment" table:orientation="row" table:used-hierarchy="0" table:function="auto">
            <table:data-pilot-level table:show-empty="false" calcext:repeat-item-labels="false"><table:data-pilot-members>
            <table:data-pilot-member table:name="Big" table:display="true" table:show-details="true"/><table:data-pilot-member table:name="Medium" table:display="false" table:show-details="true"/><table:data-pilot-member table:name="Small" table:display="true" table:show-details="true"/>
            </table:data-pilot-members><table:data-pilot-display-info table:enabled="false" table:display-member-mode="from-top" table:member-count="0" table:data-field=""/>
            <table:data-pilot-sort-info table:order="ascending" table:sort-mode="name"/><table:data-pilot-layout-info table:add-empty-lines="false" table:layout-mode="tabular-layout"/></table:data-pilot-level></table:data-pilot-field>
            <table:data-pilot-field table:source-field-name="Expenses" tableooo:display-name="Exp." table:orientation="data" table:used-hierarchy="0" table:function="sum"/>
            <table:data-pilot-field table:source-field-name="Revenue" table:orientation="data" table:used-hierarchy="0" table:function="average"/>
            <table:data-pilot-field table:source-field-name="Column D" table:orientation="page" table:selected-page="x" table:used-hierarchy="0" table:function="auto"/>
            <table:data-pilot-field table:source-field-name="Revenue" table:orientation="hidden" table:used-hierarchy="0" table:function="auto"/>
            </table:data-pilot-table>
            <table:data-pilot-table table:name="DataPilot2" table:target-range-address="'Sheet Pivot Table'.E1:'Sheet Pivot Table'.F3">
            <table:database-source-table table:database-name="db" table:database-table-name="t"/>
            <table:data-pilot-field table:source-field-name="a" table:orientation="row"/>
            </table:data-pilot-table>
            </table:data-pilot-tables>
            """
        let file = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(body)))
        // The database source can't be kept.
        #expect(file.warnings == [.pivotTables])
        let sheet = file.workbook.sheets[1]
        #expect(sheet.pivotTables.count == 1)
        let pivot = try #require(sheet.pivotTables.first)
        #expect(pivot.anchor == Self.address("A1") && pivot.source == "'Sheet 1'!A1:D5")
        #expect(pivot.rows == [PivotGroup(sourceColumn: 0, ascending: true, showsTotals: false)])
        #expect(pivot.columns.isEmpty && !pivot.valuesInRows)
        #expect(pivot.values == [PivotValue(sourceColumn: 1, summary: .sum, name: "Exp."), PivotValue(sourceColumn: 2, summary: .average)])
        #expect(pivot.filters == [PivotFilter(sourceColumn: 3, criterion: FilterCriterion()), PivotFilter(sourceColumn: 0, criterion: FilterCriterion(hiddenValues: ["Medium"]))])
        #expect(sheet.cells(in: Self.range("A1:A3")).isEmpty)
        #expect(sheet[0, 1].value == .text("kept"))

        // Grouped fields can't be kept: a warning, and the pivot table without them.
        let grouped = body.replacingOccurrences(of: "<table:data-pilot-field table:source-field-name=\"Revenue\" table:orientation=\"hidden\" table:used-hierarchy=\"0\" table:function=\"auto\"/>",
                                                with: "<table:data-pilot-field table:source-field-name=\"Revenue2\" table:orientation=\"row\"><table:data-pilot-groups table:source-field-name=\"Revenue\" table:start=\"auto\" table:end=\"auto\" table:step=\"10\"/></table:data-pilot-field>")
        let groupedFile = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(grouped)))
        #expect(groupedFile.warnings == [.pivotTables])
        #expect(groupedFile.workbook.sheets[1].pivotTables.first?.rows.count == 1)
    }

    @Test func pivotFieldNames() {
        var sheet = Sheet(name: "S")
        sheet[0, 0] = Cell(value: .text("Name"))
        sheet[0, 2] = Cell(value: .text("name"))
        sheet[0, 3] = Cell(value: .number(2024))
        sheet[0, 4] = Cell(value: .text("Name"))
        #expect(ODSPivotTables.fieldNames(sheet: sheet, range: Self.range("A1:E3")) == ["Name", "Column B", "name2", "2024", "Name3"])
    }

    // MARK: - Filter views

    @Test func filterViewsRoundTrip() throws {
        var sheet = IOXLSXRulesTests.salesSheet()
        sheet.name = "Q1 2026"
        sheet.filterViews = [
            FilterView(name: "Cheap fruit", range: Self.range("A1:C6"), criteria: [
                2: FilterCriterion(condition: CellCondition(.lessThan, ["2"])),
                0: FilterCriterion(hiddenValues: ["Kiwis", ""]),
            ]),
            FilterView(name: "Custom", range: Self.range("A1:C6"), criteria: [1: FilterCriterion(condition: CellCondition(.customFormula, ["=B2>A$1"]))]),
            FilterView(name: "Everything", range: Self.range("A1:C20")),
        ]
        let package = try Self.write(Workbook(sheets: [Sheet(name: "First"), sheet]))
        let settings = try #require(try Self.part("settings.xml", of: package))
        #expect(settings.contains("<config:config-item-set config:name=\"PuggleSheets:settings\">"))
        #expect(settings.contains("<config:config-item config:name=\"Name\" config:type=\"string\">Cheap fruit</config:config-item>"))
        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[1].filterViews == sheet.filterViews)
        #expect(file.workbook.sheets[0].filterViews.isEmpty)
        // LibreOffice drops PuggleSheets' settings when it saves: the views go, nothing else.
        let saved = try SpreadsheetIO.read(try Self.withoutPuggleSettings(package), format: .ods)
        #expect(saved.workbook.sheets[1].filterViews.isEmpty && saved.warnings.isEmpty)
    }

    // MARK: - Everything together

    static func everythingWorkbook() -> Workbook {
        var workbook = Self.pivotWorkbook()
        workbook.sheets[1].objects = Self.chartWorkbook(ChartSpec.Kind.allCases.map { Self.chart($0) }).sheets[1].objects
            + [SheetObject(anchor: ObjectAnchor(cell: Self.address("H2"), width: 30, height: 30), content: .image(Self.png(width: 3, height: 3)))]
        workbook.sheets[0][9, 0] = Cell(value: .text("Link"), link: "https://example.com")
        workbook.sheets[0][10, 0] = Cell(image: CellImage(image: Self.png(width: 3, height: 4)))
        workbook.sheets[0][11, 0] = Cell(value: .text("Back"), link: LinkTarget.sheet(workbook.sheets[1].id, Self.range("A1:B2")).link)
        workbook.sheets[0].filterViews = [FilterView(name: "View", range: Self.range("A1:D6"), criteria: [0: FilterCriterion(hiddenValues: ["West"])])]
        return workbook
    }

    @Test func survivesDamagedObjects() throws {
        let package = try Self.write(Self.everythingWorkbook())
        let zip = try ZipReader(data: package)
        var parts: [String: Data] = [:]
        for entry in zip.entries { parts[entry.path] = try zip.read(entry) }
        let targets = ["content.xml", "Object 1/content.xml", "Object 5/content.xml", "Object 13/content.xml", "settings.xml"]
        let fragments = ["<draw:frame svg:x=\"1e300in\" svg:width=\"-5in\">", "</draw:frame>", "chart:class=\"chart:stock\"", "table:orientation=\"page\"",
                         "<chart:series chart:values-cell-range-address=\"Nowhere.A1:Nowhere.Z99\"/>", "xlink:href=\"#'\"", "table:field-number=\"99\"",
                         "<table:data-pilot-field table:source-field-name=\"Q9\" table:orientation=\"row\"/>", "config:type=\"int\">-7<"]
        var random = IOTestRandom(seed: 2718)
        var readable = 0
        for _ in 0..<200 {
            var damaged = parts
            let target = targets[Int(random.next() % UInt64(targets.count))]
            var scalars = Array(String(decoding: parts[target] ?? Data(), as: UTF8.self).unicodeScalars)
            for _ in 0..<(1 + Int(random.next() % 4)) {
                let position = Int(random.next() % UInt64(scalars.count + 1))
                switch random.next() % 3 {
                case 0: scalars.removeSubrange(position..<min(scalars.count, position + Int(random.next() % 60)))
                case 1: scalars.insert(contentsOf: fragments[Int(random.next() % UInt64(fragments.count))].unicodeScalars, at: position)
                default:
                    let end = min(scalars.count, position + Int(random.next() % 120))
                    scalars.insert(contentsOf: scalars[position..<end], at: position)
                }
            }
            damaged[target] = Data(String(String.UnicodeScalarView(scalars)).utf8)
            var writer = ZipWriter()
            for entry in zip.entries { try writer.add(entry.path, damaged[entry.path] ?? Data(), compress: entry.path != "mimetype") }
            do {
                let file = try SpreadsheetIO.read(try writer.finish(), format: .ods)
                readable += 1
                #expect(!file.workbook.sheets.isEmpty)
            } catch let error as SpreadsheetIOError {
                #expect(!(error.errorDescription ?? "").isEmpty)
            }
        }
        #expect(readable > 0)
    }

    @Test func everythingIsWellFormed() throws {
        let workbook = Self.everythingWorkbook()
        let package = try Self.write(workbook)
        let zip = try ZipReader(data: package)
        for entry in zip.entries where entry.path.hasSuffix(".xml") {
            #expect(IOTestPackage.isWellFormed(try zip.read(entry)), "\(entry.path)")
        }
        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[1].objects.count == ChartSpec.Kind.allCases.count + 1)
        #expect(file.workbook.sheets[0][10, 0].image != nil)
        #expect(file.workbook.sheets[0][11, 0].link == LinkTarget.sheet(file.workbook.sheets[1].id, Self.range("A1:B2")).link)
        #expect(file.workbook.sheets[0].filterViews == workbook.sheets[0].filterViews)
        #expect(file.workbook.sheets[1].pivotTables == workbook.sheets[1].pivotTables)
    }
}
