import Foundation

/// Formula text as SpreadsheetML stores it: without the leading "=", with `_xlfn.` before functions
/// newer than Excel 2007, and with shared formulas stored once for a block of cells.
enum XLSXFormula {
    /// "=" + a formula from a file, without Excel's `_xlfn.`, `_xlws.`, `_xlpm.` and `_xludf.` prefixes,
    /// and with table references as PuggleSheets writes them: `[#ALL]`, `[#DATA]`, `[#HEADERS]`, and
    /// `Table1[]` (the data rows) as `Table1[#DATA]`. `[#This Row]` and `[#Totals]` stay as they are.
    static func importing(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "[") }) else { return "=" + text }
        var result = "="
        for token in XLSXFormulaToken.tokenize(text) {
            switch token.kind {
            case .word: result += strippingPrefixes(token.text)
            case .bracket: result += token.text == "[]" ? "[#DATA]" : specialItems(token.text, uppercased: true)
            default: result += token.text
            }
        }
        return result
    }

    /// Excel's table reference keywords with Excel's casing in files ("#All") or PuggleSheets' ("#ALL").
    private static let specialItemNames = ["#All", "#Data", "#Headers", "#This Row", "#Totals"]

    /// A bracketed table reference with its keywords recased. Only the keywords PuggleSheets reads
    /// (#ALL, #DATA, #HEADERS) are uppercased; the others keep Excel's casing.
    static func specialItems(_ bracket: String, uppercased: Bool) -> String {
        guard bracket.contains("#") else { return bracket }
        var result = ""
        var rest = Substring(bracket)
        while let hash = rest.firstIndex(of: "#") {
            result += rest[..<hash]
            rest = rest[hash...]
            var matched = false
            for name in specialItemNames where rest.count >= name.count {
                let candidate = rest.prefix(name.count)
                let after = rest.dropFirst(name.count).first
                guard candidate.caseInsensitiveCompare(name) == .orderedSame, after == "]" || after == "," else { continue }
                let readable = ["#All", "#Data", "#Headers"].contains(name)
                result += uppercased ? (readable ? name.uppercased() : name) : name
                rest = rest.dropFirst(name.count)
                matched = true
                break
            }
            if !matched {
                result.append("#")
                rest = rest.dropFirst()
            }
        }
        return result + rest
    }

    /// A formula from a file with bare table names (Excel's way of saying "the data rows") written as
    /// `Table1[#DATA]`, since a bare name means the whole table in PuggleSheets. `tableNames` is lowercased.
    static func qualifyingTableNames(_ formula: String, tableNames: Set<String>) -> String {
        guard !tableNames.isEmpty else { return formula }
        let lowered = formula.lowercased()
        guard tableNames.contains(where: { lowered.contains($0) }) else { return formula }
        let tokens = XLSXFormulaToken.tokenize(formula)
        var result = ""
        for (index, token) in tokens.enumerated() {
            result += token.text
            guard token.kind == .word, tableNames.contains(token.text.lowercased()) else { continue }
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            let previous = index > 0 ? tokens[index - 1] : nil
            if next?.kind == .bracket || next?.isSymbol("(") == true || next?.isSymbol("!") == true || previous?.isSymbol("!") == true { continue }
            // A LET or LAMBDA name that happens to match a table's stays a name.
            if parameterTokens(tokens).contains(index) { continue }
            result += "[#DATA]"
        }
        return result
    }

    /// Excel's files spell out the "@" of `Table1[@Amount]`: `Table1[[#This Row],[Amount]]`.
    static func spellingOutThisRow(_ bracket: String) -> String {
        guard bracket.hasPrefix("[@"), bracket.hasSuffix("]"), bracket.count >= 3 else { return bracket }
        let inner = bracket.dropFirst(2).dropLast()
        if inner.allSatisfy(\.isWhitespace) { return "[#This Row]" }
        return "[[#This Row]," + (inner.hasPrefix("[") ? String(inner) : "[" + inner + "]") + "]"
    }

    /// A formula as a file stores it: no "=", `_xlfn.` (or `_xlfn._xlws.`) before newer functions,
    /// and open-ended ranges ("A2:A", "B3:3"), which Excel can't read, closed at the
    /// last row or column of their sheet. `size` gives a sheet's row and column count by name (nil
    /// for the formula's own sheet). Nil for a formula with nothing after the "=".
    ///
    /// Also: LET and LAMBDA parameter names get Excel's `_xlpm.`; table references take Excel's casing
    /// (`[#All]`, `[#Data]`, `[#Headers]`) and spelling (`[@Amount]` as `[[#This Row],[Amount]]`); and a
    /// bare table name, which means the whole table in PuggleSheets but only its data rows in Excel, is
    /// written `Table1[#All]`. `tableNames` is lowercased.
    static func exporting(_ formula: String, size: (_ sheet: String?) -> (rows: Int, columns: Int) = { _ in
        (Sheet.defaultRowCount, Sheet.defaultColumnCount)
    }, tableNames: Set<String> = []) -> String? {
        let text = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
        guard text.contains(where: { !$0.isWhitespace }) else { return nil }
        let tokens = XLSXFormulaToken.tokenize(text)
        let parameters = parameterTokens(tokens)
        var result = ""
        var sheet: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token.kind == .bracket {
                result += specialItems(spellingOutThisRow(token.text), uppercased: false)
                index += 1
                continue
            }
            guard token.kind == .word || token.kind == .quoted else {
                result += token.text
                index += 1
                continue
            }
            if parameters.contains(index) {
                result += "_xlpm." + token.text
                index += 1
                continue
            }
            if token.kind == .word, sheet == nil, !tableNames.isEmpty, tableNames.contains(token.text.lowercased()),
               next?.kind != .bracket, next?.isSymbol("(") != true, next?.isSymbol("!") != true {
                result += token.text + "[#All]"
                index += 1
                continue
            }
            if next?.isSymbol("!") == true {
                sheet = token.kind == .quoted ? XLSXFormulaToken.unquoted(token.text) : token.text
                result += token.text
                index += 1
                continue
            }
            defer { sheet = nil }
            if token.kind == .word, next?.isSymbol("(") == true {
                let name = token.text.uppercased()
                if worksheetFunctions.contains(name) {
                    result += "_xlfn._xlws."
                } else if newerFunctions.contains(name) {
                    result += "_xlfn."
                }
            } else if token.kind == .word, next?.isSymbol(":") == true, index + 2 < tokens.count, tokens[index + 2].kind == .word,
                      let start = XLSXReferencePart(token.text), start.kind == .cell,
                      let end = XLSXReferencePart(tokens[index + 2].text), end.kind != .cell {
                let target = size(sheet)
                let lastRow = min(max(target.rows, start.row + 1), XLSXLimits.rows)
                let lastColumn = min(max(target.columns, start.column + 1), XLSXLimits.columns) - 1
                var closed = end
                closed.kind = .cell
                if end.kind == .column {
                    closed.row = lastRow - 1
                } else {
                    closed.column = lastColumn
                }
                result += token.text + ":" + closed.text
                index += 3
                continue
            }
            result += token.text
            index += 1
        }
        return result
    }

    /// The word tokens naming LET and LAMBDA parameters inside their calls, which Excel writes `_xlpm.x`:
    /// LET's names (every other argument before the last), LAMBDA's parameters (every argument before the last).
    static func parameterTokens(_ tokens: [XLSXFormulaToken]) -> Set<Int> {
        var result = Set<Int>()
        for (index, token) in tokens.enumerated() where token.kind == .word && (token.text.utf8.count == 3 || token.text.utf8.count == 6) {
            let function = token.text.uppercased()
            guard function == "LET" || function == "LAMBDA", index + 1 < tokens.count, tokens[index + 1].isSymbol("(") else { continue }
            var depth = 0, start = index + 2, end = tokens.count
            var arguments: [Range<Int>] = []
            for position in (index + 1)..<tokens.count {
                let current = tokens[position]
                if current.isSymbol("(") || current.isSymbol("{") {
                    depth += 1
                } else if current.isSymbol(")") || current.isSymbol("}") {
                    depth -= 1
                    if depth == 0 {
                        arguments.append(start..<position)
                        end = position
                        break
                    }
                } else if current.isSymbol(","), depth == 1 {
                    arguments.append(start..<position)
                    start = position + 1
                }
            }
            var names = Set<String>()
            for (number, argument) in arguments.enumerated() where number < arguments.count - 1 && (function == "LAMBDA" || number % 2 == 0) {
                let words = argument.filter { !(tokens[$0].kind == .symbol && tokens[$0].text.allSatisfy(\.isWhitespace)) }
                guard words.count == 1, tokens[words[0]].kind == .word else { continue }
                names.insert(tokens[words[0]].text.lowercased())
            }
            guard !names.isEmpty else { continue }
            for position in (index + 2)..<end where tokens[position].kind == .word && names.contains(tokens[position].text.lowercased()) {
                if position + 1 < tokens.count, tokens[position + 1].isSymbol("!") { continue }
                result.insert(position)
            }
        }
        return result
    }

    private static func strippingPrefixes(_ word: String) -> String {
        var result = Substring(word)
        while result.first == "_" {
            let head = result.prefix(7).lowercased()
            if head.hasPrefix("_xlfn.") || head.hasPrefix("_xlws.") || head.hasPrefix("_xlpm.") {
                result = result.dropFirst(6)
            } else if head == "_xludf." {
                result = result.dropFirst(7)
            } else {
                break
            }
        }
        return String(result)
    }

    /// Functions Excel files spell `_xlfn._xlws.NAME`.
    static let worksheetFunctions: Set<String> = ["FILTER", "SORT"]

    /// Functions added after Excel 2007, which files spell `_xlfn.NAME`. Other functions
    /// (SPLIT, JOIN, REGEXMATCH, ARRAYFORMULA, …) aren't here: they're written as is.
    static let newerFunctions: Set<String> = [
        "ACOT", "ACOTH", "AGGREGATE", "ANCHORARRAY", "ARABIC", "ARRAYTOTEXT", "BASE", "BETA.DIST", "BETA.INV", "BINOM.DIST",
        "BINOM.DIST.RANGE", "BINOM.INV", "BITAND", "BITLSHIFT", "BITOR", "BITRSHIFT", "BITXOR", "BYCOL", "BYROW",
        "CEILING.MATH", "CEILING.PRECISE", "CHISQ.DIST", "CHISQ.DIST.RT", "CHISQ.INV", "CHISQ.INV.RT", "CHISQ.TEST",
        "CHOOSECOLS", "CHOOSEROWS", "COMBINA", "CONCAT", "CONFIDENCE.NORM", "CONFIDENCE.T", "COT", "COTH", "COVARIANCE.P",
        "COVARIANCE.S", "CSC", "CSCH", "DAYS", "DECIMAL", "DETECTLANGUAGE", "DROP", "ECMA.CEILING", "ENCODEURL", "ERF.PRECISE",
        "ERFC.PRECISE", "EXPAND", "EXPON.DIST", "F.DIST", "F.DIST.RT", "F.INV", "F.INV.RT", "F.TEST", "FIELDVALUE", "FILTERXML",
        "FLOOR.MATH", "FLOOR.PRECISE", "FORECAST.ETS", "FORECAST.ETS.CONFINT", "FORECAST.ETS.SEASONALITY", "FORECAST.ETS.STAT",
        "FORECAST.LINEAR", "FORMULATEXT", "GAMMA", "GAMMA.DIST", "GAMMA.INV", "GAMMALN.PRECISE", "GAUSS", "GROUPBY", "HSTACK",
        "HYPGEOM.DIST", "IFNA", "IFS", "IMAGE", "IMCOSH", "IMCOT", "IMCSC", "IMCSCH", "IMSEC", "IMSECH", "IMSINH", "IMTAN",
        "ISFORMULA", "ISO.CEILING", "ISOMITTED", "ISOWEEKNUM", "LAMBDA", "LET", "LOGNORM.DIST", "LOGNORM.INV", "MAKEARRAY",
        "MAP", "MAXIFS", "MINIFS", "MODE.MULT", "MODE.SNGL", "MUNIT", "NEGBINOM.DIST", "NETWORKDAYS.INTL", "NORM.DIST",
        "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "NUMBERVALUE", "PDURATION", "PERCENTILE.EXC", "PERCENTILE.INC", "PERCENTOF",
        "PERCENTRANK.EXC", "PERCENTRANK.INC", "PERMUTATIONA", "PHI", "PIVOTBY", "POISSON.DIST", "QUARTILE.EXC", "QUARTILE.INC",
        "RANDARRAY", "RANK.AVG", "RANK.EQ", "REDUCE", "REGEXEXTRACT", "REGEXREPLACE", "REGEXTEST", "RRI", "SCAN", "SEC", "SECH",
        "SEQUENCE", "SHEET", "SHEETS", "SINGLE", "SKEW.P", "SORTBY", "STDEV.P", "STDEV.S", "STOCKHISTORY", "SWITCH", "T.DIST",
        "T.DIST.2T", "T.DIST.RT", "T.INV", "T.INV.2T", "T.TEST", "TAKE", "TEXTAFTER", "TEXTBEFORE", "TEXTJOIN", "TEXTSPLIT",
        "TOCOL", "TOROW", "TRANSLATE", "TRIMRANGE", "UNICHAR", "UNICODE", "UNIQUE", "VALUETOTEXT", "VAR.P", "VAR.S", "VSTACK",
        "WEBSERVICE", "WEIBULL.DIST", "WORKDAY.INTL", "WRAPCOLS", "WRAPROWS", "XLOOKUP", "XMATCH", "XOR", "Z.TEST",
    ]

    /// Moves the relative parts of every reference `rows` down and `columns` across, as Excel derives
    /// each cell of a shared formula from its first cell. See `XLSXShiftableFormula`.
    static func shifting(_ formula: String, rows: Int, columns: Int) -> String {
        guard rows != 0 || columns != 0 else { return formula }
        return XLSXShiftableFormula(formula).shifted(rows: rows, columns: columns)
    }
}

