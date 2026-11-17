import Foundation

/// OpenDocument data styles (number:number-style, percentage-style, currency-style, date-style,
/// time-style, text-style) and our number format patterns.
enum ODSNumberStyles {
    // MARK: - Reading

    /// The pattern a data style shows, or nil for General and for styles patterns can't express (eras,
    /// quarters, weeks, booleans…), which then show as Automatic. `styles` holds every data style by
    /// name, for the other styles a style maps conditions to.
    static func pattern(of node: XNode, styles: [String: XNode]) -> String? {
        guard let main = section(of: node) else { return nil }
        let maps = node.children("map")
        guard !maps.isEmpty else { return main == "General" ? nil : main }
        var conditional: [(condition: String, text: String)] = []
        for map in maps {
            guard let condition = map["condition"].map(normalizedCondition), let name = map["apply-style-name"],
                  let target = styles[name], target !== node, let section = section(of: target) else { continue }
            conditional.append((condition, section))
        }
        switch conditional.map(\.condition) {
        case []:
            return main == "General" ? nil : main
        case ["value()>=0"], ["value()>0"]:
            return conditional[0].text + ";" + main
        case ["value()<0"], ["value()<=0"]:
            return main + ";" + conditional[0].text
        case ["value()>0", "value()<0"]:
            return conditional[0].text + ";" + conditional[1].text + ";" + main
        case ["value()<0", "value()>0"]:
            return conditional[1].text + ";" + conditional[0].text + ";" + main
        default:
            // Other conditions become bracketed conditions on the first sections.
            let sections = conditional.prefix(2).map { "[\($0.condition.dropFirst("value()".count))]" + $0.text }
            return (sections + [main]).joined(separator: ";")
        }
    }

    private static func normalizedCondition(_ condition: String) -> String {
        condition.replacingOccurrences(of: " ", with: "")
    }

    /// One section of a pattern from a data style's elements; nil when an element can't be expressed.
    private static func section(of node: XNode) -> String? {
        let kind = node.name
        guard kind.hasSuffix("-style"), kind != "boolean-style" else { return nil }
        let isDateTime = kind == "date-style" || kind == "time-style"
        let elapsed = kind == "time-style" && node["truncate-on-overflow"] == "false"
        let twelveHour = node.children.contains { $0.name == "am-pm" }
        var text = ""
        var firstTimeElement = true
        for child in node.children {
            switch child.name {
            case "number":
                guard let number = numberText(child) else { return nil }
                text += number
            case "scientific-number":
                text += scientificText(child)
            case "fraction":
                text += fractionText(child)
            case "currency-symbol":
                text += quotedLiteral(child.text)
            case "text":
                text += literal(child.text, isDateTime: isDateTime, percent: kind == "percentage-style")
            case "text-content":
                text += "@"
            case "day":
                text += child["style"] == "long" ? "dd" : "d"
            case "month":
                let long = child["style"] == "long"
                text += XLSXValue.isTrue(child["textual"]) ? (long ? "MMMM" : "MMM") : (long ? "MM" : "M")
            case "year":
                text += child["style"] == "long" ? "yyyy" : "yy"
            case "day-of-week":
                text += child["style"] == "long" ? "dddd" : "ddd"
            case "hours":
                let letters = child["style"] == "long" ? "hh" : "h"
                let hours = twelveHour ? letters : letters.uppercased()
                text += elapsed && firstTimeElement ? "[\(letters)]" : hours
                firstTimeElement = false
            case "minutes":
                let letters = child["style"] == "long" ? "mm" : "m"
                text += elapsed && firstTimeElement ? "[\(letters)]" : letters
                firstTimeElement = false
            case "seconds":
                let letters = child["style"] == "long" ? "ss" : "s"
                text += elapsed && firstTimeElement ? "[\(letters)]" : letters
                if let decimals = XLSXValue.int(child["decimal-places"]), decimals > 0 { text += "." + String(repeating: "0", count: min(decimals, 3)) }
                firstTimeElement = false
            case "am-pm":
                text += "AM/PM"
            case "text-properties":
                if let color = child["color"].flatMap({ RGBColor(hex: $0) }), let name = colorName(color) { text = "[\(name)]" + text }
            case "map", "fill-character":
                continue
            default:
                // Eras, quarters, weeks of the year, booleans.
                return nil
            }
        }
        if !text.contains(where: { !$0.isWhitespace }) { return nil }
        return text
    }

