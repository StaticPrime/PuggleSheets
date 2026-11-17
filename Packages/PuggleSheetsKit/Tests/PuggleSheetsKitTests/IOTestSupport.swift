import Foundation
import Testing
@testable import PuggleSheetsKit

/// Builds .xlsx packages by hand from XML strings, laid out like the files spreadsheet apps write.
enum IOTestPackage {
    static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    struct SheetPart {
        var name: String
        /// The worksheet's children (sheetPr, sheetViews, sheetData, …), or a whole chart sheet.
        var body: String
        var state: String?
        /// Relationship type (last segment, or a full URI) and target, relative to the worksheet.
        var relationships: [(type: String, target: String)] = []
        var type = "worksheet"

        init(_ name: String, _ body: String, state: String? = nil, relationships: [(type: String, target: String)] = [],
             type: String = "worksheet") {
            self.name = name
            self.body = body
            self.state = state
            self.relationships = relationships
            self.type = type
        }
    }

    /// A worksheet part around `body`, with the namespaces Excel declares.
    static func worksheet(_ body: String) -> String {
        declaration + "<worksheet xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\" "
            + "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" mc:Ignorable=\"x14ac\" "
            + "xmlns:x14ac=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac\" "
            + "xmlns:x14=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\" "
            + "xmlns:xm=\"http://schemas.microsoft.com/office/excel/2006/main\">\(body)</worksheet>"
    }

    static func sharedStrings(_ items: String) -> String {
        declaration + "<sst xmlns=\"\(mainNamespace)\">\(items)</sst>"
    }

    static func styles(_ body: String) -> String {
        declaration + "<styleSheet xmlns=\"\(mainNamespace)\">\(body)</styleSheet>"
    }

    static func relationshipType(_ type: String) -> String {
        type.contains("://") ? type : "http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(type)"
    }

    static func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        declaration + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + items.map { "<Relationship Id=\"\($0.id)\" Type=\"\(relationshipType($0.type))\" Target=\"\($0.target)\"/>" }.joined()
            + "</Relationships>"
    }

    /// A complete package. `workbookPrefix` goes before `<bookViews>` (workbookPr, protection),
    /// `workbookSuffix` after `<sheets>` (definedNames, calcPr, pivotCaches).
    static func xlsx(sheets: [SheetPart], sharedStrings: String? = nil, styles: String? = nil, theme: String? = nil,
                     workbookPrefix: String = "", workbookSuffix: String = "", activeTab: Int? = nil,
                     workbookRelationships extraRelationships: [(type: String, target: String)] = [],
                     parts extraParts: [String: String] = [:], binaryParts: [String: Data] = [:],
                     contentTypesExtra: String = "") throws -> Data {
        var parts: [String: Data] = [:]
        var workbookRelationships: [(id: String, type: String, target: String)] = []
        var sheetEntries = ""
        for (index, sheet) in sheets.enumerated() {
            let number = index + 1
            let folder = sheet.type == "chartsheet" ? "chartsheets" : "worksheets"
            workbookRelationships.append(("rId\(number)", sheet.type, "\(folder)/sheet\(number).xml"))
            let state = sheet.state.map { " state=\"\($0)\"" } ?? ""
            sheetEntries += "<sheet name=\"\(sheet.name)\" sheetId=\"\(number)\"\(state) r:id=\"rId\(number)\"/>"
            parts["xl/\(folder)/sheet\(number).xml"] = Data((sheet.type == "worksheet" ? worksheet(sheet.body) : sheet.body).utf8)
            if !sheet.relationships.isEmpty {
                let items = sheet.relationships.enumerated().map { ("rId\($0.offset + 1)", $0.element.type, $0.element.target) }
                parts["xl/\(folder)/_rels/sheet\(number).xml.rels"] = Data(relationships(items).utf8)
            }
        }
        if let sharedStrings {
            workbookRelationships.append(("rId101", "sharedStrings", "sharedStrings.xml"))
            parts["xl/sharedStrings.xml"] = Data(sharedStrings.utf8)
        }
        if let styles {
            workbookRelationships.append(("rId102", "styles", "styles.xml"))
            parts["xl/styles.xml"] = Data(styles.utf8)
        }
        if let theme {
            workbookRelationships.append(("rId103", "theme", "theme/theme1.xml"))
            parts["xl/theme/theme1.xml"] = Data(theme.utf8)
        }
        for (offset, relationship) in extraRelationships.enumerated() {
            workbookRelationships.append(("rId\(200 + offset)", relationship.type, relationship.target))
        }
        let bookViews = activeTab.map { "<bookViews><workbookView activeTab=\"\($0)\"/></bookViews>" } ?? ""
        parts["xl/workbook.xml"] = Data((declaration + "<workbook xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\">"
            + workbookPrefix + bookViews + "<sheets>\(sheetEntries)</sheets>" + workbookSuffix + "</workbook>").utf8)
        parts["xl/_rels/workbook.xml.rels"] = Data(relationships(workbookRelationships).utf8)
        parts["_rels/.rels"] = Data(relationships([("rId1", "officeDocument", "xl/workbook.xml")]).utf8)
        parts["[Content_Types].xml"] = Data((declaration
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + contentTypesExtra + "</Types>").utf8)
        for (path, text) in extraParts { parts[path] = Data(text.utf8) }
        for (path, data) in binaryParts { parts[path] = data }
        return try zip(parts)
    }

    /// A package of one worksheet with the given body.
    static func xlsx(sheet body: String, sharedStrings: String? = nil, styles: String? = nil) throws -> Data {
        try xlsx(sheets: [SheetPart("Sheet1", body)], sharedStrings: sharedStrings, styles: styles)
    }

    static func zip(_ parts: [String: Data]) throws -> Data {
        var writer = ZipWriter()
        // [Content_Types].xml first, as Office writes it; the rest in a stable order.
        for path in parts.keys.sorted(by: { ($0 == "[Content_Types].xml" ? "" : $0) < ($1 == "[Content_Types].xml" ? "" : $1) }) {
            try writer.add(path, parts[path]!)
        }
        return try writer.finish()
    }

    static func read(_ data: Data) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(data, format: .xlsx)
    }

    /// The text of one part of a package.
    static func part(_ path: String, of package: Data) throws -> String? {
        try ZipReader(data: package).read(path).map { String(decoding: $0, as: UTF8.self) }
    }

    static func isWellFormed(_ data: Data) -> Bool {
        XMLParser(data: data).parse()
    }
}

/// Deterministic pseudo-random bytes for tests.
struct IOTestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11
    }

    mutating func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) })
    }
}

/// Helpers for the file-format tests.
enum IOTest {
    /// A format built inline, for expectations.
    static func format(_ configure: (inout CellFormat) -> Void) -> CellFormat {
        var format = CellFormat()
        configure(&format)
        return format
    }
}
