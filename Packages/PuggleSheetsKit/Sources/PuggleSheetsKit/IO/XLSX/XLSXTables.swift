import Foundation

/// Tables as Excel tables (xl/tables/tableN.xml): the header row names the columns, the table's filter
/// is its autoFilter, and its color becomes the closest built-in table style. Column types and the exact
/// color are kept in PuggleSheets' custom part.
enum XLSXTables {
    static let relationshipType = XLSXRelationshipType.base + "table"
    static let contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"

    /// The colors of Excel's table styles in the Office theme, as `TableStyleMedium1`…`7` use them:
    /// dark gray, then accents 1–6.
    static let styleColors: [RGBColor] = ["404040", "4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47"]
        .compactMap(RGBColor.init(hex:))

    /// Column names from the header cells as they show, made unique and non-empty the way Excel does:
    /// an empty header becomes "Column" and its position ("Column3"), a repeated one (ignoring case)
    /// gets the next free number ("Sales2"). Header texts keep their names the first time they appear,
    /// and new names avoid all of them.
    static func columnNames(_ table: SheetTable, sheet: Sheet) -> [String] {
        let texts = table.range.columns.map { column -> String in
            let address = CellAddress(row: table.headerRow, column: column)
            return CellDisplay.text(for: sheet.value(at: address), pattern: sheet.cells[address]?.format.numberFormat).text
        }
        func isBlank(_ text: String) -> Bool { text.allSatisfy(\.isWhitespace) }
        var used = Set<String>()
        var names = texts.map { text -> String? in
            isBlank(text) || !used.insert(text.lowercased()).inserted ? nil : text
        }
        for index in names.indices where names[index] == nil {
            let base = isBlank(texts[index]) ? "Column" : texts[index]
            var number = isBlank(texts[index]) ? index + 1 : 2
            while used.contains((base + String(number)).lowercased()) { number += 1 }
            names[index] = base + String(number)
            used.insert((base + String(number)).lowercased())
        }
        return names.map { $0 ?? "" }
    }

