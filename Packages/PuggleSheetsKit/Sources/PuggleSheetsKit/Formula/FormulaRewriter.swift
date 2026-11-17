import Foundation

/// Rewrites the references in formula text (with its leading "="). Text outside references is kept
/// exactly as typed; references that can no longer point anywhere become #REF!.
public enum FormulaRewriter {
    /// Shifts relative references, as when a formula is copied, pasted or filled `rows` down and
    /// `columns` across. Absolute parts ($A$1) stay put.
    public static func translate(_ formula: String, rows: Int, columns: Int) -> String {
        guard rows != 0 || columns != 0 else { return formula }
        return rewrite(formula) { reference, original in
            var moved = reference
            func shift(_ part: inout ReferencePart) -> Bool {
                if let row = part.row, !part.rowAbsolute { part.row = row + rows }
                if let column = part.column, !part.columnAbsolute { part.column = column + columns }
                return (part.row ?? 0) >= 0 && (part.column ?? 0) >= 0
                    && (part.row ?? 0) < ReferencePart.maxRows && (part.column ?? 0) < ReferencePart.maxColumns
            }
            guard shift(&moved.first) else { return "#REF!" }
            if moved.second != nil, !shift(&moved.second!) { return "#REF!" }
            guard moved != reference else { return nil }
            return original.prefix + moved.partsText
        }
    }

    /// Follows rows, columns or cells inserted or deleted in the sheet named `changedSheet`. `formulaSheet`
    /// is the sheet that holds the formula (unqualified references point there). For cell shifts, only
    /// references lying entirely inside the shifted band move (as `StructuralChange.map` moves cells and
    /// ranges); whole rows and columns count as inside only when they fit in the band.
    public static func adjust(_ formula: String, for change: StructuralChange, inSheet changedSheet: String,
                              formulaSheet: String) -> String {
        rewrite(formula) { reference, original in
            guard sameSheet(reference.sheet ?? formulaSheet, changedSheet) else { return nil }
            guard let adjusted = adjusted(reference, change) else { return "#REF!" }
            guard adjusted != reference else { return nil }
            return original.prefix + adjusted.partsText
        }
    }

    /// Follows cells cut from `range` in `sheet` and pasted `rows` down and `columns` across in
    /// `destinationSheet`: references that lie entirely inside `range` move with them.
    public static func move(_ formula: String, range: CellRange, inSheet sheet: String, rows: Int, columns: Int,
                            toSheet destinationSheet: String, formulaSheet: String) -> String {
        rewrite(formula) { reference, original in
            guard sameSheet(reference.sheet ?? formulaSheet, sheet), let covered = reference.cellRange,
                  range.contains(covered) else { return nil }
            var moved = reference
            func shift(_ part: inout ReferencePart) -> Bool {
                part.row = part.row.map { $0 + rows }
                part.column = part.column.map { $0 + columns }
                return (part.row ?? 0) >= 0 && (part.column ?? 0) >= 0
            }
            guard shift(&moved.first) else { return "#REF!" }
            if moved.second != nil, !shift(&moved.second!) { return "#REF!" }
            let prefix: String
            if let named = reference.sheet, sameSheet(named, destinationSheet) {
                prefix = original.prefix
            } else if sameSheet(destinationSheet, formulaSheet) {
                prefix = ""
            } else {
                prefix = quotedSheetName(destinationSheet) + "!"
            }
            guard moved != reference || prefix != original.prefix else { return nil }
            return prefix + moved.partsText
        }
    }

    /// Follows a sheet rename, quoting the new name where needed ('My sheet'!A1).
    public static func renameSheet(_ formula: String, from oldName: String, to newName: String) -> String {
        rewrite(formula) { reference, original in
            guard let named = reference.sheet, sameSheet(named, oldName) else { return nil }
            let text = quotedSheetName(newName) + "!" + original.parts
            return text == original.prefix + original.parts ? nil : text
        }
    }

    /// References to a deleted sheet become #REF!.
    public static func removeSheet(_ formula: String, named name: String) -> String {
        rewrite(formula) { reference, _ in
            guard let named = reference.sheet, sameSheet(named, name) else { return nil }
            return "#REF!"
        }
    }

    // MARK: Helpers

    /// A sheet name as references write it: quoted when it isn't a plain identifier, starts with a digit
    /// or looks like a cell reference ('My sheet', 'It''s', '2024', 'A1').
    static func quotedSheetName(_ name: String) -> String {
        needsQuotes(name) ? "'" + name.replacingOccurrences(of: "'", with: "''") + "'" : name
    }

    private static func needsQuotes(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return true }
        let isLetter: (Unicode.Scalar) -> Bool = { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
        guard isLetter(first) || first == "_" else { return true }
        guard name.unicodeScalars.allSatisfy({ isLetter($0) || $0 == "_" || ($0.value >= 48 && $0.value <= 57) }) else { return true }
        if ReferencePart.parse(name) != nil { return true }
        let upper = name.uppercased()
        if upper == "TRUE" || upper == "FALSE" { return true }
        // R1C1-style names such as R2C3.
        if upper.range(of: "^R[0-9]*C[0-9]*$", options: .regularExpression) != nil { return true }
        return false
    }

