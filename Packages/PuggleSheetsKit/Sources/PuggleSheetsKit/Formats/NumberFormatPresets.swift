import Foundation

/// What a number format shows, for alignment, editing and the toolbar.
public enum NumberFormatKind: Hashable, Sendable {
    case automatic, plainText, number, percent, scientific, currency, accounting, date, time, dateTime, duration
}

/// An entry of the toolbar's "123" menu.
public struct NumberFormatPreset: Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// "Number".
    public var name: String
    /// "#,##0.00"; nil for Automatic.
    public var pattern: String?
    /// "1,000.12".
    public var example: String

    public init(name: String, pattern: String?, example: String) {
        self.name = name
        self.pattern = pattern
        self.example = example
    }
}

public enum NumberFormatPresets {
    public static let automatic = NumberFormatPreset(name: "Automatic", pattern: nil, example: "")
    public static let plainText = NumberFormatPreset(name: "Plain text", pattern: "@", example: "")
    public static let number = NumberFormatPreset(name: "Number", pattern: "#,##0.00", example: "1,000.12")
    public static let percent = NumberFormatPreset(name: "Percent", pattern: "0.00%", example: "10.12%")
    public static let scientific = NumberFormatPreset(name: "Scientific", pattern: "0.00E+00", example: "1.01E+03")
    public static let accounting = NumberFormatPreset(name: "Accounting", pattern: "_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)", example: "$ (1,000.12)")
    public static let financial = NumberFormatPreset(name: "Financial", pattern: "#,##0.00;(#,##0.00)", example: "(1,000.12)")
    public static let currency = NumberFormatPreset(name: "Currency", pattern: "\"$\"#,##0.00", example: "$1,000.12")
    public static let currencyRounded = NumberFormatPreset(name: "Currency rounded", pattern: "\"$\"#,##0", example: "$1,000")
    public static let date = NumberFormatPreset(name: "Date", pattern: "M/d/yyyy", example: "9/26/2008")
    public static let time = NumberFormatPreset(name: "Time", pattern: "h:mm:ss AM/PM", example: "3:59:00 PM")
    public static let dateTime = NumberFormatPreset(name: "Date time", pattern: "M/d/yyyy H:mm:ss", example: "9/26/2008 15:59:00")
    public static let duration = NumberFormatPreset(name: "Duration", pattern: "[h]:mm:ss", example: "24:01:00")

    /// The "123" menu, in order.
    public static let all: [NumberFormatPreset] = [automatic, plainText, number, percent, scientific, accounting, financial,
                                                    currency, currencyRounded, date, time, dateTime, duration]

    /// Classifies a pattern by its first section: dates, times, date-times and durations (elapsed
    /// [h] [m] [s]); accounting (a currency symbol with a repeat fill) and currency; percent;
    /// scientific; plain text ("@" and other text-only patterns); everything else is a number.
    /// nil, "General" and invalid patterns are Automatic.
    public static func kind(of pattern: String?) -> NumberFormatKind {
        guard let pattern, !pattern.isEmpty else { return .automatic }
        if pattern == "@" { return .plainText }
        let parsed = FormatCache.shared.format(for: pattern)
        guard parsed.isValid, let first = parsed.sections.first else { return .automatic }
        switch first.kind {
        case .text:
            return .plainText
        case .general:
            return .automatic
        case .date:
            if first.hasElapsed { return .duration }
            if first.hasDateParts { return first.hasTimeParts ? .dateTime : .date }
            return .time
        case .scientific:
            return .scientific
        case .number, .fraction:
            if first.hasPercent { return .percent }
            if first.hasCurrency { return first.hasFill ? .accounting : .currency }
            return .number
        }
    }

