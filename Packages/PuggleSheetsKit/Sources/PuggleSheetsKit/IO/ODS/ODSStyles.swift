import Foundation

/// Lengths in OpenDocument attributes ("0.889in", "2.258cm", "15pt"), in pixels at 96 dpi.
enum ODSLength {
    private static let units: [(suffix: String, pixels: Double)] = [
        ("in", 96), ("cm", 96 / 2.54), ("mm", 9.6 / 2.54), ("pt", 96.0 / 72), ("pc", 16), ("px", 1),
    ]

    static func pixels(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        for unit in units where text.hasSuffix(unit.suffix) {
            guard let value = Double(text.dropLast(unit.suffix.count)), value.isFinite else { return nil }
            return value * unit.pixels
        }
        return nil
    }

    static func points(_ text: String?) -> Double? {
        pixels(text).map { $0 * 0.75 }
    }

    /// "15.75pt" for 21 pixels: points are exact for whole pixels.
    static func text(pixels: Double) -> String {
        XLSXValue.string(max(0, pixels) * 0.75) + "pt"
    }
}

/// The styles of an OpenDocument spreadsheet: named styles and defaults from styles.xml, automatic
/// styles from content.xml.
struct ODSStyleSheet {
    private(set) var fontFamilies: [String: String] = [:]
    private(set) var cellStyles: [String: XNode] = [:]
    private(set) var defaultCellStyle: XNode?
    private(set) var dataStyles: [String: XNode] = [:]
    private(set) var columnWidths: [String: Double] = [:]
    private(set) var rowStyles: [String: (height: Double?, optimal: Bool)] = [:]
    private(set) var tableStyles: [String: (hidden: Bool, tabColor: RGBColor?)] = [:]

    /// Font declarations (`office:font-face-decls`).
    mutating func addFontFaces(_ node: XNode?) {
        for face in node?.children("font-face") ?? [] {
            guard let name = face["name"] else { continue }
            fontFamilies[name] = ODSStyleSheet.family(face["font-family"] ?? name)
        }
    }

    /// `office:styles` or `office:automatic-styles`.
    mutating func addStyles(_ node: XNode?) {
        for child in node?.children ?? [] {
            switch child.name {
            case "style":
                guard let name = child["name"] else { continue }
                switch child["family"] {
                case "table-cell":
                    cellStyles[name] = child
                case "table-column":
                    if let width = ODSLength.pixels(child.child("table-column-properties")?["column-width"]) { columnWidths[name] = width }
                case "table-row":
                    let properties = child.child("table-row-properties")
                    rowStyles[name] = (ODSLength.pixels(properties?["row-height"]), properties?["use-optimal-row-height"] != "false")
                case "table":
                    let properties = child.child("table-properties")
                    tableStyles[name] = (properties?["display"] == "false", properties?["tab-color"].flatMap(ODSStyleSheet.color))
                default:
                    break
                }
            case "default-style":
                if child["family"] == "table-cell" { defaultCellStyle = child }
            case "number-style", "currency-style", "percentage-style", "date-style", "time-style", "text-style", "boolean-style":
                if let name = child["name"] { dataStyles[name] = child }
            default:
                break
            }
        }
    }

    /// A style and the styles it inherits from, nearest first, ending with the default cell style.
    /// Cells without a style use "Default".
    private func chain(_ name: String?) -> [XNode] {
        var result: [XNode] = []
        var next = name ?? "Default"
        var seen = Set<String>()
        while let style = cellStyles[next], seen.insert(next).inserted, result.count < 16 {
            result.append(style)
            guard let parent = style["parent-style-name"] else { break }
            next = parent
        }
        if let defaultCellStyle { result.append(defaultCellStyle) }
        return result
    }

    private static func property(_ chain: [XNode], _ element: String, _ attribute: String) -> String? {
        for node in chain {
            if let value = node.child(element)?[attribute] { return value }
        }
        return nil
    }

