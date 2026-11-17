import Foundation

/// Formulas in OpenDocument files. OpenFormula (ODF 1.2+) writes references in brackets with a period
/// before the cell, separates arguments with ";" and array rows with "|":
/// `of:=SUM([.A1:.B2];['My sheet'.C3])` is our `=SUM(A1:B2,'My sheet'!C3)`. As in LibreOffice's files,
/// LET and LAMBDA parameters are `_xlpm.x` (`_xlop.x` when optional), and table references, which
/// OpenFormula doesn't have, are written as the cells they cover.
enum ODSFormula {
    typealias SheetSize = (String?) -> (rows: Int, columns: Int)

    // MARK: - Reading

    /// A `table:formula` value as one of our formulas; nil when there's no formula. Reads OpenFormula
    /// ("of:="), OpenOffice.org 2's syntax ("oooc:=", the same references) and Excel's ("msoxl:=").
    static func importing(_ attribute: String) -> String? {
        var text = Substring(attribute.trimmingCharacters(in: .whitespacesAndNewlines))
        var isExcel = false
        if let colon = text.firstIndex(of: ":"), colon > text.startIndex,
           text[..<colon].allSatisfy({ $0.isASCII && $0.isLetter }) {
            isExcel = text[..<colon].lowercased() == "msoxl"
            text = text[text.index(after: colon)...]
        }
        if text.hasPrefix("=") { text = text.dropFirst() }
        guard text.contains(where: { !$0.isWhitespace }) else { return nil }
        return isExcel ? XLSXFormula.importing(String(text)) : "=" + importExpression(String(text))
    }

