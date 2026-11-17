import Foundation

/// Collects the distinct cell formats of a workbook into the tables of styles.xml: number formats,
/// fonts, fills, borders and cell formats (`cellXfs`), each deduplicated. Index 0 of every table is
/// the default: Arial 10, no fill, no border, General.
struct XLSXStyleWriter {
    private struct Font: Hashable {
        var family = CellFormat.defaultFontFamily
        var size = CellFormat.defaultFontSize
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var color: RGBColor?
    }

    private struct Style: Hashable {
        var numberFormat = 0
        var font = 0
        var fill = 0
        var border = 0
        var horizontal: HorizontalAlignment?
        var vertical: VerticalAlignment?
        var wraps = false
        /// Excel's `textRotation`: 1–90 up, 91–180 down, 255 stacked; 0 for none.
        var rotation = 0
        /// Editable when the sheet is protected (`<protection locked="0"/>`).
        var unlocked = false
    }

    private var fonts: [Font] = [Font()]
    private var fontIndexes: [Font: Int] = [Font(): 0]
    /// Solid fill colors; fills 0 (none) and 1 (gray125, which Excel requires) come first.
    private var fills: [RGBColor] = []
    private var fillIndexes: [RGBColor: Int] = [:]
    private var borders: [CellBorders] = [CellBorders()]
    private var borderIndexes: [CellBorders: Int] = [CellBorders(): 0]
    private var customFormats: [String] = []
    private var customFormatIDs: [String: Int] = [:]
    private var styles: [Style] = [Style()]
    private var styleIndexes: [Style: Int] = [Style(): 0]
    private var cache: [CellFormat: Int] = [:]
    private var unlockedCache: [CellFormat: Int] = [:]
    private var differentialFormats: [ConditionalFormat] = []
    private var differentialIndexes: [ConditionalFormat: Int] = [:]

    /// The `dxfId` for a conditional format's look.
    mutating func differentialFormatIndex(for format: ConditionalFormat) -> Int {
        if let index = differentialIndexes[format] { return index }
        differentialFormats.append(format)
        differentialIndexes[format] = differentialFormats.count - 1
        return differentialFormats.count - 1
    }

    /// The `s` attribute for a cell with `format`; `unlocked` cells stay editable when the sheet is protected.
    mutating func index(for format: CellFormat, unlocked: Bool = false) -> Int {
        if format.isDefault && !unlocked { return 0 }
        if let index = unlocked ? unlockedCache[format] : cache[format] { return index }
        let style = Style(numberFormat: numberFormatID(format.numberFormat), font: fontIndex(format), fill: fillIndex(format.fillColor),
                          border: borderIndex(format.borders), horizontal: format.horizontalAlignment,
                          vertical: format.verticalAlignment, wraps: format.wrap == .wrap,
                          rotation: format.textRotation.map(XLSXStyleWriter.rotation) ?? 0, unlocked: unlocked)
        let index: Int
        if let existing = styleIndexes[style] {
            index = existing
        } else {
            index = styles.count
            styles.append(style)
            styleIndexes[style] = index
        }
        if unlocked { unlockedCache[format] = index } else { cache[format] = index }
        return index
    }

    /// Excel's `textRotation` for a rotation: angles up as 1–90, angles down as 91–180, stacked as 255.
    static func rotation(_ rotation: TextRotation) -> Int {
        switch rotation {
        case .stacked: 255
        case .angle(let degrees):
            degrees >= 0 ? min(degrees, 90) : 90 + min(-degrees, 90)
        }
    }

    private mutating func numberFormatID(_ pattern: String?) -> Int {
        guard let pattern, !pattern.isEmpty, !XLSXNumberFormats.isGeneral(pattern) else { return 0 }
        if let id = XLSXNumberFormats.builtInIDs[pattern] ?? customFormatIDs[pattern] { return id }
        let id = XLSXNumberFormats.firstCustomID + customFormats.count
        customFormats.append(pattern)
        customFormatIDs[pattern] = id
        return id
    }

    private mutating func fontIndex(_ format: CellFormat) -> Int {
        let font = Font(family: format.resolvedFontFamily, size: format.resolvedFontSize, bold: format.bold, italic: format.italic,
                        underline: format.underline, strikethrough: format.strikethrough,
                        color: format.textColor == .black ? nil : format.textColor)
        if let index = fontIndexes[font] { return index }
        fonts.append(font)
        fontIndexes[font] = fonts.count - 1
        return fonts.count - 1
    }

    private mutating func fillIndex(_ color: RGBColor?) -> Int {
        guard let color else { return 0 }
        if let index = fillIndexes[color] { return index }
        fills.append(color)
        fillIndexes[color] = fills.count + 1
        return fills.count + 1
    }

    private mutating func borderIndex(_ borders: CellBorders) -> Int {
        if let index = borderIndexes[borders] { return index }
        self.borders.append(borders)
        borderIndexes[borders] = self.borders.count - 1
        return self.borders.count - 1
    }

