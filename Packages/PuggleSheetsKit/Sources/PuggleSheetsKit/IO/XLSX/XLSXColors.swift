import Foundation

/// The colors and fonts of a workbook's theme (xl/theme/theme1.xml).
struct XLSXTheme: Sendable {
    /// In the order SpreadsheetML's `theme` color indexes use: lt1, dk1, lt2, dk2, accent1–6, hlink,
    /// folHlink. (The light and dark pairs are swapped relative to the theme part, as in Excel.)
    var colors: [RGBColor]
    var minorFont: String?
    var majorFont: String?

    /// The Office theme of Excel 2013–2022, for workbooks without a theme part.
    static let office = XLSXTheme(
        colors: ["FFFFFF", "000000", "E7E6E6", "44546A", "4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47",
                 "0563C1", "954F72"].compactMap { RGBColor(hex: $0) },
        minorFont: "Calibri", majorFont: "Calibri Light")

    private static let schemeOrder = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5",
                                      "accent6", "hlink", "folHlink"]

    static func parse(_ data: Data) throws -> XLSXTheme {
        let root = try XMLTree.parse(data)
        var theme = XLSXTheme.office
        if let scheme = root.firstDescendant("clrScheme") {
            for (index, name) in schemeOrder.enumerated() {
                if let node = scheme.child(name), let color = schemeColor(node) { theme.colors[index] = color }
            }
        }
        if let fonts = root.firstDescendant("fontScheme") {
            if let minor = fonts.child("minorFont")?.child("latin")?["typeface"], !minor.isEmpty { theme.minorFont = minor }
            if let major = fonts.child("majorFont")?.child("latin")?["typeface"], !major.isEmpty { theme.majorFont = major }
        }
        return theme
    }

    private static func schemeColor(_ node: XNode) -> RGBColor? {
        if let value = node.child("srgbClr")?["val"] { return RGBColor(hex: value) }
        if let system = node.child("sysClr") {
            if let last = system["lastClr"], let color = RGBColor(hex: last) { return color }
            switch system["val"] {
            case "windowText": return .black
            case "window": return .white
            default: return nil
            }
        }
        return nil
    }
}

/// Resolves SpreadsheetML colors (CT_Color: rgb, theme, indexed, auto, tint) to sRGB.
struct XLSXColorPalette: Sendable {
    var themeColors: [RGBColor]
    var indexedColors: [RGBColor]

    init(theme: XLSXTheme = .office, indexedColors: [RGBColor] = XLSXColorPalette.legacyIndexedColors) {
        themeColors = theme.colors
        self.indexedColors = indexedColors
    }

    /// The color named by a color element's attributes; nil for automatic colors (the default text
    /// color, no fill) and for colors that can't be resolved.
    func color(_ attributes: [String: String]) -> RGBColor? {
        if XLSXValue.isTrue(attributes["auto"]) { return nil }
        var base: RGBColor?
        if let argb = attributes["rgb"] {
            base = XLSXColorPalette.parseARGB(argb)
        } else if let index = XLSXValue.int(attributes["theme"]) {
            base = themeColors.indices.contains(index) ? themeColors[index] : nil
        } else if let index = XLSXValue.int(attributes["indexed"]) {
            if indexedColors.indices.contains(index) {
                base = indexedColors[index]
            } else if index == 65 {
                // System background; 64 is the system foreground, the automatic text color.
                base = .white
            }
        }
        guard let base else { return nil }
        guard let tint = XLSXValue.double(attributes["tint"]), tint != 0 else { return base }
        return XLSXColorPalette.tinted(base, by: tint)
    }

    func color(_ node: XNode?) -> RGBColor? {
        guard let node else { return nil }
        return color(node.attributes)
    }

    /// "FF112233" (alpha first, ignored) or "112233".
    static func parseARGB(_ text: String) -> RGBColor? {
        let hex = text.trimmingCharacters(in: .whitespaces)
        switch hex.count {
        case 8: return RGBColor(hex: String(hex.dropFirst(2)))
        case 6: return RGBColor(hex: hex)
        default: return nil
        }
    }

    /// Lightens (positive tint) or darkens (negative tint) a color in HSL space, as ECMA-376 specifies:
    /// luminance becomes `l × (1 + tint)` when darkening and `l × (1 − tint) + tint` when lightening.
    static func tinted(_ color: RGBColor, by tint: Double) -> RGBColor {
        let red = Double(color.red) / 255, green = Double(color.green) / 255, blue = Double(color.blue) / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0, saturation = 0.0
        var lightness = (maximum + minimum) / 2
        if delta > 0 {
            saturation = lightness < 0.5 ? delta / (maximum + minimum) : delta / (2 - maximum - minimum)
            if maximum == red {
                hue = (green - blue) / delta + (green < blue ? 6 : 0)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
        }
        let clampedTint = min(max(tint, -1), 1)
        lightness = clampedTint < 0 ? lightness * (1 + clampedTint) : lightness * (1 - clampedTint) + clampedTint
        lightness = min(max(lightness, 0), 1)

        func channel(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        guard saturation > 0 else {
            let gray = channel(lightness)
            return RGBColor(red: gray, green: gray, blue: gray)
        }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func component(_ offset: Double) -> Double {
            var t = hue + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGBColor(red: channel(component(1.0 / 3)), green: channel(component(0)), blue: channel(component(-1.0 / 3)))
    }

    /// The legacy 64-color palette that `indexed` colors refer to unless styles.xml overrides it.
    static let legacyIndexedColors: [RGBColor] = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
    ].compactMap { RGBColor(hex: $0) }
}
