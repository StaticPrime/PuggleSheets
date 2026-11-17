import Foundation

/// Data ▸ Filter views: a saved filter with a name. Opening one hides rows only in the window that
/// shows it; the sheet's own filter and data stay as they are.
public struct FilterView: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var range: CellRange
    /// Criteria by sheet column, as in `SheetFilter`.
    public var criteria: [Int: FilterCriterion]

    public init(id: UUID = UUID(), name: String, range: CellRange, criteria: [Int: FilterCriterion] = [:]) {
        self.id = id
        self.name = name
        self.range = range
        self.criteria = criteria
    }

    /// The view as a sheet filter, for evaluating which rows it hides.
    public var asFilter: SheetFilter { SheetFilter(range: range, criteria: criteria) }
}