    private static func numberText(_ node: XNode) -> String? {
        guard node.children("embedded-text").isEmpty else { return nil }
        // LibreOffice's General is a number without decimal places.
        guard let decimals = XLSXValue.int(node["decimal-places"]) else { return "General" }
        let minimumDecimals = min(XLSXValue.int(node["min-decimal-places"]) ?? decimals, decimals)
        let integerDigits = max(0, XLSXValue.int(node["min-integer-digits"]) ?? 1)
        var text = integerPart(digits: integerDigits, grouping: XLSXValue.isTrue(node["grouping"]))
        if decimals > 0 {
            text += "." + String(repeating: "0", count: max(0, minimumDecimals)) + String(repeating: "#", count: max(0, decimals - minimumDecimals))
        }
        if let factor = XLSXValue.double(node["display-factor"]), factor >= 1000 {
            text += String(repeating: ",", count: max(0, Int((log10(factor) / 3).rounded())))
        }
        return text
    }

    /// "0", "#,##0", "#,#00"… for `digits` required integer digits.
    private static func integerPart(digits: Int, grouping: Bool) -> String {
        guard grouping else { return digits == 0 ? "#" : String(repeating: "0", count: digits) }
        switch digits {
        case 0: return "#,###"
        case 1: return "#,##0"
        case 2: return "#,#00"
        case 3: return "#,000"
        default: return String(repeating: "0", count: digits - 3) + ",000"
        }
    }

    private static func scientificText(_ node: XNode) -> String {
        let decimals = max(0, XLSXValue.int(node["decimal-places"]) ?? 2)
        let integerDigits = max(1, XLSXValue.int(node["min-integer-digits"]) ?? 1)
        let exponentDigits = max(1, XLSXValue.int(node["min-exponent-digits"]) ?? 2)
        let interval = XLSXValue.int(node["exponent-interval"]) ?? 1
        var mantissa = interval > 1 ? String(repeating: "#", count: max(0, interval - integerDigits)) + String(repeating: "0", count: integerDigits)
            : String(repeating: "0", count: integerDigits)
        if decimals > 0 { mantissa += "." + String(repeating: "0", count: decimals) }
        return mantissa + "E+" + String(repeating: "0", count: exponentDigits)
    }

    private static func fractionText(_ node: XNode) -> String {
        var text = ""
        if let whole = XLSXValue.int(node["min-integer-digits"]) {
            text = (whole > 0 ? String(repeating: "0", count: whole) : "#") + " "
        }
        let numerator = max(1, XLSXValue.int(node["min-numerator-digits"]) ?? 1)
        text += String(repeating: "?", count: numerator) + "/"
        if let denominator = XLSXValue.int(node["denominator-value"]), denominator > 0 {
            text += String(denominator)
        } else {
            text += String(repeating: "?", count: max(1, XLSXValue.int(node["min-denominator-digits"]) ?? numerator))
        }
        return text
    }