    private static func sameSheet(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// The reference after a structural change, or nil when it was deleted.
    private static func adjusted(_ reference: ReferenceSyntax, _ change: StructuralChange) -> ReferenceSyntax? {
        if let band = change.band {
            // Cells shifted down or up move within their columns, sideways within their rows: a reference
            // follows only when everything it spans across the shift lies inside the band.
            let across = change.affectsRows ? reference.columnBounds : reference.rowBounds
            guard let across, let upper = across.upper, band.contains(across.lower), band.contains(upper) else {
                return reference
            }
        }
        var result = reference
        let rows = change.affectsRows
        func get(_ part: ReferencePart) -> (Int?, Bool) {
            rows ? (part.row, part.rowAbsolute) : (part.column, part.columnAbsolute)
        }
        func set(_ part: inout ReferencePart, _ value: Int, _ absolute: Bool) {
            if rows {
                part.row = value
                part.rowAbsolute = absolute
            } else {
                part.column = value
                part.columnAbsolute = absolute
            }
        }
        let (a, aAbsolute) = get(reference.first)
        guard let second = reference.second else {
            guard let a else { return result }
            guard let mapped = change.map(a) else { return nil }
            set(&result.first, mapped, aAbsolute)
            return result
        }
        let (b, bAbsolute) = get(second)
        switch (a, b) {
        case (let x?, let y?):
            guard let span = change.map(min(x, y), max(x, y)) else { return nil }
            let (lowerAbsolute, upperAbsolute) = x <= y ? (aAbsolute, bAbsolute) : (bAbsolute, aAbsolute)
            set(&result.first, span.lowerBound, lowerAbsolute)
            set(&result.second!, span.upperBound, upperAbsolute)
        case (let x?, nil):
            guard let span = change.map(x, ReferencePart.maxRows * 100) else { return nil }
            set(&result.first, span.lowerBound, aAbsolute)
        case (nil, let y?):
            guard let span = change.map(y, ReferencePart.maxRows * 100) else { return nil }
            set(&result.second!, span.lowerBound, bAbsolute)
        case (nil, nil):
            break
        }
        return result
    }

    /// Renames a table in structured references ("Table1[Sales]" → "Sales2024[Sales]") and where the name
    /// stands alone ("=SUM(Table1)"). Names match without regard to case. Call it for every formula when a
    /// table is renamed.
    public static func renameTable(_ formula: String, from oldName: String, to newName: String) -> String {
        rewriteTokens(formula) { tokens, index, units in
            switch tokens[index].kind {
            case .tableReference(let token) where sameName(token.table, oldName):
                return "\(newName)[\(token.spec)]"
            case .word(let word) where sameName(word, oldName):
                guard isStandaloneName(tokens, index, units: units) else { return nil }
                return newName
            default:
                return nil
            }
        }
    }

    /// Renames a column in structured references to `table` ("Table1[Sales]" → "Table1[Revenue]"), for
    /// when its header is edited. Names match without regard to case.
    public static func renameTableColumn(_ formula: String, table: String, from oldName: String, to newName: String) -> String {
        rewriteTokens(formula) { tokens, index, _ in
            guard case .tableReference(let token) = tokens[index].kind, sameName(token.table, table) else { return nil }
            let name = token.table, spec = token.spec
            if !spec.contains("[") {
                return sameName(spec.trimmingCharacters(in: .whitespaces), oldName) ? "\(name)[\(newName)]" : nil
            }
            // Replace each bracketed item naming the column.
            var result = "", changed = false
            var rest = Substring(spec)
            while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
                result += rest[..<open]
                let item = rest[rest.index(after: open)..<close]
                if sameName(String(item), oldName) {
                    result += "[\(newName)]"
                    changed = true
                } else {
                    result += rest[open...close]
                }
                rest = rest[rest.index(after: close)...]
            }
            result += rest
            return changed ? "\(name)[\(result)]" : nil
        }
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Whether the word at `index` is a name on its own: not a function, sheet name or cell reference.
    static func isStandaloneName(_ tokens: [FormulaToken], _ index: Int, units: [UInt16]) -> Bool {
        let next = index + 1 < tokens.count ? tokens[index + 1].kind : nil
        if next == .leftParen || next == .bang { return false }
        if index > 0, tokens[index - 1].kind == .bang { return false }
        return FormulaParser.matchReference(tokens, at: index, units: units) == nil
    }

    /// Replaces tokens for which `transform` returns new text.
    static func rewriteTokens(_ formula: String, _ transform: ([FormulaToken], Int, [UInt16]) -> String?) -> String {
        let units = Array(formula.utf16)
        guard units.first == 0x3D else { return formula }
        let (tokens, _) = FormulaLexer.tokenize(units, from: 1)
        var result: [UInt16] = []
        var last = 0
        for index in tokens.indices {
            guard let replacement = transform(tokens, index, units) else { continue }
            result += units[last..<tokens[index].start]
            result += replacement.utf16
            last = tokens[index].end
        }
        guard last > 0 else { return formula }
        result += units[last...]
        return String(units: result)
    }

    /// Text of a reference as typed: the sheet prefix ("Sheet1!") and the parts ("A1:B2").
    struct OriginalText {
        var prefix: String
        var parts: String
    }

    /// Replaces each reference for which `transform` returns new text.
    static func rewrite(_ formula: String, _ transform: (ReferenceSyntax, OriginalText) -> String?) -> String {
        let units = Array(formula.utf16)
        guard units.first == 0x3D else { return formula }
        let (tokens, _) = FormulaLexer.tokenize(units, from: 1)
        var result: [UInt16] = []
        var last = 0
        for reference in FormulaParser.references(in: tokens, units: units) {
            let original = OriginalText(prefix: String(units: units[reference.span.lowerBound..<reference.partsStart]),
                                        parts: String(units: units[reference.partsStart..<reference.span.upperBound]))
            guard let replacement = transform(reference, original) else { continue }
            result += units[last..<reference.span.lowerBound]
            result += replacement.utf16
            last = reference.span.upperBound
        }
        guard last > 0 else { return formula }
        result += units[last...]
        return String(units: result)
    }
}

/// A reference found in formula text, for coloring ranges while a formula is edited.
public struct FormulaReference: Hashable, Sendable {
    /// Position of the reference text in the formula, in UTF-16 units (as NSString counts).
    public var location: Int
    public var length: Int
    /// The sheet named in the reference, if any.
    public var sheet: String?
    /// Rows and columns covered; nil means every row (as in "A:B") or every column (as in "2:5").
    /// Open-ended references ("A2:A") end at `FormulaReference.openEnd`.
    public var rows: ClosedRange<Int>?
    public var columns: ClosedRange<Int>?