/// A formula split once into fixed text and references, so the many cells of a shared formula can be
/// derived quickly. Absolute parts ($A$1) stay put; references pushed off the sheet become #REF!.
/// String literals, sheet names, function names and structured references are left alone.
struct XLSXShiftableFormula {
    private enum Piece {
        case text(String)
        case cell(XLSXReferencePart)
        case range(XLSXReferencePart, XLSXReferencePart)
    }

    private var pieces: [Piece] = []

    init(_ formula: String) {
        let tokens = XLSXFormulaToken.tokenize(formula)
        var literal = ""
        func flush() {
            if !literal.isEmpty {
                pieces.append(.text(literal))
                literal = ""
            }
        }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            // Sheet names ("Sheet1!"), functions ("LOG10("), tables ("T1[") aren't references.
            guard token.kind == .word, next?.isSymbol("!") != true, next?.isSymbol("(") != true, next?.kind != .bracket else {
                literal += token.text
                index += 1
                continue
            }
            if next?.isSymbol(":") == true, index + 2 < tokens.count, tokens[index + 2].kind == .word {
                let second = tokens[index + 2]
                if index + 3 < tokens.count, tokens[index + 3].isSymbol("!") {
                    // A 3-D reference's sheet span, "Sheet1:Sheet3!".
                    literal += token.text + ":" + second.text
                    index += 3
                    continue
                }
                if let first = XLSXReferencePart(token.text), let last = XLSXReferencePart(second.text), first.kind == last.kind {
                    flush()
                    pieces.append(.range(first, last))
                    index += 3
                    continue
                }
            }
            if let reference = XLSXReferencePart(token.text), reference.kind == .cell {
                flush()
                pieces.append(.cell(reference))
            } else {
                literal += token.text
            }
            index += 1
        }
        flush()
    }

    func shifted(rows: Int, columns: Int) -> String {
        var result = ""
        for piece in pieces {
            switch piece {
            case .text(let text):
                result += text
            case .cell(let reference):
                result += reference.shifted(rows: rows, columns: columns)?.text ?? "#REF!"
            case .range(let first, let last):
                if let movedFirst = first.shifted(rows: rows, columns: columns), let movedLast = last.shifted(rows: rows, columns: columns) {
                    result += movedFirst.text + ":" + movedLast.text
                } else {
                    result += "#REF!"
                }
            }
        }
        return result
    }
}

