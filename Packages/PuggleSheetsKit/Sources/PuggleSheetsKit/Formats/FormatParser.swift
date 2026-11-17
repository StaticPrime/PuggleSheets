import Foundation

/// Parses number format patterns into `ParsedFormat`.
enum FormatParser {
    static func parse(_ pattern: String) -> ParsedFormat {
        let characters = Array(pattern)
        guard !characters.isEmpty else { return .invalid }
        let rawSections = splitSections(characters)
        guard rawSections.count <= 4 else { return .invalid }
        var sections: [FormatSection] = []
        for raw in rawSections {
            guard let section = compileSection(raw) else { return .invalid }
            sections.append(section)
        }
        return ParsedFormat(sections: sections)
    }

    /// Splits at ";" outside quotes, brackets and escapes.
    static func splitSections(_ characters: [Character]) -> [[Character]] {
        var sections: [[Character]] = [[]]
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case ";":
                sections.append([])
                index += 1
                continue
            case "\"":
                let end = characters[(index + 1)...].firstIndex(of: "\"") ?? characters.count - 1
                sections[sections.count - 1].append(contentsOf: characters[index...end])
                index = end + 1
                continue
            case "[":
                let end = characters[(index + 1)...].firstIndex(of: "]") ?? characters.count - 1
                sections[sections.count - 1].append(contentsOf: characters[index...end])
                index = end + 1
                continue
            case "\\", "_", "*":
                let end = min(index + 1, characters.count - 1)
                sections[sections.count - 1].append(contentsOf: characters[index...end])
                index = end + 1
                continue
            default:
                sections[sections.count - 1].append(character)
                index += 1
            }
        }
        return sections
    }

    // MARK: - Tokens

    fileprivate enum Token {
        case literal(String)
        /// An unquoted 1–9: shown as is, or part of a fraction's fixed denominator.
        case literalDigit(Character)
        case digit(DigitPlaceholder)
        case point, comma, percent, slash, at, general
        case exponent(uppercase: Bool, alwaysSign: Bool)
        case fill(Character)
        /// A run of y, m, d, h or s (lowercased letter, run length).
        case dateLetter(Character, Int)
        /// [h], [mm], [ss]…
        case elapsed(Character, Int)
        case amPm(AmPmStyle)

        var isDateToken: Bool {
            switch self {
            case .dateLetter, .elapsed, .amPm: true
            default: false
            }
        }

        var isDigit: Bool {
            if case .digit = self { return true }
            return false
        }

        /// The text shown when the token has no special meaning in its section.
        var literalText: String? {
            switch self {
            case .literal(let text): text
            case .literalDigit(let character): String(character)
            case .digit(.zero): "0"
            case .digit(.hash): "#"
            case .digit(.question): "?"
            case .point: "."
            case .comma: ","
            case .percent: "%"
            case .slash: "/"
            case .at: "@"
            case .general: "General"
            case .exponent(let uppercase, let alwaysSign): (uppercase ? "E" : "e") + (alwaysSign ? "+" : "-")
            case .fill, .dateLetter, .elapsed, .amPm: nil
            }
        }
    }

    private struct TokenizedSection {
        var tokens: [Token] = []
        var color: RGBColor?
        var condition: FormatCondition?
    }

    /// Nil for an invalid section (an unterminated quote or bracket, a malformed condition).
    private static func tokenize(_ characters: [Character]) -> TokenizedSection? {
        var result = TokenizedSection()
        var index = 0
        let count = characters.count

        func matches(_ keyword: String) -> Bool {
            var position = index
            for expected in keyword {
                guard position < count, characters[position].lowercased() == String(expected) else { return false }
                position += 1
            }
            return true
        }

        while index < count {
            let character = characters[index]
            switch character {
            case "\"":
                var end = index + 1
                var text = ""
                while end < count, characters[end] != "\"" {
                    text.append(characters[end])
                    end += 1
                }
                guard end < count else { return nil }
                result.tokens.append(.literal(text))
                index = end + 1
            case "\\":
                if index + 1 < count { result.tokens.append(.literal(String(characters[index + 1]))) }
                index += 2
            case "_":
                if index + 1 < count { result.tokens.append(.literal(" ")) }
                index += 2
            case "*":
                if index + 1 < count { result.tokens.append(.fill(characters[index + 1])) }
                index += 2
            case "[":
                var end = index + 1
                var content = ""
                while end < count, characters[end] != "]" {
                    content.append(characters[end])
                    end += 1
                }
                guard end < count, applyBracket(content, to: &result) else { return nil }
                index = end + 1
            case "0":
                result.tokens.append(.digit(.zero))
                index += 1
            case "#":
                result.tokens.append(.digit(.hash))
                index += 1
            case "?":
                result.tokens.append(.digit(.question))
                index += 1
            case ".":
                result.tokens.append(.point)
                index += 1
            case ",":
                result.tokens.append(.comma)
                index += 1
            case "%":
                result.tokens.append(.percent)
                index += 1
            case "/":
                result.tokens.append(.slash)
                index += 1
            case "@":
                result.tokens.append(.at)
                index += 1
            case "1"..."9":
                result.tokens.append(.literalDigit(character))
                index += 1
            case "E", "e":
                if index + 1 < count, characters[index + 1] == "+" || characters[index + 1] == "-" {
                    result.tokens.append(.exponent(uppercase: character == "E", alwaysSign: characters[index + 1] == "+"))
                    index += 2
                } else {
                    result.tokens.append(.literal(String(character)))
                    index += 1
                }
            default:
                if matches("general") {
                    result.tokens.append(.general)
                    index += 7
                } else if matches("am/pm") {
                    result.tokens.append(.amPm(.full))
                    index += 5
                } else if matches("a/p") {
                    result.tokens.append(.amPm(character == "a" ? .lowerLetter : .upperLetter))
                    index += 3
                } else if let letter = character.lowercased().first, "ymdhs".contains(letter),
                          character.lowercased().count == 1 {
                    var end = index + 1
                    while end < count, characters[end].lowercased().first == letter { end += 1 }
                    result.tokens.append(.dateLetter(letter, end - index))
                    index = end
                } else {
                    result.tokens.append(.literal(String(character)))
                    index += 1
                }
            }
        }
        return result
    }

    static let namedColors: [String: RGBColor] = [
        "black": RGBColor(red: 0, green: 0, blue: 0),
        "white": RGBColor(red: 255, green: 255, blue: 255),
        "red": RGBColor(red: 255, green: 0, blue: 0),
        "green": RGBColor(red: 0, green: 255, blue: 0),
        "blue": RGBColor(red: 0, green: 0, blue: 255),
        "yellow": RGBColor(red: 255, green: 255, blue: 0),
        "magenta": RGBColor(red: 255, green: 0, blue: 255),
        "cyan": RGBColor(red: 0, green: 255, blue: 255),
    ]

    /// The default Excel palette for [Color1]…[Color56].
    static let palette: [RGBColor] = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
    ].map { RGBColor(hex: $0) ?? .black }

    /// Colors, conditions, elapsed time and currency/locale tags. False for a malformed condition.
    private static func applyBracket(_ content: String, to result: inout TokenizedSection) -> Bool {
        let lower = content.lowercased()
        if let color = namedColors[lower] {
            result.color = color
            return true
        }
        if lower.hasPrefix("color"), let number = Int(lower.dropFirst(5)), (1...56).contains(number) {
            result.color = palette[number - 1]
            return true
        }
        if let first = lower.first, "<>=".contains(first) {
            guard let condition = parseCondition(lower) else { return false }
            result.condition = condition
            return true
        }
        if let first = lower.first, "hms".contains(first), lower.allSatisfy({ $0 == first }) {
            result.tokens.append(.elapsed(first, lower.count))
            return true
        }
        if content.hasPrefix("$") {
            // [$€-407]: a currency symbol and a locale code; [$-409] has only the locale.
            let symbol = content.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if !symbol.isEmpty { result.tokens.append(.literal(String(symbol))) }
            return true
        }
        return true
    }

    private static func parseCondition(_ text: String) -> FormatCondition? {
        let operators: [(String, FormatCondition.Comparison)] = [
            ("<=", .lessOrEqual), (">=", .greaterOrEqual), ("<>", .notEqual), ("<", .less), (">", .greater), ("=", .equal),
        ]
        for (symbol, comparison) in operators where text.hasPrefix(symbol) {
            let operand = text.dropFirst(symbol.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(operand), value.isFinite else { return nil }
            return FormatCondition(comparison: comparison, operand: value)
        }
        return nil
    }

    // MARK: - Sections

    /// Collects parts, merging neighboring literals.
    private struct PartsBuilder {
        var parts: [FormatPart] = []
        var pending = ""
        var allLiterals = ""
        var hasFill = false

        mutating func literal(_ text: String) {
            pending += text
            allLiterals += text
        }

        mutating func append(_ part: FormatPart) {
            flush()
            if case .fill = part {
                guard !hasFill else { return }
                hasFill = true
            }
            parts.append(part)
        }

        mutating func flush() {
            guard !pending.isEmpty else { return }
            parts.append(.literal(Array(pending.utf8)))
            pending = ""
        }

        mutating func finish(into section: inout FormatSection) {
            flush()
            section.parts = parts
            section.hasFill = hasFill
            section.hasCurrency = allLiterals.contains { "$€£¥₹₩₽¢₪₫₱฿₺₴₦".contains($0) }
        }
    }

    private static func compileSection(_ characters: [Character]) -> FormatSection? {
        guard let tokenized = tokenize(characters) else { return nil }
        let tokens = tokenized.tokens
        var section: FormatSection
        if tokens.contains(where: \.isDateToken) {
            section = compileDate(tokens)
        } else if tokens.contains(where: { if case .at = $0 { true } else { false } }) {
            section = compileText(tokens)
        } else if tokens.contains(where: { if case .general = $0 { true } else { false } }) {
            section = compileGeneral(tokens)
        } else {
            section = compileNumber(tokens)
        }
        section.color = tokenized.color
        section.condition = tokenized.condition
        if section.kind == .text, tokens.count == 1, tokenized.color == nil { section.isPlainText = true }
        return section
    }

    private static func compileText(_ tokens: [Token]) -> FormatSection {
        var section = FormatSection(kind: .text)
        var parts = PartsBuilder()
        for token in tokens {
            switch token {
            case .at: parts.append(.text)
            case .fill(let character): parts.append(.fill(character))
            default: if let text = token.literalText { parts.literal(text) }
            }
        }
        parts.finish(into: &section)
        return section
    }

    private static func compileGeneral(_ tokens: [Token]) -> FormatSection {
        var section = FormatSection(kind: .general)
        var parts = PartsBuilder()
        var hasGeneral = false
        for token in tokens {
            switch token {
            case .general where !hasGeneral:
                parts.append(.general)
                hasGeneral = true
            case .fill(let character): parts.append(.fill(character))
            default: if let text = token.literalText { parts.literal(text) }
            }
        }
        parts.finish(into: &section)
        return section
    }

    private static func compileDate(_ tokens: [Token]) -> FormatSection {
        var section = FormatSection(kind: .date)
        var parts = PartsBuilder()

        func item(before index: Int) -> Token? {
            tokens[..<index].last(where: \.isDateToken)
        }
        func item(after index: Int) -> Token? {
            tokens[(index + 1)...].first(where: \.isDateToken)
        }
        func isHours(_ token: Token?) -> Bool {
            switch token {
            case .dateLetter("h", _), .elapsed("h", _): true
            default: false
            }
        }
        func isSeconds(_ token: Token?) -> Bool {
            switch token {
            case .dateLetter("s", _), .elapsed("s", _): true
            default: false
            }
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .dateLetter(let letter, let count):
                switch letter {
                case "y":
                    parts.append(.year(fourDigits: count > 2))
                    section.hasDateParts = true
                case "d":
                    parts.append(count <= 2 ? .day(twoDigits: count == 2) : .weekday(full: count >= 4))
                    section.hasDateParts = true
                case "h":
                    parts.append(.hour(twoDigits: count >= 2))
                    section.hasTimeParts = true
                case "s":
                    parts.append(.second(twoDigits: count >= 2))
                    section.hasTimeParts = true
                default:
                    // "m" and "mm" are minutes right after hours or right before seconds.
                    if count <= 2, isHours(item(before: index)) || isSeconds(item(after: index)) {
                        parts.append(.minute(twoDigits: count == 2))
                        section.hasTimeParts = true
                    } else {
                        let style: MonthStyle = switch count {
                        case 1: .number
                        case 2: .paddedNumber
                        case 3: .short
                        case 5: .initial
                        default: .full
                        }
                        parts.append(.month(style))
                        section.hasDateParts = true
                    }
                }
            case .elapsed(let letter, let count):
                switch letter {
                case "h": parts.append(.elapsedHours(minimumDigits: count))
                case "m": parts.append(.elapsedMinutes(minimumDigits: count))
                default: parts.append(.elapsedSeconds(minimumDigits: count))
                }
                section.hasElapsed = true
                section.hasTimeParts = true
            case .amPm(let style):
                parts.append(.amPm(style))
                section.twelveHour = true
                section.hasTimeParts = true
            case .point:
                // Fractions of a second: ".0", ".00", ".000" after seconds.
                var zeros = 0
                while index + 1 + zeros < tokens.count, case .digit(.zero) = tokens[index + 1 + zeros] { zeros += 1 }
                parts.literal(".")
                if zeros > 0, isSeconds(item(before: index)) {
                    parts.append(.secondFraction(digits: zeros))
                    section.secondDigits = max(section.secondDigits, zeros)
                    section.hasTimeParts = true
                    index += zeros
                }
            case .fill(let character):
                parts.append(.fill(character))
            default:
                if let text = token.literalText { parts.literal(text) }
            }
            index += 1
        }
        parts.finish(into: &section)
        return section
    }

    private static func compileNumber(_ tokens: [Token]) -> FormatSection {
        var section = FormatSection(kind: .number)
        let percentCount = tokens.filter { if case .percent = $0 { true } else { false } }.count
        section.hasPercent = percentCount > 0
        section.decimalShift = 2 * percentCount

        var exponentIndex: Int?
        if let first = tokens.firstIndex(where: { if case .exponent = $0 { true } else { false } }),
           tokens[(first + 1)...].contains(where: \.isDigit) {
            exponentIndex = first
        }
        let hasPoint = tokens.contains { if case .point = $0 { true } else { false } }
        if exponentIndex == nil, !hasPoint, let slash = fractionSlash(in: tokens) {
            compileFraction(tokens, slash: slash, into: &section)
            return section
        }

        let count = tokens.count
        let mantissaEnd = exponentIndex ?? count
        let pointIndex = (0..<mantissaEnd).first { if case .point = tokens[$0] { true } else { false } }
        let integerEnd = pointIndex ?? mantissaEnd
        let integerDigits = (0..<integerEnd).filter { tokens[$0].isDigit }
        let fractionDigits = pointIndex.map { (($0 + 1)..<mantissaEnd).filter { tokens[$0].isDigit } } ?? []
        let exponentDigits = exponentIndex.map { (($0 + 1)..<count).filter { tokens[$0].isDigit } } ?? []
        let needsVirtualInteger = integerDigits.isEmpty && (pointIndex != nil || exponentIndex != nil)
        let integerCount = needsVirtualInteger ? 1 : integerDigits.count

        enum CommaRole { case grouping, scaling, literal }
        func role(ofCommaAt index: Int) -> CommaRole {
            var previous = index - 1
            while previous >= 0, case .comma = tokens[previous] { previous -= 1 }
            let followsDigit = previous >= 0 && tokens[previous].isDigit
            if index < integerEnd {
                let digitBefore = integerDigits.contains { $0 < index }
                let digitAfter = integerDigits.contains { $0 > index }
                if digitBefore && digitAfter { return .grouping }
                if followsDigit && !digitAfter { return .scaling }
            } else if index < mantissaEnd, followsDigit, !fractionDigits.contains(where: { $0 > index }) {
                return .scaling
            }
            return .literal
        }

        var parts = PartsBuilder()
        var integerOrdinal = 0
        var fractionOrdinal = 0
        var exponentOrdinal = 0
        var scalingCommas = 0
        for index in 0..<count {
            let token = tokens[index]
            if let exponentIndex, index >= exponentIndex {
                if index == exponentIndex, case .exponent(let uppercase, let alwaysSign) = token {
                    if needsVirtualInteger, pointIndex == nil { parts.append(.integerDigit(.hash, position: 0)) }
                    parts.append(.exponentMarker(uppercase: uppercase, alwaysSign: alwaysSign))
                    continue
                }
                switch token {
                case .digit(let placeholder):
                    parts.append(.exponentDigit(placeholder, position: exponentDigits.count - 1 - exponentOrdinal))
                    exponentOrdinal += 1
                case .fill(let character): parts.append(.fill(character))
                default: if let text = token.literalText { parts.literal(text) }
                }
                continue
            }
            switch token {
            case .digit(let placeholder):
                if index < integerEnd {
                    parts.append(.integerDigit(placeholder, position: integerCount - 1 - integerOrdinal))
                    integerOrdinal += 1
                } else {
                    parts.append(.fractionDigit(placeholder, index: fractionOrdinal))
                    fractionOrdinal += 1
                }
            case .point:
                if index == pointIndex {
                    if needsVirtualInteger { parts.append(.integerDigit(.hash, position: 0)) }
                    parts.append(.decimalPoint)
                } else {
                    parts.literal(".")
                }
            case .comma:
                switch role(ofCommaAt: index) {
                case .grouping: section.grouping = true
                case .scaling: scalingCommas += 1
                case .literal: parts.literal(",")
                }
            case .fill(let character):
                parts.append(.fill(character))
            default:
                if let text = token.literalText { parts.literal(text) }
            }
        }
        parts.finish(into: &section)
        section.integerCount = integerCount
        section.fractionCount = fractionOrdinal
        section.exponentCount = exponentDigits.count
        section.hasDigits = !integerDigits.isEmpty || !fractionDigits.isEmpty
        if exponentIndex != nil {
            section.kind = .scientific
            section.engineering = integerCount > 1
                && integerDigits.contains { if case .digit(.hash) = tokens[$0] { true } else { false } }
        } else {
            section.decimalShift -= 3 * scalingCommas
        }
        return section
    }

    /// The "/" of a fraction: placeholders right before it and placeholders or a number right after.
    private static func fractionSlash(in tokens: [Token]) -> Int? {
        for index in tokens.indices {
            guard case .slash = tokens[index], index > 0, index + 1 < tokens.count, tokens[index - 1].isDigit else { continue }
            switch tokens[index + 1] {
            case .digit, .literalDigit: return index
            default: continue
            }
        }
        return nil
    }

    private static func compileFraction(_ tokens: [Token], slash: Int, into section: inout FormatSection) {
        section.kind = .fraction
        var numeratorStart = slash - 1
        while numeratorStart > 0, tokens[numeratorStart - 1].isDigit { numeratorStart -= 1 }
        section.numeratorCount = slash - numeratorStart

        var denominatorEnd = slash + 1
        if tokens[slash + 1].isDigit {
            while denominatorEnd < tokens.count, tokens[denominatorEnd].isDigit { denominatorEnd += 1 }
            section.denominatorCount = denominatorEnd - slash - 1
        } else {
            var digits = ""
            while denominatorEnd < tokens.count {
                if case .literalDigit(let character) = tokens[denominatorEnd] {
                    digits.append(character)
                } else if case .digit(.zero) = tokens[denominatorEnd] {
                    digits.append("0")
                } else {
                    break
                }
                denominatorEnd += 1
            }
            section.fixedDenominator = min(Int(digits.prefix(9)) ?? 1, 999_999_999)
            section.denominatorCount = digits.count
        }

        let wholeDigits = (0..<numeratorStart).filter { tokens[$0].isDigit }
        section.integerCount = wholeDigits.count
        section.hasWholePart = !wholeDigits.isEmpty
        section.hasDigits = true

        var parts = PartsBuilder()
        var wholeOrdinal = 0
        for index in tokens.indices {
            let token = tokens[index]
            if index < numeratorStart {
                switch token {
                case .digit(let placeholder):
                    parts.append(.integerDigit(placeholder, position: wholeDigits.count - 1 - wholeOrdinal))
                    wholeOrdinal += 1
                case .comma:
                    if let first = wholeDigits.first, let last = wholeDigits.last, first < index, index < last {
                        section.grouping = true
                    } else {
                        parts.literal(",")
                    }
                case .fill(let character): parts.append(.fill(character))
                default: if let text = token.literalText { parts.literal(text) }
                }
            } else if index < slash {
                if case .digit(let placeholder) = token {
                    parts.append(.numeratorDigit(placeholder, position: slash - 1 - index))
                }
            } else if index == slash {
                parts.append(.fractionSlash)
            } else if index < denominatorEnd {
                if section.fixedDenominator == 0, case .digit(let placeholder) = token {
                    parts.append(.denominatorDigit(placeholder, index: index - slash - 1))
                } else if section.fixedDenominator != 0, index == slash + 1 {
                    parts.append(.fixedDenominator(asciiDigits(of: section.fixedDenominator)))
                }
            } else {
                switch token {
                case .fill(let character): parts.append(.fill(character))
                default: if let text = token.literalText { parts.literal(text) }
                }
            }
        }
        parts.finish(into: &section)
    }
}
