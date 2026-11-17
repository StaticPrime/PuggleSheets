import Foundation

/// Row or column groups as nested `table:table-row-group` or `table:table-column-group` elements, as
/// LibreOffice writes its outlines: a collapsed group has `table:display="false"`, and its rows or
/// columns `table:visibility="collapse"`.
struct ODSOutline {
    /// The groups that nest (a group overlapping another without being inside it can't be written),
    /// inside the grid, outermost first.
    private(set) var groups: [OutlineGroup] = []
    /// Where groups start, and where they end (the index after their last row or column).
    private(set) var boundaries = Set<Int>()
    /// The rows or columns inside collapsed groups, as sorted, separate runs.
    private var collapsedRuns: [ClosedRange<Int>] = []
    private let element: String
    private var open: [OutlineGroup] = []
    private var next = 0

    init(_ groups: [OutlineGroup], limit: Int, element: String) {
        self.element = element
        var stack: [OutlineGroup] = []
        let clipped = groups.compactMap { group -> OutlineGroup? in
            guard group.range.lowerBound >= 0, group.range.lowerBound < limit else { return nil }
            return OutlineGroup(range: group.range.lowerBound...min(group.range.upperBound, limit - 1), isCollapsed: group.isCollapsed)
        }.sorted { ($0.range.lowerBound, -$0.range.upperBound) < ($1.range.lowerBound, -$1.range.upperBound) }
        for group in clipped {
            while let top = stack.last, top.range.upperBound < group.range.lowerBound { stack.removeLast() }
            if let top = stack.last, group.range.upperBound > top.range.upperBound { continue }
            stack.append(group)
            self.groups.append(group)
            boundaries.insert(group.range.lowerBound)
            boundaries.insert(group.range.upperBound + 1)
        }
        collapsedRuns = ODSOutline.merged(self.groups.filter(\.isCollapsed).map(\.range))
    }

    /// Ranges merged into sorted, separate runs.
    static func merged(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    var isEmpty: Bool { groups.isEmpty }

    /// Whether a row or column is inside a collapsed group.
    func isCollapsed(_ index: Int) -> Bool {
        guard !collapsedRuns.isEmpty else { return false }
        var low = 0, high = collapsedRuns.count
        while low < high {
            let middle = (low + high) / 2
            if collapsedRuns[middle].upperBound < index { low = middle + 1 } else { high = middle }
        }
        return low < collapsedRuns.count && collapsedRuns[low].contains(index)
    }

    /// Closes the groups ending before `position` and opens those starting there.
    mutating func writeTags(at position: Int, into xml: inout XMLWriter) {
        while let top = open.last, top.range.upperBound < position {
            xml.raw("</\(element)>")
            open.removeLast()
        }
        while next < groups.count, groups[next].range.lowerBound == position {
            xml.raw(groups[next].isCollapsed ? "<\(element) table:display=\"false\">" : "<\(element)>")
            open.append(groups[next])
            next += 1
        }
    }

    /// Closes the groups still open.
    mutating func closeAll(into xml: inout XMLWriter) {
        while !open.isEmpty {
            xml.raw("</\(element)>")
            open.removeLast()
        }
    }
}