    /// The format of cells with the style `name` (nil: the default style). Values equal to the defaults
    /// (Arial 10, black, no fill, bottom alignment) are left at their defaults.
    func cellFormat(_ name: String?) -> CellFormat {
        let chain = chain(name)
        func text(_ attribute: String) -> String? { ODSStyleSheet.property(chain, "text-properties", attribute) }
        func cell(_ attribute: String) -> String? { ODSStyleSheet.property(chain, "table-cell-properties", attribute) }
        var format = CellFormat()
        let family = text("font-name").map { fontFamilies[$0] ?? $0 } ?? text("font-family").map(ODSStyleSheet.family)
        if let family = family.map(ODSStyleSheet.aliased), !family.isEmpty, family != CellFormat.defaultFontFamily {
            format.fontFamily = family
        }
        if let size = text("font-size").flatMap(ODSStyleSheet.fontPoints), size > 0, size != CellFormat.defaultFontSize {
            format.fontSize = size
        }
        format.bold = ODSStyleSheet.isBold(text("font-weight"))
        format.italic = ODSStyleSheet.isItalic(text("font-style"))
        format.underline = ODSStyleSheet.isLine(text("text-underline-style"))
        format.strikethrough = ODSStyleSheet.isLine(text("text-line-through-style"))
        if text("use-window-font-color") != "true", let color = text("color").flatMap(ODSStyleSheet.color), color != .black {
            format.textColor = color
        }
        format.fillColor = cell("background-color").flatMap(ODSStyleSheet.color)
        if cell("text-align-source") != "value-type" {
            switch ODSStyleSheet.property(chain, "paragraph-properties", "text-align") {
            case "start", "left": format.horizontalAlignment = .left
            case "center": format.horizontalAlignment = .center
            case "end", "right": format.horizontalAlignment = .right
            default: break
            }
        }
        switch cell("vertical-align") {
        case "top": format.verticalAlignment = .top
        case "middle": format.verticalAlignment = .middle
        default: break
        }
        if cell("wrap-option") == "wrap" { format.wrap = .wrap }
        // Stacked text runs top to bottom; rotation is counterclockwise, in degrees from 0 to 360.
        if cell("direction") == "ttb" {
            format.textRotation = .stacked
        } else if let angle = cell("rotation-angle").flatMap(ODSStyleSheet.degrees) {
            format.textRotation = ODSStyleSheet.rotation(degrees: angle)
        }
        func border(_ side: String) -> BorderLine? {
            for node in chain {
                guard let properties = node.child("table-cell-properties") else { continue }
                if let value = properties["border-\(side)"] ?? properties["border"] { return ODSStyleSheet.border(value) }
            }
            return nil
        }
        format.borders = CellBorders(top: border("top"), left: border("left"), bottom: border("bottom"), right: border("right"))
        if let name = chain.lazy.compactMap({ $0["data-style-name"] }).first, let node = dataStyles[name] {
            format.numberFormat = ODSNumberStyles.pattern(of: node, styles: dataStyles)
        }
        return format
    }

    /// Whether cells with the style `name` (nil: the default style) stay editable on a protected sheet:
    /// `style:cell-protect="none"` (or "formula-hidden" alone, which hides formulas without locking).
    func isUnprotected(_ name: String?) -> Bool {
        guard let value = ODSStyleSheet.property(chain(name), "table-cell-properties", "cell-protect") else { return false }
        let parts = value.split(separator: " ")
        return value == "none" || (!parts.isEmpty && parts.allSatisfy { $0 == "formula-hidden" })
    }

    /// What a conditional formatting style sets (only what it and its parents set, not the defaults).
    func conditionalFormat(_ name: String) -> ConditionalFormat {
        let chain = chain(name).filter { $0 !== defaultCellStyle && $0["name"] != "Default" }
        func text(_ attribute: String) -> String? { ODSStyleSheet.property(chain, "text-properties", attribute) }
        var format = ConditionalFormat()
        if let weight = text("font-weight") { format.bold = ODSStyleSheet.isBold(weight) }
        if let style = text("font-style") { format.italic = ODSStyleSheet.isItalic(style) }
        if let line = text("text-underline-style") { format.underline = ODSStyleSheet.isLine(line) }
        if let line = text("text-line-through-style") { format.strikethrough = ODSStyleSheet.isLine(line) }
        if let color = text("color").flatMap(ODSStyleSheet.color) { format.textColor = color }
        if let fill = ODSStyleSheet.property(chain, "table-cell-properties", "background-color").flatMap(ODSStyleSheet.color) {
            format.fillColor = fill
        }
        return format
    }

    // MARK: - Values

    /// An angle in degrees: "45", "45deg", "1.5708rad", "50grad".
    static func degrees(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for (suffix, factor) in [("deg", 1.0), ("grad", 0.9), ("rad", 180 / Double.pi)] where trimmed.hasSuffix(suffix) {
            return Double(trimmed.dropLast(suffix.count)).map { $0 * factor }.flatMap { $0.isFinite ? $0 : nil }
        }
        return Double(trimmed).flatMap { $0.isFinite ? $0 : nil }
    }

