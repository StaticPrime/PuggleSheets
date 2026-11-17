import Foundation

/// SpreadsheetML number formats: the built-in ids and date detection.
enum XLSXNumberFormats {
    /// The first id free for custom formats.
    static let firstCustomID = 164

    /// Built-in formats (ECMA-376 Part 1, §18.8.30) as Excel shows them in en-US. Id 0 is General
    /// (nil, Automatic). Ids 27–36 and 50–58 are East Asian dates and times, mapped to their en-US kind.
    static let builtIn: [Int: String] = {
        var formats: [Int: String] = [
            1: "0",
            2: "0.00",
            3: "#,##0",
            4: "#,##0.00",
            5: "\"$\"#,##0_);\\(\"$\"#,##0\\)",
            6: "\"$\"#,##0_);[Red]\\(\"$\"#,##0\\)",
            7: "\"$\"#,##0.00_);\\(\"$\"#,##0.00\\)",
            8: "\"$\"#,##0.00_);[Red]\\(\"$\"#,##0.00\\)",
            9: "0%",
            10: "0.00%",
            11: "0.00E+00",
            12: "# ?/?",
            13: "# ??/??",
            14: "M/d/yyyy",
            15: "d-mmm-yy",
            16: "d-mmm",
            17: "mmm-yy",
            18: "h:mm AM/PM",
            19: "h:mm:ss AM/PM",
            20: "H:mm",
            21: "H:mm:ss",
            22: "M/d/yyyy H:mm",
            37: "#,##0_);(#,##0)",
            38: "#,##0_);[Red](#,##0)",
            39: "#,##0.00_);(#,##0.00)",
            40: "#,##0.00_);[Red](#,##0.00)",
            41: "_(* #,##0_);_(* \\(#,##0\\);_(* \"-\"_);_(@_)",
            42: "_(\"$\"* #,##0_);_(\"$\"* \\(#,##0\\);_(\"$\"* \"-\"_);_(@_)",
            43: "_(* #,##0.00_);_(* \\(#,##0.00\\);_(* \"-\"??_);_(@_)",
            44: "_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)",
            45: "mm:ss",
            46: "[h]:mm:ss",
            47: "mm:ss.0",
            48: "##0.0E+0",
            49: "@",
        ]
        for id in [27, 28, 29, 30, 31, 36, 50, 51, 52, 53, 54, 57, 58] { formats[id] = "M/d/yyyy" }
        formats[32] = "H:mm"
        formats[33] = "H:mm:ss"
        formats[34] = "h:mm AM/PM"
        formats[35] = "h:mm:ss AM/PM"
        formats[55] = "h:mm AM/PM"
        formats[56] = "h:mm:ss AM/PM"
        return formats
    }()

    /// Ids written for patterns that match a built-in format exactly. The locale-dependent currency
    /// formats (5–8, 41–44) are written as custom formats so they keep their dollar sign everywhere.
    static let builtInIDs: [String: Int] = {
        var ids: [String: Int] = [:]
        for id in [1, 2, 3, 4, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 37, 38, 39, 40, 45, 46, 47, 48, 49] {
            if let pattern = builtIn[id] { ids[pattern] = id }
        }
        return ids
    }()

    /// The pattern for a format id, given the file's custom formats; nil for General.
    static func pattern(for id: Int, custom: [Int: String]) -> String? {
        if let code = custom[id] { return isGeneral(code) ? nil : code }
        return builtIn[id]
    }

    static func isGeneral(_ pattern: String) -> Bool {
        pattern.caseInsensitiveCompare("General") == .orderedSame
    }

    /// True for formats that show a calendar date (with or without a time), whose numbers are serial
    /// dates: those shift when a workbook uses the 1904 date system. Times of day and durations don't.
    static func showsDate(_ pattern: String?) -> Bool {
        guard let pattern, !isGeneral(pattern) else { return false }
        switch NumberFormatPresets.kind(of: pattern) {
        case .date, .dateTime: return true
        case .time, .duration: return false
        default: return hasDateTokens(pattern)
        }
    }

    /// Looks for day, month or year codes outside quoted text, escapes and bracketed sections.
    /// "m" is a month unless the format also has hours or seconds; elapsed-time brackets ([h]) make
    /// a duration.
    static func hasDateTokens(_ pattern: String) -> Bool {
        let scalars = Array(pattern.unicodeScalars)
        var hasDay = false, hasYear = false, hasM = false, hasHour = false, hasSecond = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\"":
                index += 1
                while index < scalars.count, scalars[index] != "\"" { index += 1 }
            case "\\", "_", "*":
                index += 1
            case "[":
                let start = index + 1
                while index < scalars.count, scalars[index] != "]" { index += 1 }
                let content = String(String.UnicodeScalarView(scalars[min(start, index)..<index])).lowercased()
                if !content.isEmpty, content.allSatisfy({ $0 == "h" || $0 == "m" || $0 == "s" }) { return false }
            case "a", "A":
                // AM/PM and A/P aren't months.
                let rest = String(String.UnicodeScalarView(scalars[index...].prefix(5))).uppercased()
                if rest.hasPrefix("AM/PM") {
                    index += 4
                } else if rest.hasPrefix("A/P") {
                    index += 2
                }
            case "d", "D": hasDay = true
            case "y", "Y": hasYear = true
            case "m", "M": hasM = true
            case "h", "H": hasHour = true
            case "s", "S": hasSecond = true
            default: break
            }
            index += 1
        }
        return hasDay || hasYear || (hasM && !hasHour && !hasSecond)
    }
}
