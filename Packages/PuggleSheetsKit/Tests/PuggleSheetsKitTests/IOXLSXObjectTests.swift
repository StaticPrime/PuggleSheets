import Foundation
import Testing
@testable import PuggleSheetsKit

/// Package checks shared by the object, chart and pivot table tests.
enum IOXLSXPackageCheck {
    /// Every part is well-formed and has a content type; every relationship points at a part that
    /// exists (or is external); relationship ids are unique within each part; shape ids are unique in
    /// each drawing (except Excel's stand-in shapes for slicers, which all have id 0). Returns the problems found.
    static func problems(_ data: Data) throws -> [String] {
        let zip = try ZipReader(data: data)
        let paths = Set(zip.entries.map(\.path))
        var problems: [String] = []
        guard let types = try zip.read("[Content_Types].xml").map({ String(decoding: $0, as: UTF8.self) }) else { return ["no content types"] }
        func captures(_ pattern: String, in text: String) -> [[String]] {
            let expression = try! NSRegularExpression(pattern: pattern)
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                (1..<match.numberOfRanges).map { String(text[Range(match.range(at: $0), in: text)!]) }
            }
        }
        let defaults = Set(captures("<Default Extension=\"([^\"]+)\"", in: types).map { $0[0] })
        let overrides = Set(captures("<Override PartName=\"([^\"]+)\"", in: types).map { $0[0] })
        for override in overrides where !paths.contains(String(override.dropFirst())) { problems.append("override for missing \(override)") }
        for path in paths where path != "[Content_Types].xml" {
            let fileExtension = String(path.split(separator: ".").last ?? "")
            if !overrides.contains("/" + path) && !defaults.contains(fileExtension) { problems.append("no content type for \(path)") }
            if path.hasSuffix(".xml") || path.hasSuffix(".rels") {
                if !IOTestPackage.isWellFormed(try zip.read(path) ?? Data()) { problems.append("malformed \(path)") }
            }
            guard path.hasSuffix(".rels") else { continue }
            let text = String(decoding: try zip.read(path) ?? Data(), as: UTF8.self)
            var ids = Set<String>()
            let source = path == "_rels/.rels" ? "" : path.replacingOccurrences(of: "_rels/", with: "").replacingOccurrences(of: ".rels", with: "")
            for relationship in try XLSXPackage.relationships(of: source, in: zip) {
                if !ids.insert(relationship.id).inserted { problems.append("duplicate \(relationship.id) in \(path)") }
                if !relationship.isExternal && !paths.contains(relationship.target) { problems.append("\(path) → missing \(relationship.target)") }
            }
            _ = text
        }
        for path in paths where path.hasPrefix("xl/drawings/") && path.hasSuffix(".xml") {
            let text = String(decoding: try zip.read(path) ?? Data(), as: UTF8.self)
            let ids = captures("<xdr:cNvPr id=\"([0-9]+)\"", in: text).map { $0[0] }.filter { $0 != "0" }
            if Set(ids).count != ids.count { problems.append("duplicate shape ids in \(path)") }
        }
        return problems
    }
}

/// Images, in-cell images, links and filter views in Excel files.
struct IOXLSXObjectTests {
    /// A 4 × 2 PNG, a 2 × 6 PNG, a 4 × 2 JPEG and a 2 × 6 GIF.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEElEQVR4nGNwav0CRwzIHACugg3ZRMW1BQAAAABJRU5ErkJggg==")!
    static let tallPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAGCAIAAABmRdhlAAAAEElEQVR4nGN45WwKRAyEKQBlLRCZE5ITmQAAAABJRU5ErkJggg==")!
    static let gif = Data(base64Encoded: "R0lGODdhAgAGAJEAAAAAAOpDNf///wAAACH5BAQAAAAALAAAAAACAAYAAAIDjI9WADs=")!
    static let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAABKADAAQAAAABAAAAAgAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAgAEAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8Ar0UUV/oYfymf/9k=")!

    static func image(_ data: Data) -> ImageData { ImageData(data: data)! }

