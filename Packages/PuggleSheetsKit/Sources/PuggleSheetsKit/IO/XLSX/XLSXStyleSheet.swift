import Foundation

/// The cell formats of styles.xml, indexed like `cellXfs` (a cell's `s` attribute).
struct XLSXStyleSheet: Sendable {
    private(set) var formats: [CellFormat] = [CellFormat()]
    /// Whether each format shows dates, whose numbers shift in the 1904 date system.
    private(set) var showsDates: [Bool] = [false]
    /// Whether each format's cells stay editable when the sheet is protected (`locked="0"`).
    private(set) var unlocked: [Bool] = [false]
    /// The formats conditional formatting rules refer to (`dxfId`).
    private(set) var differentialFormats: [ConditionalFormat] = []
    private(set) var palette: XLSXColorPalette

    init(palette: XLSXColorPalette = XLSXColorPalette()) {
        self.palette = palette
    }

    func format(at index: Int) -> CellFormat {
        formats.indices.contains(index) ? formats[index] : CellFormat()
    }

    func showsDate(at index: Int) -> Bool {
        showsDates.indices.contains(index) && showsDates[index]
    }

    func isUnlocked(at index: Int) -> Bool {
        unlocked.indices.contains(index) && unlocked[index]
    }

    /// A rotation from Excel's `textRotation`: 1–90 up, 91–180 down, 255 stacked.
    static func rotation(_ value: Int?) -> TextRotation? {
        guard let value else { return nil }
        switch value {
        case 1...90: return .angle(value)
        case 91...180: return .angle(90 - value)
        case 255: return .stacked
        default: return nil
        }
    }

    private struct Font {
        var name: String?
        var size: Double?
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var color: RGBColor?
    }

