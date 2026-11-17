import Foundation

/// Row and column groups as Excel outlines: each row (or column) carries its depth, `outlineLevel`
/// 1–7; members of collapsed groups are hidden; and the summary row after a collapsed group (the
/// column after, for columns) is marked `collapsed`.
enum XLSXOutline {
    static let maximumLevel = 7

    struct Levels {
        /// Index → outline level, 1–7.
        var levels: [Int: Int] = [:]
        /// Summary rows (or columns) marked collapsed.
        var collapsedMarks: Set<Int> = []
        /// Indexes hidden by collapsed groups.
        var hidden: Set<Int> = []

        var maximum: Int { levels.values.max() ?? 0 }
    }

    /// The levels of `groups` below `limit`. Nesting deeper than Excel's 7 levels is clamped to 7.
    static func levels(_ groups: [OutlineGroup], limit: Int) -> Levels {
        var result = Levels()
        for group in groups {
            let lower = max(0, group.range.lowerBound), upper = min(group.range.upperBound, limit - 1)
            guard lower <= upper else { continue }
            for index in lower...upper { result.levels[index, default: 0] += 1 }
        }
        for (index, level) in result.levels where level > maximumLevel { result.levels[index] = maximumLevel }
        for group in groups where group.isCollapsed {
            let lower = max(0, group.range.lowerBound), upper = min(group.range.upperBound, limit - 1)
            guard lower <= upper else { continue }
            result.hidden.formUnion(lower...upper)
            // Excel reads `collapsed` on a summary row as "the group one level deeper beside it is
            // collapsed": marked only where that names this group.
            let level = min(groups.depth(of: group) + 1, maximumLevel)
            let summary = upper + 1
            if summary < limit, (result.levels[summary] ?? 0) == level - 1 { result.collapsedMarks.insert(summary) }
        }
        return result
    }

    /// Groups from outline levels: every run of indexes at level k or deeper is a group at depth k,
    /// collapsed when its summary row (after it, or before it when `summaryAfter` is false) is marked.
    static func groups(levels: [Int: Int], collapsedMarks: Set<Int>, summaryAfter: Bool) -> [OutlineGroup] {
        let indexes = levels.keys.sorted()
        var result: [OutlineGroup] = []
        func group(_ range: ClosedRange<Int>, level: Int) -> OutlineGroup {
            let summary = summaryAfter ? range.upperBound + 1 : range.lowerBound - 1
            return OutlineGroup(range: range, isCollapsed: collapsedMarks.contains(summary) && (levels[summary] ?? 0) == level - 1)
        }
        for level in 1...maximumLevel {
            var start: Int?, previous = Int.min
            for index in indexes where (levels[index] ?? 0) >= level {
                if let first = start {
                    if index == previous + 1 {
                        previous = index
                        continue
                    }
                    result.append(group(first...previous, level: level))
                }
                start = index
                previous = index
            }
            if let first = start { result.append(group(first...previous, level: level)) }
        }
        return result
    }
}
