import Foundation

/// Relationship types of the parts PuggleSheets writes beyond worksheets, styles and strings.
enum XLSXRelationshipType {
    static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let drawing = base + "drawing"
    static let chart = base + "chart"
    static let image = base + "image"
    static let hyperlink = base + "hyperlink"
    static let pivotTable = base + "pivotTable"
    static let pivotCacheDefinition = base + "pivotCacheDefinition"
    static let customXml = base + "customXml"
    static let customXmlProps = base + "customXmlProps"
}

/// Content types of those parts.
enum XLSXContentType {
    static let drawing = "application/vnd.openxmlformats-officedocument.drawing+xml"
    static let chart = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
    static let pivotTable = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml"
    static let pivotCacheDefinition = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml"
    static let customXmlProperties = "application/vnd.openxmlformats-officedocument.customXmlProperties+xml"
}

/// XML namespaces of DrawingML.
enum XLSXNamespace {
    static let spreadsheetDrawing = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    static let drawingMain = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let chart = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
}

/// The relationships of one part (its `_rels/….rels`), numbered rId1, rId2, … in the order added.
struct XLSXRelationshipsWriter {
    private(set) var items: [(id: String, type: String, target: String, isExternal: Bool)] = []
    private let firstNumber: Int

    init(firstNumber: Int = 1) {
        self.firstNumber = firstNumber
    }

    var isEmpty: Bool { items.isEmpty }

    /// Adds a relationship and returns its id.
    mutating func add(type: String, target: String, isExternal: Bool = false) -> String {
        let id = "rId\(firstNumber + items.count)"
        items.append((id, type, target, isExternal))
        return id
    }

    /// The relationships part.
    func data() -> Data {
        var xml = XMLWriter(reservingCapacity: 256 + items.count * 160)
        xml.raw("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">")
        for item in items {
            xml.raw("<Relationship")
            xml.attribute("Id", item.id)
            xml.attribute("Type", item.type)
            xml.attribute("Target", item.target)
            if item.isExternal { xml.raw(" TargetMode=\"External\"") }
            xml.raw("/>")
        }
        xml.raw("</Relationships>")
        return xml.data
    }
}

/// Parts beyond the core ones (drawings, charts, media, pivot tables, custom XML), with what
/// [Content_Types].xml needs to say about them.
struct XLSXExtraParts {
    private(set) var files: [(path: String, data: Data)] = []
    /// Part name ("/xl/charts/chart1.xml") → content type.
    private(set) var overrides: [(part: String, contentType: String)] = []
    /// File extension → content type, for media.
    private(set) var defaults: [String: String] = [:]

    /// Adds a part; `contentType` nil leaves it to the extension's default (relationships, media, plain XML).
    mutating func add(_ path: String, _ data: Data, contentType: String? = nil) {
        files.append((path, data))
        if let contentType { overrides.append(("/" + path, contentType)) }
    }

    mutating func addDefault(extension fileExtension: String, contentType: String) {
        defaults[fileExtension] = contentType
    }
}

/// Numbers parts the way Excel does: drawing1, chart1, image1, … across the workbook.
struct XLSXPartCounters {
    var drawings = 0
    var charts = 0
    var images = 0
    var pivotTables = 0
    var pivotCaches = 0
    /// Comments parts, VML drawings and threaded comment parts share one number per sheet.
    var comments = 0
    /// Excel's table ids, which are unique in the workbook.
    var tables = 0
    var slicerParts = 0
    var slicerCaches = 0
}

/// English Metric Units: DrawingML's measure, 914,400 to the inch, so 9,525 to a pixel at 96 dpi.
enum XLSXEMU {
    static let perPixel = 9525.0

    static func from(pixels: Double) -> Int {
        Int((max(0, pixels) * perPixel).rounded())
    }

    static func pixels(_ emu: Double) -> Double {
        emu / perPixel
    }
}

/// Where columns and rows sit on a sheet as Excel lays it out: hidden columns and rows (by hand or
/// by the filter) take no space.
struct XLSXSheetGrid {
    let sheet: Sheet

    func columnWidth(_ column: Int) -> Double {
        sheet.isColumnHidden(column) ? 0 : sheet.columnWidth(column)
    }

    func rowHeight(_ row: Int) -> Double {
        sheet.isRowHidden(row) ? 0 : sheet.rowHeight(row)
    }

    /// The left edge of a column, in pixels from the sheet's left edge.
    func x(ofColumn column: Int) -> Double {
        var total = 0.0
        for index in 0..<max(0, min(column, XLSXLimits.columns)) { total += columnWidth(index) }
        return total
    }

    /// The top edge of a row, in pixels from the sheet's top edge.
    func y(ofRow row: Int) -> Double {
        var total = 0.0
        for index in 0..<max(0, min(row, XLSXLimits.rows)) { total += rowHeight(index) }
        return total
    }

    /// The column a point `offset` pixels right of `column`'s left edge falls in, and how far into it.
    func column(from column: Int, offset: Double) -> (index: Int, offset: Double) {
        var index = max(0, column), remaining = max(0, offset)
        while index < XLSXLimits.columns - 1 {
            let width = columnWidth(index)
            guard remaining >= width, remaining > 0 || width == 0 else { break }
            remaining -= width
            index += 1
        }
        return (index, remaining)
    }

    /// The row a point `offset` pixels below `row`'s top edge falls in, and how far into it.
    func row(from row: Int, offset: Double) -> (index: Int, offset: Double) {
        var index = max(0, row), remaining = max(0, offset)
        // Very tall objects over many rows: bounded walk, as rows can number a million.
        var steps = 0
        while index < XLSXLimits.rows - 1, steps < 2_000_000 {
            let height = rowHeight(index)
            guard remaining >= height, remaining > 0 || height == 0 else { break }
            remaining -= height
            index += 1
            steps += 1
        }
        return (index, remaining)
    }

    /// The distance in pixels from (`fromColumn`, `fromOffset`) to (`toColumn`, `toOffset`).
    func width(fromColumn: Int, fromOffset: Double, toColumn: Int, toOffset: Double) -> Double {
        guard toColumn >= fromColumn else { return max(0, toOffset - fromOffset) }
        var total = 0.0
        for index in fromColumn..<min(toColumn, XLSXLimits.columns) { total += columnWidth(index) }
        return max(0, total - fromOffset + toOffset)
    }

    func height(fromRow: Int, fromOffset: Double, toRow: Int, toOffset: Double) -> Double {
        guard toRow >= fromRow else { return max(0, toOffset - fromOffset) }
        var total = 0.0
        for index in fromRow..<min(toRow, XLSXLimits.rows) { total += rowHeight(index) }
        return max(0, total - fromOffset + toOffset)
    }
}
