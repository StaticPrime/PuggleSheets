import Foundation

/// A test on a cell's value, shared by conditional formatting, data validation and filters
/// (all three offer the same list).
public struct CellCondition: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case isEmpty, isNotEmpty
        case textContains, textDoesNotContain, textStartsWith, textEndsWith, textIsExactly
        case textIsValidEmail, textIsValidURL
        case dateIs, dateIsBefore, dateIsAfter, dateIsOnOrBefore, dateIsOnOrAfter, dateIsBetween, dateIsNotBetween, dateIsValid
        case greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual, isEqual, isNotEqual, isBetween, isNotBetween
        case customFormula

        /// How many values the condition takes.
        public var valueCount: Int {
            switch self {
            case .isEmpty, .isNotEmpty, .textIsValidEmail, .textIsValidURL, .dateIsValid: 0
            case .dateIsBetween, .dateIsNotBetween, .isBetween, .isNotBetween: 2
            default: 1
            }
        }
    }

    public var kind: Kind
    /// What the condition compares with, as typed: text, numbers, dates ("1/2/2026"), relative dates
    /// for date conditions ("today", "tomorrow", "yesterday", "past week", "past month", "past year"),
    /// or formulas ("=B2", "=$A1>10") whose relative references count from the top-left cell of the
    /// rule's range. A custom formula condition holds when its formula is TRUE (or a nonzero number).
    public var values: [String]

    public init(_ kind: Kind, _ values: [String] = []) {
        self.kind = kind
        self.values = values
    }
}

/// Formatting a conditional rule lays over a cell's own format; nil leaves that part alone.
public struct ConditionalFormat: Hashable, Sendable {
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var textColor: RGBColor?
    public var fillColor: RGBColor?

    public init(bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strikethrough: Bool? = nil,
                textColor: RGBColor? = nil, fillColor: RGBColor? = nil) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.textColor = textColor
        self.fillColor = fillColor
    }

    public var isEmpty: Bool { self == ConditionalFormat() }

    /// `format` with this rule's formatting laid over it.
    public func applied(to format: CellFormat) -> CellFormat {
        var result = format
        if let bold { result.bold = bold }
        if let italic { result.italic = italic }
        if let underline { result.underline = underline }
        if let strikethrough { result.strikethrough = strikethrough }
        if let textColor { result.textColor = textColor }
        if let fillColor { result.fillColor = fillColor }
        return result
    }

    /// `other`'s parts where this one has none: earlier rules win.
    public func filling(from other: ConditionalFormat) -> ConditionalFormat {
        ConditionalFormat(bold: bold ?? other.bold, italic: italic ?? other.italic, underline: underline ?? other.underline,
                          strikethrough: strikethrough ?? other.strikethrough, textColor: textColor ?? other.textColor,
                          fillColor: fillColor ?? other.fillColor)
    }
}

/// A gradient fill from the lowest to the highest value of a range.
public struct ColorScale: Hashable, Sendable {
    public enum PointKind: String, CaseIterable, Sendable {
        /// The range's lowest or highest value (`value` unused).
        case minimum, maximum
        /// A fixed number (`value` holds it).
        case number
        /// A position between the lowest and highest value, 0–100.
        case percent
        /// A percentile of the range's values, 0–100.
        case percentile
    }

    public struct Point: Hashable, Sendable {
        public var kind: PointKind
        public var value: String?
        public var color: RGBColor

        public init(kind: PointKind, value: String? = nil, color: RGBColor) {
            self.kind = kind
            self.value = value
            self.color = color
        }
    }

    public var minimum: Point
    public var midpoint: Point?
    public var maximum: Point

    public init(minimum: Point, midpoint: Point? = nil, maximum: Point) {
        self.minimum = minimum
        self.midpoint = midpoint
        self.maximum = maximum
    }
}

/// Format ▸ Conditional formatting. Rules apply in order; for each part of the format, the first
/// rule that sets it wins.
public struct ConditionalFormatRule: Hashable, Sendable, Identifiable {
    public enum Style: Hashable, Sendable {
        case condition(CellCondition, ConditionalFormat)
        case colorScale(ColorScale)
    }

    public var id: UUID
    public var ranges: [CellRange]
    public var style: Style

    public init(id: UUID = UUID(), ranges: [CellRange], style: Style) {
        self.id = id
        self.ranges = ranges
        self.style = style
    }
}