    /// Text that shows as is: characters patterns read literally stay plain, others are quoted.
    private static func literal(_ text: String, isDateTime: Bool, percent: Bool) -> String {
        var result = ""
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            result += "\"" + pending + "\""
            pending = ""
        }
        for character in text {
            let plain: Bool
            switch character {
            case " ", "-", "(", ")", "+", "=", "$", "€", "£", "¥", ":", "!", "^", "&", "'", "~", "{", "}", "<", ">": plain = true
            case "/", ",", ".": plain = isDateTime
            case "%": plain = percent
            default: plain = false
            }
            if character == "\"" {
                flush()
                result += "\\\""
            } else if plain {
                flush()
                result.append(character)
            } else {
                pending.append(character)
            }
        }
        flush()
        return result
    }

    private static func quotedLiteral(_ text: String) -> String {
        text.isEmpty ? "" : "\"" + text.replacingOccurrences(of: "\"", with: "") + "\""
    }

    private static let namedColors: [(name: String, color: RGBColor)] = [
        ("Black", .black), ("White", .white), ("Red", RGBColor(red: 255, green: 0, blue: 0)), ("Green", RGBColor(red: 0, green: 255, blue: 0)),
        ("Blue", RGBColor(red: 0, green: 0, blue: 255)), ("Yellow", RGBColor(red: 255, green: 255, blue: 0)),
        ("Magenta", RGBColor(red: 255, green: 0, blue: 255)), ("Cyan", RGBColor(red: 0, green: 255, blue: 255)),
    ]

    /// "Red" or "Color10", for a color patterns can name.
    private static func colorName(_ color: RGBColor) -> String? {
        if let named = namedColors.first(where: { $0.color == color }) { return named.name }
        if let index = FormatParser.palette.firstIndex(of: color) { return "Color\(index + 1)" }
        return nil
    }

    // MARK: - Writing

    /// Writes the data style `name` for `pattern` (with volatile styles `nameP0`, `nameP1` for the other
    /// sections of multi-section patterns). False when the pattern can't be written; cells then go
    /// without a data style and show as Automatic.
    static func write(pattern: String, name: String, into xml: inout XMLWriter) -> Bool {
        let parsed = FormatCache.shared.format(for: pattern)
        guard parsed.isValid else { return false }
        let sections = parsed.numberSections.isEmpty ? (parsed.textSection.map { [$0] } ?? []) : parsed.numberSections
        guard !sections.isEmpty else { return false }
        let main: FormatSection
        var maps: [(condition: String, section: FormatSection)] = []
        switch sections.count {
        case 1:
            main = sections[0]
        case 2:
            main = sections[1]
            maps = [(condition(sections[0].condition) ?? "value()>=0", sections[0])]
        default:
            main = sections[2]
            maps = [(condition(sections[0].condition) ?? "value()>0", sections[0]),
                    (condition(sections[1].condition) ?? "value()<0", sections[1])]
        }
        var fragments: [XMLWriter] = []
        for (index, map) in maps.enumerated() {
            guard let fragment = style(map.section, name: "\(name)P\(index)", volatile: true, maps: []) else { return false }
            fragments.append(fragment)
        }
        guard let mainFragment = style(main, name: name, volatile: false,
                                       maps: maps.enumerated().map { ($0.element.condition, "\(name)P\($0.offset)") }) else { return false }
        for fragment in fragments { xml.append(fragment) }
        xml.append(mainFragment)
        return true
    }

    private static func condition(_ condition: FormatCondition?) -> String? {
        guard let condition else { return nil }
        let symbol = switch condition.comparison {
        case .less: "<"
        case .lessOrEqual: "<="
        case .greater: ">"
        case .greaterOrEqual: ">="
        case .equal: "="
        case .notEqual: "!="
        }
        return "value()" + symbol + XLSXValue.string(condition.operand)
    }

    /// One data style element for one section.
    private static func style(_ section: FormatSection, name: String, volatile: Bool, maps: [(String, String)]) -> XMLWriter? {
        let element: String
        switch section.kind {
        case .number:
            element = section.hasPercent ? "number:percentage-style" : section.hasCurrency ? "number:currency-style" : "number:number-style"
        case .scientific, .fraction, .general:
            element = "number:number-style"
        case .text:
            element = "number:text-style"
        case .date:
            element = section.hasDateParts ? "number:date-style" : "number:time-style"
        }
        var xml = XMLWriter(fragmentCapacity: 256)
        xml.raw("<\(element)")
        xml.attribute("style:name", name)
        if volatile { xml.raw(" style:volatile=\"true\"") }
        if section.kind == .date, section.hasElapsed { xml.raw(" number:truncate-on-overflow=\"false\"") }
        xml.raw(">")
        if let color = section.color { xml.raw("<style:text-properties fo:color=\"#\(color.hex.lowercased())\"/>") }
        var text = ""
        func flushText() {
            guard !text.isEmpty else { return }
            xml.raw("<number:text>")
            xml.text(text)
            xml.raw("</number:text>")
            text = ""
        }
        var wroteNumber = false
        var pendingSeconds: Bool?
        let lastFractionPart = section.parts.lastIndex { part in
            switch part {
            case .numeratorDigit, .fractionSlash, .denominatorDigit, .fixedDenominator: true
            default: false
            }
        } ?? -1
        func flushSeconds(decimals: Int = 0) {
            guard let twoDigits = pendingSeconds else { return }
            xml.raw("<number:seconds")
            if twoDigits { xml.raw(" number:style=\"long\"") }
            if decimals > 0 { xml.raw(" number:decimal-places=\"\(decimals)\"") }
            xml.raw("/>")
            pendingSeconds = nil
        }
        for (index, part) in section.parts.enumerated() {
            if case .secondFraction = part {} else if pendingSeconds != nil {
                // Seconds wait for a possible fraction after them.
                if case .literal(let bytes) = part, bytes == [0x2E], index + 1 < section.parts.count,
                   case .secondFraction = section.parts[index + 1] {
                    continue
                }
                flushSeconds()
            }
            switch part {
            case .literal(let bytes):
                // A fraction's parts make one element: what sits between them goes with it.
                if section.kind == .fraction, wroteNumber, index < lastFractionPart { continue }
                text += String(decoding: bytes, as: UTF8.self)
            case .fill:
                continue
            case .integerDigit, .decimalPoint, .fractionDigit, .exponentMarker, .exponentDigit,
                 .numeratorDigit, .fractionSlash, .denominatorDigit, .fixedDenominator:
                guard !wroteNumber else { continue }
                if section.kind == .number, !text.isEmpty, section.hasCurrency {
                    writeCurrencyText(&text, into: &xml)
                }
                flushText()
                if section.kind == .fraction {
                    writeFraction(section, into: &xml)
                } else {
                    writeNumber(section, into: &xml)
                }
                wroteNumber = true
            case .general:
                flushText()
                xml.raw("<number:number number:min-integer-digits=\"1\"/>")
                wroteNumber = true
            case .text:
                flushText()
                xml.raw("<number:text-content/>")
            case .year(let fourDigits):
                flushText()
                xml.raw(fourDigits ? "<number:year number:style=\"long\"/>" : "<number:year/>")
            case .month(let style):
                flushText()
                switch style {
                case .number: xml.raw("<number:month/>")
                case .paddedNumber: xml.raw("<number:month number:style=\"long\"/>")
                case .short, .initial: xml.raw("<number:month number:textual=\"true\"/>")
                case .full: xml.raw("<number:month number:style=\"long\" number:textual=\"true\"/>")
                }
            case .day(let twoDigits):
                flushText()
                xml.raw(twoDigits ? "<number:day number:style=\"long\"/>" : "<number:day/>")
            case .weekday(let full):
                flushText()
                xml.raw(full ? "<number:day-of-week number:style=\"long\"/>" : "<number:day-of-week/>")
            case .hour(let twoDigits):
                flushText()
                xml.raw(twoDigits ? "<number:hours number:style=\"long\"/>" : "<number:hours/>")
            case .minute(let twoDigits):
                flushText()
                xml.raw(twoDigits ? "<number:minutes number:style=\"long\"/>" : "<number:minutes/>")
            case .second(let twoDigits):
                flushText()
                pendingSeconds = twoDigits
            case .secondFraction(let digits):
                if text.hasSuffix(".") { text.removeLast() }
                flushText()
                flushSeconds(decimals: digits)
            case .elapsedHours(let digits):
                flushText()
                xml.raw(digits >= 2 ? "<number:hours number:style=\"long\"/>" : "<number:hours/>")
            case .elapsedMinutes(let digits):
                flushText()
                xml.raw(digits >= 2 ? "<number:minutes number:style=\"long\"/>" : "<number:minutes/>")
            case .elapsedSeconds(let digits):
                flushText()
                xml.raw(digits >= 2 ? "<number:seconds number:style=\"long\"/>" : "<number:seconds/>")
            case .amPm:
                flushText()
                xml.raw("<number:am-pm/>")
            }
        }
        flushSeconds()
        if section.kind == .number, section.hasCurrency { writeCurrencyText(&text, into: &xml) }
        flushText()
        for map in maps {
            xml.raw("<style:map")
            xml.attribute("style:condition", map.0)
            xml.attribute("style:apply-style-name", map.1)
            xml.raw("/>")
        }
        xml.raw("</\(element)>")
        return xml
    }

    /// Writes `text` with its currency symbols as `number:currency-symbol`, emptying it.
    private static func writeCurrencyText(_ text: inout String, into xml: inout XMLWriter) {
        let symbols: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "¢", "₪", "₫", "₱", "฿", "₺", "₴", "₦"]
        var plain = ""
        for character in text {
            if symbols.contains(character) {
                if !plain.isEmpty {
                    xml.raw("<number:text>")
                    xml.text(plain)
                    xml.raw("</number:text>")
                    plain = ""
                }
                xml.raw("<number:currency-symbol>")
                xml.text(String(character))
                xml.raw("</number:currency-symbol>")
            } else {
                plain.append(character)
            }
        }
        text = plain
    }

    private static func writeNumber(_ section: FormatSection, into xml: inout XMLWriter) {
        let integerZeros = section.parts.filter { if case .integerDigit(.zero, _) = $0 { true } else { false } }.count
        let fractionZeros = section.parts.filter { if case .fractionDigit(.zero, _) = $0 { true } else { false } }.count
        if section.kind == .scientific {
            let exponentZeros = section.parts.filter { if case .exponentDigit = $0 { true } else { false } }.count
            xml.raw("<number:scientific-number number:decimal-places=\"\(section.fractionCount)\"")
            xml.raw(" number:min-integer-digits=\"\(max(1, integerZeros))\" number:min-exponent-digits=\"\(max(1, exponentZeros))\"")
            if section.engineering { xml.raw(" number:exponent-interval=\"\(section.integerCount)\"") }
            xml.raw("/>")
            return
        }
        xml.raw("<number:number number:decimal-places=\"\(section.fractionCount)\" number:min-decimal-places=\"\(fractionZeros)\"")
        xml.raw(" number:min-integer-digits=\"\(integerZeros)\"")
        if section.grouping { xml.raw(" number:grouping=\"true\"") }
        let percentShift = section.hasPercent ? 2 : 0
        let scaling = (percentShift - section.decimalShift) / 3
        if scaling > 0 { xml.raw(" number:display-factor=\"\(XLSXValue.string(pow(1000, Double(scaling))))\"") }
        xml.raw("/>")
    }

    private static func writeFraction(_ section: FormatSection, into xml: inout XMLWriter) {
        xml.raw("<number:fraction")
        if section.hasWholePart {
            let zeros = section.parts.filter { if case .integerDigit(.zero, _) = $0 { true } else { false } }.count
            xml.raw(" number:min-integer-digits=\"\(zeros)\"")
        }
        xml.raw(" number:min-numerator-digits=\"\(max(1, section.numeratorCount))\"")
        if section.fixedDenominator > 0 {
            xml.raw(" number:denominator-value=\"\(section.fixedDenominator)\"")
        } else {
            xml.raw(" number:min-denominator-digits=\"\(max(1, section.denominatorCount))\"")
        }
        xml.raw("/>")
    }
}