/// One side of a reference: a cell ("$B$2"), a whole column ("B") or a whole row ("2").
struct XLSXReferencePart: Equatable {
    enum Kind { case cell, column, row }

    var kind: Kind
    var column = 0
    var row = 0
    var absoluteColumn = false
    var absoluteRow = false

    init?(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        let end = scalars.count
        var leadingDollar = false
        if index < end, scalars[index] == "$" {
            leadingDollar = true
            index += 1
        }
        var letters = 0
        var column = 0
        while index < end, let value = XLSXReferencePart.letterValue(scalars[index]) {
            column = column * 26 + value
            letters += 1
            index += 1
            if letters > 3 { return nil }
        }
        var rowDollar = false
        if letters > 0, index < end, scalars[index] == "$" {
            rowDollar = true
            index += 1
        }
        var digits = 0
        var row = 0
        while index < end, scalars[index].value >= 0x30, scalars[index].value <= 0x39 {
            row = row * 10 + Int(scalars[index].value - 0x30)
            digits += 1
            index += 1
            if digits > 7 { return nil }
        }
        guard index == end else { return nil }
        switch (letters > 0, digits > 0) {
        case (true, true):
            guard column <= XLSXLimits.columns, row >= 1, row <= XLSXLimits.rows else { return nil }
            kind = .cell
            self.column = column - 1
            self.row = row - 1
            absoluteColumn = leadingDollar
            absoluteRow = rowDollar
        case (true, false):
            guard !rowDollar, column <= XLSXLimits.columns else { return nil }
            kind = .column
            self.column = column - 1
            absoluteColumn = leadingDollar
        case (false, true):
            guard row >= 1, row <= XLSXLimits.rows else { return nil }
            kind = .row
            self.row = row - 1
            absoluteRow = leadingDollar
        case (false, false):
            return nil
        }
    }

