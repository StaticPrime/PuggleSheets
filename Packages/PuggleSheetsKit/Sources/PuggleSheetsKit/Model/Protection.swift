import Foundation

/// Data ▸ Protect sheets and ranges: cells that warn before they change, or that can't be changed
/// until the protection is removed.
public struct ProtectedRange: Identifiable, Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case range(CellRange)
        /// The whole sheet, except these ranges.
        case sheet(except: [CellRange])
    }

    public let id: UUID
    public var scope: Scope
    public var description: String
    /// "Show a warning when editing this range" (true), or "Restrict who can edit this range" (false),
    /// which in PuggleSheets refuses edits until the protection is removed.
    public var warningOnly: Bool

    public init(id: UUID = UUID(), scope: Scope, description: String = "", warningOnly: Bool = true) {
        self.id = id
        self.scope = scope
        self.description = description
        self.warningOnly = warningOnly
    }

    public func covers(_ address: CellAddress) -> Bool {
        switch scope {
        case .range(let range): range.contains(address)
        case .sheet(let except): !except.contains { $0.contains(address) }
        }
    }

    /// Whether any cell of `range` is protected.
    public func covers(anyOf range: CellRange) -> Bool {
        switch scope {
        case .range(let protected):
            return protected.intersects(range)
        case .sheet(let except):
            // Protected unless the exceptions cover every cell of `range`.
            guard !except.isEmpty else { return true }
            if except.contains(where: { $0.contains(range) }) { return false }
            if range.cellCount > 100_000 { return true }
            for row in range.rows {
                for column in range.columns where covers(CellAddress(row: row, column: column)) { return true }
            }
            return false
        }
    }
}
