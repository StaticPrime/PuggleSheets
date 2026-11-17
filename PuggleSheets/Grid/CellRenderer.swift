import AppKit
import PuggleSheetsKit

extension RGBColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(red: channel(rgb.redComponent), green: channel(rgb.greenComponent), blue: channel(rgb.blueComponent))
    }
}

/// Fonts and text for cells. Sizes are points at 96 dpi, as a browser shows them,
/// so a 10 pt font is 13.33 pixels tall on a grid where a pixel is a point.
final class CellRenderer {
    static let fontScale: CGFloat = 96.0 / 72.0
    /// Space between a cell's edge and its text, in sheet pixels.
    static let horizontalPadding: CGFloat = 3
    static let verticalPadding: CGFloat = 2

    private struct FontKey: Hashable {
        var family: String
        var size: CGFloat
        var bold: Bool
        var italic: Bool
    }

    private var fonts: [FontKey: NSFont] = [:]
    private var digitWidths: [ObjectIdentifier: CGFloat] = [:]

    private struct LineKey: Hashable {
        var text: String
        var font: ObjectIdentifier
        var color: RGBColor
    }

    /// Laid-out single lines of text, reused from frame to frame while scrolling.
    private var lines: [LineKey: (line: CTLine, width: CGFloat)] = [:]

    func invalidate() {
        fonts = [:]
        digitWidths = [:]
        lines = [:]
    }

    /// A single line of cell text, laid out once and cached. Underlined and struck-through text isn't
    /// cached here: Core Text doesn't draw those lines, so it goes through `NSAttributedString` instead.
    func line(_ text: String, format: CellFormat, color: RGBColor?, zoom: CGFloat) -> (line: CTLine, width: CGFloat) {
        let font = self.font(for: format, zoom: zoom)
        let resolved = color ?? format.textColor ?? .black
        let key = LineKey(text: text, font: ObjectIdentifier(font), color: resolved)
        if let cached = lines[key] { return cached }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: resolved.nsColor])
        let line = CTLineCreateWithAttributedString(attributed)
        let entry = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        if lines.count > 20_000 { lines.removeAll(keepingCapacity: true) }
        lines[key] = entry
        return entry
    }

    /// The font for a format at a zoom level, falling back to Arial for fonts this Mac doesn't have.
    func font(for format: CellFormat, zoom: CGFloat) -> NSFont {
        let key = FontKey(family: format.resolvedFontFamily, size: (CGFloat(format.resolvedFontSize) * Self.fontScale * zoom * 100).rounded() / 100,
                          bold: format.bold, italic: format.italic)
        if let font = fonts[key] { return font }
        let font = Self.makeFont(family: key.family, size: key.size, bold: key.bold, italic: key.italic)
        fonts[key] = font
        return font
    }

    static func makeFont(family: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let manager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        for candidate in [family, CellFormat.defaultFontFamily] {
            if let font = manager.font(withFamily: candidate, traits: traits, weight: 5, size: size) { return font }
            if let font = manager.font(withFamily: candidate, traits: [], weight: 5, size: size) {
                return manager.convert(font, toHaveTrait: traits)
            }
        }
        return NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// The row height (100% zoom) a cell's text needs in a column of `width` pixels.
    static func neededHeight(_ cell: Cell, width: CGFloat) -> CGFloat {
        let display = CellDisplay.text(for: cell.value, pattern: cell.format.numberFormat)
        let font = makeFont(family: cell.format.resolvedFontFamily, size: CGFloat(cell.format.resolvedFontSize) * fontScale,
                            bold: cell.format.bold, italic: cell.format.italic)
        let padding = 2 * verticalPadding + 1
        if let rotation = cell.format.textRotation, !display.text.isEmpty {
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            switch rotation {
            case .stacked:
                return lineHeight * CGFloat(display.text.count) + padding
            case .angle(let degrees):
                let size = (display.text as NSString).size(withAttributes: [.font: font])
                let radians = CGFloat(abs(degrees)) * .pi / 180
                return ceil(size.width * sin(radians) + lineHeight * cos(radians)) + padding
            }
        }
        guard cell.format.resolvedWrap == .wrap || display.text.contains("\n") else {
            return ceil(font.ascender - font.descender + font.leading) + padding
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = cell.format.resolvedWrap == .wrap ? .byWordWrapping : .byClipping
        let bounds = (display.text as NSString).boundingRect(with: CGSize(width: max(1, width - 2 * horizontalPadding), height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin],
                                                             attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
        return ceil(bounds.height) + padding
    }

    func digitWidth(_ font: NSFont) -> CGFloat {
        if let width = digitWidths[ObjectIdentifier(font)] { return width }
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        digitWidths[ObjectIdentifier(font)] = width
        return width
    }

    /// Where a value sits when its format doesn't say: numbers right, booleans and errors centered, text left.
    static func automaticAlignment(for value: CellValue) -> HorizontalAlignment {
        switch value {
        case .number: .right
        case .boolean, .error: .center
        case .text, .empty: .left
        }
    }

    func attributes(for format: CellFormat, color: RGBColor?, zoom: CGFloat, alignment: NSTextAlignment = .left,
                    wraps: Bool = false) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: format, zoom: zoom),
            .foregroundColor: (color ?? format.textColor ?? .black).nsColor,
        ]
        if format.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if format.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if wraps || alignment != .left {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
            attributes[.paragraphStyle] = paragraph
        }
        return attributes
    }
}