    /// A table name Excel accepts: letters, digits, underscores and periods, starting with a letter or
    /// underscore, not a cell reference. Others are adjusted.
    static func validName(_ name: String, used: inout Set<String>) -> String {
        var clean = String(name.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "." ? Character(scalar) : "_"
        })
        if clean.isEmpty || !(clean.first!.isLetter || clean.first == "_") { clean = "_" + clean }
        if !NamedRange.isValidName(clean) { clean = "Table_" + clean }
        var candidate = clean
        var number = 2
        while used.contains(candidate.lowercased()) {
            candidate = clean + "_" + String(number)
            number += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// The built-in style closest to a color: `TableStyleMedium1`…`7`.
    static func style(for color: RGBColor) -> String {
        "TableStyleMedium\(closestIndex(color, in: styleColors) + 1)"
    }

    /// The palette color closest to `color` as people see it: grays match grays by lightness, other
    /// colors match by hue, then lightness.
    static func closestIndex(_ color: RGBColor, in palette: [RGBColor]) -> Int {
        let target = hsl(color)
        let isGray = target.saturation < 0.2
        let pool = palette.indices.filter { (hsl(palette[$0]).saturation < 0.2) == isGray }
        func distance(_ index: Int) -> Double {
            let other = hsl(palette[index])
            let lightness = abs(other.lightness - target.lightness)
            guard !isGray else { return lightness }
            let hue = abs(other.hue - target.hue)
            return min(hue, 360 - hue) + lightness * 30
        }
        return (pool.isEmpty ? Array(palette.indices) : pool).min { distance($0) < distance($1) } ?? 0
    }

    private static func hsl(_ color: RGBColor) -> (hue: Double, saturation: Double, lightness: Double) {
        let red = Double(color.red) / 255, green = Double(color.green) / 255, blue = Double(color.blue) / 255
        let high = max(red, green, blue), low = min(red, green, blue), delta = high - low
        let lightness = (high + low) / 2
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case red: hue = 60 * ((green - blue) / delta)
        case green: hue = 60 * ((blue - red) / delta) + 120
        default: hue = 60 * ((red - green) / delta) + 240
        }
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    /// A table color for a built-in style: the style's accent in the workbook's theme, as the closest of
    /// the colors PuggleSheets offers. The black and gray styles are gray; other styles get the first color.
    static func color(forStyle name: String?, theme: XLSXTheme) -> RGBColor {
        guard let name, let match = name.range(of: "^TableStyle(Light|Medium|Dark)([0-9]+)$", options: .regularExpression) else {
            return SheetTable.colors[0]
        }
        let text = name[match]
        let number = max(1, Int(text.drop { !$0.isNumber }) ?? 1)
        // Each group of seven styles runs dark, then accents 1–6; Dark9–11 pair accents 1–2, 3–4 and 5–6.
        let accent = text.contains("Dark") && number >= 9 ? min((number - 9) * 2 + 1, 5) : (number - 1) % 7
        // Theme colors: lt1, dk1, lt2, dk2, accent1…6.
        let color = accent == 0 || theme.colors.count < 10 ? RGBColor(hex: "5F6368")! : theme.colors[3 + accent]
        return SheetTable.colors[closestIndex(color, in: SheetTable.colors)]
    }

    /// The range Excel's table gets: an Excel table has at least one data row, so a table that is only a
    /// header row gets the row below it.
    static func excelRange(_ range: CellRange) -> CellRange {
        guard range.rowCount < 2, range.end.row + 1 < XLSXLimits.rows else { return range }
        return CellRange(rows: range.start.row...(range.end.row + 1), columns: range.columns)
    }

    /// xl/tables/tableN.xml for a table with Excel id `id`; `criteria` is the table's filter (with any
    /// slicer selections added).
    static func part(_ table: SheetTable, name: String, id: Int, columnNames: [String], criteria: [Int: FilterCriterion], sheet: Sheet) -> Data {
        let range = excelRange(table.range)
        var xml = XMLWriter(reservingCapacity: 512 + columnNames.count * 64)
        xml.raw("<table xmlns=\"\(XLSXNamespace.main)\" id=\"\(id)\"")
        xml.attribute("name", name)
        xml.attribute("displayName", name)
        xml.raw(" ref=\"\(range.a1)\" totalsRowShown=\"0\">")
        XLSXRules.writeAutoFilter(SheetFilter(range: range, criteria: criteria), sheet: sheet, into: &xml)
        xml.raw("<tableColumns count=\"\(columnNames.count)\">")
        for (index, column) in columnNames.enumerated() {
            xml.raw("<tableColumn id=\"\(index + 1)\"")
            xml.attribute("name", column)
            xml.raw("/>")
        }
        xml.raw("</tableColumns>")
        xml.raw("<tableStyleInfo name=\"\(style(for: table.color))\" showFirstColumn=\"0\" showLastColumn=\"0\" showRowStripes=\"1\" "
            + "showColumnStripes=\"0\"/>")
        xml.raw("</table>")
        return xml.data
    }

    // MARK: - Reading

    /// A table from Excel: Excel's id and its columns' ids (for slicers), and whether something about it
    /// couldn't be kept.
    struct Read {
        var table: SheetTable?
        var id: Int?
        var columnIDs: [Int] = []
        var unsupported = false
    }

    static func read(_ data: Data, sheet: Sheet, theme: XLSXTheme) -> Read {
        var result = Read()
        guard let root = try? XMLTree.parse(data), root.name == "table",
              let reference = root["ref"], var range = CellRange(a1: reference.replacingOccurrences(of: "$", with: "")),
              range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns,
              let name = root["displayName"] ?? root["name"], !name.isEmpty else {
            result.unsupported = true
            return result
        }
        // A table without a header row has no counterpart.
        if let headers = XLSXValue.int(root["headerRowCount"]), headers == 0 {
            result.unsupported = true
            return result
        }
        // PuggleSheets' tables have no totals row; it stays as cells below the table.
        if let totals = XLSXValue.int(root["totalsRowCount"]), totals > 0 {
            guard range.rowCount > totals else {
                result.unsupported = true
                return result
            }
            range = CellRange(rows: range.start.row...(range.end.row - totals), columns: range.columns)
        }
        var criteria: [Int: FilterCriterion] = [:]
        if let autoFilter = root.child("autoFilter") {
            let filter = XLSXRules.filter(autoFilter, sheet: sheet)
            if filter.unsupported { result.unsupported = true }
            criteria = filter.filter?.criteria.filter { range.columns.contains($0.key) } ?? [:]
        }
        result.table = SheetTable(name: name, range: range, color: color(forStyle: root.child("tableStyleInfo")?["name"], theme: theme),
                                  criteria: criteria)
        result.id = XLSXValue.int(root["id"])
        result.columnIDs = (root.child("tableColumns")?.children("tableColumn") ?? []).enumerated().map { position, column in
            XLSXValue.int(column["id"]) ?? position + 1
        }
        return result
    }
}