    /// A counterclockwise angle as our rotation (-90 to 90, positive up); nil for none. Angles that turn
    /// text upside down are taken as the nearest upright one.
    static func rotation(degrees: Double) -> TextRotation? {
        guard degrees.isFinite else { return nil }
        var angle = Int(degrees.truncatingRemainder(dividingBy: 360).rounded()) % 360
        if angle < 0 { angle += 360 }
        switch angle {
        case 0: return nil
        case 1...90: return .angle(angle)
        case 91...180: return .angle(90)
        case 181..<270: return .angle(-90)
        default: return .angle(angle - 360)
        }
    }

    /// "#ff0000" → red; "transparent" and anything else → nil.
    static func color(_ text: String) -> RGBColor? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        return RGBColor(hex: trimmed)
    }

    static func isBold(_ weight: String?) -> Bool {
        guard let weight else { return false }
        if weight == "bold" { return true }
        return (Int(weight) ?? 400) >= 600
    }

    static func isItalic(_ style: String?) -> Bool {
        style == "italic" || style == "oblique"
    }

    static func isLine(_ style: String?) -> Bool {
        guard let style else { return false }
        return style != "none"
    }

    /// Font sizes in points ("10pt", "13.33px"); relative sizes aren't kept.
    static func fontPoints(_ text: String) -> Double? {
        guard let points = ODSLength.points(text) else { return nil }
        return (points * 100).rounded() / 100
    }

    /// "'Times New Roman'" → "Times New Roman"; a list keeps its first family.
    static func family(_ text: String) -> String {
        let first = text.split(separator: ",", maxSplits: 1).first.map(String.init) ?? text
        return first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// LibreOffice's metric-compatible stand-ins read as the fonts they stand for.
    static func aliased(_ family: String) -> String {
        switch family {
        case "Liberation Sans": "Arial"
        case "Liberation Serif": "Times New Roman"
        case "Liberation Mono": "Courier New"
        case "Carlito": "Calibri"
        case "Caladea": "Cambria"
        default: family
        }
    }

    /// "0.74pt solid #000000" (in any order) → a border line; nil for none.
    static func border(_ text: String) -> BorderLine? {
        var width: Double?
        var style: String?
        var color = RGBColor.black
        for token in text.split(separator: " ") {
            let part = String(token)
            if part.hasPrefix("#") {
                color = RGBColor(hex: part) ?? .black
            } else if let points = ODSLength.points(part) {
                width = points
            } else {
                style = part.lowercased()
            }
        }
        guard let style, style != "none", style != "hidden", width.map({ $0 > 0 }) ?? true else { return nil }
        let lineStyle: BorderStyle
        switch style {
        case "double", "double-thin", "thin-thick", "thick-thin": lineStyle = .double
        case "dotted": lineStyle = .dotted
        case "dashed", "dash-dot", "dash-dot-dot", "fine-dashed", "long-dash": lineStyle = .dashed
        default:
            let points = width ?? 0.75
            lineStyle = points < 1.1 ? .thin : points < 2 ? .medium : .thick
        }
        return BorderLine(style: lineStyle, color: color)
    }
}

/// Collects the automatic styles a written spreadsheet needs: column widths, row heights, tables,
/// cells (with their data styles) and the fonts they use; and the named styles conditional formats apply.
struct ODSStyleWriter {
    private var columnNames: [Double: String] = [:]
    private var columnOrder: [(name: String, width: Double)] = []
    private var rowNames: [Double: String] = [:]
    private var rowOrder: [(name: String, height: Double)] = []
    private var tableNames: [RGBColor?: String] = [:]
    private var tableOrder: [(name: String, tabColor: RGBColor?)] = []
    private var cellNames: [CellFormat: String] = [:]
    /// Styles of cells left editable on a protected sheet.
    private var unprotectedNames: [CellFormat: String] = [:]
    private var cellOrder: [(name: String, format: CellFormat, dataStyle: String?, unprotected: Bool)] = []
    private var dataStyleNames: [String: String?] = [:]
    private var dataStyles = XMLWriter(fragmentCapacity: 256)
    private var conditionalNames: [ConditionalFormat: String] = [:]
    private var conditionalOrder: [(name: String, format: ConditionalFormat)] = []
    private(set) var fonts: [String] = [CellFormat.defaultFontFamily]

    mutating func columnStyle(width: Double) -> String {
        if let name = columnNames[width] { return name }
        let name = "co\(columnOrder.count + 1)"
        columnNames[width] = name
        columnOrder.append((name, width))
        return name
    }

