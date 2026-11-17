import Foundation

/// The text of axis ticks, data labels and pie slices, in the data's number format.
///
/// Tick labels use the format of the axis' first series (the labels' format on a numeric horizontal
/// axis), so dates, currency and percents read as they do in the cells. Two refinements:
/// - Numbers in Automatic format get as many decimals as the tick step needs ("0.25", "0.50"), with
///   thousands separators on value axes ("2,500").
/// - When the biggest tick reaches 10,000, numbers, currency and Automatic are shortened with K, M, B
///   and T ("25K", "$1.5M"), keeping the format's currency symbol and other text around the digits.
///   Dates, times, durations, percents and scientific formats are never shortened.
enum ChartNumberText {
    static let compactThreshold = 10_000.0

    /// Labels for `ticks`, which are `step` apart (0 when they aren't evenly spaced).
    static func tickLabels(_ ticks: [Double], step: Double, pattern: String?, grouping: Bool = true) -> [String] {
        let maxMagnitude = ticks.reduce(0) { Swift.max($0, abs($1)) }
        switch NumberFormatPresets.kind(of: pattern) {
        case .date, .time, .dateTime, .duration, .percent, .scientific:
            return ticks.map { text($0, pattern: pattern) }
        case .number, .currency, .accounting:
            if maxMagnitude >= compactThreshold {
                let affixes = self.affixes(of: pattern)
                return ticks.map { compact($0, prefix: affixes.prefix, suffix: affixes.suffix) }
            }
            return ticks.map { text($0, pattern: pattern) }
        case .automatic, .plainText:
            if maxMagnitude >= compactThreshold { return ticks.map { compact($0, prefix: "", suffix: "") } }
            let decimals = step > 0 ? ChartTicks.decimals(of: step) : 0
            if step <= 0 { return ticks.map { text($0, pattern: nil) } }
            var automatic = grouping ? "#,##0" : "0"
            if decimals > 0 { automatic += "." + String(repeating: "0", count: Swift.min(decimals, 10)) }
            return ticks.map { text($0, pattern: automatic) }
        }
    }

    /// A number in a pattern, without the padding Accounting adds.
    static func text(_ value: Double, pattern: String?) -> String {
        let shown = CellDisplay.text(for: .number(value == 0 ? 0 : value), pattern: pattern).text
        guard let first = shown.utf8.first, let last = shown.utf8.last else { return shown }
        // Trim only when needed: most labels have no padding.
        if first == 0x20 || last == 0x20 { return shown.trimmingCharacters(in: .whitespaces) }
        return shown
    }

    /// A data label: the value as its cell shows it.
    static func dataLabel(_ value: Double, pattern: String?) -> String {
        text(value, pattern: pattern)
    }

    /// A pie slice's share: "36.4%", "25%".
    static func percent(_ fraction: Double) -> String {
        let tenths = (fraction * 1000).rounded()
        if tenths.truncatingRemainder(dividingBy: 10) == 0 { return "\(Int(tenths / 10))%" }
        return "\(Int(tenths) / 10).\(abs(Int(tenths) % 10))%"
    }

    /// "1.5M": the value in thousands (K), millions (M), billions (B) or trillions (T), with up to two
    /// decimals, between `prefix` and `suffix` ("$", " €").
    static func compact(_ value: Double, prefix: String, suffix: String) -> String {
        let units: [(size: Double, symbol: String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K"), (1, "")]
        let magnitude = abs(value)
        var unit = units.count - 1
        for (index, candidate) in units.enumerated() where magnitude >= candidate.size * (1 - 1e-12) {
            unit = index
            break
        }
        var scaled = (magnitude / units[unit].size * 100).rounded() / 100
        // 999,999 rounds to 1000K: say 1M instead.
        if scaled >= 1000, unit > 0 {
            unit -= 1
            scaled = (magnitude / units[unit].size * 100).rounded() / 100
        }
        let digits = shortDecimal(scaled)
        let sign = value < 0 && digits != "0" ? "-" : ""
        return sign + prefix + digits + units[unit].symbol + suffix
    }

    /// Up to two decimals, trailing zeros dropped: "2.5", "10", "1.25".
    static func shortDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let hundredths = (value * 100).rounded()
        guard abs(hundredths) < 9e15 else { return String(format: "%.0f", value) }
        let whole = Int(hundredths) / 100
        let fraction = abs(Int(hundredths) % 100)
        if fraction == 0 { return String(whole) }
        return fraction % 10 == 0 ? "\(whole).\(fraction / 10)" : "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// The text a pattern puts around the digits of a positive number: ("$", "") for "$#,##0.00",
    /// ("", " €") for "#,##0.00 €".
    static func affixes(of pattern: String?) -> (prefix: String, suffix: String) {
        guard let pattern, !pattern.isEmpty else { return ("", "") }
        let sample = text(1234.5, pattern: pattern)
        let scalars = Array(sample.unicodeScalars)
        guard let first = scalars.firstIndex(where: { ("0"..."9").contains($0) }),
              let last = scalars.lastIndex(where: { ("0"..."9").contains($0) }) else { return ("", "") }
        var prefix = String(String.UnicodeScalarView(scalars[..<first]))
        var suffix = String(String.UnicodeScalarView(scalars[(last + 1)...]))
        prefix = prefix.trimmingCharacters(in: .whitespaces)
        suffix = suffix.hasPrefix(" ") ? " " + suffix.trimmingCharacters(in: .whitespaces) : suffix.trimmingCharacters(in: .whitespaces)
        if suffix == " " { suffix = "" }
        return (prefix, suffix)
    }
}