    /// xl/styles.xml.
    func data() -> Data {
        var xml = XMLWriter()
        xml.raw("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">")
        if !customFormats.isEmpty {
            xml.raw("<numFmts count=\"\(customFormats.count)\">")
            for (offset, pattern) in customFormats.enumerated() {
                xml.raw("<numFmt")
                xml.attribute("numFmtId", XLSXNumberFormats.firstCustomID + offset)
                xml.attribute("formatCode", pattern)
                xml.raw("/>")
            }
            xml.raw("</numFmts>")
        }

        xml.raw("<fonts count=\"\(fonts.count)\">")
        for font in fonts {
            xml.raw("<font>")
            if font.bold { xml.raw("<b/>") }
            if font.italic { xml.raw("<i/>") }
            if font.strikethrough { xml.raw("<strike/>") }
            if font.underline { xml.raw("<u/>") }
            xml.raw("<sz val=\"\(XLSXValue.string(font.size))\"/>")
            if let color = font.color { xml.raw("<color rgb=\"FF\(color.hex)\"/>") }
            xml.raw("<name")
            xml.attribute("val", font.family)
            xml.raw("/></font>")
        }
        xml.raw("</fonts>")

        xml.raw("<fills count=\"\(fills.count + 2)\">")
        xml.raw("<fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>")
        for color in fills {
            xml.raw("<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\(color.hex)\"/><bgColor indexed=\"64\"/></patternFill></fill>")
        }
        xml.raw("</fills>")

        xml.raw("<borders count=\"\(borders.count)\">")
        for border in borders {
            xml.raw("<border>")
            for (name, line) in [("left", border.left), ("right", border.right), ("top", border.top), ("bottom", border.bottom)] {
                if let line {
                    xml.raw("<\(name) style=\"\(XLSXStyleWriter.styleName(line.style))\"><color rgb=\"FF\(line.color.hex)\"/></\(name)>")
                } else {
                    xml.raw("<\(name)/>")
                }
            }
            xml.raw("<diagonal/></border>")
        }
        xml.raw("</borders>")

        xml.raw("<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>")
        xml.raw("<cellXfs count=\"\(styles.count)\">")
        for style in styles {
            xml.raw("<xf numFmtId=\"\(style.numberFormat)\" fontId=\"\(style.font)\" fillId=\"\(style.fill)\" borderId=\"\(style.border)\" xfId=\"0\"")
            if style.numberFormat != 0 { xml.raw(" applyNumberFormat=\"1\"") }
            if style.font != 0 { xml.raw(" applyFont=\"1\"") }
            if style.fill != 0 { xml.raw(" applyFill=\"1\"") }
            if style.border != 0 { xml.raw(" applyBorder=\"1\"") }
            let aligned = style.horizontal != nil || style.vertical != nil || style.wraps || style.rotation != 0
            if aligned { xml.raw(" applyAlignment=\"1\"") }
            if style.unlocked { xml.raw(" applyProtection=\"1\"") }
            guard aligned || style.unlocked else {
                xml.raw("/>")
                continue
            }
            xml.raw(">")
            if aligned {
                xml.raw("<alignment")
                if let horizontal = style.horizontal { xml.raw(" horizontal=\"\(horizontal.rawValue)\"") }
                switch style.vertical {
                case .top: xml.raw(" vertical=\"top\"")
                case .middle: xml.raw(" vertical=\"center\"")
                case .bottom: xml.raw(" vertical=\"bottom\"")
                case nil: break
                }
                if style.rotation != 0 { xml.raw(" textRotation=\"\(style.rotation)\"") }
                if style.wraps { xml.raw(" wrapText=\"1\"") }
                xml.raw("/>")
            }
            if style.unlocked { xml.raw("<protection locked=\"0\"/>") }
            xml.raw("</xf>")
        }
        xml.raw("</cellXfs>")
        xml.raw("<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>")
        writeDifferentialFormats(into: &xml)
        xml.raw("<tableStyles count=\"0\" defaultTableStyle=\"TableStyleMedium2\" defaultPivotStyle=\"PivotStyleLight16\"/>")
        xml.raw("</styleSheet>")
        return xml.data
    }

    private func writeDifferentialFormats(into xml: inout XMLWriter) {
        guard !differentialFormats.isEmpty else {
            xml.raw("<dxfs count=\"0\"/>")
            return
        }
        xml.raw("<dxfs count=\"\(differentialFormats.count)\">")
        for format in differentialFormats {
            xml.raw("<dxf>")
            var font = ""
            if let bold = format.bold { font += bold ? "<b/>" : "<b val=\"0\"/>" }
            if let italic = format.italic { font += italic ? "<i/>" : "<i val=\"0\"/>" }
            if let strikethrough = format.strikethrough { font += strikethrough ? "<strike/>" : "<strike val=\"0\"/>" }
            if let underline = format.underline { font += underline ? "<u/>" : "<u val=\"none\"/>" }
            if let color = format.textColor { font += "<color rgb=\"FF\(color.hex)\"/>" }
            if !font.isEmpty { xml.raw("<font>\(font)</font>") }
            if let fill = format.fillColor {
                xml.raw("<fill><patternFill><bgColor rgb=\"FF\(fill.hex)\"/></patternFill></fill>")
            }
            xml.raw("</dxf>")
        }
        xml.raw("</dxfs>")
    }

    static func styleName(_ style: BorderStyle) -> String {
        switch style {
        case .thin: "thin"
        case .medium: "medium"
        case .thick: "thick"
        case .dashed: "dashed"
        case .dotted: "dotted"
        case .double: "double"
        }
    }
}