    mutating func rowStyle(height: Double) -> String {
        if let name = rowNames[height] { return name }
        let name = "ro\(rowOrder.count + 1)"
        rowNames[height] = name
        rowOrder.append((name, height))
        return name
    }

    mutating func tableStyle(tabColor: RGBColor?) -> String {
        if let name = tableNames[tabColor] { return name }
        let name = "ta\(tableOrder.count + 1)"
        tableNames[tabColor] = name
        tableOrder.append((name, tabColor))
        return name
    }

    /// The automatic style for a cell format; nil for the default format.
    mutating func cellStyle(_ format: CellFormat) -> String? {
        if format.isDefault { return nil }
        if let name = cellNames[format] { return name }
        return addCellStyle(format, unprotected: false)
    }

    /// The automatic style for a cell left editable on a protected sheet (`style:cell-protect="none"`).
    mutating func unprotectedCellStyle(_ format: CellFormat) -> String {
        if let name = unprotectedNames[format] { return name }
        return addCellStyle(format, unprotected: true)
    }

    private mutating func addCellStyle(_ format: CellFormat, unprotected: Bool) -> String {
        var dataStyle: String?
        if let pattern = format.numberFormat, !pattern.isEmpty, !XLSXNumberFormats.isGeneral(pattern) {
            if let known = dataStyleNames[pattern] {
                dataStyle = known
            } else {
                let name = "N\(100 + dataStyleNames.count)"
                dataStyle = ODSNumberStyles.write(pattern: pattern, name: name, into: &dataStyles) ? name : nil
                dataStyleNames[pattern] = dataStyle
            }
        }
        if let family = format.fontFamily, !fonts.contains(family) { fonts.append(family) }
        let name = "ce\(cellOrder.count + 1)"
        if unprotected { unprotectedNames[format] = name } else { cellNames[format] = name }
        cellOrder.append((name, format, dataStyle, unprotected))
        return name
    }

    /// The named style a conditional format applies.
    mutating func conditionalStyle(_ format: ConditionalFormat) -> String {
        if let name = conditionalNames[format] { return name }
        let name = "PuggleSheets_Conditional_\(conditionalOrder.count + 1)"
        conditionalNames[format] = name
        conditionalOrder.append((name, format))
        return name
    }

    /// `office:font-face-decls`.
    func writeFontFaces(into xml: inout XMLWriter) {
        xml.raw("<office:font-face-decls>")
        for font in fonts {
            xml.raw("<style:font-face")
            xml.attribute("style:name", font)
            xml.attribute("svg:font-family", font.contains(" ") ? "'\(font)'" : font)
            xml.raw("/>")
        }
        xml.raw("</office:font-face-decls>")
    }

    /// The content of `office:automatic-styles` in content.xml.
    func writeAutomaticStyles(into xml: inout XMLWriter) {
        for column in columnOrder {
            xml.raw("<style:style style:name=\"\(column.name)\" style:family=\"table-column\"><style:table-column-properties fo:break-before=\"auto\" style:column-width=\"\(ODSLength.text(pixels: column.width))\"/></style:style>")
        }
        for row in rowOrder {
            xml.raw("<style:style style:name=\"\(row.name)\" style:family=\"table-row\"><style:table-row-properties style:row-height=\"\(ODSLength.text(pixels: row.height))\" fo:break-before=\"auto\" style:use-optimal-row-height=\"false\"/></style:style>")
        }
        for table in tableOrder {
            xml.raw("<style:style style:name=\"\(table.name)\" style:family=\"table\" style:master-page-name=\"Default\"><style:table-properties table:display=\"true\" style:writing-mode=\"lr-tb\"")
            if let color = table.tabColor { xml.raw(" tableooo:tab-color=\"#\(color.hex.lowercased())\"") }
            xml.raw("/></style:style>")
        }
        xml.append(dataStyles)
        for cell in cellOrder {
            xml.raw("<style:style style:name=\"\(cell.name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\"")
            if let dataStyle = cell.dataStyle { xml.raw(" style:data-style-name=\"\(dataStyle)\"") }
            xml.raw(">")
            ODSStyleWriter.writeProperties(cell.format, unprotected: cell.unprotected, into: &xml)
            xml.raw("</style:style>")
        }
    }

