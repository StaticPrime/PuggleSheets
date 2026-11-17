import Foundation

/// Text positions count UTF-16 units.
extension String {
    var units: [UInt16] { Array(utf16) }

    init(units: some Collection<UInt16>) {
        self = String(decoding: units, as: UTF16.self)
    }

    /// The first index of `needle` in `self` at or after `start`, comparing UTF-16 units.
    static func find(_ needle: [UInt16], in haystack: [UInt16], from start: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        guard !needle.isEmpty else { return start }
        var index = start
        while index + needle.count <= haystack.count {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }
}

extension Evaluator {
    func regex(_ pattern: String, function: String) throws -> NSRegularExpression {
        if let cached = regexCache[pattern] { return cached }
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            regexCache[pattern] = regex
            return regex
        } catch {
            throw CellError(.reference, "Function \(function) parameter 2 value \"\(pattern)\" is not a valid regular expression.")
        }
    }
}

extension Arguments {
    /// A text argument that must really be text (REGEX functions don't convert numbers).
    func strictText(_ index: Int) throws -> String {
        let value = try scalar(index)
        switch value {
        case .text(let text): return text
        case .empty: return ""
        case .number:
            throw FormulaErrors.value("Function \(name) parameter \(index + 1) expects text values. But '\(Coercion.displayText(value))' is a number and cannot be coerced to a string.")
        default:
            throw FormulaErrors.value("Function \(name) parameter \(index + 1) expects text values. But '\(Coercion.displayText(value))' is a boolean and cannot be coerced to a string.")
        }
    }

    func nonNegative(_ index: Int, default defaultValue: Int? = nil) throws -> Int {
        let number: Int
        if let defaultValue {
            number = try integer(index, default: defaultValue)
        } else {
            number = try integer(index)
        }
        guard number >= 0 else {
            throw FormulaErrors.value("Function \(name) parameter \(index + 1) value is negative. It should be positive or zero.")
        }
        return number
    }
}

