import Foundation

/// A cell position, zero-based: row 0, column 0 is A1.
public struct CellAddress: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// Row-major order: A1, B1, …, A2.
    public static func < (lhs: CellAddress, rhs: CellAddress) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
    }

    /// "B3".
    public var a1: String { CellAddress.columnName(column) + String(row + 1) }
    public var description: String { a1 }

    /// Parses "B3", "$B$3" or "b3".
    public init?(a1 text: some StringProtocol) {
        var letters = ""
        var digits = ""
        for character in text where character != "$" {
            if character.isLetter, digits.isEmpty {
                letters.append(character)
            } else if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard let column = CellAddress.columnIndex(letters), let number = Int(digits), number >= 1 else { return nil }
        self.init(row: number - 1, column: column)
    }

    public func offsetBy(rows: Int = 0, columns: Int = 0) -> CellAddress {
        CellAddress(row: row + rows, column: column + columns)
    }

    /// "A", …, "Z", "AA", "AB", …
    public static func columnName(_ index: Int) -> String {
        var scalars: [Unicode.Scalar] = []
        var remaining = index + 1
        while remaining > 0 {
            let letter = (remaining - 1) % 26
            scalars.append(Unicode.Scalar(UInt8(65 + letter)))
            remaining = (remaining - 1) / 26
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    /// 0 for "A" (or "a"); nil for anything that isn't one to three letters.
    public static func columnIndex(_ name: some StringProtocol) -> Int? {
        guard !name.isEmpty, name.unicodeScalars.count <= 3 else { return nil }
        var index = 0
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 65...90: index = index * 26 + Int(scalar.value - 64)
            case 97...122: index = index * 26 + Int(scalar.value - 96)
            default: return nil
            }
        }
        return index - 1
    }
}

/// A rectangular block of cells. `start` is the top-left cell and `end` the bottom-right one, inclusive.
public struct CellRange: Hashable, Sendable, CustomStringConvertible {
    public private(set) var start: CellAddress
    public private(set) var end: CellAddress

    /// The block spanned by two corners, in any order.
    public init(_ corner: CellAddress, _ otherCorner: CellAddress) {
        start = CellAddress(row: min(corner.row, otherCorner.row), column: min(corner.column, otherCorner.column))
        end = CellAddress(row: max(corner.row, otherCorner.row), column: max(corner.column, otherCorner.column))
    }

    public init(_ address: CellAddress) {
        start = address
        end = address
    }

    public init(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        start = CellAddress(row: rows.lowerBound, column: columns.lowerBound)
        end = CellAddress(row: rows.upperBound, column: columns.upperBound)
    }

    public var rows: ClosedRange<Int> { start.row...end.row }
    public var columns: ClosedRange<Int> { start.column...end.column }
    public var rowCount: Int { end.row - start.row + 1 }
    public var columnCount: Int { end.column - start.column + 1 }
    public var cellCount: Int { rowCount * columnCount }
    public var isSingleCell: Bool { start == end }

    public func contains(_ address: CellAddress) -> Bool {
        rows.contains(address.row) && columns.contains(address.column)
    }

    public func contains(_ range: CellRange) -> Bool {
        contains(range.start) && contains(range.end)
    }

    public func intersects(_ other: CellRange) -> Bool {
        intersection(other) != nil
    }

    public func intersection(_ other: CellRange) -> CellRange? {
        let top = max(start.row, other.start.row), bottom = min(end.row, other.end.row)
        let left = max(start.column, other.start.column), right = min(end.column, other.end.column)
        guard top <= bottom, left <= right else { return nil }
        return CellRange(rows: top...bottom, columns: left...right)
    }

    /// The smallest range containing both.
    public func union(_ other: CellRange) -> CellRange {
        CellRange(rows: min(start.row, other.start.row)...max(end.row, other.end.row),
                  columns: min(start.column, other.start.column)...max(end.column, other.end.column))
    }

    public func offsetBy(rows: Int = 0, columns: Int = 0) -> CellRange {
        CellRange(start.offsetBy(rows: rows, columns: columns), end.offsetBy(rows: rows, columns: columns))
    }

    /// "A1:B2", or "A1" for a single cell.
    public var a1: String { isSingleCell ? start.a1 : "\(start.a1):\(end.a1)" }
    public var description: String { a1 }

    /// Parses "A1:B2" (corners in any order) or "A1".
    public init?(a1 text: some StringProtocol) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let first = CellAddress(a1: parts[0]) else { return nil }
        guard parts.count == 2 else {
            self.init(first)
            return
        }
        guard let second = CellAddress(a1: parts[1]) else { return nil }
        self.init(first, second)
    }

    /// Every address in row-major order. Avoid on huge ranges; prefer `Sheet.cells(in:)`.
    public var addresses: [CellAddress] {
        var result: [CellAddress] = []
        result.reserveCapacity(cellCount)
        for row in rows {
            for column in columns { result.append(CellAddress(row: row, column: column)) }
        }
        return result
    }
}