    /// An OpenFormula expression (no prefix, no "=") in our syntax (no "=").
    static func importExpression(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        var arrayDepth = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\"":
                let end = XLSXFormulaToken.endOfQuote(scalars, from: index)
                result.append(contentsOf: scalars[index..<end])
                index = end
            case "[":
                let end = endOfReference(scalars, from: index)
                let inner = String(String.UnicodeScalarView(scalars[(index + 1)..<max(index + 1, end - 1)]))
                if let name = lambdaParameter(inner) {
                    // An optional LAMBDA parameter, as other grammars of LibreOffice write it.
                    result.append(contentsOf: "[\(name.name)]".unicodeScalars)
                } else {
                    result.append(contentsOf: importReference(inner).unicodeScalars)
                }
                index = end
            case "#":
                // Error values: their "!" isn't the intersection operator.
                let literal = errorLiteral(scalars, at: index)
                result.append(contentsOf: scalars[index..<(index + max(literal, 1))])
                index += max(literal, 1)
            case "{":
                arrayDepth += 1
                result.append(scalar)
                index += 1
            case "}":
                arrayDepth = max(0, arrayDepth - 1)
                result.append(scalar)
                index += 1
            case ";":
                // Arguments, and columns inside arrays.
                result.append(",")
                index += 1
            case "|":
                // Rows inside arrays.
                result.append(arrayDepth > 0 ? ";" : "|")
                index += 1
            case "!":
                // The intersection operator is a space in our syntax.
                result.append(" ")
                index += 1
            default:
                guard XLSXFormulaToken.startsWord(scalar) else {
                    result.append(scalar)
                    index += 1
                    continue
                }
                var end = index + 1
                while end < scalars.count, XLSXFormulaToken.continuesWord(scalars[end]) { end += 1 }
                let word = String(String.UnicodeScalarView(scalars[index..<end]))
                if scalar == "_", let parameter = lambdaParameter(word) {
                    // LET and LAMBDA parameters: "_xlpm.x", or "_xlop.x" for an optional one ("[x]" in our syntax).
                    let call = end < scalars.count && scalars[end] == "("
                    result.append(contentsOf: (parameter.isOptional && !call ? "[\(parameter.name)]" : parameter.name).unicodeScalars)
                    index = end
                    continue
                }
                if end < scalars.count, scalars[end] == "(" {
                    let upper = word.uppercased()
                    // TRUE() and FALSE() are how OpenFormula writes logical values.
                    if upper == "TRUE" || upper == "FALSE", end + 1 < scalars.count, scalars[end + 1] == ")" {
                        result.append(contentsOf: upper.unicodeScalars)
                        index = end + 2
                        continue
                    }
                    result.append(contentsOf: functionName(importing: word).unicodeScalars)
                } else {
                    result.append(contentsOf: word.unicodeScalars)
                }
                index = end
            }
        }
        return String(result)
    }

    /// "_xlpm.x" and "_xlop.x", LibreOffice's (and Excel's) spelling of a LET or LAMBDA parameter, the
    /// second an optional one; nil for other text.
    private static func lambdaParameter(_ text: String) -> (name: String, isOptional: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.utf8.count > 6, trimmed.utf8.first == UInt8(ascii: "_") else { return nil }
        let head = trimmed.prefix(6).lowercased()
        guard head == "_xlpm." || head == "_xlop." else { return nil }
        return (String(trimmed.dropFirst(6)), head == "_xlop.")
    }

    /// OpenFormula's error values.
    private static let errorLiterals = ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"].map { Array($0.unicodeScalars) }

    /// The length of the error value starting at `start` ("#DIV/0!"), or 0.
    private static func errorLiteral(_ scalars: [Unicode.Scalar], at start: Int) -> Int {
        for literal in errorLiterals where start + literal.count <= scalars.count {
            var matches = true
            for (offset, expected) in literal.enumerated() {
                let scalar = scalars[start + offset]
                let upper = (0x61...0x7A).contains(scalar.value) ? scalar.value - 0x20 : scalar.value
                if upper != expected.value {
                    matches = false
                    break
                }
            }
            if matches { return literal.count }
        }
        return 0
    }

    /// The index after the "]" closing the "[" at `start`; quoted sheet names may hold brackets.
    private static func endOfReference(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        while index < scalars.count {
            switch scalars[index] {
            case "'":
                index = XLSXFormulaToken.endOfQuote(scalars, from: index)
                continue
            case "]":
                return index + 1
            default:
                index += 1
            }
        }
        return scalars.count
    }

    /// The inside of a bracketed reference (".A1", "$Sheet2.A1:.B2", "'My sheet'.A:.A") in our syntax.
    static func importReference(_ inner: String) -> String {
        guard let reference = parseAddress(Substring(inner)) else { return "#REF!" }
        return reference.text
    }

    /// A parsed OpenDocument address: an optional sheet and one or two reference parts.
    struct Address {
        var sheet: String?
        var first: XLSXReferencePart
        var second: XLSXReferencePart?

        /// "Sheet1!$A$1:$B$2" in our syntax.
        var text: String {
            (sheet.map { SheetNames.quoted($0) + "!" } ?? "") + first.text + (second.map { ":" + $0.text } ?? "")
        }

        /// The cells covered, for cell references (not whole rows or columns).
        var range: CellRange? {
            guard first.kind == .cell else { return nil }
            let start = CellAddress(row: first.row, column: first.column)
            guard let second else { return CellRange(start) }
            guard second.kind == .cell else { return nil }
            return CellRange(start, CellAddress(row: second.row, column: second.column))
        }
    }

    /// Parses an address as references and attributes write it: "$Sheet1.$A$1", ".A1:.B2",
    /// "'My sheet'.A1:'My sheet'.B2", ".A:.C", ".3:.5". Nil for external, three-dimensional or broken ones.
    static func parseAddress(_ text: Substring) -> Address? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("#") else { return nil }
        let endpoints = splitOutsideQuotes(Substring(trimmed), at: ":")
        guard endpoints.count == 1 || endpoints.count == 2, let start = endpoint(endpoints[0]),
              let first = XLSXReferencePart(start.part) else { return nil }
        guard endpoints.count == 2 else {
            return first.kind == .cell ? Address(sheet: start.sheet, first: first) : nil
        }
        guard let end = endpoint(endpoints[1]), let second = XLSXReferencePart(end.part) else { return nil }
        // A second sheet other than the first makes a 3-D reference, which PuggleSheets doesn't have.
        if let other = end.sheet, let sheet = start.sheet, other.caseInsensitiveCompare(sheet) != .orderedSame { return nil }
        if end.sheet != nil, start.sheet == nil { return nil }
        guard first.kind == second.kind else { return nil }
        return Address(sheet: start.sheet, first: first, second: second)
    }

    /// Splits "$'My sheet'.$A$1" into its sheet ("My sheet"; nil for ".A1") and cell part ("$A$1").
    private static func endpoint(_ text: Substring) -> (sheet: String?, part: String)? {
        var rest = text
        if rest.hasPrefix(".") { return (nil, String(rest.dropFirst())) }
        if rest.hasPrefix("$") { rest = rest.dropFirst() }
        if rest.hasPrefix("'") {
            var name = ""
            var index = rest.index(after: rest.startIndex)
            while index < rest.endIndex {
                if rest[index] == "'" {
                    let next = rest.index(after: index)
                    if next < rest.endIndex, rest[next] == "'" {
                        name.append("'")
                        index = rest.index(after: next)
                        continue
                    }
                    guard next < rest.endIndex, rest[next] == "." else { return nil }
                    return (name, String(rest[rest.index(after: next)...]))
                }
                name.append(rest[index])
                index = rest.index(after: index)
            }
            return nil
        }
        guard let dot = rest.lastIndex(of: ".") else { return (nil, String(rest)) }
        let sheet = String(rest[..<dot])
        return (sheet.isEmpty ? nil : sheet, String(rest[rest.index(after: dot)...]))
    }

    private static func splitOutsideQuotes(_ text: Substring, at separator: Character) -> [Substring] {
        var parts: [Substring] = []
        var start = text.startIndex
        var inQuote = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "'" {
                inQuote.toggle()
            } else if character == separator, !inQuote {
                parts.append(text[start..<index])
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        parts.append(text[start...])
        return parts
    }

    /// A list of addresses separated by spaces (`calcext:target-range-address`), as ranges by sheet.
    static func parseAddressList(_ text: String) -> [(sheet: String?, range: CellRange)] {
        var result: [(sheet: String?, range: CellRange)] = []
        var current = ""
        var inQuote = false
        func flush() {
            if let address = parseAddress(Substring(current)), let range = address.range { result.append((address.sheet, range)) }
            current = ""
        }
        for character in text {
            if character == "'" { inQuote.toggle() }
            if character == " ", !inQuote {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }

    /// Function names LibreOffice writes with a prefix (Excel 2010+ functions are `COM.MICROSOFT.…`).
    private static func functionName(importing name: String) -> String {
        for prefix in ["COM.MICROSOFT.", "_XLFN._XLWS.", "_XLFN."] where name.uppercased().hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    // MARK: - Writing

    /// One of our formulas as a `table:formula` value; nil for an empty formula. Open-ended ranges
    /// ("A2:A"), which OpenFormula doesn't have, end at the last row or column of their sheet.
    static func exporting(_ formula: String, size: SheetSize) -> String? {
        exporting(formula, size: size, tables: nil, row: 0)?.text
    }

    /// The same, with structured references (Table1[Column]), which OpenFormula doesn't have, written as
    /// the cells they cover (for [#This Row], in row `row`), as LibreOffice writes them. `hasTableReferences`
    /// tells when there were any, so the formula as typed can be kept elsewhere.
    static func exporting(_ formula: String, size: SheetSize, tables: ODSTableReferences?, row: Int) -> (text: String, hasTableReferences: Bool)? {
        let text = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
        guard text.contains(where: { !$0.isWhitespace }) else { return nil }
        let expression = exportExpression(text, size: size, tables: tables, row: row)
        return ("of:=" + expression.text, expression.hasTableReferences)
    }

    /// Our formula text (no "=") as an OpenFormula expression (no prefix). Structured references stay as
    /// they are.
    static func exportExpression(_ text: String, size: SheetSize) -> String {
        exportExpression(text, size: size, tables: nil, row: 0).text
    }

    /// Our formula text (no "=") as an OpenFormula expression (no prefix): LET and LAMBDA parameters get
    /// LibreOffice's "_xlpm." prefix ("_xlop." for optional ones, "[b]" in our syntax), and with `tables`,
    /// structured references become the cells they cover.
    static func exportExpression(_ text: String, size: SheetSize, tables: ODSTableReferences?, row: Int) -> (text: String, hasTableReferences: Bool) {
        let tokens = XLSXFormulaToken.tokenize(text)
        let parameters = lambdaParameters(tokens)
        var result = ""
        var hasTableReferences = false
        var index = 0
        var braceDepth = 0
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if !parameters.names.isEmpty, parameters.names.contains(index) {
                result += "_xlpm." + token.text
                index += 1
                continue
            }
            if !parameters.optional.isEmpty, parameters.optional.contains(index), let name = optionalParameter(token.text) {
                result += "_xlop." + name
                index += 1
                continue
            }
            if let tables, token.kind == .word, let specifier = next, specifier.kind == .bracket {
                result += tables.reference(token.text, specifier.text, row: row)
                hasTableReferences = true
                index += 2
                continue
            }
            if let (reference, next) = reference(at: index, tokens, size: size) {
                result += reference
                index = next
                continue
            }
            switch token.kind {
            case .word:
                let upper = token.text.uppercased()
                if next?.isSymbol("(") == true {
                    result += microsoftFunctions.contains(upper) ? "COM.MICROSOFT." + token.text : token.text
                } else if upper == "TRUE" || upper == "FALSE", next?.isSymbol("!") != true {
                    result += upper + "()"
                } else {
                    result += token.text
                }
            case .symbol:
                switch token.text {
                case "{":
                    braceDepth += 1
                    result += "{"
                case "}":
                    braceDepth = max(0, braceDepth - 1)
                    result += "}"
                case ",":
                    result += ";"
                case ";":
                    result += braceDepth > 0 ? "|" : ";"
                default:
                    result += token.text
                }
            case .string, .quoted, .bracket:
                result += token.text
            }
            index += 1
        }
        return (result, hasTableReferences)
    }

    /// The parameters of LET and LAMBDA calls: the indexes of the word tokens that name them, where
    /// they're declared and where they're used inside the call, and of bracketed optional LAMBDA
    /// parameters ("[b]"). A name followed by "(" is a call of the lambda it holds, unless it's a function.
    private static func lambdaParameters(_ tokens: [XLSXFormulaToken]) -> (names: Set<Int>, optional: Set<Int>) {
        var calls: [Int] = []
        for index in tokens.indices.dropLast() where tokens[index].kind == .word && tokens[index + 1].isSymbol("(") {
            if isWord(tokens[index].text, "LET") || isWord(tokens[index].text, "LAMBDA") { calls.append(index) }
        }
        guard !calls.isEmpty else { return ([], []) }
        // The ")" closing each "(".
        var closing: [Int: Int] = [:]
        var open: [Int] = []
        for (index, token) in tokens.enumerated() where token.kind == .symbol {
            if token.text == "(" {
                open.append(index)
            } else if token.text == ")", let start = open.popLast() {
                closing[start] = index
            }
        }
        var names = Set<Int>(), optional = Set<Int>()
        for call in calls {
            let start = call + 1, end = closing[start] ?? tokens.count
            let isLet = isWord(tokens[call].text, "LET")
            // The arguments: commas split them outside parentheses and arrays.
            var arguments: [Range<Int>] = []
            var depth = 0, braces = 0, argumentStart = start + 1
            for index in (start + 1)..<end where tokens[index].kind == .symbol {
                switch tokens[index].text {
                case "(": depth += 1
                case ")": depth -= 1
                case "{": braces += 1
                case "}": braces -= 1
                case "," where depth == 0 && braces == 0:
                    arguments.append(argumentStart..<index)
                    argumentStart = index + 1
                default: break
                }
            }
            arguments.append(argumentStart..<end)
            // LET(name, value, …, calculation) and LAMBDA(parameter, …, calculation).
            var declared = Set<String>()
            for (position, argument) in arguments.enumerated().dropLast() where !isLet || position % 2 == 0 {
                let parts = argument.filter { !(tokens[$0].kind == .symbol && tokens[$0].text.allSatisfy(\.isWhitespace)) }
                guard parts.count == 1 else { continue }
                let token = tokens[parts[0]]
                if token.kind == .word, isParameterName(token.text) {
                    names.insert(parts[0])
                    declared.insert(token.text.uppercased())
                } else if !isLet, token.kind == .bracket, let name = optionalParameter(token.text) {
                    optional.insert(parts[0])
                    declared.insert(name.uppercased())
                }
            }
            guard !declared.isEmpty else { continue }
            for index in (start + 1)..<end where tokens[index].kind == .word && !names.contains(index) {
                guard declared.contains(tokens[index].text.uppercased()) else { continue }
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                // Not a sheet name ("x!A1"), a name on another sheet ("Sheet1!x") or a table ("x[Column]").
                if next?.isSymbol("!") == true || tokens[index - 1].isSymbol("!") || next?.kind == .bracket { continue }
                if next?.isSymbol("(") == true, knownFunctions.contains(tokens[index].text.uppercased()) { continue }
                names.insert(index)
            }
        }
        return (names, optional)
    }

    /// "x" in "[x]", an optional LAMBDA parameter.
    private static func optionalParameter(_ bracket: String) -> String? {
        guard bracket.hasPrefix("["), bracket.hasSuffix("]"), bracket.count > 2 else { return nil }
        let name = bracket.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return isParameterName(name) ? name : nil
    }

    /// A name a LET or LAMBDA can give: a letter or "_" first, and not a cell reference or logical value.
    private static func isParameterName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first == "_" || first.properties.isAlphabetic,
              text.unicodeScalars.allSatisfy({ XLSXFormulaToken.continuesWord($0) && $0 != "$" }) else { return false }
        if isWord(text, "TRUE") || isWord(text, "FALSE") { return false }
        return XLSXReferencePart(text)?.kind != .cell
    }

    /// Whether `text` is `upper` (ASCII capitals) in any case.
    private static func isWord(_ text: String, _ upper: String) -> Bool {
        text.utf8.count == upper.utf8.count && text.uppercased() == upper
    }

    /// Functions a LET name followed by "(" still calls.
    private static let knownFunctions: Set<String> = Set(FormulaEngine.functionNames.map { $0.uppercased() }).union(microsoftFunctions)

    /// A reference starting at token `index` (with its sheet, if any) as "[Sheet.A1:.B2]", and the index
    /// after it.
    private static func reference(at index: Int, _ tokens: [XLSXFormulaToken], size: SheetSize) -> (String, Int)? {
        var position = index
        var sheet: String?
        if position + 1 < tokens.count, tokens[position + 1].isSymbol("!"), tokens[position].kind == .word || tokens[position].kind == .quoted {
            sheet = tokens[position].kind == .quoted ? XLSXFormulaToken.unquoted(tokens[position].text) : tokens[position].text
            position += 2
        }
        guard position < tokens.count, tokens[position].kind == .word else { return nil }
        let following = position + 1 < tokens.count ? tokens[position + 1] : nil
        if following?.isSymbol("(") == true || following?.isSymbol("!") == true || following?.kind == .bracket { return nil }
        guard let first = XLSXReferencePart(tokens[position].text) else { return nil }
        var second: XLSXReferencePart?
        var end = position + 1
        if following?.isSymbol(":") == true, position + 2 < tokens.count, tokens[position + 2].kind == .word,
           let candidate = XLSXReferencePart(tokens[position + 2].text) {
            let after = position + 3 < tokens.count ? tokens[position + 3] : nil
            if after?.isSymbol("(") != true, after?.isSymbol("!") != true {
                second = candidate
                end = position + 3
            }
        }
        if var last = second, first.kind == .cell, last.kind != .cell {
            // An open-ended range, closed at its sheet's edge.
            let target = size(sheet)
            if last.kind == .column {
                last.row = min(max(target.rows, first.row + 1), XLSXLimits.rows) - 1
            } else {
                last.column = min(max(target.columns, first.column + 1), XLSXLimits.columns) - 1
            }
            last.kind = .cell
            second = last
        }
        if let second, second.kind != first.kind { return nil }
        if second == nil, first.kind != .cell { return nil }
        var text = "[" + (sheet.map(quotedSheet) ?? "") + "." + first.text
        if let second { text += ":." + second.text }
        return (text + "]", end)
    }

    /// A sheet name as OpenDocument addresses write it.
    static func quotedSheet(_ name: String) -> String {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0)
            || ("0"..."9").contains($0) || $0 == "_" } && !("0"..."9").contains(name.unicodeScalars.first!)
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// "Sheet1.A1:Sheet1.B2" (or with "$" everywhere) for attributes that name ranges.
    static func address(sheet: String, range: CellRange, absolute: Bool = false) -> String {
        let name = (absolute ? "$" : "") + quotedSheet(sheet)
        func cell(_ address: CellAddress) -> String {
            absolute ? "$" + CellAddress.columnName(address.column) + "$" + String(address.row + 1) : address.a1
        }
        if range.isSingleCell { return name + "." + cell(range.start) }
        return absolute ? "\(name).\(cell(range.start)):.\(cell(range.end))" : "\(name).\(cell(range.start)):\(name).\(cell(range.end))"
    }

    /// A reference in our syntax ("Sheet1!$A$1:$B$2", "A1") as an OpenDocument address; references
    /// without a sheet get `defaultSheet`.
    static func address(fromReference reference: String, defaultSheet: String) -> String? {
        let tokens = XLSXFormulaToken.tokenize(reference.trimmingCharacters(in: .whitespaces))
        var index = 0
        var sheet = defaultSheet
        if tokens.count >= 2, tokens[1].isSymbol("!"), tokens[0].kind == .word || tokens[0].kind == .quoted {
            sheet = tokens[0].kind == .quoted ? XLSXFormulaToken.unquoted(tokens[0].text) : tokens[0].text
            index = 2
        }
        guard index < tokens.count, tokens[index].kind == .word, let first = XLSXReferencePart(tokens[index].text) else { return nil }
        var text = "$" + quotedSheet(sheet) + "." + first.text
        if index + 3 == tokens.count, tokens[index + 1].isSymbol(":"), let second = XLSXReferencePart(tokens[index + 2].text),
           second.kind == first.kind {
            text += ":." + second.text
        } else if index + 1 != tokens.count || first.kind != .cell {
            return nil
        }
        return text
    }

    /// Functions OpenFormula files spell `COM.MICROSOFT.NAME`, as LibreOffice writes them (its ODFF names):
    /// Excel 2010+ additions (LET, LAMBDA and its helpers among them), and CEILING and FLOOR, whose plain
    /// OpenFormula versions round negative numbers differently. Functions with no OpenFormula
    /// name (QUERY, SORTN, SPARKLINE…) are written as they are.
    static let microsoftFunctions: Set<String> = [
        "AGGREGATE", "ARRAYTOTEXT", "BAHTTEXT", "BETA.DIST", "BETA.INV", "BINOM.DIST", "BINOM.INV", "BYCOL", "BYROW", "CEILING",
        "CEILING.MATH", "CEILING.PRECISE", "CHISQ.DIST", "CHISQ.DIST.RT", "CHISQ.INV", "CHISQ.INV.RT", "CHISQ.TEST", "CHOOSECOLS",
        "CHOOSEROWS", "CONCAT", "CONFIDENCE.NORM", "CONFIDENCE.T", "COVARIANCE.P", "COVARIANCE.S", "DROP", "ENCODEURL", "ERF.PRECISE",
        "ERFC.PRECISE", "EXPAND", "EXPON.DIST", "F.DIST.RT", "F.INV.RT", "F.TEST", "FILTER", "FILTERXML", "FLOOR", "FLOOR.MATH",
        "FLOOR.PRECISE", "FORECAST.ETS", "FORECAST.ETS.CONFINT", "FORECAST.ETS.SEASONALITY", "FORECAST.ETS.STAT", "FORECAST.LINEAR",
        "GAMMA.DIST", "GAMMA.INV", "GAMMALN.PRECISE", "HSTACK", "HYPGEOM.DIST", "IFS", "ISO.CEILING", "ISOMITTED", "LAMBDA", "LET",
        "LOGNORM.DIST", "LOGNORM.INV", "MAKEARRAY", "MAP", "MAXIFS", "MINIFS", "MODE.MULT", "MODE.SNGL", "NEGBINOM.DIST",
        "NETWORKDAYS.INTL", "NORM.DIST", "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "PERCENTILE.EXC", "PERCENTILE.INC",
        "PERCENTRANK.EXC", "PERCENTRANK.INC", "POISSON.DIST", "QUARTILE.EXC", "QUARTILE.INC", "RANDARRAY", "RANK.AVG", "RANK.EQ",
        "REDUCE", "SCAN", "SEQUENCE", "SORT", "SORTBY", "STDEV.P", "STDEV.S", "SWITCH", "T.DIST", "T.DIST.2T", "T.DIST.RT", "T.INV",
        "T.INV.2T", "T.TEST", "TAKE", "TEXTAFTER", "TEXTBEFORE", "TEXTJOIN", "TEXTSPLIT", "TOCOL", "TOROW", "UNIQUE", "VAR.P", "VAR.S",
        "VSTACK", "WEBSERVICE", "WEIBULL.DIST", "WORKDAY.INTL", "WRAPCOLS", "WRAPROWS", "XLOOKUP", "XMATCH", "Z.TEST",
    ]
}
