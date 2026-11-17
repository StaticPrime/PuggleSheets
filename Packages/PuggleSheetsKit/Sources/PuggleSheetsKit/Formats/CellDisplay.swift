import Foundation

/// How a value looks in its cell.
public struct DisplayText: Hashable, Sendable {
    /// The full text, e.g. "$ 1,234.00".
    public var text: String
    /// A color picked by the number format ("[Red]").
    public var color: RGBColor?
    /// Set for formats with a repeat fill ("* ", as in Accounting): the cell draws `before` at its
    /// left edge and `after` at its right edge.
    public var fill: Fill?

    public struct Fill: Hashable, Sendable {
        public var before: String
        public var after: String
        /// The character repeated between `before` and `after` ("*-" fills with "-"); a space for
        /// Accounting. `text` holds it once, between the two.
        public var character: Character

        public init(before: String, after: String) {
            self.init(before: before, after: after, character: " ")
        }

        public init(before: String, after: String, character: Character) {
            self.before = before
            self.after = after
            self.character = character
        }
    }

    public init(text: String, color: RGBColor? = nil, fill: Fill? = nil) {
        self.text = text
        self.color = color
        self.fill = fill
    }
}

public enum CellDisplay {
    /// The text a cell shows for `value` with the number format `pattern` (nil = Automatic).
    ///
    /// Patterns use the usual number format syntax: up to four sections (positive; negative; zero; text),
    /// conditions and colors, digit placeholders, grouping and scaling commas, percent, scientific
    /// notation, fractions, literals, fills, "@", and date and time tokens (case-insensitive).
    /// Booleans and errors look the same under every pattern; invalid patterns act as Automatic.
    public static func text(for value: CellValue, pattern: String?) -> DisplayText {
        switch value {
        case .empty:
            return DisplayText(text: "")
        case .number(let number):
            guard let pattern, !pattern.isEmpty else { return DisplayText(text: GeneralFormat.automatic(number)) }
            return FormatCache.shared.format(for: pattern).display(number: number)
        case .text(let text):
            guard let pattern, !pattern.isEmpty else { return DisplayText(text: text) }
            return FormatCache.shared.format(for: pattern).display(text: text)
        case .boolean(let boolean):
            return DisplayText(text: boolean ? "TRUE" : "FALSE")
        case .error(let error):
            return DisplayText(text: error.code)
        }
    }

    /// An Automatic-format number shortened to at most `maxLength` characters (fewer decimals, then
    /// scientific notation), as a narrow column shows it. When not even one significant digit fits,
    /// the shortest scientific form ("1E+15") is returned anyway.
    public static func automaticNumberText(_ number: Double, maxLength: Int) -> String {
        GeneralFormat.automatic(number, maxLength: maxLength)
    }

    /// The text the formula bar shows: the formula, or the value in an editable form
    /// (1234.5 rather than "$1,234.50", "12%" for percentages, "1/2/2026" for dates).
    /// Text that would be read back as something else gets a leading apostrophe.
    public static func editText(for cell: Cell) -> String {
        if let formula = cell.formula { return formula }
        switch cell.value {
        case .empty:
            return ""
        case .number(let number):
            return EditText.number(number, kind: NumberFormatPresets.kind(of: cell.format.numberFormat))
        case .text(let text):
            guard !text.isEmpty else { return "" }
            let reread = InputParser.parse(text, currentFormat: cell.format.numberFormat)
            return reread.formula == nil && reread.value == .text(text) ? text : "'" + text
        case .boolean(let boolean):
            return boolean ? "TRUE" : "FALSE"
        case .error(let error):
            return error.code
        }
    }
}

public enum NumberText {
    /// A number turned into text the way formulas do it ("0.333333333333333", "1E+20"): up to 15
    /// significant digits, no grouping; scientific notation from 10^15 up and below 10^-6.
    public static func general(_ number: Double) -> String {
        GeneralFormat.formulaText(number)
    }
}
