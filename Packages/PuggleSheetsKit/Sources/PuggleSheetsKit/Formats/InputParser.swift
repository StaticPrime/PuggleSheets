import Foundation

/// What typed text means.
public struct ParsedInput: Hashable, Sendable {
    public var value: CellValue
    /// The formula, when the input starts with "=".
    public var formula: String?
    /// A number format implied by the input when the cell has no explicit format yet
    /// ("12%" → "0%", "$1,200" → "\"$\"#,##0", "1/2/2026" → "M/d/yyyy").
    public var impliedFormat: String?

    public init(value: CellValue, formula: String? = nil, impliedFormat: String? = nil) {
        self.value = value
        self.formula = formula
        self.impliedFormat = impliedFormat
    }
}

public enum InputParser {
    /// Interprets text typed into a cell whose number format is `currentFormat`. "=…" is a formula,
    /// a leading apostrophe forces text, and the plain-text format ("@") keeps everything as text.
    ///
    /// Recognizes (en-US, surrounding spaces ignored) numbers with optional sign, grouping and exponent,
    /// percentages, "$" amounts, dates ("1/2/2026", "2026-01-02", "Jan 2, 2026", "1/2"), times
    /// ("13:45", "1:45 PM", "25:30:00"), dates with times, TRUE/FALSE and error codes. Anything else is
    /// text, exactly as typed.
    public static func parse(_ input: String, currentFormat: String?) -> ParsedInput {
        if input.isEmpty { return ParsedInput(value: .empty) }
        if currentFormat != nil, NumberFormatPresets.kind(of: currentFormat) == .plainText {
            return ParsedInput(value: .text(input))
        }
        if input.hasPrefix("=") {
            return input.count > 1 ? ParsedInput(value: .empty, formula: input) : ParsedInput(value: .text(input))
        }
        if input.hasPrefix("'") { return ParsedInput(value: .text(String(input.dropFirst()))) }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedInput(value: .text(input)) }
        switch trimmed.uppercased() {
        case "TRUE": return ParsedInput(value: .boolean(true))
        case "FALSE": return ParsedInput(value: .boolean(false))
        default: break
        }
        if trimmed.hasPrefix("#"), let error = CellError(code: trimmed) { return ParsedInput(value: .error(error)) }
        if let recognized = InputRecognizer.recognize(trimmed) {
            return ParsedInput(value: .number(recognized.value), impliedFormat: recognized.format)
        }
        return ParsedInput(value: .text(input))
    }

    /// The number a text value stands for in arithmetic ("12%", "1,234", "$5", "1/2/2026", "13:45"),
    /// or nil.
    public static func number(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return InputRecognizer.recognize(trimmed)?.value
    }
}