    /// The named styles conditional formats apply, for `office:styles` in styles.xml.
    func writeConditionalStyles(into xml: inout XMLWriter) {
        for style in conditionalOrder {
            xml.raw("<style:style style:name=\"\(style.name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\">")
            let format = style.format
            if let fill = format.fillColor {
                xml.raw("<style:table-cell-properties fo:background-color=\"#\(fill.hex.lowercased())\"/>")
            }
            var text = ""
            if let bold = format.bold { text += " fo:font-weight=\"\(bold ? "bold" : "normal")\"" }
            if let italic = format.italic { text += " fo:font-style=\"\(italic ? "italic" : "normal")\"" }
            if let underline = format.underline {
                text += underline ? " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\""
                    : " style:text-underline-style=\"none\""
            }
            if let strikethrough = format.strikethrough {
                text += strikethrough ? " style:text-line-through-style=\"solid\" style:text-line-through-type=\"single\""
                    : " style:text-line-through-style=\"none\""
            }
            if let color = format.textColor { text += " fo:color=\"#\(color.hex.lowercased())\"" }
            if !text.isEmpty { xml.raw("<style:text-properties\(text)/>") }
            xml.raw("</style:style>")
        }
    }

    /// The cell, paragraph and text properties of a format.
    private static func writeProperties(_ format: CellFormat, unprotected: Bool, into xml: inout XMLWriter) {
        var cell = ""
        if let fill = format.fillColor { cell += " fo:background-color=\"#\(fill.hex.lowercased())\"" }
        for (side, line) in [("top", format.borders.top), ("bottom", format.borders.bottom), ("left", format.borders.left),
                             ("right", format.borders.right)] {
            guard let line else { continue }
            cell += " fo:border-\(side)=\"\(borderText(line))\""
            if line.style == .double { cell += " style:border-line-width-\(side)=\"0.6pt 0.6pt 0.6pt\"" }
        }
        switch format.verticalAlignment {
        case .top: cell += " style:vertical-align=\"top\""
        case .middle: cell += " style:vertical-align=\"middle\""
        case .bottom: cell += " style:vertical-align=\"bottom\""
        case nil: break
        }
        if format.wrap == .wrap { cell += " fo:wrap-option=\"wrap\"" }
        switch format.textRotation {
        case .stacked:
            cell += " style:direction=\"ttb\""
        case .angle(let angle) where angle % 360 != 0:
            // LibreOffice measures from the bottom edge unless told otherwise; PuggleSheets rotates inside the
            // cell, and slants a bordered cell's borders with its text, as LibreOffice does when importing Excel.
            let degrees = (min(max(angle, -90), 90) + 360) % 360
            cell += " style:rotation-angle=\"\(degrees)\" style:rotation-align=\"\(format.borders.isEmpty ? "none" : "bottom")\""
        default:
            break
        }
        if unprotected { cell += " style:cell-protect=\"none\"" }
        if format.horizontalAlignment != nil { cell += " style:text-align-source=\"fix\" style:repeat-content=\"false\"" }
        if !cell.isEmpty { xml.raw("<style:table-cell-properties\(cell)/>") }
        if let alignment = format.horizontalAlignment {
            let value = switch alignment {
            case .left: "start"
            case .center: "center"
            case .right: "end"
            }
            xml.raw("<style:paragraph-properties fo:text-align=\"\(value)\" fo:margin-left=\"0in\"/>")
        }
        var text = ""
        if let family = format.fontFamily {
            var attribute = XMLWriter(fragmentCapacity: 32)
            attribute.attribute("style:font-name", family)
            text += String(decoding: attribute.bytes, as: UTF8.self)
        }
        if let size = format.fontSize {
            let points = XLSXValue.string(size) + "pt"
            text += " fo:font-size=\"\(points)\" style:font-size-asian=\"\(points)\" style:font-size-complex=\"\(points)\""
        }
        if format.bold { text += " fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"" }
        if format.italic { text += " fo:font-style=\"italic\" style:font-style-asian=\"italic\" style:font-style-complex=\"italic\"" }
        if format.underline {
            text += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\""
        }
        if format.strikethrough { text += " style:text-line-through-style=\"solid\" style:text-line-through-type=\"single\"" }
        if let color = format.textColor { text += " fo:color=\"#\(color.hex.lowercased())\"" }
        if !text.isEmpty { xml.raw("<style:text-properties\(text)/>") }
    }

    private static func borderText(_ line: BorderLine) -> String {
        let color = "#" + line.color.hex.lowercased()
        switch line.style {
        case .thin: return "0.75pt solid \(color)"
        case .medium: return "1.5pt solid \(color)"
        case .thick: return "2.25pt solid \(color)"
        case .dashed: return "0.75pt dashed \(color)"
        case .dotted: return "0.75pt dotted \(color)"
        case .double: return "1.8pt double \(color)"
        }
    }
}