    /// Reads styles.xml. Values equal to the defaults (Arial 10, black text, no fill, bottom alignment)
    /// are left at their defaults so typical cells keep an empty format.
    static func parse(_ data: Data, theme: XLSXTheme) throws -> XLSXStyleSheet {
        let root = try XMLTree.parse(data)
        guard root.name == "styleSheet" else { throw MalformedXMLError() }

        var indexed = XLSXColorPalette.legacyIndexedColors
        let customIndexed = root.child("colors")?.child("indexedColors")?.children("rgbColor")
            .map { XLSXColorPalette.parseARGB($0["rgb"] ?? "") ?? .black } ?? []
        if !customIndexed.isEmpty { indexed = customIndexed }
        let palette = XLSXColorPalette(theme: theme, indexedColors: indexed)
        var sheet = XLSXStyleSheet(palette: palette)

        var customFormats: [Int: String] = [:]
        for node in root.child("numFmts")?.children("numFmt") ?? [] {
            if let id = XLSXValue.int(node["numFmtId"]), let code = node["formatCode"] { customFormats[id] = code }
        }

        let fonts = (root.child("fonts")?.children("font") ?? []).map { node -> Font in
            var font = Font()
            var scheme: String?
            for child in node.children {
                switch child.name {
                case "b": font.bold = XLSXValue.isOn(child["val"])
                case "i": font.italic = XLSXValue.isOn(child["val"])
                case "u": font.underline = XLSXValue.isOn(child["val"])
                case "strike": font.strikethrough = XLSXValue.isOn(child["val"])
                case "sz": font.size = XLSXValue.double(child["val"])
                case "color": font.color = palette.color(child)
                case "name": font.name = child["val"]
                case "scheme": scheme = child["val"]
                default: break
                }
            }
            if font.name == nil {
                font.name = scheme == "major" ? theme.majorFont : scheme == "minor" ? theme.minorFont : nil
            }
            return font
        }

        let fills = (root.child("fills")?.children("fill") ?? []).map { node -> RGBColor? in
            guard let pattern = node.child("patternFill"), pattern["patternType"] == "solid" else { return nil }
            return palette.color(pattern.child("fgColor")) ?? palette.color(pattern.child("bgColor"))
        }

        func line(_ node: XNode?) -> BorderLine? {
            guard let node, let style = node["style"].flatMap(borderStyle) else { return nil }
            return BorderLine(style: style, color: palette.color(node.child("color")) ?? .black)
        }
        let borders = (root.child("borders")?.children("border") ?? []).map { node in
            CellBorders(top: line(node.child("top")),
                        left: line(node.child("left")) ?? line(node.child("start")),
                        bottom: line(node.child("bottom")),
                        right: line(node.child("right")) ?? line(node.child("end")))
        }

        var formats: [CellFormat] = []
        var showsDates: [Bool] = []
        var unlocked: [Bool] = []
        for xf in root.child("cellXfs")?.children("xf") ?? [] {
            var format = CellFormat()
            format.numberFormat = XLSXNumberFormats.pattern(for: XLSXValue.int(xf["numFmtId"]) ?? 0, custom: customFormats)
            if let id = XLSXValue.int(xf["fontId"]), fonts.indices.contains(id) {
                let font = fonts[id]
                if let name = font.name, !name.isEmpty, name != CellFormat.defaultFontFamily { format.fontFamily = name }
                if let size = font.size, size > 0, size != CellFormat.defaultFontSize { format.fontSize = size }
                format.bold = font.bold
                format.italic = font.italic
                format.underline = font.underline
                format.strikethrough = font.strikethrough
                if let color = font.color, color != .black { format.textColor = color }
            }
            if let id = XLSXValue.int(xf["fillId"]), fills.indices.contains(id) { format.fillColor = fills[id] }
            if let id = XLSXValue.int(xf["borderId"]), borders.indices.contains(id) { format.borders = borders[id] }
            if let alignment = xf.child("alignment") {
                switch alignment["horizontal"] {
                case "left": format.horizontalAlignment = .left
                case "center", "centerContinuous": format.horizontalAlignment = .center
                case "right": format.horizontalAlignment = .right
                default: break
                }
                switch alignment["vertical"] {
                case "top": format.verticalAlignment = .top
                case "center": format.verticalAlignment = .middle
                default: break
                }
                if XLSXValue.isTrue(alignment["wrapText"]) { format.wrap = .wrap }
                format.textRotation = rotation(XLSXValue.int(alignment["textRotation"]))
            }
            formats.append(format)
            showsDates.append(XLSXNumberFormats.showsDate(format.numberFormat))
            unlocked.append(xf.child("protection").map { !XLSXValue.isOn($0["locked"]) } ?? false)
        }
        if !formats.isEmpty {
            sheet.formats = formats
            sheet.showsDates = showsDates
            sheet.unlocked = unlocked
        }
        sheet.differentialFormats = (root.child("dxfs")?.children("dxf") ?? []).map { differentialFormat($0, palette: palette) }
        return sheet
    }

    /// A conditional format's look. Only what the rule sets is filled in; `<b val="0"/>` turns bold off.
    private static func differentialFormat(_ node: XNode, palette: XLSXColorPalette) -> ConditionalFormat {
        var format = ConditionalFormat()
        for child in node.child("font")?.children ?? [] {
            switch child.name {
            case "b": format.bold = XLSXValue.isOn(child["val"])
            case "i": format.italic = XLSXValue.isOn(child["val"])
            case "u": format.underline = XLSXValue.isOn(child["val"])
            case "strike": format.strikethrough = XLSXValue.isOn(child["val"])
            case "color": format.textColor = palette.color(child)
            default: break
            }
        }
        // In differential formats the fill's color is its background color, and the pattern defaults to solid.
        if let pattern = node.child("fill")?.child("patternFill"), pattern["patternType"] == nil || pattern["patternType"] == "solid" {
            format.fillColor = palette.color(pattern.child("bgColor")) ?? palette.color(pattern.child("fgColor"))
        }
        return format
    }

    /// Excel's border styles, folded into the six PuggleSheets draws.
    static func borderStyle(_ name: String) -> BorderStyle? {
        switch name {
        case "hair", "thin": .thin
        case "medium": .medium
        case "thick": .thick
        case "dashed", "mediumDashed", "dashDot", "mediumDashDot", "dashDotDot", "mediumDashDotDot", "slantDashDot": .dashed
        case "dotted": .dotted
        case "double": .double
        default: nil
        }
    }
}
