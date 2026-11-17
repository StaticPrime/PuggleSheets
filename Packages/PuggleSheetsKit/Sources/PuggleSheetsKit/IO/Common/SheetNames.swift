import Foundation

/// Sheet names inside references.
enum SheetNames {
    /// The name as formulas write it: as is when it's letters, digits, underscores and periods (not
    /// starting with a digit or a period) and can't be read as a cell reference; otherwise quoted, with
    /// quotes doubled ('Q1 2026'!A1, 'It''s'!A1).
    static func quoted(_ name: String) -> String {
        if isPlain(name) { return name }
        return "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func isPlain(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard first == "_" || ("A"..."Z").contains(first) || ("a"..."z").contains(first) else { return false }
        guard name.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
            || $0 == "_" || $0 == "." }) else { return false }
        let upper = name.uppercased()
        if upper == "TRUE" || upper == "FALSE" { return false }
        // Names like "A1", "XFD2" or "R1C1" read as references.
        if XLSXReferencePart(name) != nil { return false }
        if upper.range(of: "^R[0-9]*C[0-9]*$", options: .regularExpression) != nil { return false }
        return true
    }
}

/// "$A$1:$B$2" forms of ranges.
extension CellRange {
    var absoluteA1: String {
        func absolute(_ address: CellAddress) -> String { "$" + CellAddress.columnName(address.column) + "$" + String(address.row + 1) }
        return isSingleCell ? absolute(start) : absolute(start) + ":" + absolute(end)
    }
}