    /// The pattern after the toolbar's "Decrease/Increase decimal places" buttons, for a cell showing `value`.
    ///
    /// Automatic starts from the decimals the value shows (1.5 → +1 gives "0.00"); patterns gain or lose
    /// a "0" after the decimal point in each numeric section, keeping everything else. Dates, times,
    /// durations and text are unchanged, and there are never fewer than 0 decimals.
    public static func adjustingDecimals(_ pattern: String?, by delta: Int, for value: CellValue) -> String? {
        guard delta != 0 else { return pattern }
        switch kind(of: pattern) {
        case .date, .time, .dateTime, .duration, .plainText:
            return pattern
        case .automatic:
            // Invalid patterns stay as they are; nil, "" and "General" act as Automatic.
            if let pattern, !pattern.isEmpty, !FormatCache.shared.format(for: pattern).isValid { return pattern }
            return automaticAdjusted(by: delta, for: value)
        default:
            break
        }
        guard let pattern else { return nil }
        let sections = FormatParser.splitSections(Array(pattern)).map { section in
            var characters = section
            for _ in 0..<abs(delta) {
                guard let adjusted = adjustSection(characters, increase: delta > 0) else { break }
                characters = adjusted
            }
            return String(characters)
        }
        return sections.joined(separator: ";")
    }

    /// "0", "0.0", "0.00"… (or "0.00E+00"…) one step from what Automatic shows.
    private static func automaticAdjusted(by delta: Int, for value: CellValue) -> String {
        var decimals = 0
        var scientific = false
        if case .number(let number) = value, number.isFinite {
            let shown = GeneralFormat.automatic(number)
            scientific = shown.contains("E")
            let mantissa = shown.split(separator: "E").first ?? ""
            if let point = mantissa.firstIndex(of: ".") {
                decimals = mantissa.distance(from: point, to: mantissa.endIndex) - 1
            }
        }
        let adjusted = max(0, decimals + delta)
        let base = adjusted > 0 ? "0." + String(repeating: "0", count: adjusted) : "0"
        return scientific ? base + "E+00" : base
    }

    /// One step more or fewer decimals in one section, or nil when the section can't change
    /// (dates, text, fractions, General, no digits, already no decimals).
    private static func adjustSection(_ characters: [Character], increase: Bool) -> [Character]? {
        var placeholders: [Int] = []
        var point: Int?
        var exponent: Int?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\"":
                index = (characters[(index + 1)...].firstIndex(of: "\"") ?? characters.count) + 1
                continue
            case "[":
                let end = characters[(index + 1)...].firstIndex(of: "]") ?? characters.count
                let content = String(characters[min(index + 1, end)..<end]).lowercased()
                if let first = content.first, "hms".contains(first), content.allSatisfy({ $0 == first }) { return nil }
                index = end + 1
                continue
            case "\\", "_", "*":
                index += 2
                continue
            case "0", "#", "?":
                if exponent == nil { placeholders.append(index) }
            case ".":
                if point == nil, exponent == nil { point = index }
            case "E", "e":
                if exponent == nil, index + 1 < characters.count, characters[index + 1] == "+" || characters[index + 1] == "-" {
                    exponent = index
                    index += 2
                    continue
                }
            case "@":
                return nil
            case "/":
                if let last = placeholders.last, last == index - 1 { return nil }
            default:
                let lower = character.lowercased()
                if lower == "g", String(characters[index...].prefix(7)).lowercased() == "general" { return nil }
                if let letter = lower.first, lower.count == 1, "ymdhs".contains(letter) { return nil }
                if lower == "a", ["am/pm", "a/p"].contains(where: {
                    String(characters[index...].prefix($0.count)).lowercased() == $0
                }) { return nil }
            }
            index += 1
        }
        guard let lastPlaceholder = placeholders.last else { return nil }
        var result = characters

        if point == nil, placeholders.allSatisfy({ characters[$0] == "?" }) {
            // Accounting's zero section ("-"??) aligns with the decimals using "?".
            if increase {
                result.insert("?", at: lastPlaceholder + 1)
            } else {
                result.remove(at: lastPlaceholder)
            }
            return result
        }
        guard let point else {
            guard increase else { return nil }
            result.insert(contentsOf: [".", "0"], at: lastPlaceholder + 1)
            return result
        }
        let decimals = placeholders.filter { $0 > point }
        if increase {
            if let last = decimals.last {
                result.insert(characters[last] == "0" ? "0" : characters[last], at: last + 1)
            } else {
                result.insert("0", at: point + 1)
            }
        } else if let last = decimals.last {
            result.remove(at: last)
            if decimals.count == 1 { result.remove(at: point) }
        } else {
            result.remove(at: point)
        }
        return result
    }
}