    private static func letterValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x41...0x5A: Int(scalar.value - 0x40)
        case 0x61...0x7A: Int(scalar.value - 0x60)
        default: nil
        }
    }

    func shifted(rows: Int, columns: Int) -> XLSXReferencePart? {
        var moved = self
        if kind != .row, !absoluteColumn { moved.column += columns }
        if kind != .column, !absoluteRow { moved.row += rows }
        guard moved.column >= 0, moved.column < XLSXLimits.columns, moved.row >= 0, moved.row < XLSXLimits.rows else { return nil }
        return moved
    }

    var text: String {
        switch kind {
        case .cell: (absoluteColumn ? "$" : "") + CellAddress.columnName(column) + (absoluteRow ? "$" : "") + String(row + 1)
        case .column: (absoluteColumn ? "$" : "") + CellAddress.columnName(column)
        case .row: (absoluteRow ? "$" : "") + String(row + 1)
        }
    }
}

/// A piece of formula text: a "word" (name, function, reference or number), a string literal, a quoted
/// sheet name, a bracketed part (structured reference, external workbook) or a single other character.
struct XLSXFormulaToken {
    enum Kind { case word, string, quoted, bracket, symbol }

    var kind: Kind
    var text: String

    func isSymbol(_ symbol: String) -> Bool {
        kind == .symbol && text == symbol
    }

