import Foundation

/// Text conventions of SpreadsheetML.
enum XLSXText {
    /// Decodes Excel's `_xHHHH_` escapes (Excel writes carriage returns and other control characters
    /// this way) and turns "\r\n" and lone "\r" into "\n", the only line break cells use.
    static func decode(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == UInt8(ascii: "_") || $0 == 0x0D }) else { return text }
        let scalars = Array(text.unicodeScalars)
        var decoded: [Unicode.Scalar] = []
        decoded.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            if let value = escapeValue(scalars, at: index) {
                if (0xD800...0xDBFF).contains(value), let low = escapeValue(scalars, at: index + 7), (0xDC00...0xDFFF).contains(low),
                   let scalar = Unicode.Scalar(0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)) {
                    decoded.append(scalar)
                    index += 14
                    continue
                }
                if let scalar = Unicode.Scalar(value) {
                    decoded.append(scalar)
                    index += 7
                    continue
                }
            }
            decoded.append(scalars[index])
            index += 1
        }
        var result = String.UnicodeScalarView()
        index = 0
        while index < decoded.count {
            let scalar = decoded[index]
            index += 1
            if scalar == "\r" {
                result.append("\n")
                if index < decoded.count, decoded[index] == "\n" { index += 1 }
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// "\r\n" and lone "\r" as "\n".
    static func normalizedLineBreaks(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Escapes literal text that Excel would otherwise read as an `_xHHHH_` escape ("_x0041_" is written
    /// "_x005F_x0041_").
    static func encode(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "_")) else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        for index in scalars.indices {
            if escapeValue(scalars, at: index) != nil {
                result.append(contentsOf: "_x005F_".unicodeScalars)
            } else {
                result.append(scalars[index])
            }
        }
        return String(result)
    }

    /// The code unit of an `_xHHHH_` escape starting at `index`.
    private static func escapeValue(_ scalars: [Unicode.Scalar], at index: Int) -> UInt32? {
        guard index + 6 < scalars.count, scalars[index] == "_", scalars[index + 1] == "x" || scalars[index + 1] == "X",
              scalars[index + 6] == "_" else { return nil }
        var value: UInt32 = 0
        for offset in 2...5 {
            guard let digit = hexDigit(scalars[index + offset]) else { return nil }
            value = value << 4 | digit
        }
        return value
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39: scalar.value - 0x30
        case 0x41...0x46: scalar.value - 0x41 + 10
        case 0x61...0x66: scalar.value - 0x61 + 10
        default: nil
        }
    }

    /// Text without xml:space="preserve" loses its leading and trailing whitespace, as in Excel.
    static func trimmingXMLWhitespace(_ text: String) -> String {
        let utf8 = text.utf8
        guard let first = utf8.first, let last = utf8.last, isXMLWhitespace(first) || isXMLWhitespace(last) else { return text }
        guard let start = utf8.firstIndex(where: { !isXMLWhitespace($0) }),
              let end = utf8.lastIndex(where: { !isXMLWhitespace($0) }) else { return "" }
        return String(text[start...end])
    }

    /// True when text starts or ends with whitespace, which needs xml:space="preserve" to survive.
    static func needsPreservedSpace(_ text: String) -> Bool {
        guard let first = text.utf8.first, let last = text.utf8.last else { return false }
        return isXMLWhitespace(first) || isXMLWhitespace(last)
    }

    private static func isXMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

/// Attribute value helpers.
enum XLSXValue {
    /// xsd:boolean: "1" and "true" (also "on", as some writers use).
    static func isTrue(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "1", "true", "on": true
        default: false
        }
    }

    /// Absent means true, as for `<b/>`; "0", "false", "off" and "none" turn the property off.
    static func isOn(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return true }
        return !(value == "0" || value == "false" || value == "off" || value == "none")
    }

    static func double(_ value: String?) -> Double? {
        guard let value else { return nil }
        if let number = Double(value), number.isFinite { return number }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(trimmed), number.isFinite else { return nil }
        return number
    }

    static func int(_ value: String?) -> Int? {
        guard let value else { return nil }
        if let number = Int(value) { return number }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The shortest text that reads back as the same number ("15.75", "0.1", "1E-05").
    static func string(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return "\(number)".uppercased()
    }
}

/// The size of an Excel worksheet.
enum XLSXLimits {
    static let rows = 1_048_576
    static let columns = 16_384
}

/// Conversions between Excel's units and pixels at 100% zoom, for Excel's standard maximum digit width
/// of 7 pixels (Calibri 11 and Arial 10 alike).
enum XLSXUnits {
    static let maximumDigitWidth = 7.0

    /// Pixels for a stored column width (`<col width>`, `defaultColWidth`). The stored width already
    /// includes the 5 pixels of cell padding (ECMA-376 Part 1, §18.3.1.13), so a width of 8.7109375 is
    /// 61 pixels and Excel's 64-pixel default is 9.140625.
    static func pixels(fromColumnWidth width: Double) -> Double {
        let padding = (128 / maximumDigitWidth).rounded(.down)
        return max(0, ((256 * width + padding) / 256 * maximumDigitWidth).rounded(.down))
    }

    /// The stored column width Excel writes for a width in pixels (exact for whole pixels).
    static func columnWidth(fromPixels pixels: Double) -> Double {
        (max(0, pixels) * 256 / maximumDigitWidth).rounded(.down) / 256
    }

    /// Pixels for `baseColWidth`, a count of digits without padding. Excel adds the padding and rounds
    /// the default column width up to a multiple of 8 pixels: 8 digits make Excel's usual 64 pixels.
    static func pixels(fromBaseColumnWidth characters: Double) -> Double {
        ((characters * maximumDigitWidth + 5) / 8).rounded(.up) * 8
    }

    static func pixels(fromPoints points: Double) -> Double {
        max(0, (points * 4 / 3).rounded())
    }

    static func points(fromPixels pixels: Double) -> Double {
        max(0, pixels) * 3 / 4
    }
}