extension FunctionTable {
    mutating func addTextFunctions() {
        for name in ["CHAR", "UNICHAR"] {
            add(name, 1, 1, lift: Params.all) { a in
                let code = try a.integer(0)
                guard code >= 1, code <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(code)) else {
                    throw FormulaErrors.number("Function \(name) parameter 1 value \(code) is out of range.")
                }
                return .text(String(Character(scalar)))
            }
        }
        add("CLEAN", 1, 1, lift: Params.all) { a in
            var scalars = String.UnicodeScalarView()
            for scalar in try a.text(0).unicodeScalars where scalar.value >= 32 { scalars.append(scalar) }
            return .text(String(scalars))
        }
        for name in ["CODE", "UNICODE"] {
            add(name, 1, 1, lift: Params.all) { a in
                guard let scalar = try a.text(0).unicodeScalars.first else {
                    throw FormulaErrors.value("Function \(name) parameter 1 value should be non-empty.")
                }
                return .number(Double(scalar.value))
            }
        }
        add("CONCAT", 2, 2, lift: Params.all) { a in .text(try a.text(0) + a.text(1)) }
        add("CONCATENATE", 1, .max) { a in
            var result = ""
            try a.forEachValue(0..<a.count) { value, _, _ in result += try Coercion.text(value) }
            return .text(result)
        }
        add("EXACT", 2, 2, lift: Params.all) { a in .boolean(try a.text(0).units == a.text(1).units) }
        for (name, ignoreCase) in [("FIND", false), ("SEARCH", true)] {
            add(name, 2, 3, lift: Params.all) { a in
                var needle = try a.text(0), haystack = try a.text(1)
                if ignoreCase {
                    needle = needle.lowercased()
                    haystack = haystack.lowercased()
                }
                let haystackUnits = haystack.units
                let start = try a.integer(2, default: 1)
                guard start >= 1, start <= haystackUnits.count + (needle.isEmpty ? 1 : 0) else {
                    throw FormulaErrors.value("Function \(name) parameter 3 value is \(start). It should be greater than or equal to 1 and less than or equal to \(haystackUnits.count).")
                }
                guard let index = String.find(needle.units, in: haystackUnits, from: start - 1) else {
                    throw FormulaErrors.value("In \(name) evaluation, cannot find '\(try a.text(0))' within '\(try a.text(1))'.")
                }
                return .number(Double(index + 1))
            }
        }
        add("FIXED", 1, 3, lift: Params.all) { a in
            let number = try a.number(0)
            let decimals = try a.integer(1, default: 2)
            let noCommas = try a.boolean(2, default: false)
            let rounded = Rounding.round(number, digits: decimals, mode: .halfAwayFromZero)
            var text = String(format: "%.\(min(max(decimals, 0), 30))f", abs(rounded))
            if !noCommas {
                let parts = text.split(separator: ".", omittingEmptySubsequences: false)
                var integer = String(parts[0])
                var grouped = ""
                while integer.count > 3 {
                    grouped = "," + integer.suffix(3) + grouped
                    integer.removeLast(3)
                }
                text = integer + grouped + (parts.count > 1 ? "." + parts[1] : "")
            }
            return .text(rounded < 0 ? "-" + text : text)
        }
        add("JOIN", 2, .max) { a in
            let delimiter = try a.text(0)
            var parts: [String] = []
            for index in 1..<a.count {
                for value in try a.matrix(index).values { parts.append(try Coercion.text(value)) }
            }
            return .text(parts.joined(separator: delimiter))
        }
        add("LEFT", 1, 2, lift: Params.all) { a in
            let units = try a.text(0).units
            let count = try a.nonNegative(1, default: 1)
            return .text(String(units: units.prefix(count)))
        }
        add("RIGHT", 1, 2, lift: Params.all) { a in
            let units = try a.text(0).units
            let count = try a.nonNegative(1, default: 1)
            return .text(String(units: units.suffix(count)))
        }
        add("MID", 3, 3, lift: Params.all) { a in
            let units = try a.text(0).units
            let start = try a.integer(1)
            guard start >= 1 else {
                throw FormulaErrors.value("Function MID parameter 2 value is \(start). It should be greater than or equal to 1.")
            }
            let length = try a.nonNegative(2)
            let lower = min(start - 1, units.count), upper = min(lower + length, units.count)
            return .text(String(units: units[lower..<upper]))
        }
        add("LEN", 1, 1, lift: Params.all) { a in .number(Double(try a.text(0).utf16.count)) }
        add("LOWER", 1, 1, lift: Params.all) { a in .text(try a.text(0).lowercased()) }
        add("UPPER", 1, 1, lift: Params.all) { a in .text(try a.text(0).uppercased()) }
        add("PROPER", 1, 1, lift: Params.all) { a in
            var result = ""
            var afterLetter = false
            for character in try a.text(0) {
                if character.isLetter {
                    result += afterLetter ? character.lowercased() : character.uppercased()
                    afterLetter = true
                } else {
                    result.append(character)
                    afterLetter = false
                }
            }
            return .text(result)
        }
        add("REGEXEXTRACT", 2, 2, lift: Params.all) { a in
            let text = try a.strictText(0), pattern = try a.strictText(1)
            let regex = try a.evaluator.regex(pattern, function: "REGEXEXTRACT")
            let nsText = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
                throw CellError(.notAvailable, "Function REGEXEXTRACT parameter 2 value \"\(pattern)\" does not match text of Function REGEXEXTRACT parameter 1 value \"\(text)\".")
            }
            func group(_ index: Int) -> CellValue {
                let range = match.range(at: index)
                return range.location == NSNotFound ? .text("") : .text(nsText.substring(with: range))
            }
            switch regex.numberOfCaptureGroups {
            case 0: return .value(group(0))
            case 1: return .value(group(1))
            default: return .array(ValueMatrix(row: (1...regex.numberOfCaptureGroups).map(group)))
            }
        }
        add("REGEXMATCH", 2, 2, lift: Params.all) { a in
            let text = try a.strictText(0), pattern = try a.strictText(1)
            let regex = try a.evaluator.regex(pattern, function: "REGEXMATCH")
            return .boolean(regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil)
        }
        add("REGEXREPLACE", 3, 3, lift: Params.all) { a in
            let text = try a.strictText(0), pattern = try a.strictText(1), replacement = try a.strictText(2)
            let regex = try a.evaluator.regex(pattern, function: "REGEXREPLACE")
            return .text(regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                        withTemplate: replacement))
        }
        add("REPLACE", 4, 4, lift: Params.all) { a in
            let units = try a.text(0).units
            let position = try a.integer(1)
            guard position >= 1 else {
                throw FormulaErrors.value("Function REPLACE parameter 2 value is \(position). It should be greater than or equal to 1.")
            }
            let length = try a.nonNegative(2)
            let lower = min(position - 1, units.count), upper = min(lower + length, units.count)
            return .text(String(units: units[..<lower]) + (try a.text(3)) + String(units: units[upper...]))
        }
        add("REPT", 2, 2, lift: Params.all) { a in
            let text = try a.text(0)
            let count = try a.nonNegative(1)
            guard count <= 32_000, text.utf16.count * count <= 32_000 else {
                throw FormulaErrors.value("Text result of REPT is longer than the limit of 32000 characters.")
            }
            return .text(String(repeating: text, count: count))
        }
        add("SPLIT", 2, 4, lift: Params.at(0, 1, 2, 3)) { a in
            let text = try a.text(0), delimiter = try a.text(1)
            guard !delimiter.isEmpty else { throw FormulaErrors.value("Function SPLIT parameter 2 value should be non-empty.") }
            let byEach = try a.boolean(2, default: true), removeEmpty = try a.boolean(3, default: true)
            var pieces: [String]
            if byEach {
                let separators = Set(delimiter)
                pieces = text.split(omittingEmptySubsequences: false) { separators.contains($0) }.map(String.init)
            } else {
                pieces = text.components(separatedBy: delimiter)
            }
            if removeEmpty { pieces = pieces.filter { !$0.isEmpty } }
            guard !pieces.isEmpty else { return .value(.empty) }
            let values = pieces.map { piece -> CellValue in
                let parsed = InputParser.parse(piece, currentFormat: nil)
                return parsed.formula == nil ? parsed.value : .text(piece)
            }
            return values.count == 1 ? .value(values[0]) : .array(ValueMatrix(row: values))
        }
        add("SUBSTITUTE", 3, 4, lift: Params.all) { a in
            let text = try a.text(0), search = try a.text(1), replacement = try a.text(2)
            guard !search.isEmpty else { return .text(text) }
            guard a.has(3) else { return .text(text.replacingOccurrences(of: search, with: replacement, options: .literal)) }
            let occurrence = try a.integer(3)
            guard occurrence >= 0 else {
                throw FormulaErrors.value("Function SUBSTITUTE parameter 4 value is \(occurrence). It should be greater than or equal to 0.")
            }
            guard occurrence > 0 else { return .text(text.replacingOccurrences(of: search, with: replacement, options: .literal)) }
            var searchStart = text.startIndex
            var seen = 0
            while let found = text.range(of: search, options: .literal, range: searchStart..<text.endIndex) {
                seen += 1
                if seen == occurrence { return .text(text.replacingCharacters(in: found, with: replacement)) }
                searchStart = found.upperBound
            }
            return .text(text)
        }
        add("T", 1, 1, lift: Params.all) { a in
            if case .text(let text) = try a.scalar(0) { return .text(text) }
            return .text("")
        }
        add("TEXT", 2, 2, lift: Params.all) { a in
            var value = try a.scalar(0)
            switch value {
            case .empty: value = .number(0)
            case .text(let text): if !text.isEmpty, let number = Coercion.number(fromText: text) { value = .number(number) }
            default: break
            }
            return .text(CellDisplay.text(for: value, pattern: try a.text(1)).text)
        }
        add("TEXTJOIN", 3, .max) { a in
            let delimiters = try a.matrix(0).values.map { try Coercion.text($0) }
            let ignoreEmpty = try a.boolean(1)
            var parts: [String] = []
            for index in 2..<a.count {
                for value in try a.matrix(index).values {
                    let text = try Coercion.text(value)
                    if ignoreEmpty, text.isEmpty { continue }
                    parts.append(text)
                }
            }
            var result = ""
            for (index, part) in parts.enumerated() {
                if index > 0 { result += delimiters[(index - 1) % delimiters.count] }
                result += part
            }
            return .text(result)
        }
        add("TRIM", 1, 1, lift: Params.all) { a in
            .text(try a.text(0).split(separator: " ").joined(separator: " "))
        }
        add("VALUE", 1, 1, lift: Params.all) { a in
            switch try a.scalar(0) {
            case .number(let number): return .number(number)
            case .boolean(let boolean): return .number(boolean ? 1 : 0)
            case .text(let text):
                guard let number = Coercion.number(fromText: text.trimmingCharacters(in: .whitespaces)) else {
                    throw FormulaErrors.value("VALUE parameter '\(text)' cannot be parsed to number.")
                }
                return .number(number)
            default: return .number(0)
            }
        }
    }
}
