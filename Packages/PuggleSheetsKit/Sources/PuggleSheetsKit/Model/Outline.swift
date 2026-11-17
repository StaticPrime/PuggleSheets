import Foundation

/// Data ▸ Group rows or columns: a band of rows (or columns) that collapses to a + button. Groups can
/// sit inside one another.
public struct OutlineGroup: Hashable, Sendable {
    /// Row or column indexes.
    public var range: ClosedRange<Int>
    public var isCollapsed: Bool

    public init(range: ClosedRange<Int>, isCollapsed: Bool = false) {
        self.range = range
        self.isCollapsed = isCollapsed
    }
}

extension Array where Element == OutlineGroup {
    /// The rows (or columns) hidden by collapsed groups.
    public var collapsedIndexes: Set<Int> {
        var result = Set<Int>()
        for group in self where group.isCollapsed { result.formUnion(group.range) }
        return result
    }

    /// How deeply each group sits: 0 for outermost groups, 1 for groups inside one, and so on.
    public func depth(of group: OutlineGroup) -> Int {
        filter { $0 != group && $0.range.lowerBound <= group.range.lowerBound && $0.range.upperBound >= group.range.upperBound }.count
    }

    /// The number of outline levels in use.
    public var maximumDepth: Int {
        isEmpty ? 0 : (map { depth(of: $0) }.max() ?? 0) + 1
    }
}