    static func roundTrip(_ workbook: Workbook, activeSheet: Int = 0) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(try SpreadsheetIO.write(workbook, activeSheet: activeSheet, format: .xlsx), format: .xlsx)
    }

    static func part(_ path: String, of workbook: Workbook) throws -> String {
        try IOTestPackage.part(path, of: try SpreadsheetIO.write(workbook, activeSheet: 0, format: .xlsx)) ?? ""
    }

    // MARK: - Floating images

    static func picturesSheet() -> Sheet {
        var sheet = Sheet(name: "Pictures")
        sheet[0, 0] = Cell(value: .text("Logo below"))
        sheet.columnWidths = [1: 150, 3: 40]
        sheet.hiddenColumns = [2]
        sheet.rowHeights = [2: 60]
        sheet.objects = [
            SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 1, column: 1), offsetX: 10, offsetY: 5, width: 300, height: 120),
                        content: .image(image(png)), title: "Logo", altDescription: "The company logo"),
            SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 10, column: 0), width: 20, height: 60), content: .image(image(jpeg))),
            SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 4, column: 5), offsetX: 2.5, offsetY: 7, width: 64.5, height: 33),
                        content: .image(image(gif)), title: "Animation", altDescription: ""),
            // The same image twice is stored once.
            SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 20, column: 3), width: 8, height: 4), content: .image(image(png))),
        ]
        return sheet
    }

    @Test func imagesRoundTrip() throws {
        let original = Self.picturesSheet()
        let file = try Self.roundTrip(Workbook(sheets: [original]))
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        #expect(sheet.objects.count == original.objects.count)
        for (copy, object) in zip(sheet.objects, original.objects) {
            #expect(copy.anchor == object.anchor, "\(object.title)")
            #expect(copy.image == object.image, "\(object.title)")
            #expect(copy.title == object.title && copy.altDescription == object.altDescription)
        }
        let data = try SpreadsheetIO.write(Workbook(sheets: [original]), activeSheet: 0, format: .xlsx)
        let zip = try ZipReader(data: data)
        #expect(zip.entries.map(\.path).filter { $0.hasPrefix("xl/media/") }.sorted() == ["xl/media/image1.png", "xl/media/image2.jpeg",
                                                                                          "xl/media/image3.gif"])
        #expect(try zip.read("xl/media/image2.jpeg") == Self.jpeg)
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
        let types = try #require(try IOTestPackage.part("[Content_Types].xml", of: data))
        #expect(types.contains("<Default Extension=\"gif\" ContentType=\"image/gif\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>"
            + "<Default Extension=\"png\" ContentType=\"image/png\"/>"))
        #expect(types.contains("<Override PartName=\"/xl/drawings/drawing1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"))
    }

    @Test func anchorXML() throws {
        var sheet = Sheet(name: "S")
        sheet.columnWidths = [2: 50]
        sheet.hiddenColumns = [3]
        sheet.rowHeights = [3: 30]
        sheet.objects = [SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 1, column: 1), offsetX: 10, offsetY: 5, width: 150, height: 80),
                                     content: .image(Self.image(Self.png)), title: "T", altDescription: "D & \"quoted\"")]
        let drawing = try Self.part("xl/drawings/drawing1.xml", of: Workbook(sheets: [sheet]))
        // From B2 + (10, 5) px. Across: 90 px left in column B, 50 in C, D hidden, 10 into E.
        // Down: 16 px left in row 2, 21 in row 3, 30 in row 4, 13 into row 5.
        #expect(drawing.contains("<xdr:twoCellAnchor editAs=\"oneCell\"><xdr:from><xdr:col>1</xdr:col><xdr:colOff>95250</xdr:colOff>"
            + "<xdr:row>1</xdr:row><xdr:rowOff>47625</xdr:rowOff></xdr:from><xdr:to><xdr:col>4</xdr:col><xdr:colOff>95250</xdr:colOff>"
            + "<xdr:row>4</xdr:row><xdr:rowOff>123825</xdr:rowOff></xdr:to>"))
        #expect(drawing.contains("<xdr:cNvPr id=\"2\" name=\"Picture 1\" descr=\"D &amp; &quot;quoted&quot;\" title=\"T\"/>"))
        // The picture's own frame: 110 px and 26 px from the sheet's corner, 150 × 80.
        #expect(drawing.contains("<a:off x=\"1047750\" y=\"247650\"/><a:ext cx=\"1428750\" cy=\"762000\"/>"))
        let sheetPart = try Self.part("xl/worksheets/sheet1.xml", of: Workbook(sheets: [sheet]))
        #expect(sheetPart.hasSuffix("<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
            + "<drawing r:id=\"rId1\"/></worksheet>"))
        let relationships = try Self.part("xl/worksheets/_rels/sheet1.xml.rels", of: Workbook(sheets: [sheet]))
        #expect(relationships.contains("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing\" "
            + "Target=\"../drawings/drawing1.xml\"/>"))
    }

    @Test func picturesFromOtherAppsFloat() throws {
        let picture = { (anchor: String, id: Int) in
            "\(anchor)<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"\(id)\" name=\"Picture \(id)\" descr=\"from Excel\"/><xdr:cNvPicPr/></xdr:nvPicPr>"
                + "<xdr:blipFill><a:blip r:embed=\"rId1\"><a:extLst><a:ext uri=\"{96DAC541-7B7A-43D3-8B79-37D633B846F1}\"/></a:extLst></a:blip>"
                + "<a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1905000\" cy=\"952500\"/>"
                + "</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/>"
        }
        let anchors = "<xdr:oneCellAnchor><xdr:from><xdr:col>2</xdr:col><xdr:colOff>19050</xdr:colOff><xdr:row>3</xdr:row>"
            + "<xdr:rowOff>9525</xdr:rowOff></xdr:from><xdr:ext cx=\"952500\" cy=\"476250\"/>" + picture("", 2) + "</xdr:oneCellAnchor>"
            + "<xdr:absoluteAnchor><xdr:pos x=\"2000250\" y=\"476250\"/><xdr:ext cx=\"190500\" cy=\"190500\"/>" + picture("", 3) + "</xdr:absoluteAnchor>"
            // A two-cell anchor over hidden columns takes the picture's own size.
            + "<xdr:twoCellAnchor editAs=\"oneCell\"><xdr:from><xdr:col>5</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff>"
            + "</xdr:from><xdr:to><xdr:col>6</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>"
            + picture("", 4) + "</xdr:twoCellAnchor>"
        let drawing = IOTestPackage.declaration + "<xdr:wsDr xmlns:xdr=\"\(XLSXNamespace.spreadsheetDrawing)\" xmlns:a=\"\(XLSXNamespace.drawingMain)\" "
            + "xmlns:r=\"\(IOTestPackage.relationshipNamespace)\">\(anchors)</xdr:wsDr>"
        let data = try IOTestPackage.xlsx(
            sheets: [IOTestPackage.SheetPart("S", "<cols><col min=\"6\" max=\"6\" width=\"9\" hidden=\"1\" customWidth=\"1\"/></cols><sheetData/>"
                + "<drawing r:id=\"rId1\"/>", relationships: [("drawing", "../drawings/drawing1.xml")])],
            parts: ["xl/drawings/drawing1.xml": drawing,
                    "xl/drawings/_rels/drawing1.xml.rels": IOTestPackage.relationships([("rId1", "image", "../media/image1.png")])],
            binaryParts: ["xl/media/image1.png": Self.png])
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        let objects = file.workbook.sheets[0].objects
        #expect(objects.map(\.anchor) == [
            ObjectAnchor(cell: CellAddress(row: 3, column: 2), offsetX: 2, offsetY: 1, width: 100, height: 50),
            // 210 px right and 50 px down: column D (64-px columns), 18 px in; row 3, 8 px in.
            ObjectAnchor(cell: CellAddress(row: 2, column: 3), offsetX: 18, offsetY: 8, width: 20, height: 20),
            ObjectAnchor(cell: CellAddress(row: 0, column: 5), width: 200, height: 100),
        ])
        #expect(objects.allSatisfy { $0.altDescription == "from Excel" && $0.image == Self.image(Self.png) })
    }

    // MARK: - In-cell images

    @Test func inCellImagesRoundTrip() throws {
        var sheet = Sheet(name: "Cells")
        sheet.columnWidths = [1: 200]
        sheet.rowHeights = [1: 40]
        sheet[1, 1] = Cell(image: CellImage(image: Self.image(Self.png), altText: "wide logo"))
        sheet[2, 0] = Cell(value: .text("with text"), format: IOTest.format { $0.bold = true }, image: CellImage(image: Self.image(Self.tallPNG)))
        sheet[3, 3] = Cell(image: CellImage(image: Self.image(Self.gif), altText: "merged"))
        sheet.merges = [CellRange(a1: "D4:E5")!]
        let workbook = Workbook(sheets: [sheet])
        let file = try Self.roundTrip(workbook)
        #expect(file.warnings.isEmpty)
        let copy = file.workbook.sheets[0]
        #expect(copy.objects.isEmpty)
        for address in [CellAddress(row: 1, column: 1), CellAddress(row: 2, column: 0), CellAddress(row: 3, column: 3)] {
            #expect(copy[address] == sheet[address], "\(address)")
        }
        let drawing = try Self.part("xl/drawings/drawing1.xml", of: workbook)
        // Fitted without distortion and centered: 4 × 2 in 200 × 40 is 80 × 40, 60 px in from the left.
        #expect(drawing.contains("<xdr:twoCellAnchor editAs=\"twoCell\"><xdr:from><xdr:col>1</xdr:col><xdr:colOff>571500</xdr:colOff>"
            + "<xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>"))
        #expect(drawing.contains("name=\"PuggleSheets cell image B2\" descr=\"wide logo\""))
        // 2 × 6 in a 100 × 21 cell is 7 × 21; in the 200 × 42 merged block, a 2 × 6 GIF is 14 × 42.
        #expect(drawing.contains("<a:ext cx=\"66675\" cy=\"200025\"/>"))
        #expect(drawing.contains("<a:ext cx=\"133350\" cy=\"400050\"/>"))
    }

    @Test func excelPicturesInCellsWarn() throws {
        // Excel 365 keeps them as rich values the cell refers to; the cell itself holds #VALUE!.
        let data = try IOTestPackage.xlsx(sheet: "<sheetData><row r=\"1\"><c r=\"A1\" t=\"e\" vm=\"1\"><v>#VALUE!</v></c></row></sheetData>")
        #expect(try IOTestPackage.read(data).warnings == [.images])
    }

    // MARK: - Links

    static func linkedWorkbook() -> Workbook {
        var first = Sheet(name: "Links")
        var second = Sheet(name: "Q1 2026")
        second[0, 0] = Cell(value: .number(1))
        first[0, 0] = Cell(value: .text("Web"), link: "https://example.com/path?q=1&r=2#top")
        first[1, 0] = Cell(value: .text("Mail"), link: "mailto:someone@example.com")
        first[2, 0] = Cell(value: .text("Range"), link: LinkTarget.sheet(second.id, CellRange(a1: "B2:C3")).link)
        first[3, 0] = Cell(value: .text("Sheet"), link: LinkTarget.sheet(second.id, nil).link)
        first[4, 0] = Cell(value: .text("Name"), link: LinkTarget.namedRange("Totals").link)
        first[5, 0] = Cell(link: "https://example.com/no-text")
        first[6, 0] = Cell(value: .text("Formula"), formula: "=HYPERLINK(\"https://example.com\",\"Go\")")
        return Workbook(sheets: [first, second], namedRanges: [NamedRange(name: "Totals", reference: "'Q1 2026'!$A$1")])
    }

    @Test func linksRoundTrip() throws {
        let workbook = Self.linkedWorkbook()
        let file = try Self.roundTrip(workbook)
        #expect(file.warnings.isEmpty)
        let links = file.workbook.sheets[0]
        let quarter = file.workbook.sheets[1]
        #expect(links[0, 0].link == "https://example.com/path?q=1&r=2#top")
        #expect(links[1, 0].link == "mailto:someone@example.com")
        // Places in the workbook point to the sheets as read.
        #expect(links[2, 0].link == LinkTarget.sheet(quarter.id, CellRange(a1: "B2:C3")).link)
        #expect(links[3, 0].link == LinkTarget.sheet(quarter.id, CellRange(a1: "A1")).link)
        #expect(links[4, 0].link == LinkTarget.namedRange("Totals").link)
        #expect(links[5, 0] == Cell(link: "https://example.com/no-text"))
        // HYPERLINK formulas are formulas like any other.
        #expect(links[6, 0].formula == "=HYPERLINK(\"https://example.com\",\"Go\")" && links[6, 0].link == nil)

        let sheetPart = try Self.part("xl/worksheets/sheet1.xml", of: workbook)
        #expect(sheetPart.contains("<hyperlinks><hyperlink ref=\"A1\" r:id=\"rId1\"/><hyperlink ref=\"A2\" r:id=\"rId2\"/>"
            + "<hyperlink ref=\"A3\" location=\"'Q1 2026'!B2:C3\"/><hyperlink ref=\"A4\" location=\"'Q1 2026'!A1\"/>"
            + "<hyperlink ref=\"A5\" location=\"Totals\"/><hyperlink ref=\"A6\" r:id=\"rId3\"/></hyperlinks><pageMargins"))
        let relationships = try Self.part("xl/worksheets/_rels/sheet1.xml.rels", of: workbook)
        #expect(relationships.contains("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" "
            + "Target=\"https://example.com/path?q=1&amp;r=2#top\" TargetMode=\"External\"/>"))
        #expect(try IOXLSXPackageCheck.problems(try SpreadsheetIO.write(workbook, activeSheet: 0, format: .xlsx)).isEmpty)
    }

    @Test func linksToDeletedSheetsAreLeftOut() throws {
        var sheet = Sheet(name: "S")
        sheet[0, 0] = Cell(value: .text("gone"), link: LinkTarget.sheet(UUID(), nil).link)
        sheet[1, 0] = Cell(value: .text("spaces"), link: "https://example.com/a b")
        let file = try Self.roundTrip(Workbook(sheets: [sheet]))
        #expect(file.workbook.sheets[0][0, 0] == Cell(value: .text("gone")))
        #expect(file.workbook.sheets[0][1, 0].link == "https://example.com/a%20b")
    }

    @Test func excelLinksAreRead() throws {
        let data = try IOTestPackage.xlsx(sheets: [
            IOTestPackage.SheetPart("Main", """
                <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>a</t></is></c></row></sheetData>
                <hyperlinks><hyperlink ref="A1:B2" r:id="rId1" display="Example"/><hyperlink ref="C3" r:id="rId2" location="section-2"/>
                <hyperlink ref="D4" location="'Other sheet'!$C$3" display="Other"/><hyperlink ref="E5" location="Budget"/>
                <hyperlink ref="F6" location="#Main!A1"/><hyperlink ref="G7" r:id="rId9"/><hyperlink ref="H8" location="Nowhere!A1"/></hyperlinks>
                """, relationships: [("hyperlink", "https://example.com/"), ("hyperlink", "https://example.com/doc")]),
            IOTestPackage.SheetPart("Other sheet", "<sheetData/>"),
        ], workbookSuffix: "<definedNames><definedName name=\"Budget\">'Other sheet'!$A$1:$A$9</definedName></definedNames>")
        let file = try IOTestPackage.read(data)
        let main = file.workbook.sheets[0], other = file.workbook.sheets[1]
        for address in ["A1", "B1", "A2", "B2"] { #expect(main[CellAddress(a1: address)!].link == "https://example.com/", "\(address)") }
        #expect(main[0, 0].value == .text("a"))
        #expect(main[2, 2].link == "https://example.com/doc#section-2")
        #expect(main[3, 3].link == LinkTarget.sheet(other.id, CellRange(a1: "C3")).link)
        #expect(main[4, 4].link == LinkTarget.namedRange("Budget").link)
        #expect(main[5, 5].link == LinkTarget.sheet(main.id, CellRange(a1: "A1")).link)
        // A missing relationship and an unknown sheet can't be followed.
        #expect(main.cells[CellAddress(a1: "G7")!] == nil && main.cells[CellAddress(a1: "H8")!] == nil)
        #expect(file.warnings == [.hyperlinks])
    }

    // MARK: - Filter views

    @Test func filterViewsRoundTrip() throws {
        var sales = Sheet(name: "Sales")
        sales[0, 0] = Cell(value: .text("Region"))
        let views = [
            FilterView(name: "East & West", range: CellRange(a1: "A1:D20")!, criteria: [
                0: FilterCriterion(hiddenValues: ["North", "", "<South>"]),
                2: FilterCriterion(condition: CellCondition(.isBetween, ["10", "20"])),
            ]),
            FilterView(name: "Big", range: CellRange(a1: "B2:C9")!, criteria: [1: FilterCriterion(condition: CellCondition(.customFormula, ["=B2>100"]))]),
        ]
        sales.filterViews = views
        var other = Sheet(name: "Other")
        other.filterViews = [FilterView(name: "Empty", range: CellRange(a1: "A1:A5")!)]
        let workbook = Workbook(sheets: [Sheet(name: "First"), sales, other])
        let file = try Self.roundTrip(workbook)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[1].filterViews == views)
        #expect(file.workbook.sheets[2].filterViews == other.filterViews)
        #expect(file.workbook.sheets[0].filterViews.isEmpty)

        let data = try SpreadsheetIO.write(workbook, activeSheet: 0, format: .xlsx)
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
        let item = try #require(try IOTestPackage.part("customXml/item1.xml", of: data))
        #expect(item.contains("<filterViews xmlns=\"http://schemas.pugglesoft.com/pugglesheets/2026/filterViews\"><sheet sheetId=\"2\" name=\"Sales\">"))
        let relationships = try #require(try IOTestPackage.part("xl/_rels/workbook.xml.rels", of: data))
        #expect(relationships.contains("Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml\" Target=\"../customXml/item1.xml\""))
        let types = try #require(try IOTestPackage.part("[Content_Types].xml", of: data))
        #expect(types.contains("<Override PartName=\"/customXml/itemProps1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.customXmlProperties+xml\"/>"))
    }

    @Test func filterViewsFollowRenamedSheets() throws {
        var sales = Sheet(name: "Sales")
        sales.filterViews = [FilterView(name: "View", range: CellRange(a1: "A1:B5")!)]
        let data = try SpreadsheetIO.write(Workbook(sheets: [sales, Sheet(name: "Other")]), activeSheet: 0, format: .xlsx)
        // Excel renamed and moved the sheet; its sheetId stays.
        var parts: [String: Data] = [:]
        let zip = try ZipReader(data: data)
        for entry in zip.entries { parts[entry.path] = try zip.read(entry) }
        let workbook = String(decoding: parts["xl/workbook.xml"]!, as: UTF8.self)
            .replacingOccurrences(of: "<sheet name=\"Sales\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Other\" sheetId=\"2\" r:id=\"rId2\"/>",
                                  with: "<sheet name=\"Other\" sheetId=\"2\" r:id=\"rId2\"/><sheet name=\"Renamed\" sheetId=\"1\" r:id=\"rId1\"/>")
        parts["xl/workbook.xml"] = Data(workbook.utf8)
        let file = try IOTestPackage.read(try IOTestPackage.zip(parts))
        #expect(file.workbook.sheets.map(\.name) == ["Other", "Renamed"])
        #expect(file.workbook.sheets[1].filterViews.map(\.name) == ["View"])
        #expect(file.workbook.sheets[0].filterViews.isEmpty)
    }

    // MARK: - Everything together

    @Test func damagedObjectPartsOnlyWarn() throws {
        var sheet = Self.picturesSheet()
        sheet[0, 1] = Cell(value: .text("link"), link: "https://example.com")
        sheet.objects.append(SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 30, column: 0), width: 200, height: 100),
                                         content: .chart(ChartSpec(ranges: ["A1:B3"]))))
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        let zip = try ZipReader(data: data)
        var parts: [String: Data] = [:]
        for entry in zip.entries { parts[entry.path] = try zip.read(entry) }
        var random = IOTestRandom(seed: 99)
        for target in ["xl/drawings/drawing1.xml", "xl/charts/chart1.xml", "xl/media/image1.png", "xl/drawings/_rels/drawing1.xml.rels"] {
            for _ in 0..<20 {
                var damaged = parts
                var bytes = [UInt8](damaged[target]!)
                for _ in 0..<4 where !bytes.isEmpty {
                    let position = Int(random.next() % UInt64(bytes.count))
                    if random.next() % 2 == 0 {
                        bytes.removeSubrange(position..<min(bytes.count, position + Int(random.next() % 30)))
                    } else {
                        bytes[position] = UInt8(truncatingIfNeeded: random.next())
                    }
                }
                damaged[target] = Data(bytes)
                // Damage in a drawing or chart costs that part only.
                let file = try IOTestPackage.read(try IOTestPackage.zip(damaged))
                #expect(file.workbook.sheets[0][0, 1].link == "https://example.com")
            }
        }
    }
}