    static func tokenize(_ formula: String) -> [XLSXFormulaToken] {
        let scalars = Array(formula.unicodeScalars)
        var tokens: [XLSXFormulaToken] = []
        var index = 0
        func token(_ kind: Kind, _ start: Int, _ end: Int) -> XLSXFormulaToken {
            XLSXFormulaToken(kind: kind, text: String(String.UnicodeScalarView(scalars[start..<end])))
        }
        while index < scalars.count {
            let scalar = scalars[index]
            let end: Int
            let kind: Kind
            switch scalar {
            case "\"":
                end = endOfQuote(scalars, from: index)
                kind = .string
            case "'":
                end = endOfQuote(scalars, from: index)
                kind = .quoted
            case "[":
                end = endOfBracket(scalars, from: index)
                kind = .bracket
            default:
                if startsWord(scalar) {
                    var wordEnd = index + 1
                    while wordEnd < scalars.count, continuesWord(scalars[wordEnd]) { wordEnd += 1 }
                    end = wordEnd
                    kind = .word
                } else {
                    end = index + 1
                    kind = .symbol
                }
            }
            tokens.append(token(kind, index, end))
            index = end
        }
        return tokens
    }

    /// "'It''s'" → "It's".
    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }

    static func startsWord(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: true
        case 0x5F, 0x5C, 0x24: true // _ \ $
        case 0x80...: scalar.properties.isAlphabetic
        default: false
        }
    }

    static func continuesWord(_ scalar: Unicode.Scalar) -> Bool {
        startsWord(scalar) || scalar == "." || (scalar.value >= 0x80 && scalar.properties.numericType != nil)
    }

    /// The index after the quote that closes the one at `start`; doubled quotes are escapes.
    static func endOfQuote(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        let quote = scalars[start]
        var index = start + 1
        while index < scalars.count {
            if scalars[index] == quote {
                if index + 1 < scalars.count, scalars[index + 1] == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return scalars.count
    }

    /// The index after the bracket that closes the one at `start`, allowing nesting ("[[#This Row],[A]]")
    /// and apostrophe escapes inside structured references.
    static func endOfBracket(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var depth = 0
        var index = start
        while index < scalars.count {
            switch scalars[index] {
            case "'":
                index += 1
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index + 1 }
            default:
                break
            }
            index += 1
        }
        return scalars.count
    }
}