    /// For a structured reference ("Table1[Sales]") or a table's name, the table's name.
    public var table: String?

    /// The upper bound of open-ended references such as "A2:A" (to the last row).
    public static let openEnd = Int(Int32.max)

    public init(location: Int, length: Int, sheet: String?, rows: ClosedRange<Int>?, columns: ClosedRange<Int>?, table: String? = nil) {
        self.location = location
        self.length = length
        self.sheet = sheet
        self.rows = rows
        self.columns = columns
        self.table = table
    }

    /// The covered cells in a sheet of the given size (clipped to the grid).
    public func range(rowCount: Int, columnCount: Int) -> CellRange {
        func clip(_ span: ClosedRange<Int>?, _ count: Int) -> ClosedRange<Int> {
            let last = max(0, count - 1)
            guard let span else { return 0...last }
            let lower = min(max(span.lowerBound, 0), last)
            return lower...max(lower, min(span.upperBound, last))
        }
        return CellRange(rows: clip(rows, rowCount), columns: clip(columns, columnCount))
    }
}

public enum FormulaReferences {
    /// Every reference in `formula` as `references(in:)` finds them, plus structured table references and
    /// table names, resolved in `workbook` to the table's sheet and cells. Unknown tables and columns are left out.
    public static func references(in formula: String, workbook: Workbook) -> [FormulaReference] {
        var result = references(in: formula)
        let units = Array(formula.utf16)
        guard units.first == 0x3D, !workbook.sheets.isEmpty else { return result }
        let (tokens, _) = FormulaLexer.tokenize(units, from: 1)
        let evaluator = Evaluator(workbook: workbook, sheetIndex: 0, address: CellAddress(row: 0, column: 0), now: Date())
        for (index, token) in tokens.enumerated() {
            let resolved: FormulaValue
            let table: String
            switch token.kind {
            case .tableReference(let token):
                guard let syntax = TableReferenceSyntax(table: token.table, spec: token.spec) else { continue }
                resolved = evaluator.resolveTable(syntax)
                table = token.table
            case .word(let word) where FormulaRewriter.isStandaloneName(tokens, index, units: units) && workbook.namedRange(word) == nil:
                guard let found = workbook.table(named: word) else { continue }
                resolved = .reference(SheetReference(sheet: found.sheet, range: found.table.range))
                table = word
            default:
                continue
            }
            guard case .reference(let reference) = resolved else { continue }
            result.append(FormulaReference(location: token.start, length: token.end - token.start,
                                           sheet: workbook.sheets[reference.sheet].name, rows: reference.range.rows,
                                           columns: reference.range.columns, table: table))
        }
        return result.sorted { $0.location < $1.location }
    }

    /// Every cell, range, whole-row and whole-column reference in `formula`, in order of appearance.
    public static func references(in formula: String) -> [FormulaReference] {
        let units = Array(formula.utf16)
        guard units.first == 0x3D else { return [] }
        let (tokens, _) = FormulaLexer.tokenize(units, from: 1)
        return FormulaParser.references(in: tokens, units: units).map { reference in
            func span(_ bounds: (lower: Int, upper: Int?)?) -> ClosedRange<Int>? {
                bounds.map { $0.lower...($0.upper ?? FormulaReference.openEnd) }
            }
            return FormulaReference(location: reference.span.lowerBound, length: reference.span.count, sheet: reference.sheet,
                                    rows: span(reference.rowBounds), columns: span(reference.columnBounds))
        }
    }
}