/// Data ▸ Data validation.
public struct DataValidationRule: Hashable, Sendable, Identifiable {
    public enum Criterion: Hashable, Sendable {
        /// A dropdown of these items.
        case list([String])
        /// A dropdown of the values in a range, written as a reference without "=" ("Sheet1!$A$1:$A$10").
        case listFromRange(String)
        /// A checkbox; nil values mean TRUE and FALSE.
        case checkbox(checked: String?, unchecked: String?)
        case condition(CellCondition)
    }

    public var id: UUID
    public var ranges: [CellRange]
    public var criterion: Criterion
    /// Refuse input that breaks the rule (true), or accept it and mark the cell (false).
    public var rejectsInvalid: Bool
    public var helpText: String?
    /// Dropdowns show an arrow chip (true) or just their text (false).
    public var showsDropdown: Bool

    public init(id: UUID = UUID(), ranges: [CellRange], criterion: Criterion, rejectsInvalid: Bool = false,
                helpText: String? = nil, showsDropdown: Bool = true) {
        self.id = id
        self.ranges = ranges
        self.criterion = criterion
        self.rejectsInvalid = rejectsInvalid
        self.helpText = helpText
        self.showsDropdown = showsDropdown
    }
}

/// What a filter hides in one column.
public struct FilterCriterion: Hashable, Sendable {
    /// Filter by values: the shown texts to hide ("" stands for empty cells).
    public var hiddenValues: Set<String>
    /// Filter by condition: rows whose cell fails it are hidden.
    public var condition: CellCondition?

    public init(hiddenValues: Set<String> = [], condition: CellCondition? = nil) {
        self.hiddenValues = hiddenValues
        self.condition = condition
    }

    public var isEmpty: Bool { hiddenValues.isEmpty && condition == nil }
}

/// Data ▸ Create a filter: one per sheet.
public struct SheetFilter: Hashable, Sendable {
    /// The filtered block; its first row holds the column headers and is never hidden.
    public var range: CellRange
    /// Criteria by column index.
    public var criteria: [Int: FilterCriterion]

    public init(range: CellRange, criteria: [Int: FilterCriterion] = [:]) {
        self.range = range
        self.criteria = criteria
    }
}

/// Format ▸ Alternating colors.
public struct Banding: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var range: CellRange
    /// The first row's color; nil when the range has no header row.
    public var headerColor: RGBColor?
    public var firstColor: RGBColor
    public var secondColor: RGBColor
    /// The last row's color; nil when the range has no footer row.
    public var footerColor: RGBColor?

    public init(id: UUID = UUID(), range: CellRange, headerColor: RGBColor?, firstColor: RGBColor, secondColor: RGBColor,
                footerColor: RGBColor? = nil) {
        self.id = id
        self.range = range
        self.headerColor = headerColor
        self.firstColor = firstColor
        self.secondColor = secondColor
        self.footerColor = footerColor
    }

    /// The fill a row of the range gets, or nil outside it.
    public func color(forRow row: Int) -> RGBColor? {
        guard range.rows.contains(row) else { return nil }
        if let headerColor, row == range.start.row { return headerColor }
        if let footerColor, row == range.end.row, range.rowCount > 1 { return footerColor }
        let first = range.start.row + (headerColor == nil ? 0 : 1)
        return (row - first) % 2 == 0 ? firstColor : secondColor
    }
}

/// Data ▸ Named ranges: a name formulas can use instead of a reference.
public struct NamedRange: Hashable, Sendable {
    /// Letters, digits and underscores, starting with a letter or underscore, and not a cell reference.
    public var name: String
    /// A reference without "=", usually with its sheet: "Sheet1!$A$1:$B$10".
    public var reference: String

    public init(name: String, reference: String) {
        self.name = name
        self.reference = reference
    }

    /// Whether `name` can name a range: letters, digits, underscores and periods, starting with a letter or
    /// underscore, at most 250 characters, and not something formulas read otherwise (A1, R1C1, TRUE).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 250 else { return false }
        func isLetter(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(scalar) }
        guard isLetter(first) || first == "_" else { return false }
        guard name.unicodeScalars.allSatisfy({ isLetter($0) || $0 == "_" || $0 == "." || ("0"..."9").contains($0) }) else { return false }
        let upper = name.uppercased()
        if upper == "TRUE" || upper == "FALSE" { return false }
        if CellAddress(a1: name) != nil { return false }
        if upper.range(of: "^R[0-9]*C[0-9]*$", options: .regularExpression) != nil { return false }
        return true
    }
}
