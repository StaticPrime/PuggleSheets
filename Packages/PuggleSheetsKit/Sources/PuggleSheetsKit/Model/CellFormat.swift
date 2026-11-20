import Foundation

/// An opaque sRGB color.
public struct RGBColor: Hashable, Sendable, CustomStringConvertible, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "RRGGBB" or "#RRGGBB" (case-insensitive).
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(red: UInt8((rgb >> 16) & 0xFF), green: UInt8((rgb >> 8) & 0xFF), blue: UInt8(rgb & 0xFF))
    }

    /// "RRGGBB", uppercase.
    public var hex: String { String(format: "%02X%02X%02X", red, green, blue) }
    public var description: String { "#" + hex }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 255, green: 255, blue: 255)
}

public enum HorizontalAlignment: String, CaseIterable, Sendable, Codable {
    case left, center, right
}

public enum VerticalAlignment: String, CaseIterable, Sendable, Codable {
    case top, middle, bottom
}

/// What happens to text wider than its cell.
public enum WrapStrategy: String, CaseIterable, Sendable, Codable {
    /// Spills into empty neighboring cells (the default).
    case overflow
    /// Breaks into lines; the row grows to fit unless its height was set by hand.
    case wrap
    /// Cut off at the cell edge.
    case clip
}

/// Format ▸ Rotation: text turned by an angle from -90 to 90 degrees (positive turns it up, counterclockwise),
/// or stacked one character per line.
public enum TextRotation: Hashable, Sendable, Codable {
    case angle(Int)
    case stacked
}

public enum BorderStyle: String, CaseIterable, Sendable, Codable {
    case thin, medium, thick, dashed, dotted, double
}

public struct BorderLine: Hashable, Sendable, Codable {
    public var style: BorderStyle
    public var color: RGBColor

    public init(style: BorderStyle = .thin, color: RGBColor = .black) {
        self.style = style
        self.color = color
    }
}

/// The borders drawn on each side of a cell. A line between two cells may be stored on either side.
public struct CellBorders: Hashable, Sendable, Codable {
    public var top: BorderLine?
    public var left: BorderLine?
    public var bottom: BorderLine?
    public var right: BorderLine?

    public init(top: BorderLine? = nil, left: BorderLine? = nil, bottom: BorderLine? = nil, right: BorderLine? = nil) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil }
}

/// A cell's formatting. `nil` means "the default": Arial 10, black, no fill, automatic alignment
/// (numbers right, text left, booleans and errors centered), bottom aligned, overflowing, Automatic number format.
public struct CellFormat: Hashable, Sendable {
    public static let defaultFontFamily = "Arial"
    public static let defaultFontSize = 10.0

    public var fontFamily: String?
    public var fontSize: Double?
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var textColor: RGBColor?
    public var fillColor: RGBColor?
    public var horizontalAlignment: HorizontalAlignment?
    public var verticalAlignment: VerticalAlignment?
    public var wrap: WrapStrategy?
    /// A number format pattern in spreadsheet syntax ("#,##0.00", "0%", "M/d/yyyy", "@" for plain text);
    /// nil is Automatic.
    public var numberFormat: String?
    public var borders = CellBorders()
    /// nil: horizontal text.
    public var textRotation: TextRotation?

    public init() {}

    public var isDefault: Bool { self == CellFormat() }
    public var resolvedFontFamily: String { fontFamily ?? CellFormat.defaultFontFamily }
    public var resolvedFontSize: Double { fontSize ?? CellFormat.defaultFontSize }
    public var resolvedVerticalAlignment: VerticalAlignment { verticalAlignment ?? .bottom }
    public var resolvedWrap: WrapStrategy { wrap ?? .overflow }
}
